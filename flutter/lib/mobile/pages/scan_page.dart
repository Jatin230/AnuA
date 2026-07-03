import 'dart:async';
import 'dart:convert';
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
    // Handle localtunnel format (legacy)
    if (data.startsWith('https://') && data.contains('.localtunnel.me')) {
      connect(context, "tunnel:$data");
      return;
    }
    // Handle Nostr WebRTC host offer (laptop Nostr tab QR)
    if (data.contains('nostr-webrtc://')) {
      if (!data.startsWith('nostr-webrtc://')) {
        data = data.substring(data.indexOf('nostr-webrtc://'));
      }
      final deviceId = _parseNostrDeviceId(data);
      final pubkey = _parseNostrPubkey(data);
      final password = _parseNostrPassword(data);
      if (deviceId.isEmpty) {
        showToast('Invalid Nostr WebRTC QR');
        controller?.resumeCamera();
        return;
      }
      final embeddedOffer = _decodeEmbeddedOffer(_parseNostrOfferParam(data));
      if (embeddedOffer != null) {
        connect(context, _buildNostrWebRtcUri(deviceId, pubkey, embeddedOffer), password: password);
      } else {
        showToast('Fetching host offer from Nostr (may take ~45 s)...');
        final offer = await fetchHostOffer(
          deviceId: deviceId,
          pubkey: pubkey,
          onStatus: (diag) {
            showToast('$diag', timeout: const Duration(seconds: 6));
          },
        );
        if (offer != null && offer.startsWith('webrtc://')) {
          showToast('Establishing WebRTC connection...');
          // Build a nostr-webrtc:// URI and use the existing connect() flow,
          // which navigates to RemotePage → gFFI.start() → Client::_start()
          // → WebRTCStream::new() → normal Anuvadini session over the data channel.
          final uri = _buildNostrWebRtcUri(deviceId, pubkey, offer);
          if (mounted) {
            connect(context, uri, password: password);
          } else {
            // Scanner was popped during the long fetchHostOffer await;
            // fall back to root navigator context.
            final rootCtx = globalKey.currentContext;
            if (rootCtx != null) {
              connect(rootCtx, uri, password: password);
            } else {
              showToast('Page closed during offer fetch — please scan again');
            }
          }
          return;
        }
        final diag = getNostrDiagnosticsSummary();
        if (!mounted) return;
        await showDialog(
          context: context,
          barrierDismissible: true,
          builder: (ctx) => AlertDialog(
            title: const Text('Nostr Offer Not Found'),
            content: SingleChildScrollView(
              child: Text(diag),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        controller?.resumeCamera();
      }
      return;
    }
    if (!data.startsWith('config=')) {
      showToast('Invalid QR code');
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
          await Socket.connect(ip, port, timeout: const Duration(seconds: 6));

      // Build device identity: name + device-local IP
      final deviceName = Platform.isAndroid
          ? 'Android Phone'
          : Platform.isIOS
              ? 'iPhone'
              : 'Mobile';
      final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);
      String myIp = ip; // fallback: use the laptop-facing IP
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            myIp = addr.address;
            break;
          }
        }
        break;
      }

      // Send registration message
      socket.write('ANUVADINI_HELLO:$deviceName:$myIp\n');
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
      showToast('Failed to connect: $e');
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

  String? _parseNostrPassword(String data) {
    final uri = Uri.tryParse(data);
    final pwd = uri?.queryParameters['pwd'];
    if (pwd != null && pwd.isNotEmpty) {
      return pwd;
    }
    return null;
  }

  String? _decodeEmbeddedOffer(String raw) {
    if (raw.isEmpty) return null;
    if (raw.startsWith('webrtc://')) return raw;
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
