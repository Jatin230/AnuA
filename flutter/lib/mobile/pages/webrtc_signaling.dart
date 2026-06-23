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

const List<String> _defaultNostrRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
];

String _normalizeDeviceId(String deviceId) => deviceId.replaceAll(' ', '');

String _normalizePubkey(String pubkey) => pubkey.toLowerCase();

/// Poll Nostr relays until the laptop publishes its WebRTC offer.
/// ICE gathering on the host can take ~8 s, so we retry with backoff.
Future<String?> fetchHostOffer({
  required String deviceId,
  required String pubkey,
  Duration timeout = const Duration(seconds: 45),
}) async {
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
            timeout: const Duration(seconds: 8),
          );
        } catch (e) {
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
  final socket = await WebSocket.connect(relay).timeout(timeout);
  final completer = Completer<NostrOfferLookup?>();
  final subscriptionId = 'nostr-${DateTime.now().microsecondsSinceEpoch}';
  var sawEose = false;

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
            final eventTags = event['tags'];
            final eventPubkey =
                _normalizePubkey(event['pubkey']?.toString() ?? '');
            final content = event['content']?.toString() ?? '';
            final isHostMatch = _matchesDeviceId(eventTags, deviceId);
            final pubkeyMatches = pubkey.isEmpty ||
                eventPubkey.isEmpty ||
                eventPubkey == pubkey;
            if (isHostMatch && pubkeyMatches && content.startsWith('webrtc://')) {
              finish(NostrOfferLookup(
                deviceId: deviceId,
                pubkey: pubkey,
                offer: content,
                relay: relay,
              ));
            } else {
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
          // ponytail: don't finish on EOSE — another relay may still deliver
        }
      } catch (_) {}
    },
    onError: (e) {
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

  final since = (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 600;
  final filter = <String, dynamic>{
    'kinds': [20005],
    '#t': [deviceId],
    'since': since,
    'limit': 5,
  };
  socket.add(jsonEncode(['REQ', subscriptionId, filter]));

  return completer.future.timeout(timeout, onTimeout: () {
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
