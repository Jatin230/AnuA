import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/chat_page.dart';
import 'package:flutter_hbb/mobile/pages/device_hub_widgets.dart';
import 'package:flutter_hbb/mobile/pages/home_page.dart';
import 'package:flutter_hbb/mobile/pages/pair_device_page.dart';
import 'package:flutter_hbb/models/device_model.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../models/chat_model.dart';

class DevicesPage extends StatefulWidget implements PageShape {
  @override
  final String title = 'Devices';

  @override
  final Widget icon = const Icon(Icons.devices);

  @override
  final List<Widget> appBarActions = [];

  DevicesPage({Key? key}) : super(key: key);

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      gFFI.deviceModel.load();
      _probeAll();
    });
  }

  Future<void> _probeAll() async {
    if (_probing) return;
    setState(() => _probing = true);
    gFFI.deviceModel.clearProbeCache();
    final devices = gFFI.deviceModel.devices;
    for (final d in devices) {
      await gFFI.deviceModel.probe(d);
    }
    if (mounted) setState(() => _probing = false);
  }

  String _connectTarget(Device device) {
    final directId = device.lanIp.isNotEmpty
        ? 'direct-tcp:${device.lanIp}_port_$kLanDirectPort'
        : '';
    final relayId = !device.remoteId.startsWith('direct-tcp:')
        ? device.remoteId
        : '';
    if (directId.isNotEmpty) return directId;
    if (relayId.isNotEmpty) return relayId;
    return device.remoteId;
  }

  Future<void> _connect(Device device, {bool isFileTransfer = false}) async {
    final target = _connectTarget(device);
    if (target.isEmpty) {
      showToast('No connect target for ${device.name}');
      return;
    }
    // LAN direct first, fall back to the remote id / Nostr path only when the
    // direct server is unreachable.
    if (device.lanIp.isNotEmpty && !device.remoteId.startsWith('direct-tcp:')) {
      final ready = await gFFI.deviceModel.probe(device);
      if (!ready) {
        await connect(context, device.remoteId, isFileTransfer: isFileTransfer);
        return;
      }
    }
    await connect(context, target, isFileTransfer: isFileTransfer);
  }

  Future<void> _chat(Device device) async {
    MessageKey? key;
    for (final k in gFFI.chatModel.messages.keys) {
      if (k.peerId == device.remoteId) {
        key = k;
        break;
      }
    }
    if (key != null) {
      gFFI.chatModel.changeCurrentKey(key);
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Chat')),
        body: ChatPage(type: ChatPageType.mobileMain),
      ),
    ));
  }

  Future<void> _editDevice(Device device) async {
    final nameController = TextEditingController(text: device.name);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Device'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Device name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save')),
        ],
      ),
    );
    if (saved == true) {
      final name = nameController.text.trim();
      if (name.isNotEmpty) {
        await gFFI.deviceModel.update(device.copyWith(name: name));
      }
    }
  }

  Future<void> _removeDevice(Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Device?'),
        content: Text(
            '${device.name} will be removed from My Devices. This does not '
            'affect the other device.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove',
                  style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      await gFFI.deviceModel.remove(device.remoteId);
    }
  }

  void _openPairDevice() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const PairDevicePage(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: gFFI.deviceModel,
      child: Consumer<DeviceModel>(
        builder: (context, model, _) {
          final devices = model.devices;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'My Devices',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (_probing)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      IconButton(
                        tooltip: 'Refresh',
                        icon: const Icon(Icons.refresh),
                        onPressed: _probeAll,
                      ),
                    IconButton(
                      tooltip: 'Pair Device',
                      icon: const Icon(Icons.add),
                      color: MyTheme.accent,
                      onPressed: _openPairDevice,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: devices.isEmpty
                    ? _buildEmpty(model)
                    : RefreshIndicator(
                        onRefresh: _probeAll,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                          itemCount: devices.length,
                          itemBuilder: (context, index) =>
                              _buildDeviceCard(devices[index]),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildEmpty(DeviceModel model) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.devices_other, size: 56, color: MyTheme.darkGray),
          const SizedBox(height: 12),
          const Text('No paired devices',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'Pair a device to connect in one tap.',
            style: TextStyle(color: MyTheme.darkGray, fontSize: 13),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _openPairDevice,
            icon: const Icon(Icons.add),
            label: const Text('Pair Device'),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCard(Device device) {
    final ready = gFFI.deviceModel.probeResult(device.remoteId);
    final hasLan = device.lanIp.isNotEmpty;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.symmetric(vertical: 5),
      elevation: 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _connect(device),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  DeviceAvatar(name: device.name, platform: device.platform),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                device.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (device.pinned) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.push_pin,
                                  size: 14, color: MyTheme.darkGray),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          'Last connected · ${formatLastConnected(device.lastConnected)}',
                          style: TextStyle(
                              color: MyTheme.darkGray, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (hasLan)
                    ReadyBadge(ready: ready, showReadyText: false)
                  else
                    const Icon(Icons.public, size: 16, color: MyTheme.darkGray),
                  PopupMenuButton<String>(
                    tooltip: '',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (value) {
                      switch (value) {
                        case 'rename':
                          _editDevice(device);
                          break;
                        case 'pin':
                          gFFI.deviceModel.togglePinned(device.remoteId);
                          break;
                        case 'remove':
                          _removeDevice(device);
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                          value: 'rename', child: Text('Rename')),
                      PopupMenuItem(
                          value: 'pin',
                          child: Text(device.pinned ? 'Unpin' : 'Pin')),
                      const PopupMenuItem(
                          value: 'remove',
                          child: Text('Remove',
                              style: TextStyle(color: Colors.red))),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  DeviceActionButton(
                    icon: Icons.laptop_mac,
                    label: 'Connect',
                    onTap: () => _connect(device),
                  ),
                  DeviceActionButton(
                    icon: Icons.folder_outlined,
                    label: 'Files',
                    onTap: () => _connect(device, isFileTransfer: true),
                  ),
                  DeviceActionButton(
                    icon: Icons.chat_bubble_outline,
                    label: 'Chat',
                    onTap: () => _chat(device),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
