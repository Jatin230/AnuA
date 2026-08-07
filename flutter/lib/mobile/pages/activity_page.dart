import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/activity_model.dart';
import 'package:flutter_hbb/mobile/pages/home_page.dart';
import 'package:provider/provider.dart';

import '../../common.dart';

class ActivityPage extends StatefulWidget implements PageShape {
  @override
  final String title = 'Activity';

  @override
  final Widget icon = const Icon(Icons.history);

  @override
  final List<Widget> appBarActions = [];

  ActivityPage({Key? key}) : super(key: key);

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  @override
  void initState() {
    super.initState();
    gFFI.activityModel.load();
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Activity?'),
        content: const Text('All recorded activity will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirmed == true) {
      await gFFI.activityModel.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Clear all',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearAll,
          ),
        ],
      ),
      body: ChangeNotifierProvider.value(
        value: gFFI.activityModel,
        child: Consumer<ActivityModel>(
          builder: (context, model, _) {
            final events = model.events;
            if (events.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.history_toggle_off,
                        size: 56, color: MyTheme.darkGray),
                    const SizedBox(height: 12),
                    const Text('No activity yet',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text(
                      'Share your screen or connect to a device and it will '
                      'show up here.',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: MyTheme.darkGray, fontSize: 13),
                    ),
                  ],
                ),
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: events.length,
              itemBuilder: (context, index) =>
                  _buildEventCard(events[index]),
            );
          },
        ),
      ),
    );
  }

  Widget _buildEventCard(ActivityEvent event) {
    final (icon, color) = switch (event.type) {
      ActivityType.connectOut => (Icons.call_made, MyTheme.accent),
      ActivityType.connectIn => (Icons.call_received, const Color(0xFF16A34A)),
      ActivityType.shareStart => (Icons.play_arrow, MyTheme.accent),
      ActivityType.shareStop => (Icons.stop, Colors.deepOrange),
      ActivityType.fileTransfer => (Icons.folder_outlined, Colors.deepPurple),
    };
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.12),
          child: Icon(icon, color: color, size: 20),
        ),
        title: Text(
          event.kindLabel,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        ),
        subtitle: Text(
          event.detail.isNotEmpty ? event.detail : event.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: MyTheme.darkGray, fontSize: 12),
        ),
        trailing: Text(
          _timeLabel(event.time),
          style: TextStyle(color: MyTheme.darkGray, fontSize: 11),
        ),
      ),
    );
  }

  String _timeLabel(int epochMs) {
    if (epochMs <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs).toLocal();
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.month}/${dt.day}';
  }
}
