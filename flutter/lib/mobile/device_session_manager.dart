import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/model.dart';
import '../../common.dart';
import 'device_model.dart';

class DeviceSessionManager extends ChangeNotifier {
  DeviceSessionManager._();
  static final DeviceSessionManager instance = DeviceSessionManager._();

  final Map<String, Device> _devices = {};
  String? _activeDeviceId;

  List<Device> get devices => _devices.values.toList();
  String? get activeDeviceId => _activeDeviceId;
  int get deviceCount => _devices.length;

  Device? get activeDevice =>
      _activeDeviceId != null ? _devices[_activeDeviceId] : null;

  Device createDevice({
    required String id,
    required String label,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? nostrMode,
  }) {
    final device = _devices.values.firstWhere(
      (d) => d.id == id,
      orElse: () => _createNewDevice(id: id, label: label, password: password, isSharedPassword: isSharedPassword, forceRelay: forceRelay, nostrMode: nostrMode),
    );
    activate(device.sessionId.toString());
    return device;
  }

  Device _createNewDevice({
    required String id,
    required String label,
    String? password,
    bool? isSharedPassword,
    bool? forceRelay,
    String? nostrMode,
  }) {
    final sessionId = Uuid().v4obj();
    final ffi = FFI(sessionId);
    final device = Device(
      id: id,
      label: label,
      sessionId: sessionId,
      ffi: ffi,
      password: password,
      isSharedPassword: isSharedPassword,
      forceRelay: forceRelay,
      nostrMode: nostrMode,
    );
    _devices[sessionId.toString()] = device;
    return device;
  }

  void activate(String sessionIdStr) {
    if (_devices.containsKey(sessionIdStr)) {
      _activeDeviceId = sessionIdStr;
      _updateGffiOverride();
      notifyListeners();
    }
  }

  void removeDevice(String sessionIdStr) {
    final device = _devices.remove(sessionIdStr);
    if (device != null) {
      device.ffi.close(closeSession: true);
    }
    if (_activeDeviceId == sessionIdStr) {
      _activeDeviceId = _devices.keys.isNotEmpty ? _devices.keys.first : null;
    }
    _updateGffiOverride();
    notifyListeners();
  }

  void removeAll() {
    for (final device in _devices.values) {
      device.ffi.close(closeSession: true);
    }
    _devices.clear();
    _activeDeviceId = null;
    _updateGffiOverride();
    notifyListeners();
  }

  void _updateGffiOverride() {
    final device = activeDevice;
    if (device != null) {
      setGffiOverride(() => device.ffi);
    } else {
      setGffiOverride(null);
    }
  }

  void updateState(String sessionIdStr, DeviceState state, {String? error}) {
    final device = _devices[sessionIdStr];
    if (device != null) {
      device.state = state;
      device.errorMessage = error;
      notifyListeners();
    }
  }

  Device? getDeviceById(String id) {
    try {
      return _devices.values.firstWhere((d) => d.id == id);
    } catch (_) {
      return null;
    }
  }
}
