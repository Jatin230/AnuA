import 'package:flutter/material.dart';

import '../../common.dart';
import '../device_model.dart';
import '../device_session_manager.dart';
import 'device_tile.dart';

class DeviceListSheet extends StatelessWidget {
  const DeviceListSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final manager = DeviceSessionManager.instance;
    final devices = manager.devices;

    if (devices.isEmpty) {
      return _buildEmptySheet(context, manager);
    }

    final connected = devices.where((d) => d.state == DeviceState.connected).toList();
    final connecting = devices.where((d) => d.state == DeviceState.connecting || d.state == DeviceState.waitingPermission).toList();
    final other = devices.where((d) => d.state == DeviceState.disconnected || d.state == DeviceState.error).toList();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Devices',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            if (connected.isNotEmpty) ...[
              if (connected.length != devices.length)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text('Connected (${connected.length})',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ),
              ...connected.map((d) => _buildDeviceTile(context, manager, d)),
            ],
            if (connecting.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('Connecting (${connecting.length})',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
              ...connecting.map((d) => _buildDeviceTile(context, manager, d)),
            ],
            if (other.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text('Other',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
              ),
              ...other.map((d) => _buildDeviceTile(context, manager, d)),
            ],
            const Divider(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add Another Device'),
                onPressed: () {
                  Navigator.of(context).pop('add');
                },
              ),
            ),
            if (manager.deviceCount >= 3)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Running many simultaneous remote sessions may reduce performance depending on your CPU, GPU, memory, and network.',
                  style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptySheet(BuildContext context, DeviceSessionManager manager) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[400],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Icon(Icons.desktop_windows, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text('No devices connected',
                style: TextStyle(fontSize: 16, color: Colors.grey)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan a Device'),
              onPressed: () => Navigator.of(context).pop('scan'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceTile(BuildContext context, DeviceSessionManager manager, Device device) {
    final isActive = device.sessionId.toString() == manager.activeDeviceId;
    return DeviceTile(
      device: device,
      isActive: isActive,
      onSwitch: () {
        manager.activate(device.sessionId.toString());
        Navigator.of(context).pop();
      },
      onClose: () {
        manager.removeDevice(device.sessionId.toString());
      },
    );
  }
}
