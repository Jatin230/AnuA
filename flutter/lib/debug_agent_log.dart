import 'dart:convert';

import 'package:http/http.dart' as http;

/// Agent debug mode logging (session 50082e).
void agentDebugLog(
  String hypothesisId,
  String location,
  String message,
  Map<String, dynamic> data,
) {
  final payload = jsonEncode({
    'sessionId': '50082e',
    'hypothesisId': hypothesisId,
    'location': location,
    'message': message,
    'data': data,
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });
  // #region agent log
  http
      .post(
        Uri.parse(
            'http://127.0.0.1:7826/ingest/d7d78858-e7eb-4568-9559-bc35896e950b'),
        headers: {
          'Content-Type': 'application/json',
          'X-Debug-Session-Id': '50082e',
        },
        body: payload,
      )
      .catchError((_) => http.Response('', 500));
  // #endregion
}
