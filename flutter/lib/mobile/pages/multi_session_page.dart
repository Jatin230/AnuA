import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../device_model.dart';
import '../device_session_manager.dart';
import '../widgets/device_list_sheet.dart';
import 'remote_page.dart';
import 'scan_page.dart';

class MultiSessionPage extends StatefulWidget {
  const MultiSessionPage({super.key});

  @override
  State<MultiSessionPage> createState() => _MultiSessionPageState();
}

class _MultiSessionPageState extends State<MultiSessionPage>
    with WidgetsBindingObserver {
  final _manager = DeviceSessionManager.instance;
  int _sessionCount = 0;
  Offset _fabOffset = const Offset(0, 0);

  @override
  void initState() {
    super.initState();
    _sessionCount = _manager.deviceCount;
    _manager.addListener(_onDevicesChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _manager.removeListener(_onDevicesChanged);
    WidgetsBinding.instance.removeObserver(this);
    _manager.removeAll();
    setGffiOverride(null);
    super.dispose();
  }

  void _onDevicesChanged() {
    if (mounted) {
      setState(() {
        _sessionCount = _manager.deviceCount;
      });
    }
  }

  Future<void> _showSessionSheet() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const DeviceListSheet(),
    );

    if (result == 'add') {
      _showAddDeviceDialog();
    }
  }

  Future<void> _showAddDeviceDialog() async {
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(translate('Add Connection')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.qr_code_scanner),
                title: Text(translate('Scan QR Code')),
                onTap: () {
                  Navigator.of(context).pop();
                  _pushScanner();
                },
              ),
              ListTile(
                leading: const Icon(Icons.keyboard),
                title: Text(translate('Enter Remote ID')),
                onTap: () {
                  Navigator.of(context).pop();
                  _showManualIdDialog();
                },
              ),
            ],
          ),
        );
      }
    );
  }

  Future<void> _showManualIdDialog() async {
    String manualId = '';
    await showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(translate('Enter Remote ID')),
          content: TextField(
            autofocus: true,
            decoration: InputDecoration(hintText: translate('Remote ID')),
            onChanged: (v) => manualId = v,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(translate('Cancel')),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                if (manualId.isNotEmpty) {
                  manualId = manualId.replaceAll(' ', '');
                  final finalId = await bind.mainHandleRelayId(id: manualId);
                  _manager.createDevice(id: finalId, label: finalId);
                  if (mounted) setState(() {});
                }
              },
              child: Text(translate('Connect')),
            ),
          ],
        );
      }
    );
  }

  Future<void> _pushScanner() async {
    await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ScanPage(
          onNostrControlLaptop: (uri, password) {
            final label = Uri.tryParse(uri)?.host ?? uri;
            _manager.createDevice(
              id: uri,
              label: label,
              password: password,
              nostrMode: 'control',
            );
          },
          onLanControl: (uri, password) {
            final label = lanIpFromDirectTcp(uri) ?? uri;
            _manager.createDevice(
              id: uri,
              label: label,
              password: password,
              nostrMode: null,
            );
          },
        ),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Widget _buildDevicePage(Device device) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: device.ffi.ffiModel),
        ChangeNotifierProvider.value(value: device.ffi.imageModel),
        ChangeNotifierProvider.value(value: device.ffi.cursorModel),
        ChangeNotifierProvider.value(value: device.ffi.canvasModel),
      ],
      child: RemotePage(
        key: ValueKey(device.sessionId.toString()),
        id: device.id,
        password: device.password,
        isSharedPassword: device.isSharedPassword,
        forceRelay: device.forceRelay,
        nostrMode: device.nostrMode,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final devices = _manager.devices;

    if (devices.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Remote Sessions')),
        body: const Center(child: Text('No active sessions')),
      );
    }

    final activeIndex = devices.indexWhere(
      (d) => d.sessionId.toString() == _manager.activeDeviceId,
    );

    return Stack(
      children: [
        IndexedStack(
          index: activeIndex >= 0 ? activeIndex : 0,
          children: devices.map<Widget>(_buildDevicePage).toList(),
        ),
        Positioned(
          right: 16 + _fabOffset.dx,
          bottom: 16 - _fabOffset.dy,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _fabOffset += details.delta;
              });
            },
            child: FloatingActionButton(
              heroTag: 'session_switcher',
              mini: true,
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              onPressed: _showSessionSheet,
              tooltip: 'Switch device',
              child: Badge(
                isLabelVisible: _sessionCount > 1,
                label: Text('$_sessionCount'),
                child: const Icon(Icons.swap_horiz),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
