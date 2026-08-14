import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/consts.dart';

import 'platform_model.dart';

/// LAN direct server port used by the sharing service. The same port is
/// hard-coded throughout the app (`direct-tcp:<ip>_port_21118`).
const int kLanDirectPort = 21118;

enum DevicePlatform { android, ios, windows, macos, linux, unknown }

DevicePlatform devicePlatformFromString(String? value) {
  switch (value) {
    case 'Android':
    case 'android':
      return DevicePlatform.android;
    case 'iOS':
    case 'ios':
      return DevicePlatform.ios;
    case 'Windows':
    case 'windows':
      return DevicePlatform.windows;
    case 'macOS':
    case 'macos':
    case 'MacOS':
      return DevicePlatform.macos;
    case 'Linux':
    case 'linux':
      return DevicePlatform.linux;
    default:
      return DevicePlatform.unknown;
  }
}

/// A paired device in the Device Hub.
class Device {
  /// Stable identifier (e.g. "This Phone" uses this id too). For a remote
  /// device this is the RustDesk remote id which works across networks.
  String remoteId;

  /// Human friendly name shown on cards.
  String name;

  /// Last known LAN IPv4 address (refreshed on each successful connect).
  String lanIp;

  DevicePlatform platform;

  /// Epoch milliseconds of the last successful connection (out or in).
  int lastConnected;

  bool pinned;

  /// Saved password used for automatic reconnects without re-approval when the
  /// laptop has password-based access enabled.
  String password;

  Device({
    required this.remoteId,
    required this.name,
    this.lanIp = '',
    this.platform = DevicePlatform.unknown,
    this.lastConnected = 0,
    this.pinned = false,
    this.password = '',
  });

  Device copyWith({
    String? remoteId,
    String? name,
    String? lanIp,
    DevicePlatform? platform,
    int? lastConnected,
    bool? pinned,
    String? password,
  }) {
    return Device(
      remoteId: remoteId ?? this.remoteId,
      name: name ?? this.name,
      lanIp: lanIp ?? this.lanIp,
      platform: platform ?? this.platform,
      lastConnected: lastConnected ?? this.lastConnected,
      pinned: pinned ?? this.pinned,
      password: password ?? this.password,
    );
  }

  Device.fromJson(Map<String, dynamic> json)
      : remoteId = (json['remoteId'] ?? json['id'] ?? '').toString(),
        name = (json['name'] ?? '').toString(),
        lanIp = (json['lanIp'] ?? json['ip'] ?? '').toString(),
        platform = devicePlatformFromString(json['platform']?.toString()),
        lastConnected = (json['lastConnected'] as num?)?.toInt() ?? 0,
        pinned = json['pinned'] == true,
        password = (json['password'] ?? '').toString();

  Map<String, dynamic> toJson() => {
        'remoteId': remoteId,
        'name': name,
        'lanIp': lanIp,
        'platform': platform.name,
        'lastConnected': lastConnected,
        'pinned': pinned,
        'password': password,
      };
}

/// Persisted list of paired devices plus an on-demand LAN "Ready" probe.
class DeviceModel extends ChangeNotifier {
  final List<Device> _devices = [];

  /// Per-device probe results cached for the lifetime of the opened page.
  /// True = service verified listening on lanIp:21118 (green Ready badge).
  final Map<String, bool> _probeCache = {};

  bool _loaded = false;

  List<Device> get devices => List.unmodifiable(_devices);

  List<Device> get pinnedDevices =>
      _devices.where((d) => d.pinned).toList();

  bool get loaded => _loaded;

  Device? byRemoteId(String remoteId) {
    for (final d in _devices) {
      if (d.remoteId == remoteId) return d;
    }
    return null;
  }

  /// Match a connect target id (plain remote id or `direct-tcp:<ip>_port_<p>`)
  /// against the saved device list.
  Device? matchById(String id) {
    final direct = byRemoteId(id);
    if (direct != null) return direct;
    String? ip;
    if (id.startsWith('direct-tcp:')) {
      final m = RegExp(r'^direct-tcp:(.+)_port_(\d+)$').firstMatch(id);
      if (m != null) ip = m.group(1);
    }
    if (ip == null) return null;
    for (final d in _devices) {
      if (d.lanIp == ip) return d;
    }
    return null;
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final raw = bind.mainGetLocalOption(key: kDeviceHubDevices);
      if (raw.isNotEmpty) {
        final list = jsonDecode(raw) as List<dynamic>;
        _devices.clear();
        for (final item in list) {
          try {
            _devices.add(Device.fromJson(item as Map<String, dynamic>));
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
          key: kDeviceHubDevices,
          value: jsonEncode(_devices.map((d) => d.toJson()).toList()));
    } catch (_) {}
  }

  Future<void> add(Device device) async {
    final existing = byRemoteId(device.remoteId);
    if (existing != null) {
      _devices.remove(existing);
    }
    _devices.insert(0, device);
    await _persist();
    notifyListeners();
  }

  Future<void> update(Device updated) async {
    final index = _devices.indexWhere((d) => d.remoteId == updated.remoteId);
    if (index < 0) return;
    _devices[index] = updated;
    await _persist();
    notifyListeners();
  }

  Future<void> touchLastConnected(String remoteId, {String? lanIp}) async {
    final device = byRemoteId(remoteId);
    if (device == null) return;
    final updated = device.copyWith(
      lastConnected: DateTime.now().millisecondsSinceEpoch,
      lanIp: (lanIp != null && lanIp.isNotEmpty) ? lanIp : device.lanIp,
    );
    await update(updated);
  }

  Future<void> remove(String remoteId) async {
    _devices.removeWhere((d) => d.remoteId == remoteId);
    _probeCache.remove(remoteId);
    await _persist();
    notifyListeners();
  }

  Future<void> togglePinned(String remoteId) async {
    final index = _devices.indexWhere((d) => d.remoteId == remoteId);
    if (index < 0) return;
    _devices[index] = _devices[index].copyWith(pinned: !_devices[index].pinned);
    _devices.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.lastConnected.compareTo(a.lastConnected);
    });
    await _persist();
    notifyListeners();
  }

  /// On-demand TCP probe to `lanIp:21118` with a short timeout. No background
  /// polling: callers (Devices page open, card tap) trigger this explicitly.
  Future<bool> probe(Device device) async {
    if (device.lanIp.isEmpty) return false;
    final cached = _probeCache[device.remoteId];
    if (cached != null) return cached;
    var ready = false;
    try {
      final socket = await Socket.connect(device.lanIp, kLanDirectPort,
          timeout: const Duration(milliseconds: 800));
      await socket.close();
      ready = true;
    } catch (_) {}
    _probeCache[device.remoteId] = ready;
    notifyListeners();
    return ready;
  }

  Future<bool> probeAndRemember(Device device) => probe(device);

  void clearProbeCache() {
    if (_probeCache.isEmpty) return;
    _probeCache.clear();
    notifyListeners();
  }

  bool probeResult(String remoteId) => _probeCache[remoteId] ?? false;
}

/// Compact human friendly "last connected" text (e.g. "Today · 14:05").
String formatLastConnected(int epochMs) {
  if (epochMs <= 0) return 'Never';
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final now = DateTime.now();
  final local = dt.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(day).inDays;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  if (diffDays == 0) return 'Today · $hh:$mm';
  if (diffDays == 1) return 'Yesterday · $hh:$mm';
  return '${local.month}/${local.day} · $hh:$mm';
}
