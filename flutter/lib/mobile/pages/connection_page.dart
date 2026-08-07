import 'dart:async';
import 'dart:io';

import 'package:auto_size_text_field/auto_size_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/common/widgets/connection_page_title.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_hbb/models/peer_model.dart';

import 'package:qr_flutter/qr_flutter.dart';
import '../../common.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../common/widgets/autocomplete.dart';
import '../../consts.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';
import 'scan_page.dart';

/// Connection page for connecting to a remote peer.
class ConnectionPage extends StatefulWidget implements PageShape {
  ConnectionPage({Key? key, required this.appBarActions}) : super(key: key);

  @override
  final icon = const Icon(Icons.connected_tv);

  @override
  final title = translate("Connection");

  @override
  final List<Widget> appBarActions;

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

/// State for the connection page.
class _ConnectionPageState extends State<ConnectionPage> {
  /// Controller for the id input bar.
  final _idController = IDTextEditingController();
  final RxBool _idEmpty = true.obs;

  final FocusNode _idFocusNode = FocusNode();
  final TextEditingController _idEditingController = TextEditingController();

  final AllPeersLoader _allPeersLoader = AllPeersLoader();

  StreamSubscription? _uniLinksSubscription;

  // https://github.com/flutter/flutter/issues/157244
  Iterable<Peer> _autocompleteOpts = [];

  String _localIP = "";
  String _oneTimePassword = "";

  _ConnectionPageState() {
    if (!isWeb) _uniLinksSubscription = listenUniLinks();
    _idController.addListener(() {
      _idEmpty.value = _idController.text.isEmpty;
    });
    Get.put<IDTextEditingController>(_idController);
  }

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init(setState);
    _idFocusNode.addListener(onFocusChanged);
    if (_idController.text.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final lastRemoteId = stripNostrUri(await bind.mainGetLastRemoteId());
        if (lastRemoteId != _idController.id) {
          setState(() {
            _idController.id = lastRemoteId;
          });
        }
      });
    }
    Get.put<TextEditingController>(_idEditingController);
    _detectLocalIP();
  }

  Future<void> _detectLocalIP() async {
    _localIP = bind.mainGetOptionSync(key: 'local-ip-addr');
    if (_localIP.isEmpty) {
      try {
        final interfaces = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
        for (var interface in interfaces) {
          for (var addr in interface.addresses) {
            if (!addr.isLoopback && addr.address.isNotEmpty) {
              _localIP = addr.address;
              await bind.mainSetOption(key: 'local-ip-addr', value: _localIP);
              break;
            }
          }
          if (_localIP.isNotEmpty) break;
        }
      } catch (_) {}
    }
    _oneTimePassword = bind.mainGetOptionSync(key: 'one-time-password');
    if (mounted) setState(() {});
  }

  Widget _buildDirectConnectionInfo() {
    if (_localIP.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: MyTheme.accent.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: MyTheme.accent.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Direct Connection IP",
              style: TextStyle(fontSize: 11, color: Colors.grey[600], fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SelectableText(_localIP,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1)),
          if (_oneTimePassword.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text("One Time Password: $_oneTimePassword",
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Provider.of<FfiModel>(context);
    return CustomScrollView(
      slivers: [
        SliverList(
            delegate: SliverChildListDelegate([
          if (!bind.isCustomClient() && !isIOS)
            Obx(() => _buildUpdateUI(stateGlobal.updateUrl.value)),
          _buildDirectConnectionInfo(),
          _buildRemoteIDTextField(),
        ])),
        SliverFillRemaining(
          hasScrollBody: true,
          child: PeerTabPage(),
        )
      ],
    ).marginOnly(top: 2, left: 10, right: 10);
  }

  /// Callback for the connect button.
  /// Connects to the selected peer.
  void onConnect() {
    var id = _idController.id;
    connect(context, id);
  }

  void onFocusChanged() {
    _idEmpty.value = _idEditingController.text.isEmpty;
    if (_idFocusNode.hasFocus) {
      if (_allPeersLoader.needLoad) {
        _allPeersLoader.getAllPeers();
      }

      final textLength = _idEditingController.value.text.length;
      // Select all to facilitate removing text, just following the behavior of address input of chrome.
      _idEditingController.selection =
          TextSelection(baseOffset: 0, extentOffset: textLength);
    }
  }

  /// UI for software update.
  /// If _updateUrl] is not empty, shows a button to update the software.
  Widget _buildUpdateUI(String updateUrl) {
    return updateUrl.isEmpty
        ? const SizedBox(height: 0)
        : InkWell(
            onTap: () async {
              final url = 'https://anuvadini.com/download';
              // https://pub.dev/packages/url_launcher#configuration
              // https://developer.android.com/training/package-visibility/use-cases#open-urls-custom-tabs
              //
              // `await launchUrl(Uri.parse(url))` can also run if skip
              // 1. The following check
              // 2. `<action android:name="android.support.customtabs.action.CustomTabsService" />` in AndroidManifest.xml
              //
              // But it is better to add the check.
              await launchUrl(Uri.parse(url));
            },
            child: Container(
                alignment: AlignmentDirectional.center,
                width: double.infinity,
                color: Colors.pinkAccent,
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(translate('Download new version'),
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold))));
  }

  /// UI for the remote ID TextField.
  /// Search for a peer and connect to it if the id exists.
  Widget _buildRemoteIDTextField() {
    final w = SizedBox(
      height: 84,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        child: Ink(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.all(Radius.circular(13)),
          ),
          child: Row(
            children: <Widget>[
              IconButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => ScanPage()),
                  );
                },
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: translate('Scan QR Code'),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.only(left: 16, right: 16),
                  child: RawAutocomplete<Peer>(
                    optionsBuilder: (TextEditingValue textEditingValue) {
                      if (textEditingValue.text == '') {
                        _autocompleteOpts = const Iterable<Peer>.empty();
                      } else if (_allPeersLoader.peers.isEmpty &&
                          !_allPeersLoader.isPeersLoaded) {
                        Peer emptyPeer = Peer(
                          id: '',
                          username: '',
                          hostname: '',
                          alias: '',
                          platform: '',
                          tags: [],
                          hash: '',
                          password: '',
                          forceAlwaysRelay: false,
                          rdpPort: '',
                          rdpUsername: '',
                          loginName: '',
                          device_group_name: '',
                          note: '',
                        );
                        _autocompleteOpts = [emptyPeer];
                      } else {
                        String textWithoutSpaces =
                            textEditingValue.text.replaceAll(" ", "");
                        if (int.tryParse(textWithoutSpaces) != null) {
                          textEditingValue = TextEditingValue(
                            text: textWithoutSpaces,
                            selection: textEditingValue.selection,
                          );
                        }
                        String textToFind = textEditingValue.text.toLowerCase();

                        _autocompleteOpts = _allPeersLoader.peers
                            .where((peer) =>
                                peer.id.toLowerCase().contains(textToFind) ||
                                peer.username
                                    .toLowerCase()
                                    .contains(textToFind) ||
                                peer.hostname
                                    .toLowerCase()
                                    .contains(textToFind) ||
                                peer.alias.toLowerCase().contains(textToFind))
                            .toList();
                      }
                      return _autocompleteOpts;
                    },
                    focusNode: _idFocusNode,
                    textEditingController: _idEditingController,
                    fieldViewBuilder: (BuildContext context,
                        TextEditingController fieldTextEditingController,
                        FocusNode fieldFocusNode,
                        VoidCallback onFieldSubmitted) {
                      updateTextAndPreserveSelection(
                          fieldTextEditingController, _idController.text);
                      return AutoSizeTextField(
                        controller: fieldTextEditingController,
                        focusNode: fieldFocusNode,
                        minFontSize: 18,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.visiblePassword,
                        // keyboardType: TextInputType.number,
                        onChanged: (String text) {
                          _idController.id = text;
                        },
                        style: const TextStyle(
                          fontFamily: 'WorkSans',
                          fontWeight: FontWeight.bold,
                          fontSize: 30,
                          color: MyTheme.idColor,
                        ),
                        decoration: InputDecoration(
                          labelText: translate('Remote ID'),
                          // hintText: 'Enter your remote ID',
                          border: InputBorder.none,
                          helperStyle: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: MyTheme.darkGray,
                          ),
                          labelStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            letterSpacing: 0.2,
                            color: MyTheme.darkGray,
                          ),
                        ),
                        inputFormatters: [IDTextInputFormatter()],
                        onSubmitted: (_) {
                          onConnect();
                        },
                      );
                    },
                    onSelected: (option) {
                      setState(() {
                        _idController.id = option.id;
                        FocusScope.of(context).unfocus();
                      });
                    },
                    optionsViewBuilder: (BuildContext context,
                        AutocompleteOnSelected<Peer> onSelected,
                        Iterable<Peer> options) {
                      options = _autocompleteOpts;
                      double maxHeight = options.length * 50;
                      if (options.length == 1) {
                        maxHeight = 52;
                      } else if (options.length == 3) {
                        maxHeight = 146;
                      } else if (options.length == 4) {
                        maxHeight = 193;
                      }
                      maxHeight = maxHeight.clamp(0, 200);
                      return Align(
                          alignment: Alignment.topLeft,
                          child: Container(
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.3),
                                    blurRadius: 5,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                  borderRadius: BorderRadius.circular(5),
                                  child: Material(
                                      elevation: 4,
                                      child: ConstrainedBox(
                                          constraints: BoxConstraints(
                                            maxHeight: maxHeight,
                                            maxWidth: 320,
                                          ),
                                          child: _allPeersLoader
                                                      .peers.isEmpty &&
                                                  !_allPeersLoader.isPeersLoaded
                                              ? Container(
                                                  height: 80,
                                                  child: Center(
                                                      child:
                                                          CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  )))
                                              : ListView(
                                                  padding:
                                                      EdgeInsets.only(top: 5),
                                                  children: options
                                                      .map((peer) =>
                                                          AutocompletePeerTile(
                                                              onSelect: () =>
                                                                  onSelected(
                                                                      peer),
                                                              peer: peer))
                                                      .toList(),
                                                ))))));
                    },
                  ),
                ),
              ),
                  Obx(() => Offstage(
                        offstage: _idEmpty.value,
                        child: IconButton(
                            onPressed: () {
                              setState(() {
                                _idController.clear();
                              });
                            },
                            icon: Icon(Icons.clear, color: MyTheme.darkGray)),
                      )),
                  IconButton(
                    onPressed: _showMyQrCode,
                    icon: Icon(Icons.qr_code, color: MyTheme.darkGray),
                    tooltip: 'Show My QR',
                  ),
                  IconButton(
                    onPressed: () {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) => ScanPage()));
                    },
                    icon: Icon(Icons.qr_code_scanner, color: MyTheme.darkGray),
                    tooltip: 'Scan QR',
                  ),
              SizedBox(
                width: 60,
                height: 60,
                child: IconButton(
                  icon: const Icon(Icons.arrow_forward,
                      color: MyTheme.darkGray, size: 45),
                  onPressed: onConnect,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final child = Column(children: [
      if (isWebDesktop)
        getConnectionPageTitle(context, true)
            .marginOnly(bottom: 10, top: 15, left: 12),
      w
    ]);
    return Align(
        alignment: Alignment.topCenter,
        child: Container(constraints: kMobilePageConstraints, child: child));
  }

  void _showMyQrCode() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _MyQrDialog(),
    );
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    _idController.dispose();
    _idFocusNode.removeListener(onFocusChanged);
    _allPeersLoader.clear();
    _idFocusNode.dispose();
    _idEditingController.dispose();
    if (Get.isRegistered<IDTextEditingController>()) {
      Get.delete<IDTextEditingController>();
    }
    if (Get.isRegistered<TextEditingController>()) {
      Get.delete<TextEditingController>();
    }
    super.dispose();
  }
}

/// Open the "My QR" dialog (LAN / Internet tabs) from anywhere in the app.
void showMyQrDialog(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _MyQrDialog(),
  );
}

class _MyQrDialog extends StatefulWidget {
  @override
  State<_MyQrDialog> createState() => _MyQrDialogState();
}

class _MyQrDialogState extends State<_MyQrDialog> {
  int _tab = 0; // 0 = LAN, 1 = Internet (Nostr)

  // LAN state
  bool _lanLoading = true;
  String? _lanError;
  String? _lanUrl;
  String? _selectedIp;
  final List<String> _allIps = [];
  bool _listenerReady = false;
  String? _listenerError;
  Timer? _probeTimer;

  // Internet (Nostr) state
  String? _nostrUri;
  String? _nostrError;
  bool _nostrLoading = false;

  @override
  void initState() {
    super.initState();
    _ensureDirectServerEnabled();
    _setupDirectServerListener();
    _startListenerProbe();
    _generateLan();
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    platformFFI.unregisterEventHandler(
        'direct_server_status', '_my_qr_dialog_status');
    platformFFI.unregisterEventHandler(
        'on_nostr_webrtc_ready', '_my_qr_dialog_ready');
    platformFFI.unregisterEventHandler(
        'on_nostr_webrtc_error', '_my_qr_dialog_err');
    super.dispose();
  }

  Future<void> _ensureDirectServerEnabled() async {
    try {
      if (bind.mainGetOptionSync(key: 'direct-server') != 'Y') {
        await bind.mainSetOption(key: 'direct-server', value: 'Y');
      }
      if (bind.mainGetOptionSync(key: 'stop-service') == 'Y') {
        await bind.mainSetOption(key: 'stop-service', value: '');
      }
    } catch (_) {}
  }

  void _setupDirectServerListener() {
    platformFFI.registerEventHandler(
        'direct_server_status', '_my_qr_dialog_status', (evt) async {
      final data = evt['data']?.toString() ?? '';
      if (!mounted) return;
      if (data == 'started') {
        setState(() {
          _listenerReady = true;
          _listenerError = null;
        });
        _probeTimer?.cancel();
      } else if (data.startsWith('error:')) {
        setState(() {
          _listenerReady = false;
          _listenerError = data.substring(6);
        });
      }
    });
  }

  void _startListenerProbe() {
    _probeListener();
    _probeTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_listenerReady) {
        _probeTimer?.cancel();
        return;
      }
      _probeListener();
    });
  }

  Future<void> _probeListener() async {
    const port = 21118;
    for (final host in ['127.0.0.1', if (_selectedIp != null) _selectedIp!]) {
      try {
        final socket = await Socket.connect(
            host, port, timeout: const Duration(milliseconds: 800));
        await socket.close();
        if (mounted && !_listenerReady) {
          setState(() {
            _listenerReady = true;
            _listenerError = null;
          });
        }
        return;
      } catch (_) {}
    }
  }

  Future<void> _generateLan() async {
    setState(() {
      _lanLoading = true;
      _lanError = null;
      _allIps.clear();
    });
    try {
      final interfaces = await NetworkInterface.list(
          includeLoopback: false, type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
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
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && _isUsableLanIp(addr.address)) {
            _allIps.add(addr.address);
          }
        }
      }
      if (_allIps.isEmpty) {
        setState(() {
          _lanError = 'No network IP found. Connect to Wi-Fi.';
          _lanLoading = false;
        });
        return;
      }
      final rustIp = bind.mainGetOptionSync(key: 'local-ip-addr');
      if (rustIp.isNotEmpty &&
          _isUsableLanIp(rustIp) &&
          !_allIps.contains(rustIp)) {
        _allIps.insert(0, rustIp);
      }
      final ip = _selectedIp ??
          (rustIp.isNotEmpty &&
                  _isUsableLanIp(rustIp) &&
                  _allIps.contains(rustIp)
              ? rustIp
              : _pickBestLocalIp(_allIps));
      setState(() {
        _lanUrl = 'anuvadini://direct-tcp:${ip}_port_21118';
        _selectedIp = ip;
        _lanLoading = false;
      });
    } catch (e) {
      setState(() {
        _lanError = e.toString();
        _lanLoading = false;
      });
    }
  }

  bool _isUsableLanIp(String ip) {
    if (ip.startsWith('169.254.')) return false;
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

  Future<void> _startNostrHost() async {
    setState(() {
      _nostrLoading = true;
      _nostrError = null;
      _nostrUri = null;
    });
    final completer = Completer<String?>();

    platformFFI.registerEventHandler(
        'on_nostr_webrtc_ready', '_my_qr_dialog_ready', (evt) async {
      if (!completer.isCompleted) completer.complete(evt['uri']);
    });
    platformFFI.registerEventHandler(
        'on_nostr_webrtc_error', '_my_qr_dialog_err', (evt) async {
      if (!completer.isCompleted) completer.complete(null);
    });

    try {
      await bind.startNostrWebrtcHost();
    } catch (e) {
      platformFFI.unregisterEventHandler(
          'on_nostr_webrtc_ready', '_my_qr_dialog_ready');
      platformFFI.unregisterEventHandler(
          'on_nostr_webrtc_error', '_my_qr_dialog_err');
      if (mounted) {
        setState(() {
          _nostrError = 'Failed to start: $e';
          _nostrLoading = false;
        });
      }
      return;
    }

    final uri = await completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () => null,
    );

    platformFFI.unregisterEventHandler(
        'on_nostr_webrtc_ready', '_my_qr_dialog_ready');
    platformFFI.unregisterEventHandler(
        'on_nostr_webrtc_error', '_my_qr_dialog_err');

    if (mounted) {
      setState(() {
        if (uri == null || uri.isEmpty) {
          _nostrError = 'Timed out generating offer. Try again.';
        } else {
          _nostrUri = uri;
        }
        _nostrLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('My QR Code'),
      content: SizedBox(
        width: 260,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('LAN'),
                    selected: _tab == 0,
                    onSelected: (_) => setState(() => _tab = 0),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('Internet'),
                    selected: _tab == 1,
                    onSelected: (_) {
                      setState(() => _tab = 1);
                      if (!_nostrLoading &&
                          _nostrUri == null &&
                          _nostrError == null) {
                        _startNostrHost();
                      }
                    },
                    selectedColor: Colors.deepPurple.withOpacity(0.2),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_tab == 0) _buildLanTab() else _buildNostrTab(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildLanTab() {
    if (_lanLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Finding LAN IP...', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    if (_lanError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.red[400], size: 40),
            const SizedBox(height: 8),
            Text(_lanError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _generateLan,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        QrImageView(
          data: _lanUrl!,
          version: QrVersions.auto,
          size: 180,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.H,
          eyeStyle: QrEyeStyle(color: Colors.black, eyeShape: QrEyeShape.square),
          dataModuleStyle: QrDataModuleStyle(
              color: Colors.black, dataModuleShape: QrDataModuleShape.square),
          embeddedImage: const AssetImage('assets/logo.png'),
          embeddedImageStyle: const QrEmbeddedImageStyle(
            size: Size(40, 40),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Same Wi-Fi required',
            style: TextStyle(fontSize: 10, color: Colors.grey)),
        const SizedBox(height: 4),
        if (!_listenerReady)
          Text(
            _listenerError != null
                ? 'Port 21118 unavailable: $_listenerError'
                : 'Waiting for listener on port 21118…',
            style: TextStyle(
              fontSize: 10,
              color: _listenerError != null ? Colors.red : Colors.orange[800],
            ),
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 4),
        const Text('Start screen sharing to let others connect',
            style: TextStyle(fontSize: 9, color: Colors.grey),
            textAlign: TextAlign.center),
        const SizedBox(height: 4),
        Text('$_selectedIp:21118',
            style: const TextStyle(fontSize: 10, color: Colors.grey)),
        if (_allIps.length > 1) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            alignment: WrapAlignment.center,
            children: _allIps.map((ip) {
              final selected = ip == _selectedIp;
              return ChoiceChip(
                label: Text(ip, style: const TextStyle(fontSize: 10)),
                selected: selected,
                onSelected: (_) {
                  setState(() {
                    _selectedIp = ip;
                    _lanUrl = 'anuvadini://direct-tcp:${ip}_port_21118';
                  });
                  _probeListener();
                },
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildNostrTab() {
    if (_nostrLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Generating Nostr offer...', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    if (_nostrError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, color: Colors.red[400], size: 40),
            const SizedBox(height: 8),
            Text(_nostrError!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _startNostrHost,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        QrImageView(
          data: _nostrUri!,
          version: QrVersions.auto,
          size: 180,
          backgroundColor: Colors.white,
          errorCorrectionLevel: QrErrorCorrectLevel.H,
          eyeStyle: QrEyeStyle(color: Colors.black, eyeShape: QrEyeShape.square),
          dataModuleStyle: QrDataModuleStyle(
              color: Colors.black, dataModuleShape: QrDataModuleShape.square),
          embeddedImage: const AssetImage('assets/logo.png'),
          embeddedImageStyle: const QrEmbeddedImageStyle(
            size: Size(40, 40),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Works over 5G / internet',
            style: TextStyle(fontSize: 10, color: Colors.deepPurple)),
        const SizedBox(height: 4),
        const Text(
          'Other phone scans this QR to connect.',
          style: TextStyle(fontSize: 10, color: Colors.grey),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        ElevatedButton(
          onPressed: _startNostrHost,
          child: const Text('New QR'),
        ),
      ],
    );
  }
}
