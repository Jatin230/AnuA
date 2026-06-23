import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:zxing2/qrcode.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import '../widgets/dialog.dart';
import 'webrtc_signaling.dart';
import '../../debug_agent_log.dart';

class ScanPage extends StatefulWidget {
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  QRViewController? controller;
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  StreamSubscription? scanSubscription;

  @override
  void reassemble() {
    super.reassemble();
    if (isAndroid && controller != null) {
      controller!.pauseCamera();
    } else if (controller != null) {
      controller!.resumeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan QR'),
        actions: [
          _buildImagePickerButton(),
          _buildFlashToggleButton(),
          _buildCameraSwitchButton(),
        ],
      ),
      body: _buildQrView(context),
    );
  }

  Widget _buildQrView(BuildContext context) {
    var scanArea = MediaQuery.of(context).size.width < 400 ||
            MediaQuery.of(context).size.height < 400
        ? 150.0
        : 300.0;
    return QRView(
      key: qrKey,
      onQRViewCreated: _onQRViewCreated,
      overlay: QrScannerOverlayShape(
        borderColor: Colors.red,
        borderRadius: 10,
        borderLength: 30,
        borderWidth: 10,
        cutOutSize: scanArea,
      ),
      onPermissionSet: (ctrl, p) => _onPermissionSet(context, ctrl, p),
    );
  }

  void _onQRViewCreated(QRViewController controller) {
    setState(() {
      this.controller = controller;
    });
    scanSubscription = controller.scannedDataStream.listen((scanData) {
      if (scanData.code != null) {
        controller.pauseCamera();
        showServerSettingFromQr(scanData.code!);
      }
    });
  }

  void _onPermissionSet(BuildContext context, QRViewController ctrl, bool p) {
    if (!p) {
      showToast('No permission');
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file != null) {
      try {
        var image = img.decodeImage(await File(file.path).readAsBytes())!;
        LuminanceSource source = RGBLuminanceSource(
          image.width,
          image.height,
          image.getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
        );
        var bitmap = BinaryBitmap(HybridBinarizer(source));

        var reader = QRCodeReader();
        var result = reader.decode(bitmap);
        if (result.text.startsWith(bind.mainUriPrefixSync())) {
          handleUriLink(uriString: result.text);
        } else {
          showServerSettingFromQr(result.text);
        }
      } catch (e) {
        showToast('No QR code found');
      }
    }
  }

  Widget _buildImagePickerButton() {
    return IconButton(
      color: Colors.white,
      icon: Icon(Icons.image_search),
      iconSize: 32.0,
      onPressed: _pickImage,
    );
  }

  Widget _buildFlashToggleButton() {
    return IconButton(
      color: Colors.yellow,
      icon: Icon(Icons.flash_on),
      iconSize: 32.0,
      onPressed: () async {
        await controller?.toggleFlash();
      },
    );
  }

  Widget _buildCameraSwitchButton() {
    return IconButton(
      color: Colors.white,
      icon: Icon(Icons.switch_camera),
      iconSize: 32.0,
      onPressed: () async {
        await controller?.flipCamera();
      },
    );
  }

  @override
  void dispose() {
    scanSubscription?.cancel();
    controller?.dispose();
    super.dispose();
  }

  void showServerSettingFromQr(String data) async {
    closeConnection();
    await controller?.pauseCamera();
    data = data.trim();
    // Handle direct local IP connection (laptop QR code)
    if (data.startsWith('anuvadini://')) {
      final address = data.substring('anuvadini://'.length).trim();
      if (address.startsWith('direct-tcp:')) {
        // Laptop registration QR — register this phone with the laptop
        final hostPart = address.substring('direct-tcp:'.length);
        // Expected format: <ip>_port_<port>
        final match = RegExp(r'^(.+)_port_(\d+)$').firstMatch(hostPart);
        if (match != null) {
          final ip = match.group(1)!;
          final port = int.parse(match.group(2)!);
          await _registerWithLaptop(context, ip, port);
        } else {
          showToast('Invalid QR code format');
          controller?.resumeCamera();
        }
      } else {
        // Other anuvadini:// deep links (tunnel, etc.) — normal connect
        connect(context, address);
      }
      return;
    }
    if (data.contains('nostr-webrtc://')) {
      if (!data.startsWith('nostr-webrtc://')) {
        data = data.substring(data.indexOf('nostr-webrtc://'));
      }
      final deviceId = _parseNostrDeviceId(data);
      final pubkey = _parseNostrPubkey(data);
      if (deviceId.isEmpty) {
        showToast('Invalid Nostr WebRTC QR');
        controller?.resumeCamera();
        return;
      }
      // #region agent log
      agentDebugLog('N3', 'scan_page.dart:nostrScan', 'nostr qr parsed', {
        'deviceId': deviceId,
        'pubkeyLen': pubkey.length,
        'hasEmbeddedOffer': _decodeEmbeddedOffer(_parseNostrOfferParam(data)) != null,
      });
      // #endregion
      final embeddedOffer = _decodeEmbeddedOffer(_parseNostrOfferParam(data));
      if (embeddedOffer != null) {
        connect(context, _buildNostrWebRtcUri(deviceId, pubkey, embeddedOffer));
      } else {
        showToast('Fetching host offer from Nostr (may take ~15 s)...');
        final offer = await fetchHostOffer(deviceId: deviceId, pubkey: pubkey);
        if (offer != null && offer.startsWith('webrtc://')) {
          connect(context, _buildNostrWebRtcUri(deviceId, pubkey, offer));
        } else {
          showToast(
              'Failed to fetch host offer — open Nostr tab on laptop, wait 10 s, then rescan');
          controller?.resumeCamera();
        }
      }
      return;
    }
    // Handle localtunnel format (legacy)
    if (data.startsWith('https://') && data.contains('.localtunnel.me')) {
      connect(context, "tunnel:$data");
      return;
    }
    if (!data.startsWith('config=')) {
      if (data.length > 500) {
        showToast('QR unreadable — use the small Nostr QR (wait for it to finish generating)');
      } else {
        showToast('Invalid QR code');
      }
      controller?.resumeCamera();
      return;
    }
    try {
      final sc = ServerConfig.decode(data.substring(7));
      Timer(Duration(milliseconds: 60), () {
        showServerSettingsWithValue(sc, gFFI.dialogManager, null);
      });
    } catch (e) {
      showToast('Invalid QR code');
    }
  }

  /// Opens a plain TCP connection to the laptop, sends `ANUVADINI_HELLO`, and
  /// waits for `ANUVADINI_ACK`.  No Anuvadini crypto handshake is involved.
  Future<void> _registerWithLaptop(
      BuildContext ctx, String ip, int port) async {
    showToast('Connecting to laptop at $ip:$port...');
    try {
      final socket =
          await Socket.connect(ip, port, timeout: const Duration(seconds: 10));

      // Build device identity: name + device-local IP
      final deviceName = Platform.isAndroid
          ? 'Android Phone'
          : Platform.isIOS
              ? 'iPhone'
              : 'Mobile';
      String myIp = bind.mainGetOptionSync(key: 'local-ip-addr');
      if (myIp.isEmpty || myIp.startsWith('192.0.0.')) {
        final interfaces = await NetworkInterface.list(
            type: InternetAddressType.IPv4, includeLoopback: false);
        for (final iface in interfaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback && !addr.address.startsWith('192.0.0.')) {
              myIp = addr.address;
              break;
            }
          }
          if (myIp.isNotEmpty && !myIp.startsWith('192.0.0.')) break;
        }
      }
      if (myIp.isEmpty) myIp = ip;

      // Fetch the phone's current temporary password so the laptop can connect
      // back without requiring manual password entry.
      String tempPassword = '';
      try {
        tempPassword = await bind.mainGetTemporaryPassword();
      } catch (_) {}

      // Send registration message — format: ANUVADINI_HELLO:<name>:<myIp>:<tempPwd>
      // The tempPassword field is optional (empty string if unavailable).
      socket.write('ANUVADINI_HELLO:$deviceName:$myIp:$tempPassword\n');
      await socket.flush();

      // Wait for acknowledgment (up to 4 s)
      String response = '';
      try {
        await for (final chunk
            in socket.timeout(const Duration(seconds: 4))) {
          response += String.fromCharCodes(chunk);
          if (response.contains('ANUVADINI_ACK')) break;
        }
      } catch (_) {}

      await socket.close();

      if (response.contains('ANUVADINI_ACK')) {
        showToast('Registered with laptop successfully!');
      } else {
        showToast('Connected to laptop (no ACK received)');
      }
    } catch (e) {
      showToast(
          'Cannot reach laptop at $ip:$port. Phone IP and laptop IP must be on the same Wi-Fi (e.g. both 192.168.68.x). Allow port $port in Windows Firewall. Disable router "AP/client isolation" if enabled.');
      controller?.resumeCamera();
    }
  }

  String _parseNostrDeviceId(String data) {
    final uri = Uri.tryParse(data);
    if (uri != null && uri.host.isNotEmpty) {
      return uri.host;
    }
    return RegExp(r'nostr-webrtc://([^?#]+)').firstMatch(data)?.group(1) ?? '';
  }

  String _parseNostrPubkey(String data) {
    final uri = Uri.tryParse(data);
    if (uri != null && uri.fragment.isNotEmpty) {
      return uri.fragment;
    }
    return RegExp(r'#([^?#]+)$').firstMatch(data)?.group(1) ?? '';
  }

  String _parseNostrOfferParam(String data) {
    final uri = Uri.tryParse(data);
    final fromUri = uri?.queryParameters['offer'];
    if (fromUri != null && fromUri.isNotEmpty) {
      return fromUri;
    }
    return RegExp(r'[?&]offer=([^#&]+)').firstMatch(data)?.group(1) ?? '';
  }

  /// Offer in QR is base64-encoded `webrtc://…`, not plain text.
  String? _decodeEmbeddedOffer(String raw) {
    if (raw.isEmpty) {
      return null;
    }
    if (raw.startsWith('webrtc://')) {
      return raw;
    }
    try {
      final decoded = utf8.decode(base64Decode(raw));
      return decoded.startsWith('webrtc://') ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  String _buildNostrWebRtcUri(String deviceId, String pubkey, String offer) {
    final encodedOffer = base64Encode(utf8.encode(offer));
    return 'nostr-webrtc://$deviceId?offer=$encodedOffer#$pubkey';
  }
}
