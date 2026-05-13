import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';

class MobileControlPage extends StatefulWidget {
  const MobileControlPage({super.key});

  @override
  _MobileControlPageState createState() => _MobileControlPageState();
}

class _MobileControlPageState extends State<MobileControlPage> {
  String? _connectionUrl;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _generateConnectionUrl();
  }

  /// Gets local IP and builds the connection URL immediately — no external tunnel needed.
  Future<void> _generateConnectionUrl() async {
    setState(() {
      _loading = true;
      _error = null;
      _connectionUrl = null;
    });
    try {
      String? localIp = await _getLocalIpAddress();
      if (localIp == null) {
        setState(() {
          _error = 'Could not determine local IP address.\nMake sure you are connected to a Wi-Fi network.';
          _loading = false;
        });
        return;
      }
      // Format: anuvadini://direct-tcp:ip_port_port — scanned by the mobile app to connect directly
      final url = 'anuvadini://direct-tcp:${localIp}_port_21118';
      setState(() {
        _connectionUrl = url;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Finds the best local non-loopback IPv4 address.
  Future<String?> _getLocalIpAddress() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (var interface in interfaces) {
      for (var addr in interface.addresses) {
        // Prefer 192.168.x.x or 10.x.x.x addresses (common home/office Wi-Fi)
        if (addr.address.startsWith('192.168.') ||
            addr.address.startsWith('10.') ||
            addr.address.startsWith('172.')) {
          return addr.address;
        }
      }
    }
    // Fallback: return any non-loopback IPv4
    for (var interface in interfaces) {
      for (var addr in interface.addresses) {
        return addr.address;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile Control via QR'),
        backgroundColor: MyTheme.accent,
      ),
      body: Container(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mobile_friendly, size: 64, color: MyTheme.accent),
                  const SizedBox(height: 24),

                  if (_loading) ...[
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    const Text('Detecting local IP address...'),
                  ],

                  if (_error != null) ...[
                    const Icon(Icons.error_outline, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _generateConnectionUrl,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],

                  if (_connectionUrl != null) ...[
                    const Text(
                      'Scan with Anuvadini Mobile App',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Make sure your phone is on the same Wi-Fi network.',
                      style: TextStyle(color: Colors.grey, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    QrImageView(
                      data: _connectionUrl!,
                      version: QrVersions.auto,
                      size: 240.0,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[200],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: SelectableText(
                              _connectionUrl!,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _connectionUrl!));
                              showToast('Copied!');
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: _generateConnectionUrl,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh IP'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
