import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/device_model.dart';
import 'package:flutter_hbb/mobile/pages/scan_page.dart';

import '../../common.dart';
import 'connection_page.dart';

class PairDevicePage extends StatefulWidget {
  const PairDevicePage({Key? key}) : super(key: key);

  @override
  State<PairDevicePage> createState() => _PairDevicePageState();
}

class _PairDevicePageState extends State<PairDevicePage> {
  bool _showRemoteId = false;
  bool _showAdvanced = false;

  final _idController = TextEditingController();
  final _ipController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _idController.dispose();
    _ipController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _connectWithRemoteId() async {
    final id = _idController.text.trim().replaceAll(' ', '');
    if (id.isEmpty) {
      showToast('Enter the Remote ID first');
      return;
    }
    FocusScope.of(context).unfocus();
    await connect(context, id);
    if (!mounted) return;
    await showSaveAsDeviceDialog(context,
        remoteId: id, name: id, lanIp: '', platform: DevicePlatform.unknown);
  }

  Future<void> _connectWithIp() async {
    final ip = _ipController.text.trim();
    if (ip.isEmpty) {
      showToast('Enter the device IP address first');
      return;
    }
    FocusScope.of(context).unfocus();
    final targetId = 'direct-tcp:${ip}_port_$kLanDirectPort';
    final password = _passwordController.text.trim();
    await connect(context, targetId,
        password: password.isEmpty ? null : password);
    if (!mounted) return;
    await showSaveAsDeviceDialog(context,
        remoteId: targetId, name: ip, lanIp: ip, platform: DevicePlatform.unknown);
  }

  Future<void> _scanQr() async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ScanPage(
        onConnectedDevice: (ip, port) async {
          if (!mounted) return;
          await showSaveAsDeviceDialog(context,
              remoteId: 'direct-tcp:${ip}_port_$port',
              name: ip,
              lanIp: ip,
              platform: DevicePlatform.unknown);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pair Device')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Choose how to connect to the other device. Once connected it '
            'will appear in My Devices for quick access.',
            style: TextStyle(color: MyTheme.darkGray, fontSize: 13),
          ),
          const SizedBox(height: 16),
          _methodCard(
            icon: Icons.qr_code,
            color: const Color(0xFF16A34A),
            title: 'My QR Code',
            subtitle:
                'Show your LAN & Internet QR codes to pair from the other device',
            onTap: () => showMyQrDialog(context),
          ),
          _methodCard(
            icon: Icons.qr_code_scanner,
            color: MyTheme.accent,
            title: 'Scan QR Code',
            subtitle: 'Point the camera at the device\'s QR code',
            onTap: _scanQr,
          ),
          _methodCard(
            icon: Icons.pin_outlined,
            color: Colors.deepPurple,
            title: 'Enter Remote ID',
            subtitle: 'Use the 9-character ID shown on the other device',
            onTap: () => setState(() {
              _showRemoteId = !_showRemoteId;
              _showAdvanced = false;
            }),
          ),
          if (_showRemoteId) _buildRemoteIdForm(),
          _methodCard(
            icon: Icons.tune,
            color: Colors.teal,
            title: 'Direct IP + Password (Advanced)',
            subtitle: 'Connect straight over your local network',
            onTap: () => setState(() {
              _showAdvanced = !_showAdvanced;
              _showRemoteId = false;
            }),
          ),
          if (_showAdvanced) _buildAdvancedForm(),
        ],
      ),
    );
  }

  Widget _methodCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.12),
          child: Icon(icon, color: color),
        ),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        subtitle: Text(subtitle,
            style: TextStyle(color: MyTheme.darkGray, fontSize: 12)),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  Widget _buildRemoteIdForm() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _idController,
                keyboardType: TextInputType.number,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Remote ID',
                  hintText: 'e.g. 123456789',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.pin_outlined),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _connectWithRemoteId,
                icon: const Icon(Icons.bolt),
                label: const Text('Connect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: MyTheme.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAdvancedForm() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _ipController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Device IP Address',
                  hintText: 'e.g. 192.168.1.10',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lan_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password (optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Port $kLanDirectPort · direct LAN connection',
                style: TextStyle(color: MyTheme.darkGray, fontSize: 12),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _connectWithIp,
                icon: const Icon(Icons.bolt),
                label: const Text('Connect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: MyTheme.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Offer to save the freshly connected peer as a device in the hub.
/// Returns true when the user saved it.
Future<bool> showSaveAsDeviceDialog(
  BuildContext context, {
  required String remoteId,
  String? name,
  String? lanIp,
  DevicePlatform? platform,
}) async {
  final nameController = TextEditingController(text: name ?? remoteId);
  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save as Device?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Give this device a friendly name so you can find it '
              'again in My Devices.'),
          const SizedBox(height: 12),
          TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Device name',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.devices),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Save Device'),
        ),
      ],
    ),
  );
  if (saved == true) {
    final finalName =
        nameController.text.trim().isEmpty ? remoteId : nameController.text.trim();
    await gFFI.deviceModel.add(Device(
      remoteId: remoteId,
      name: finalName,
      lanIp: lanIp ?? '',
      platform: platform ?? DevicePlatform.unknown,
      lastConnected: DateTime.now().millisecondsSinceEpoch,
    ));
    if (context.mounted) {
      showToast('$finalName added to My Devices');
    }
  }
  return saved == true;
}
