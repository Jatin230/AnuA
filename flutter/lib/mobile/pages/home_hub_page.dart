import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/pages/device_hub_widgets.dart';
import 'package:flutter_hbb/mobile/pages/home_page.dart';
import 'package:flutter_hbb/mobile/pages/pair_device_page.dart';
import 'package:flutter_hbb/mobile/pages/server_page.dart';
import 'package:flutter_hbb/models/device_model.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../../models/server_model.dart';
import 'connection_page.dart';

class HomeHubPage extends StatefulWidget implements PageShape {
  @override
  final String title = 'Home';

  @override
  final Widget icon = const Icon(Icons.home);

  @override
  final List<Widget> appBarActions = [];

  HomeHubPage({Key? key}) : super(key: key);

  @override
  State<HomeHubPage> createState() => _HomeHubPageState();
}

class _HomeHubPageState extends State<HomeHubPage> {
  String _myId = '';
  String _localIP = '';
  bool _directServerStarted = false;

  @override
  void initState() {
    super.initState();
    gFFI.deviceModel.load();
    _fetchMyId();
    _detectLocalIP();
    platformFFI.registerEventHandler(
        'direct_server_status', 'home_hub_direct_status', (evt) async {
      final data = evt['data']?.toString() ?? '';
      if (!mounted) return;
      setState(() {
        _directServerStarted = data == 'started';
      });
    });
    // The direct server only reports "started" after a fresh bind, so also
    // reflect the current sharing service state on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _directServerStarted =
            _directServerStarted || gFFI.serverModel.isStart;
      });
    });
  }

  @override
  void dispose() {
    platformFFI.unregisterEventHandler(
        'direct_server_status', 'home_hub_direct_status');
    super.dispose();
  }

  Future<void> _fetchMyId() async {
    try {
      final id = await bind.mainGetMyId();
      if (mounted) setState(() => _myId = id);
    } catch (_) {}
  }

  Future<void> _detectLocalIP() async {
    var ip = bind.mainGetOptionSync(key: 'local-ip-addr');
    if (ip.isEmpty) {
      try {
        final interfaces =
            await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
        for (final interface in interfaces) {
          for (final addr in interface.addresses) {
            if (!addr.isLoopback && addr.address.isNotEmpty) {
              ip = addr.address;
              await bind.mainSetOption(key: 'local-ip-addr', value: ip);
              break;
            }
          }
          if (ip.isNotEmpty) break;
        }
      } catch (_) {}
    }
    if (mounted) setState(() => _localIP = ip);
  }

  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 5) return 'Good night';
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    showToast(translate('Copied'));
  }

  void _openShareScreen() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(
          title: const Text('Share Your Screen'),
          centerTitle: true,
        ),
        body: ServerPage(),
      ),
    ));
  }

  void _openPairDevice() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const PairDevicePage(),
    ));
  }

  void _goToDevicesTab() {
    HomePage.homeKey.currentState?.switchTab(1);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.deviceModel),
        ChangeNotifierProvider.value(value: gFFI.serverModel),
      ],
      child: Consumer<DeviceModel>(
        builder: (context, deviceModel, _) {
          final devices = deviceModel.devices;
          final preview =
              devices.length > 4 ? devices.sublist(0, 4) : devices;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text(
                '$_greeting!',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Share your screen, or connect to one of your devices.',
                style: TextStyle(color: MyTheme.darkGray, fontSize: 13),
              ),
              const SizedBox(height: 20),
              _buildThisPhoneCard(context),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'My Devices',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  if (devices.isNotEmpty)
                    TextButton(
                      onPressed: _goToDevicesTab,
                      child: const Text('See all'),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              if (devices.isEmpty)
                _buildEmptyDevices()
              else
                ...preview.map((d) => _buildDeviceTile(d)),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _openPairDevice,
                icon: const Icon(Icons.add),
                label: const Text('Pair Device'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: BorderSide(color: MyTheme.accent.withOpacity(0.6)),
                  foregroundColor: MyTheme.accent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildThisPhoneCard(BuildContext cardContext) {
    final serverModel = Provider.of<ServerModel>(cardContext);
    final isSharing = _directServerStarted || serverModel.isStart;
    final canHost = !bind.isOutgoingOnly();
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 0,
      color: Theme.of(context).colorScheme.primary.withOpacity(0.06),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const DeviceAvatar(name: 'This Phone', size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'This Phone',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ReadyBadge(ready: isSharing),
                    ],
                  ),
                ),
                if (canHost)
                  IconButton(
                    tooltip: 'Share Your Screen',
                    icon: const Icon(Icons.mobile_screen_share),
                    color: MyTheme.accent,
                    onPressed: _openShareScreen,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            if (_myId.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _myId,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    onPressed: () => _copy(_myId),
                  ),
                ],
              ),
            if (_localIP.isNotEmpty) ...[
              const Divider(height: 20),
              Row(
                children: [
                  const Icon(Icons.lan_outlined, size: 18, color: MyTheme.darkGray),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Direct IP · $_localIP',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    onPressed: () => _copy(_localIP),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => showMyQrDialog(context),
                icon: const Icon(Icons.qr_code, size: 20),
                label: const Text('Show My QR Code'),
              ),
            ),
            if (canHost) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _openShareScreen,
                  icon: const Icon(Icons.play_arrow, size: 22),
                  label: const Text(
                    'Start Sharing',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: MyTheme.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyDevices() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: MyTheme.darkGray.withOpacity(0.06),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          const Icon(Icons.devices_other, size: 40, color: MyTheme.darkGray),
          const SizedBox(height: 8),
          const Text('No devices yet'),
          const SizedBox(height: 4),
          Text(
            'Pair a device to connect in one tap.',
            style: TextStyle(color: MyTheme.darkGray, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceTile(Device device) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: DeviceAvatar(name: device.name, platform: device.platform),
        title: Text(device.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          'Last connected · ${formatLastConnected(device.lastConnected)}',
          style: TextStyle(color: MyTheme.darkGray, fontSize: 12),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _goToDevicesTab,
      ),
    );
  }
}
