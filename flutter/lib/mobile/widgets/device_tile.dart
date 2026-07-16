import 'package:flutter/material.dart';

import '../../common.dart';
import '../device_model.dart';

class DeviceTile extends StatelessWidget {
  final Device device;
  final bool isActive;
  final VoidCallback? onSwitch;
  final VoidCallback? onClose;

  const DeviceTile({
    super.key,
    required this.device,
    this.isActive = false,
    this.onSwitch,
    this.onClose,
  });

  IconData _iconForState() {
    switch (device.state) {
      case DeviceState.connected:
        return Icons.desktop_windows;
      case DeviceState.connecting:
        return Icons.desktop_windows;
      case DeviceState.waitingPermission:
        return Icons.desktop_windows;
      case DeviceState.disconnected:
        return Icons.desktop_access_disabled;
      case DeviceState.error:
        return Icons.error_outline;
    }
  }

  Color _colorForState() {
    switch (device.state) {
      case DeviceState.connected:
        return Colors.green;
      case DeviceState.connecting:
        return Colors.orange;
      case DeviceState.waitingPermission:
        return Colors.amber;
      case DeviceState.disconnected:
        return Colors.grey;
      case DeviceState.error:
        return Colors.red;
    }
  }

  String _labelForState() {
    switch (device.state) {
      case DeviceState.connected:
        return 'Connected';
      case DeviceState.connecting:
        return 'Connecting...';
      case DeviceState.waitingPermission:
        return 'Waiting for Permission';
      case DeviceState.disconnected:
        return 'Disconnected';
      case DeviceState.error:
        return device.errorMessage ?? 'Error';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(_iconForState(), color: _colorForState(), size: 32),
      title: Text(device.label, style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _colorForState(),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(_labelForState(), style: TextStyle(color: _colorForState(), fontSize: 12)),
        ],
      ),
      trailing: isActive
          ? const Chip(
              label: Text('Active', style: TextStyle(fontSize: 11)),
              backgroundColor: Colors.green,
              labelStyle: TextStyle(color: Colors.white),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : TextButton(
              onPressed: onSwitch,
              child: const Text('Switch'),
            ),
      onLongPress: onClose,
    );
  }
}
