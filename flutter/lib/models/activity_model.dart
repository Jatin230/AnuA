import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';

import 'platform_model.dart';

enum ActivityType {
  connectOut, // you connected to a device
  connectIn, // a device shared its screen with you
  shareStart,
  shareStop,
  fileTransfer,
}

class ActivityEvent {
  final ActivityType type;
  final String title;
  final String detail;
  final int time;

  ActivityEvent({
    required this.type,
    required this.title,
    this.detail = '',
    int? time,
  }) : time = time ?? DateTime.now().millisecondsSinceEpoch;

  String get kindLabel {
    switch (type) {
      case ActivityType.connectOut:
        return 'Connected';
      case ActivityType.connectIn:
        return 'Shared with you';
      case ActivityType.shareStart:
        return 'Sharing started';
      case ActivityType.shareStop:
        return 'Sharing stopped';
      case ActivityType.fileTransfer:
        return 'File transfer';
    }
  }

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'title': title,
        'detail': detail,
        'time': time,
      };

  factory ActivityEvent.fromJson(Map<String, dynamic> json) {
    ActivityType type = ActivityType.connectOut;
    for (final t in ActivityType.values) {
      if (t.name == json['type']) {
        type = t;
        break;
      }
    }
    return ActivityEvent(
      type: type,
      title: (json['title'] ?? '').toString(),
      detail: (json['detail'] ?? '').toString(),
      time: (json['time'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persisted reverse-chronological activity log (capped at [kMaxEvents]).
class ActivityModel extends ChangeNotifier {
  static const int kMaxEvents = 50;

  final List<ActivityEvent> _events = [];
  bool _loaded = false;

  List<ActivityEvent> get events => List.unmodifiable(_events);

  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = bind.mainGetLocalOption(key: kDeviceHubActivity);
      if (raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        _events.clear();
        for (final item in list) {
          try {
            _events.add(ActivityEvent.fromJson(item as Map<String, dynamic>));
          } catch (_) {}
        }
      }
    } catch (_) {}
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      await bind.mainSetLocalOption(
          key: kDeviceHubActivity,
          value: jsonEncode(_events.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> add(ActivityEvent event) async {
    _events.insert(0, event);
    while (_events.length > kMaxEvents) {
      _events.removeLast();
    }
    await _persist();
    notifyListeners();
  }

  Future<void> clear() async {
    _events.clear();
    await _persist();
    notifyListeners();
  }
}
