import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/device_model.dart';

import '../../common.dart';

IconData platformIcon(DevicePlatform platform) {
  switch (platform) {
    case DevicePlatform.android:
      return Icons.smartphone;
    case DevicePlatform.ios:
      return Icons.phone_iphone;
    case DevicePlatform.windows:
      return Icons.laptop_windows;
    case DevicePlatform.macos:
      return Icons.laptop_mac;
    case DevicePlatform.linux:
      return Icons.computer;
    case DevicePlatform.unknown:
      return Icons.devices_other;
  }
}

/// Colored circular avatar with the first letter of [name].
class DeviceAvatar extends StatelessWidget {
  final String name;
  final DevicePlatform platform;
  final double size;

  const DeviceAvatar({
    Key? key,
    required this.name,
    this.platform = DevicePlatform.unknown,
    this.size = 44,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final color = str2color(name,
        Theme.of(context).brightness == Brightness.light ? 255 : 150);
    final label = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: color,
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.4,
        ),
      ),
    );
  }
}

/// Green "Ready" pill shown only when the service is verifiably on, otherwise
/// a neutral "Last connected · Today" label is expected from the caller.
class ReadyBadge extends StatelessWidget {
  final bool ready;
  final bool showReadyText;

  const ReadyBadge({
    Key? key,
    required this.ready,
    this.showReadyText = true,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ready
            ? const Color(0xFFE6F7EC)
            : MyTheme.darkGray.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: ready
                  ? const Color(0xFF22C55E)
                  : MyTheme.darkGray,
            ),
          ),
          if (showReadyText) ...[
            const SizedBox(width: 5),
            Text(
              ready ? 'Ready' : 'Offline',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: ready
                    ? const Color(0xFF15803D)
                    : MyTheme.darkGray,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small icon quick-action used on device cards (Connect / Files / Chat).
class DeviceActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const DeviceActionButton({
    Key? key,
    required this.icon,
    required this.label,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 22,
                color: onTap == null ? MyTheme.darkGray : MyTheme.accent),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: onTap == null ? MyTheme.darkGray : MyTheme.dark,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
