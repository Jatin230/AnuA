import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

class MobileControlPage extends StatefulWidget {
  const MobileControlPage({super.key});

  @override
  _MobileControlPageState createState() => _MobileControlPageState();
}

class _MobileControlPageState extends State<MobileControlPage> {
  String? _connectionUrl;
  String? _error;
  bool _loading = false;
  final List<Map<String, String>> _registeredDevices = [];

  @override
  void initState() {
    super.initState();
    _generateConnectionUrl();
    _setupEventListener();
    
    // TEMPORARY DEBUG: Confirm Dart code is updated
    Future.delayed(Duration.zero, () {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("DEBUG: DART UPDATED"),
          content: const Text("This confirms you are running the NEW Flutter build."),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("OK"))],
        ),
      );
    });
  }

  bool _serverReady = false;
  bool _rustAlive = false;
  DateTime? _lastHeartbeat;

  void _setupEventListener() {
    // Listen for server status
    platformFFI.registerEventHandler("direct_server_status", "mobile_control_page_status", (evt) async {
       if (evt['data'] == 'started') {
         setState(() => _serverReady = true);
       }
    });

    // Listen for rust heartbeat
    platformFFI.registerEventHandler("rust_heartbeat", "mobile_control_page_heartbeat", (evt) async {
       setState(() {
         _rustAlive = true;
         _lastHeartbeat = DateTime.now();
       });
    });

    // Register the handler for mobile registration events
    platformFFI.registerEventHandler("mobile_device_registered", "mobile_control_page", (evt) async {
      try {
        final device = Map<String, String>.from(json.decode(evt['data']));
        setState(() {
          // Add or update the device in the list
          _registeredDevices.removeWhere((d) => d['id'] == device['id']);
          _registeredDevices.add(device);
        });
        
        // Show the interactive Action Dialog on the laptop
        _showDeviceActionDialog(device);
      } catch (e) {
        debugPrint('Failed to parse registration: $e');
      }
    });
  }

  void _showDeviceActionDialog(Map<String, String> device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('New Mobile Device: ${device['name']}'),
        content: const Text('A mobile device has just scanned your QR code. What would you like to do?'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _controlPhone(device['ip']!);
            },
            child: const Text('Control Phone'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _authorizePhone(device['id']!);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            child: const Text('Authorize Phone to Control Me'),
          ),
        ],
      ),
    );
  }

  List<String> _allLocalIps = [];

  Future<void> _generateConnectionUrl() async {
    setState(() {
      _loading = true;
      _error = null;
      _allLocalIps = [];
    });
    try {
      final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (var interface in interfaces) {
        final name = interface.name.toLowerCase();
        // Ignore virtual adapters that belong to WSL, VMware, VirtualBox, etc.
        if (name.contains('wsl') || 
            name.contains('virtual') || 
            name.contains('vbox') || 
            name.contains('vmware') || 
            name.contains('vethernet') || 
            name.contains('host-only') ||
            name.contains('loopback')) {
          continue;
        }
        for (var addr in interface.addresses) {
          if (!addr.isLoopback) {
            _allLocalIps.add(addr.address);
          }
        }
      }
      
      if (_allLocalIps.isEmpty) {
        // Fallback to all IPs if physical interfaces couldn't be detected
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (!addr.isLoopback) _allLocalIps.add(addr.address);
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

      // Prioritize the best IP: 192.168 first, then 10., then 172., then others
      String localIp = _allLocalIps.firstWhere(
        (ip) => ip.startsWith('192.168.'), 
        orElse: () => _allLocalIps.firstWhere(
          (ip) => ip.startsWith('10.'),
          orElse: () => _allLocalIps.firstWhere(
            (ip) => ip.startsWith('172.'),
            orElse: () => _allLocalIps.first,
          ),
        ),
      );
      
      // Use a direct-tcp format that the existing Android app can parse correctly
      final url = 'anuvadini://direct-tcp:${localIp}_port_21118';
      setState(() {
        _connectionUrl = url;
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile Command Center'),
        backgroundColor: MyTheme.accent,
      ),
      body: Row(
        children: [
          // Left Side: QR Code & Setup
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: _buildSetupCard(),
            ),
          ),
          // Right Side: Active Devices List
          VerticalDivider(width: 1, color: Colors.grey[300]),
          Expanded(
            flex: 3,
            child: _buildDeviceList(),
          ),
        ],
      ),
    );
  }

  Widget _buildSetupCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            const Icon(Icons.qr_code_scanner, size: 48, color: MyTheme.accent),
            const SizedBox(height: 16),
            const Text(
              'Pair New Device',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan this QR code with the Anuvadini app on your phone to register it with this laptop.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 24),
            if (_loading) const CircularProgressIndicator(),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red)),
            if (_connectionUrl != null) ...[
              QrImageView(
                data: _connectionUrl!,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _generateConnectionUrl,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh IP'),
              ),
            ],
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text('Manual Fallback', style: TextStyle(fontWeight: FontWeight.bold)),
            const Text('Type the IP shown on your phone:', style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: const InputDecoration(
                      hintText: 'e.g. 192.168.1.5',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (val) => _controlPhone(val),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    // Manual connect logic
                  },
                  child: const Text('Connect'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text('Troubleshooting:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ..._allLocalIps.map((ip) => Text('• Laptop IP: $ip', style: const TextStyle(fontSize: 11, color: Colors.blue))),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.circle, size: 10, color: _serverReady ? Colors.green : Colors.orange),
                const SizedBox(width: 4),
                Text(
                  _serverReady ? 'Status: Ready (Listening on 21118)' : 'Status: Initializing Listener...',
                  style: TextStyle(
                    color: _serverReady ? Colors.green : Colors.orange, 
                    fontSize: 11, 
                    fontWeight: FontWeight.bold
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _rustAlive ? 'Backend Heartbeat: Alive' : 'Backend Heartbeat: Waiting...',
              style: TextStyle(
                color: _rustAlive ? Colors.blue : Colors.grey,
                fontSize: 10,
                fontStyle: FontStyle.italic
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceList() {
    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Active Mobile Devices',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              if (_registeredDevices.isNotEmpty)
                Chip(
                  label: Text('${_registeredDevices.length} Connected'),
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
                    SizedBox(height: 16),
                    Text('No devices paired yet.', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _registeredDevices.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final device = _registeredDevices[index];
                  return _buildDeviceTile(device);
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(Map<String, String> device) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.blueAccent.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.phone_android, color: Colors.blueAccent),
        ),
        title: Text(
          device['name'] ?? 'Unknown Device',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('IP: ${device['ip']}'),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.visibility, size: 16),
              label: const Text('Control Phone'),
              onPressed: () => _controlPhone(device['ip']!),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.laptop, size: 16),
              label: const Text('Let Phone Control Me'),
              onPressed: () => _authorizePhone(device['ip']!),
            ),
          ],
        ),
      ),
    );
  }

  void _controlPhone(String ip) async {
    final address = 'direct-tcp:${ip}_port_21118';
    debugPrint('Connecting to phone at: $address');
    await connectMainDesktop(
      address,
      isFileTransfer: false,
      isViewCamera: false,
      isTerminal: false,
      isTcpTunneling: false,
      isRDP: false,
    );
    showToast('Launching session to control phone...');
  }

  void _authorizePhone(String id) {
    // This allows the mobile device to control the laptop
    setState(() {
      for (var device in _registeredDevices) {
        if (device['id'] == id) {
          device['authorized'] = 'true';
        }
      }
    });
    showToast('Phone $id is now authorized to control this laptop.');
  }
}
