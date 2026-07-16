import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../models/model.dart';
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

    if (result == 'scan') {
      _pushScanner();
    }
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
