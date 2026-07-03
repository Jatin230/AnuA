import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/remote_input.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/input_model.dart';
import 'package:get/get.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_hbb/debug_agent_log.dart';

class MobileControlPage extends StatefulWidget {
  const MobileControlPage({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _MobileControlPageState createState() => _MobileControlPageState();
}

class _MobileControlPageState extends State<MobileControlPage> {
  String? _connectionUrl;
  String? _nostrUri;
  String? _nostrError;
  bool _nostrLoading = false;
  int _qrTab = 0; // 0 = LAN, 1 = Nostr
  String? _error;
  bool _loading = false;
  final TextEditingController _manualIpController = TextEditingController();
  final List<Map<String, String>> _registeredDevices = [];
  final Map<String, FFI> _activeSessions = {};
  final Map<String, String> _sessionStatus = {};
  bool _sidebarExpanded = true;

  bool _serverReady = false;
  bool _rustAlive = false;
  String? _listenerError;
  List<String> _allLocalIps = [];
  String? _selectedLanIp;
  Timer? _listenerProbe;
  final _overlayKeyState = OverlayKeyState();

  @override
  void initState() {
    super.initState();
    _setupEventListener();
    unawaited(_ensureDirectServerEnabled());
    _generateConnectionUrl();
    _startListenerProbe();
  }

  /// The Rust backend may emit direct_server_status before this page opens.
  /// Probe localhost:21118 so we don't miss the ready state.
  void _startListenerProbe() {
    _listenerProbe?.cancel();
    _probeDirectListener();
    _listenerProbe = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_serverReady) {
        _listenerProbe?.cancel();
        return;
      }
      _probeDirectListener();
    });
  }

  Future<void> _probeDirectListener() async {
    const port = 21118;
    for (final host in ['127.0.0.1', if (_selectedLanIp != null) _selectedLanIp!]) {
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(milliseconds: 800),
        );
        await socket.close();
        if (!mounted || _serverReady) return;
        setState(() {
          _serverReady = true;
          _listenerError = null;
        });
        return;
      } catch (_) {}
    }
  }

  Future<void> _ensureDirectServerEnabled() async {
    try {
      if (bind.mainGetOptionSync(key: 'direct-server') != 'Y') {
        await bind.mainSetOption(key: 'direct-server', value: 'Y');
      }
      if (bind.mainGetOptionSync(key: 'stop-service') == 'Y') {
        await bind.mainSetOption(key: 'stop-service', value: '');
      }
    } catch (e) {
      debugPrint('Failed to ensure direct server options: $e');
    }
  }

  @override
  void dispose() {
    _nostrWatchdog?.cancel();
    _nostrAutoRefresh?.cancel();
    _listenerProbe?.cancel();
    _imageTimeout?.cancel();
    _manualIpController.dispose();
    for (final ffi in _activeSessions.values) {
      ffi.close();
    }
    _activeSessions.clear();
    super.dispose();
  }

  void _setupEventListener() {
    platformFFI.registerEventHandler(
        'direct_server_status', 'mobile_control_page_status', (evt) async {
      final data = evt['data']?.toString() ?? '';
      if (!mounted) return;
      if (data == 'started') {
        setState(() {
          _serverReady = true;
          _listenerError = null;
        });
        _listenerProbe?.cancel();
      } else if (data.startsWith('error:')) {
        setState(() {
          _serverReady = false;
          _listenerError = data.substring(6);
        });
      }
    });

    platformFFI.registerEventHandler(
        'rust_heartbeat', 'mobile_control_page_heartbeat', (evt) async {
      if (mounted) {
        setState(() {
          _rustAlive = true;
        });
      }
    });

    platformFFI.registerEventHandler(
        'mobile_device_registered', 'mobile_control_page', (evt) async {
      try {
        final device = Map<String, String>.from(json.decode(evt['data']));
        if (!mounted) return;
        setState(() {
          _registeredDevices.removeWhere((d) => _deviceKey(d) == _deviceKey(device));
          _registeredDevices.add(device);
        });
        _showDeviceActionDialog(device);
      } catch (e) {
        debugPrint('Failed to parse registration: $e');
      }
    });

    // Nostr WebRTC events
    platformFFI.registerEventHandler(
        'on_nostr_webrtc_ready', 'mobile_control_page_nostr', (evt) async {
      if (!mounted) return;
      _nostrWatchdog?.cancel();
      setState(() {
        _nostrUri = _compactNostrQrUri(evt['uri'] ?? '');
        _nostrError = null;
        _nostrLoading = false;
      });
    });

    platformFFI.registerEventHandler(
        'on_nostr_webrtc_error', 'mobile_control_page_nostr_err', (evt) async {
      if (!mounted) return;
      _nostrWatchdog?.cancel();
      setState(() {
        _nostrError = evt['error'] ?? 'Unknown error';
        _nostrLoading = false;
      });
    });
  }

  void _showDeviceActionDialog(Map<String, String> device) {
    final hasPassword = (device['temp_password'] ?? '').isNotEmpty;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('New Mobile Device: ${device['name']}'),
        content: Text(hasPassword
            ? 'A mobile device has just scanned your QR code. What would you like to do?'
            : 'A mobile device has just scanned your QR code.\n\n'
              'Tip: Make sure the Anuvadini app is running on the phone before tapping "Control Phone".'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _connectDevice(device);
            },
            child: const Text('Control Phone'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _authorizePhone(device['id'] ?? _deviceKey(device));
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Authorize Phone to Control Me'),
          ),
        ],
      ),
    );
  }

  Future<void> _generateConnectionUrl() async {
    setState(() {
      _loading = true;
      _error = null;
      _allLocalIps = [];
    });
    try {
      final interfaces = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      for (var interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.contains('wsl') ||
            name.contains('virtual') ||
            name.contains('vbox') ||
            name.contains('vmware') ||
            name.contains('vethernet') ||
            name.contains('hyper-v') ||
            name.contains('hyperv') ||
            name.contains('docker') ||
            name.contains('npcap') ||
            name.contains('bluetooth') ||
            name.contains('tun') ||
            name.contains('tap') ||
            name.contains('host-only') ||
            name.contains('loopback')) {
          continue;
        }
        for (var addr in interface.addresses) {
          if (!addr.isLoopback && _isUsableLanIp(addr.address)) {
            _allLocalIps.add(addr.address);
          }
        }
      }

      if (_allLocalIps.isEmpty) {
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (!addr.isLoopback && _isUsableLanIp(addr.address)) {
              _allLocalIps.add(addr.address);
            }
          }
        }
      }

      if (_allLocalIps.isEmpty) {
        setState(() {
          _error = 'No network IP found. Connect to Wi-Fi.';
          _loading = false;
        });
        return;
      }

      // Prefer the Rust-detected default-route IP over interface enumeration.
      final rustIp = bind.mainGetOptionSync(key: 'local-ip-addr');
      if (rustIp.isNotEmpty &&
          _isUsableLanIp(rustIp) &&
          !_allLocalIps.contains(rustIp)) {
        _allLocalIps.insert(0, rustIp);
      }

      final localIp = _selectedLanIp ??
          (rustIp.isNotEmpty && _isUsableLanIp(rustIp) && _allLocalIps.contains(rustIp)
              ? rustIp
              : _pickBestLocalIp(_allLocalIps));

      final url = 'anuvadini://direct-tcp:${localIp}_port_21118';
      setState(() {
        _connectionUrl = url;
        _selectedLanIp = localIp;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
    // Nostr QR is generated lazily when the user first taps the Nostr chip.
  }

  /// Skip virtual/emulator/link-local ranges that phones cannot reach.
  bool _isUsableLanIp(String ip) {
    if (ip.startsWith('169.254.')) return false;
    // Hyper-V / Genymotion / some emulators
    if (ip.startsWith('192.168.199.')) return false;
    return true;
  }

  String _pickBestLocalIp(List<String> ips) {
    int score(String ip) {
      if (ip.startsWith('192.168.1.')) return 0;
      if (ip.startsWith('192.168.0.')) return 1;
      if (ip.startsWith('192.168.')) return 2;
      if (ip.startsWith('10.')) return 3;
      if (ip.startsWith('172.')) return 4;
      return 5;
    }

    ips.sort((a, b) => score(a).compareTo(score(b)));
    return ips.first;
  }

  String localIpFromUrl(String url) {
    final hostPart = url.replaceFirst('anuvadini://direct-tcp:', '');
    final match = RegExp(r'^(.+)_port_\d+$').firstMatch(hostPart);
    return match?.group(1) ?? hostPart;
  }

  /// WebRTC SDPs must not go in the QR — too dense to scan. Relay fetch only.
  String _compactNostrQrUri(String uri) {
    final parsed = Uri.tryParse(uri);
    if (parsed == null || !parsed.queryParameters.containsKey('offer')) {
      return uri;
    }
    return 'nostr-webrtc://${parsed.host}#${parsed.fragment}';
  }

  Timer? _nostrWatchdog;
  Timer? _nostrAutoRefresh;
  // Whether the user has ever explicitly requested Nostr QR generation.
  bool _nostrRequested = false;

  /// Called when the user taps the Nostr chip to switch to the Nostr tab.
  void _onNostrTabSelected() {
    setState(() => _qrTab = 1);
    // Start generation on first open, or retry automatically after a previous error.
    if (!_nostrRequested ||
        (_nostrError != null && _nostrUri == null && !_nostrLoading)) {
      _generateNostrUri();
    }
    // NOTE: We intentionally do NOT auto-refresh. The background WebRTC session
    // waits up to 120 s for the phone's answer. Auto-refreshing every 90 s was
    // killing active sessions by overwriting PENDING_ANSWER_TX and causing
    // "WebRTC answer channel was dropped". The user can tap "New Offer" to retry.
  }

  Future<void> _generateNostrUri() async {
    // Cancel any outstanding watchdog from a previous attempt.
    _nostrWatchdog?.cancel();
    if (!mounted) return;
    setState(() {
      _nostrLoading = true;
      _nostrError = null;
      _nostrUri = null;
      _nostrRequested = true;
    });

    // Await the FFI call so any immediate bridge errors are surfaced.
    try {
      await bind.startNostrWebrtcHost();
    } catch (e) {
      if (!mounted) return;
      _nostrWatchdog?.cancel();
      setState(() {
        _nostrLoading = false;
        _nostrError = 'Failed to start Nostr host: $e';
      });
      return;
    }

    // Safety watchdog: if Rust hasn't responded within 30 s, surface an error.
    _nostrWatchdog = Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      if (_nostrLoading) {
        setState(() {
          _nostrLoading = false;
          _nostrError = 'Timed out generating offer. Tap "New Offer" to retry.';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Overlay(
      key: _overlayKeyState.key,
      initialEntries: [
        OverlayEntry(builder: (context) => _buildScaffold()),
      ],
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile Command Center'),
        backgroundColor: MyTheme.accent,
      ),
      body: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: _sidebarExpanded ? 360 : 56,
            child: _buildSidebar(),
          ),
          VerticalDivider(width: 1, color: Colors.grey[300]),
          Expanded(child: _buildDeviceDashboard()),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    if (!_sidebarExpanded) {
      return Align(
        alignment: Alignment.topCenter,
        child: IconButton(
          icon: const Icon(Icons.chevron_right),
          onPressed: () => setState(() => _sidebarExpanded = true),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _sidebarExpanded = false),
              ),
              const Text('Setup', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          _buildSetupCard(),
        ],
      ),
    );
  }

  Widget _buildSetupCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          children: [
            const Icon(Icons.qr_code_scanner, size: 28, color: MyTheme.accent),
            const SizedBox(height: 6),
            const Text('Pair New Device', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            // Tab selector: LAN vs Nostr
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('LAN'),
                  selected: _qrTab == 0,
                  onSelected: (_) => setState(() => _qrTab = 0),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Nostr'),
                  selected: _qrTab == 1,
                  onSelected: (_) => _onNostrTabSelected(),
                  selectedColor: Colors.deepPurple.withOpacity(0.2),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_qrTab == 0) ...[
              if (_loading) const CircularProgressIndicator(),
              if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
              if (_connectionUrl != null) ...[
                QrImageView(
                  data: _connectionUrl!,
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 4),
                Text('Same Wi-Fi required', style: TextStyle(fontSize: 10, color: Colors.grey[600])),
                if (!_serverReady)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _listenerError != null
                          ? 'Port 21118 unavailable: $_listenerError'
                          : 'Waiting for listener on port 21118…',
                      style: TextStyle(
                        fontSize: 10,
                        color: _listenerError != null ? Colors.red : Colors.orange[800],
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                if (_connectionUrl != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${_selectedLanIp ?? localIpFromUrl(_connectionUrl!)}:21118',
                    style: TextStyle(fontSize: 9, color: Colors.grey[500]),
                  ),
                ],
                if (_allLocalIps.length > 1) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    alignment: WrapAlignment.center,
                    children: _allLocalIps.map((ip) {
                      final selected = ip == _selectedLanIp;
                      return ChoiceChip(
                        label: Text(ip, style: const TextStyle(fontSize: 10)),
                        selected: selected,
                        onSelected: (_) {
                          setState(() {
                            _selectedLanIp = ip;
                            _connectionUrl = 'anuvadini://direct-tcp:${ip}_port_21118';
                          });
                        },
                      );
                    }).toList(),
                  ),
                  Text(
                    'Wrong IP? Tap the address your phone can reach.',
                    style: TextStyle(fontSize: 9, color: Colors.grey[500]),
                  ),
                ],
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: _generateConnectionUrl,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh IP'),
                ),
              ],
            ] else ...[
              if (_nostrLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Generating Nostr offer...', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                )
              else if (!_nostrRequested && _nostrUri == null && _nostrError == null)
                // User just tapped the chip — generation is starting immediately
                // via _onNostrTabSelected. Show a brief "starting" indicator.
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Starting Nostr...', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
              if (_nostrError != null) ...[
                Text(_nostrError!, style: const TextStyle(color: Colors.red, fontSize: 11)),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: _generateNostrUri,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
              if (_nostrUri != null) ...[
                QrImageView(
                  data: _nostrUri!,
                  version: QrVersions.auto,
                  size: 150,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 4),
                Text('Works over 5G / internet', style: TextStyle(fontSize: 10, color: Colors.deepPurple[400])),
                Text(
                  'Wait ~10 s after opening, then scan. Phone fetches offer via Nostr.',
                  style: TextStyle(fontSize: 9, color: Colors.grey[500]),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: _generateNostrUri,
                  icon: const Icon(Icons.refresh),
                  label: const Text('New Offer'),
                ),
              ],
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _manualIpController,
              decoration: const InputDecoration(
                hintText: 'Manual IP (e.g. 192.168.1.5)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: _connectManualIp,
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _connectManualIp(_manualIpController.text.trim()),
                child: const Text('Connect Manual IP'),
              ),
            ),
            const SizedBox(height: 8),
            const Divider(),
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: _serverReady ? Colors.green : Colors.orange),
                const SizedBox(width: 4),
                Text(
                  _serverReady
                      ? 'Listener: Ready (port 21118)'
                      : (_listenerError != null
                          ? 'Listener: Failed'
                          : 'Listener: Initializing'),
                  style: TextStyle(
                    color: _serverReady
                        ? Colors.green
                        : (_listenerError != null ? Colors.red : Colors.orange),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _rustAlive ? 'Backend Heartbeat: Alive' : 'Backend Heartbeat: Waiting',
              style: TextStyle(
                color: _rustAlive ? Colors.blue : Colors.grey,
                fontSize: 10,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceDashboard() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Mobile Streams Dashboard',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              Chip(
                label: Text('${_activeSessions.length} Live'),
                backgroundColor: MyTheme.accent.withOpacity(0.1),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (_registeredDevices.isEmpty)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.mobile_off, size: 64, color: Colors.grey),
                    SizedBox(height: 12),
                    Text('No paired devices yet.', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final crossAxisCount = constraints.maxWidth > 1000
                      ? 4
                      : constraints.maxWidth > 750
                          ? 3
                          : constraints.maxWidth > 500
                              ? 2
                              : 1;
                  return GridView.builder(
                    itemCount: _registeredDevices.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.55, // Better for portrait phones (narrower & smaller)
                    ),
                    itemBuilder: (context, index) =>
                        _buildDevicePanel(_registeredDevices[index]),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDevicePanel(Map<String, String> device) {
    final key = _deviceKey(device);
    final ffi = _activeSessions[key];
    final isConnected = ffi != null;
    final status = _sessionStatus[key] ?? (isConnected ? 'Connected' : 'Disconnected');

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blueAccent.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.phone_android, color: Colors.blueAccent),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device['name'] ?? 'Unknown Device', style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text('IP: ${device['ip'] ?? '-'}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _statusColor(status).withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: _statusColor(status),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(color: const Color(0xFF212121), borderRadius: BorderRadius.circular(8)),
                clipBehavior: Clip.antiAlias,
                child: ffi == null
                    ? const Center(child: Text('Not Connected', style: TextStyle(color: Colors.white70)))
                    : InlineStreamPanel(deviceKey: key, ffi: ffi),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(isConnected ? Icons.link_off : Icons.link, size: 16),
                    label: Text(isConnected ? 'Disconnect' : 'Connect'),
                    onPressed: () => isConnected ? _disconnectDevice(device) : _connectDevice(device),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.laptop, size: 16),
                    label: const Text('Authorize'),
                    onPressed: () => _authorizePhone(device['id'] ?? key),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'Connected':
        return Colors.green;
      case 'Connecting':
        return Colors.orange;
      case 'Error':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  String _deviceKey(Map<String, String> device) => device['id'] ?? device['ip'] ?? '';

  void _connectManualIp(String ip) {
    final cleaned = ip.trim();
    if (cleaned.isEmpty) return;
    final device = <String, String>{
      'id': cleaned,
      'name': 'Manual $cleaned',
      'ip': cleaned,
    };
    setState(() {
      _registeredDevices.removeWhere((d) => _deviceKey(d) == _deviceKey(device));
      _registeredDevices.add(device);
    });
    _connectDevice(device);
  }

  Future<void> _connectDevice(Map<String, String> device) async {
    final ip = device['ip'];
    if (ip == null || ip.isEmpty) {
      showToast('Device IP is missing.');
      return;
    }
    final key = _deviceKey(device);
    if (_activeSessions.containsKey(key)) return;

    setState(() => _sessionStatus[key] = 'Connecting');

    // #region agent log
    agentDebugLog('L2', 'mobile_control_page.dart:_connectDevice', 'connect start', {
      'ip': ip,
      'key': key,
      'hasTempPassword': (device['temp_password'] ?? '').isNotEmpty,
      'connectionId': 'direct-tcp:${ip}_port_21118',
    });
    // #endregion

    try {
      // Use a unique SessionID per panel so sessions are fully isolated.
      final ffi = FFI(null);
      final connectionId = 'direct-tcp:${ip}_port_21118';
      ffi.id = connectionId;
      Get.put<FFI>(ffi, tag: 'mobile-inline-$key', permanent: false);

      ffi.dialogManager.setOverlayState(_overlayKeyState);
      // #region agent log
      agentDebugLog('L3', 'mobile_control_page.dart:_connectDevice', 'overlay attached', {
        'ip': ip,
        'overlayReady': _overlayKeyState.state != null,
      });
      // #endregion

      initSharedStates(connectionId);

      // Mark as Connected when the first decoded frame arrives.
      ffi.imageModel.addCallbackOnFirstImage((_) {
        _imageTimeout?.cancel();
        if (mounted) setState(() => _sessionStatus[key] = 'Connected');
      });

      // ffi.start() internally sets up the per-session Rust event stream.
      // Do NOT call ffi.ffiModel.updateEventListener() after this — that
      // method overwrites the GLOBAL platformFFI event callback, which
      // would break all other active sessions.
      // Use the phone's temporary password so the login is auto-authorized.
      final tempPwd = device['temp_password'] ?? '';
      if (tempPwd.isNotEmpty) {
        ffi.start(connectionId, password: tempPwd, isSharedPassword: false);
      } else {
        ffi.start(connectionId);
      }

      setState(() {
        _activeSessions[key] = ffi;
      });
      showToast('Connecting to $ip...');

      // Timeout: if no first image within 30s, report the pi state to help diagnose.
      _imageTimeout?.cancel();
      _imageTimeout = Timer(const Duration(seconds: 30), () {
        if (!mounted || _sessionStatus[key] == 'Connected') return;
        final pi = ffi.ffiModel.pi.isSet.value;
        showToast('No video from $ip after 30s (pi.isSet=$pi). '
            'Check phone screen-capture permission & restart the phone app.');
      });
    } catch (e) {
      _imageTimeout?.cancel();
      setState(() => _sessionStatus[key] = 'Error');
      showToast('Failed to connect $ip: $e');
    }
  }

  Timer? _imageTimeout;

  Future<void> _disconnectDevice(Map<String, String> device) async {
    final key = _deviceKey(device);
    final ffi = _activeSessions[key];
    if (ffi == null) return;

    final ip = device['ip'];
    final connectionId = 'direct-tcp:${ip}_port_21118';
    removeSharedStates(connectionId);

    await ffi.close();
    await Get.delete<FFI>(tag: 'mobile-inline-$key');
    setState(() {
      _activeSessions.remove(key);
      _sessionStatus[key] = 'Disconnected';
    });
  }

  void _authorizePhone(String id) {
    setState(() {
      for (var device in _registeredDevices) {
        if ((device['id'] ?? device['ip']) == id) {
          device['authorized'] = 'true';
        }
      }
    });
    showToast('Phone $id is now authorized to control this laptop.');
  }
}

/// A self-contained widget that renders a single phone's live stream.
/// It is a [StatefulWidget] so it can safely manage texture lifecycle
/// in [initState]/[dispose] rather than inside build().
class InlineStreamPanel extends StatefulWidget {
  final String deviceKey;
  final FFI ffi;

  const InlineStreamPanel(
      {super.key, required this.deviceKey, required this.ffi});

  @override
  State<InlineStreamPanel> createState() => _InlineStreamPanelState();
}

class _InlineStreamPanelState extends State<InlineStreamPanel> {
  FFI get ffi => widget.ffi;
  Size? _lastSize;
  bool _callbackScheduled = false;
  late final FocusNode _focusNode;

  // Touch gesture state
  bool _panActive = false;
  double _scrollAccumY = 0.0;
  double _scrollAccumX = 0.0;
  Offset _lastFocalPoint = Offset.zero;
  Offset _doubleTapDownPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Rect? getRemoteRect() {
    var rect = ffi.ffiModel.rect;
    if (rect == null) {
      final curDisp = ffi.ffiModel.pi.getCurDisplays();
      if (curDisp.isNotEmpty) {
        final d = curDisp.first;
        rect = Rect.fromLTWH(
            d.x.toDouble(), d.y.toDouble(), d.width.toDouble(), d.height.toDouble());
      }
    }
    return rect;
  }

  Offset _clampToImage(Offset localPos) {
    final rect = getRemoteRect();
    if (rect == null || rect.width <= 0 || rect.height <= 0) {
      return localPos;
    }
    final canvas = ffi.canvasModel;
    final scale = canvas.scale;
    final adjust = canvas.getAdjustY();
    final imageWidth = rect.width * scale;
    final imageHeight = rect.height * scale;

    final left = canvas.x;
    final right = canvas.x + imageWidth;
    final top = canvas.y + adjust;
    final bottom = canvas.y + adjust + imageHeight;

    final clampedX = localPos.dx.clamp(left, right);
    final clampedY = localPos.dy.clamp(top, bottom);
    return Offset(clampedX, clampedY);
  }

  bool _isTouch(PointerDeviceKind? kind) {
    return kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus;
  }

  void _onTapUp(TapUpDetails d) async {
    if (!_isTouch(d.kind)) return;
    final clamped = _clampToImage(d.localPosition);
    final isMoved = await ffi.cursorModel.move(clamped.dx, clamped.dy);
    if (isMoved) {
      await ffi.inputModel.tapDown(MouseButtons.left);
      await ffi.inputModel.tapUp(MouseButtons.left);
    }
  }

  void _onDoubleTapDown(TapDownDetails d) {
    if (!_isTouch(d.kind)) return;
    _doubleTapDownPos = _clampToImage(d.localPosition);
  }

  void _onDoubleTap() async {
    final isMoved = await ffi.cursorModel.move(_doubleTapDownPos.dx, _doubleTapDownPos.dy);
    if (isMoved) {
      await ffi.inputModel.tap(MouseButtons.left);
      await ffi.inputModel.tap(MouseButtons.left);
    }
  }

  void _onLongPressStart(LongPressStartDetails d) async {
    if (ffi.inputModel.isPhysicalMouse.value) return;
    final clamped = _clampToImage(d.localPosition);
    final isMoved = await ffi.cursorModel.move(clamped.dx, clamped.dy);
    if (isMoved) {
      await ffi.inputModel.tap(MouseButtons.right);
    }
  }

  void _onScaleStart(ScaleStartDetails d) async {
    if (ffi.inputModel.isPhysicalMouse.value) return;
    _lastFocalPoint = d.localFocalPoint;
    if (d.pointerCount == 1) {
      _panActive = true;
      final clamped = _clampToImage(d.localFocalPoint);
      await ffi.cursorModel.move(clamped.dx, clamped.dy);
      if (!ffi.inputModel.relativeMouseMode.value) {
        await ffi.inputModel.sendMouse('down', MouseButtons.left);
      }
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) async {
    if (ffi.inputModel.isPhysicalMouse.value) return;
    if (d.pointerCount == 1) {
      final clamped = _clampToImage(d.localFocalPoint);
      if (ffi.inputModel.relativeMouseMode.value) {
        final delta = d.localFocalPoint - _lastFocalPoint;
        await ffi.inputModel.sendMobileRelativeMouseMove(delta.dx, delta.dy);
      } else {
        final delta = d.localFocalPoint - _lastFocalPoint;
        await ffi.cursorModel.updatePan(delta, clamped, true);
      }
      _lastFocalPoint = d.localFocalPoint;
    } else if (d.pointerCount == 2) {
      final delta = d.localFocalPoint - _lastFocalPoint;
      _lastFocalPoint = d.localFocalPoint;

      _scrollAccumY += delta.dy / 4.0;
      _scrollAccumX += delta.dx / 4.0;

      if (_scrollAccumY.abs() >= 1.0 || _scrollAccumX.abs() >= 1.0) {
        ffi.inputModel.scroll(_scrollAccumY.toInt(), x: _scrollAccumX.toInt());
        _scrollAccumY -= _scrollAccumY.truncateToDouble();
        _scrollAccumX -= _scrollAccumX.truncateToDouble();
      }
    }
  }

  void _onScaleEnd(ScaleEndDetails d) async {
    if (_panActive) {
      _panActive = false;
      if (!ffi.inputModel.relativeMouseMode.value) {
        await ffi.inputModel.sendMouse('up', MouseButtons.left);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        ffi.inputModel.updateImageWidgetSize(size);

        if (_lastSize != size) {
          _lastSize = size;
          if (!_callbackScheduled) {
            _callbackScheduled = true;
            SchedulerBinding.instance.addPostFrameCallback((_) {
              _callbackScheduled = false;
              if (mounted) {
                ffi.canvasModel.fixedSize = size;
                ffi.canvasModel.updateViewStyle();
              }
            });
          }
        }

        return Focus(
          focusNode: _focusNode,
          onKeyEvent: (node, event) => ffi.inputModel.handleKeyEvent(event),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: _onTapUp,
            onDoubleTapDown: _onDoubleTapDown,
            onDoubleTap: _onDoubleTap,
            onLongPressStart: _onLongPressStart,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            child: RawPointerMouseRegion(
              isInline: true,
              inputModel: ffi.inputModel,
              onEnter: (_) {
                ffi.inputModel.enterOrLeave(true);
                _focusNode.requestFocus();
              },
              onExit: (_) => ffi.inputModel.enterOrLeave(false),
              onPointerDown: (evt) {
                if (evt.kind == PointerDeviceKind.mouse) {
                  ffi.inputModel.isPhysicalMouse.value = true;
                } else {
                  ffi.inputModel.isPhysicalMouse.value = false;
                }
                bind.setCurSessionId(sessionId: ffi.sessionId);
                _focusNode.requestFocus();
              },
              child: Obx(() {
                // Reading pi.isSet reactive-ly avoids rendering a 0x0 texture before peer-info is ready.
                if (ffi.ffiModel.pi.isSet.isFalse) {
                  return Container(
                    color: const Color(0xFF1a1a2e),
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.blueAccent),
                          SizedBox(height: 12),
                          Text('Waiting for stream…',
                              style: TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                }

                final useTexture = ffi.imageModel.useTextureRender || ffi.ffiModel.pi.forceTextureRender;

                // Using the shared display state tag matching ffi.id
                final curDisplay = CurrentDisplayState.find(ffi.id).value;
                // Reactively ensure that updateCurrentDisplay is called inside the Obx builder
                // whenever the display state changes, exactly as is done in the main remote_page.dart!
                ffi.textureModel.updateCurrentDisplay(curDisplay);

                final textureId = ffi.textureModel.getTextureId(curDisplay);

                // We build a hybrid widget: if texture render is disabled, or if software frames
                // have already been received as a fallback, we display the software RawImage.
                // Otherwise, we render using the Texture widget.
                return AnimatedBuilder(
                  animation: ffi.imageModel,
                  builder: (context, child) {
                    final softwareImage = ffi.imageModel.image;

                    if (!useTexture || textureId.value == -1 || softwareImage != null) {
                      if (softwareImage != null) {
                        return SizedBox.expand(
                          child: RawImage(
                            image: softwareImage,
                            fit: BoxFit.contain,
                          ),
                        );
                      }
                    }

                    if (textureId.value == -1) {
                      return Container(
                        color: const Color(0xFF1a1a2e),
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.blueAccent),
                              SizedBox(height: 12),
                              Text('Starting stream…',
                                  style: TextStyle(color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ),
                      );
                    }

                    // Texture is ready: fill the entire panel.
                    return SizedBox.expand(
                      child: Texture(
                        textureId: textureId.value,
                        filterQuality: FilterQuality.low,
                      ),
                    );
                  },
                );
              }),
            ),
          ),
        );
      },
    );
  }
}
