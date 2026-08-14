import '../../common.dart';
import '../../models/model.dart';

enum DeviceState {
  connected,
  connecting,
  waitingPermission,
  disconnected,
  error,
}

class Device {
  final String id;
  final String label;
  final SessionID sessionId;
  final FFI ffi;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? nostrMode;
  DeviceState state;
  String? errorMessage;

  Device({
    required this.id,
    required this.label,
    required this.sessionId,
    required this.ffi,
    this.password,
    this.isSharedPassword,
    this.forceRelay,
    this.nostrMode,
    this.state = DeviceState.connecting,
    this.errorMessage,
  });
}
