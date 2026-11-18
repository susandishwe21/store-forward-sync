import 'dart:convert';
import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';

import 'server_store.dart';

/// Serves the store-and-forward sync protocol (SFSP v1) over HTTP.
final class SyncHttpServer {
  SyncHttpServer._(this._http, this._store);

  /// Largest batch (or pull page) accepted in one request.
  static const maxBatchSize = 500;

  /// Starts listening. Port 0 lets the system pick a free port (handy in tests).
  /// [address] defaults to this computer only; use InternetAddress.anyIPv4 to
  /// accept phones on the same Wi-Fi.
  static Future<SyncHttpServer> start(ServerStore store,
      {int port = 8080, InternetAddress? address}) async {
    final http = await HttpServer.bind(address ?? InternetAddress.loopbackIPv4, port);
    final server = SyncHttpServer._(http, store);
    http.listen(server._handle);
    return server;
  }

  final HttpServer _http;
  final ServerStore _store;

  int get port => _http.port;

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final route = '${request.method} ${request.uri.path}';
    try {
      switch (route) {
        case 'GET /health':
          await _send(request, 200, {'ok': true, 'sfsp': sfspVersion});
        case 'POST /sync/push':
          await _push(request);
        case 'POST /sync/ops/status':
          await _status(request);
        case 'POST /sync/pull':
          await _pull(request);
        default:
          await _send(request, 404, {'error': 'not found: $route'});
      }
    } on _BadRequest catch (e) {
      await _send(request, 400, {'error': e.message});
    } catch (e) {
      stderr.writeln('internal error on $route: $e');
      await _send(request, 500, {'error': 'internal server error'});
    }
  }

  Future<void> _push(HttpRequest request) async {
    final body = await _readBody(request);
    final clientId = _parse(() => body['clientId'] as String);
    final ops = _parse(() => [
          for (final o in body['ops'] as List)
            PushOp.fromJson((o as Map).cast<String, Object?>()),
        ]);
    if (ops.length > maxBatchSize) {
      throw _BadRequest('batch too large: ${ops.length} > $maxBatchSize');
    }
    final replies = [for (final op in ops) _store.receive(clientId, op).toJson()];
    await _send(request, 200, {'replies': replies});
  }

  Future<void> _status(HttpRequest request) async {
    final body = await _readBody(request);
    final clientId = _parse(() => body['clientId'] as String);
    final opIds = _parse(() => [for (final id in body['opIds'] as List) id as String]);
    final statuses = [
      for (final id in opIds)
        StatusReply(id,
                applied: _store.status(clientId, id) != null,
                serverVersion: _store.status(clientId, id)?.serverVersion)
            .toJson(),
    ];
    await _send(request, 200, {'statuses': statuses});
  }

  Future<void> _pull(HttpRequest request) async {
    final body = await _readBody(request);
    final since = _parse(() => body['since'] as int);
    final limit = _parse(() => (body['limit'] as int?) ?? 200);
    if (since < 0 || limit < 1 || limit > maxBatchSize) {
      throw _BadRequest('since must be >= 0 and limit 1..$maxBatchSize');
    }
    await _send(request, 200, _store.pull(since: since, limit: limit).toJson());
  }

  Future<Map<String, Object?>> _readBody(HttpRequest request) async {
    final String text;
    try {
      text = await utf8.decoder.bind(request).join();
    } on FormatException {
      throw _BadRequest('body is not valid UTF-8');
    }
    final decoded = _parse(() => jsonDecode(text));
    if (decoded is! Map) throw _BadRequest('body must be a JSON object');
    final body = decoded.cast<String, Object?>();
    if (body['sfsp'] != sfspVersion) {
      throw _BadRequest('unsupported protocol version: ${body['sfsp']}');
    }
    return body;
  }

  Future<void> _send(HttpRequest request, int status, Map<String, Object?> body) async {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    } catch (_) {
      // The phone went away before we could answer. That is fine:
      // it will ask again, and dedupe makes that safe.
    }
  }
}

/// Runs [read]. Any failure means the request was malformed: the phone's fault.
T _parse<T>(T Function() read) {
  try {
    return read();
  } catch (e) {
    throw _BadRequest('malformed request: $e');
  }
}

final class _BadRequest implements Exception {
  _BadRequest(this.message);
  final String message;
}
