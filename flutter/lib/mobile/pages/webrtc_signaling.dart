import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/debug_agent_log.dart';

class NostrOfferLookup {
  final String deviceId;
  final String pubkey;
  final String offer;
  final String relay;

  NostrOfferLookup({
    required this.deviceId,
    required this.pubkey,
    required this.offer,
    required this.relay,
  });
}

/// nos.lol is excluded — its TLS certificate is not trusted on Windows
/// (native-tls os error -2146762487) and causes connection failures.
const List<String> _defaultNostrRelays = [
  'wss://relay.damus.io',
  'wss://relay.primal.net',
];

final Map<String, String> nostrDiagnostics = {};

String getNostrDiagnosticsSummary() {
  if (nostrDiagnostics.isEmpty) {
    return 'No relays contacted.';
  }
  return nostrDiagnostics.entries.map((e) {
    final name = e.key.replaceFirst('wss://', '');
    return '$name: ${e.value}';
  }).join('\n');
}

String _normalizeDeviceId(String deviceId) => deviceId.replaceAll(' ', '');

String _normalizePubkey(String pubkey) => pubkey.toLowerCase();

/// Poll Nostr relays until the laptop publishes its WebRTC offer.
/// ICE gathering on the host can take ~8 s, so we retry with backoff.
/// [onStatus] is called with current diagnostic summary after each attempt.
Future<String?> fetchHostOffer({
  required String deviceId,
  required String pubkey,
  Duration timeout = const Duration(seconds: 45),
  void Function(String summary)? onStatus,
}) async {
  nostrDiagnostics.clear();
  final normalizedId = _normalizeDeviceId(deviceId);
  final normalizedPubkey = _normalizePubkey(pubkey);
  // #region agent log
  agentDebugLog('N4', 'webrtc_signaling.dart:fetchHostOffer', 'fetch started', {
    'deviceId': normalizedId,
    'pubkeyLen': normalizedPubkey.length,
    'timeoutSec': timeout.inSeconds,
  });
  // #endregion
  final deadline = DateTime.now().add(timeout);
  var delay = const Duration(seconds: 2);
  var attempt = 0;

  while (DateTime.now().isBefore(deadline)) {
    attempt++;
    final results = await Future.wait(
      _defaultNostrRelays.map((relay) async {
        try {
          return await _fetchOfferFromRelay(
            relay: relay,
            deviceId: normalizedId,
            pubkey: normalizedPubkey,
            timeout: const Duration(seconds: 15),
          );
        } catch (e) {
          nostrDiagnostics[relay] = 'Conn error: ${e.toString().split(":").last.trim()}';
          // #region agent log
          agentDebugLog('N5', 'webrtc_signaling.dart:fetchHostOffer', 'relay error', {
            'relay': relay,
            'err': e.toString(),
          });
          // #endregion
          return null;
        }
      }),
    );
    for (final result in results) {
      if (result != null) {
        // #region agent log
        agentDebugLog('N6', 'webrtc_signaling.dart:fetchHostOffer', 'offer found', {
          'attempt': attempt,
          'relay': result.relay,
          'offerLen': result.offer.length,
        });
        // #endregion
        return result.offer;
      }
    }

    // #region agent log
    agentDebugLog('N5', 'webrtc_signaling.dart:fetchHostOffer', 'attempt miss', {
      'attempt': attempt,
      'relays': _defaultNostrRelays.length,
    });
    // #endregion

    if (onStatus != null) {
      onStatus(getNostrDiagnosticsSummary());
    }

    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) {
      break;
    }
    await Future.delayed(delay);
    if (delay < const Duration(seconds: 5)) {
      delay += const Duration(seconds: 1);
    }
  }
  // #region agent log
  agentDebugLog('N6', 'webrtc_signaling.dart:fetchHostOffer', 'fetch failed all attempts', {
    'attempts': attempt,
  });
  // #endregion
  return null;
}

Future<NostrOfferLookup?> _fetchOfferFromRelay({
  required String relay,
  required String deviceId,
  required String pubkey,
  required Duration timeout,
}) async {
  nostrDiagnostics[relay] = 'Connecting...';
  WebSocket socket;
  try {
    socket = await WebSocket.connect(relay).timeout(timeout);
  } catch (e) {
    nostrDiagnostics[relay] = 'Failed to connect: ${e.toString().split(":").last.trim()}';
    rethrow;
  }
  nostrDiagnostics[relay] = 'Subscribed, waiting for offer...';
  final completer = Completer<NostrOfferLookup?>();
  final subscriptionId = 'nostr-${DateTime.now().microsecondsSinceEpoch}';
  var sawEose = false;
  var eventsCount = 0;

  void finish(NostrOfferLookup? result) {
    if (!completer.isCompleted) {
      completer.complete(result);
    }
    socket.close();
  }

  socket.listen(
    (dynamic data) {
      if (data is! String) {
        return;
      }
      try {
        final decoded = jsonDecode(data);
        if (decoded is! List || decoded.isEmpty) {
          return;
        }
        final kind = decoded.first;
        if (kind == 'EVENT' && decoded.length >= 3) {
          final event = decoded[2];
          if (event is Map<String, dynamic>) {
            eventsCount++;
            final eventTags = event['tags'];
            final eventPubkey =
                _normalizePubkey(event['pubkey']?.toString() ?? '');
            final content = event['content']?.toString() ?? '';
            final isHostMatch = _matchesDeviceId(eventTags, deviceId);
            final pubkeyMatches = pubkey.isEmpty ||
                eventPubkey.isEmpty ||
                eventPubkey == pubkey;
            if (isHostMatch && pubkeyMatches && content.startsWith('webrtc://')) {
              nostrDiagnostics[relay] = 'Offer found!';
              finish(NostrOfferLookup(
                deviceId: deviceId,
                pubkey: pubkey.isEmpty ? eventPubkey : pubkey,
                offer: content,
                relay: relay,
              ));
            } else {
              nostrDiagnostics[relay] = 'Event matched=$isHostMatch keyMatch=$pubkeyMatches (no webrtc)';
              // #region agent log
              agentDebugLog('N4', 'webrtc_signaling.dart:relayEvent', 'event rejected', {
                'relay': relay,
                'hostMatch': isHostMatch,
                'pubkeyMatch': pubkeyMatches,
                'contentPrefix': content.length > 12 ? content.substring(0, 12) : content,
                'eventPubkeyLen': eventPubkey.length,
              });
              // #endregion
            }
          }
        } else if (kind == 'EOSE') {
          sawEose = true;
          nostrDiagnostics[relay] = 'No offer found (EOSE) after $eventsCount events';
          // ponytail: don't finish on EOSE — another relay may still deliver
        }
      } catch (_) {}
    },
    onError: (e) {
      nostrDiagnostics[relay] = 'Read error: ${e.toString().split(":").last.trim()}';
      // #region agent log
      agentDebugLog('N5', 'webrtc_signaling.dart:relayEvent', 'socket error', {
        'relay': relay,
        'err': e.toString(),
      });
      // #endregion
      finish(null);
    },
    onDone: () => finish(null),
    cancelOnError: true,
  );

  // Look back 10 minutes (600 seconds) to be robust against clock drift between
  // the phone and the host computer.
  final since = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 600;
  final filter = <String, dynamic>{
    'kinds': [10005],
    '#t': [deviceId],
    'since': since,
    'limit': 10,
  };
  socket.add(jsonEncode(['REQ', subscriptionId, filter]));

  return completer.future.timeout(timeout, onTimeout: () {
    nostrDiagnostics[relay] = 'Timeout after $eventsCount events';
    // #region agent log
    agentDebugLog('N6', 'webrtc_signaling.dart:relayEvent', 'relay timeout', {
      'relay': relay,
      'sawEose': sawEose,
    });
    // #endregion
    finish(null);
    return null;
  });
}

/// Result of a Nostr device lookup.
class DeviceLookupResult {
  final String deviceId;
  final String pubkey;
  final String offer;
  final String relay;

  DeviceLookupResult({
    required this.deviceId,
    required this.pubkey,
    required this.offer,
    required this.relay,
  });
}

/// Look up a device by its ID on Nostr relays and return its WebRTC offer
/// and Nostr pubkey. Unlike [fetchHostOffer], this does not require a known
/// pubkey — it extracts it from the relay event.
///
/// Returns null if no offer is found within [timeout].
Future<DeviceLookupResult?> lookupDeviceById(
  String deviceId, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final normalizedId = _normalizeDeviceId(deviceId);
  final deadline = DateTime.now().add(timeout);
  var delay = const Duration(seconds: 2);

  while (DateTime.now().isBefore(deadline)) {
    final results = await Future.wait(
      _defaultNostrRelays.map((relay) async {
        try {
          final lookup = await _fetchOfferFromRelay(
            relay: relay,
            deviceId: normalizedId,
            pubkey: '', // no pubkey filter — accept any
            timeout: Duration(seconds: 15),
          );
          if (lookup != null && lookup.pubkey.isNotEmpty) {
            return DeviceLookupResult(
              deviceId: normalizedId,
              pubkey: lookup.pubkey,
              offer: lookup.offer,
              relay: lookup.relay,
            );
          }
          return null;
        } catch (_) {
          return null;
        }
      }),
    );
    for (final r in results) {
      if (r != null) return r;
    }
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) break;
    await Future.delayed(delay);
    if (delay < const Duration(seconds: 5)) {
      delay += const Duration(seconds: 1);
    }
  }
  return null;
}

bool _matchesDeviceId(dynamic tags, String deviceId) {
  if (tags is! List) {
    return false;
  }
  for (final tag in tags) {
    if (tag is List && tag.length >= 2 && tag[0].toString() == 't') {
      if (_normalizeDeviceId(tag[1].toString()) == deviceId) {
        return true;
      }
    }
  }
  return false;
}
