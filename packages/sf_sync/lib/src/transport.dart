import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';

import 'send_failure.dart';

/// How the phone talks to a sync server. The engine only knows this interface,
/// so tests, or a future web or Bluetooth transport, can plug in their own.
abstract interface class SyncTransport {
  Future<List<PushReply>> push(String clientId, List<PushOp> ops);
  Future<List<StatusReply>> status(String clientId, List<String> opIds);
  void close();
}

/// Talks SFSP v1 over HTTP.
final class HttpTransport implements SyncTransport {
  HttpTransport(
    this.serverUrl, {
    this.connectTimeout = const Duration(seconds: 10),
    this.replyTimeout = const Duration(seconds: 30),
  }) : _client = HttpClient()..connectionTimeout = connectTimeout;

  final Uri serverUrl;
  final Duration connectTimeout;
  final Duration replyTimeout;
  final HttpClient _client;

  @override
  Future<List<PushReply>> push(String clientId, List<PushOp> ops) async {
    final json = await _post('/sync/push', {
      'sfsp': sfspVersion,
      'clientId': clientId,
      'ops': [for (final op in ops) op.toJson()],
    });
    final replies = _read(
      () => [
        for (final r in json['replies'] as List)
          PushReply.fromJson((r as Map).cast<String, Object?>()),
      ],
    );
    if (replies.length != ops.length) {
      throw DeliveryUnknown(
        'expected ${ops.length} replies, got ${replies.length}',
      );
    }
    return replies;
  }

  @override
  Future<List<StatusReply>> status(String clientId, List<String> opIds) async {
    final json = await _post('/sync/ops/status', {
      'sfsp': sfspVersion,
      'clientId': clientId,
      'opIds': opIds,
    });
    return _read(
      () => [
        for (final s in json['statuses'] as List)
          StatusReply.fromJson((s as Map).cast<String, Object?>()),
      ],
    );
  }

  @override
  void close() => _client.close(force: true);

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    final bytes = utf8.encode(
      jsonEncode(body),
    ); // prepare BEFORE touching the network

    // Phase 1: connect. If this fails, not a single byte reached the server.
    final HttpClientRequest request;
    try {
      request = await _client.postUrl(serverUrl.resolve(path));
    } catch (e) {
      throw NotDelivered('could not connect: $e');
    }

    // Phase 2: send and wait. From the first byte sent, the server MAY have it.
    final int statusCode;
    final String text;
    try {
      request.headers.contentType = ContentType.json;
      request.add(bytes);
      final response = await request.close().timeout(replyTimeout);
      statusCode = response.statusCode;
      text = await utf8.decoder.bind(response).join().timeout(replyTimeout);
    } catch (e) {
      throw DeliveryUnknown('no complete answer: $e');
    }

    if (statusCode == 400) {
      throw RequestRejected('server refused the request: $text');
    }
    if (statusCode != 200) {
      throw DeliveryUnknown('server answered HTTP $statusCode');
    }
    return _read(() => (jsonDecode(text) as Map).cast<String, Object?>());
  }
}

/// A 200 answer we cannot understand: the server may still have applied it.
T _read<T>(T Function() parse) {
  try {
    return parse();
  } catch (e) {
    throw DeliveryUnknown('unreadable answer: $e');
  }
}
