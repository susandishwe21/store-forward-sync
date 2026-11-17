import 'dart:convert';
import 'dart:io';

import 'package:sf_contracts/sf_contracts.dart';

import 'server_store.dart';

final class SyncHttpServer {
  SyncHttpServer._(this._http, this._store);
  static const maxBatchSize = 500;
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
    final ops = _parse(
      () => [
        for (final o in body['ops'] as List)
          PushOp.fromJson((o as Map).cast<String, Object?>()),
      ],
    );
    if (ops.length > maxBatchSize) {
      throw _BadRequest('batch too large: ${ops.length} > $maxBatchSize');
    }
    final replies = [
      for (final op in ops) _store.receive(clientId, op).toJson(),
    ];
    await _send(request, 200, {'replies': replies});
  }

  Future<void> _status(HttpRequest request) async {
    final body = await _readBody(request);
    final clientId = _parse(() => body['clientId'] as String);
    final opIds = _parse(
      () => [for (final id in body['opIds'] as List) id as String],
    );
    final statuses = [
      for (final id in opIds)
        StatusReply(
          id,
          applied: _store.status(clientId, id) != null,
          serverVersion: _store.status(clientId, id)?.serverVersion,
        ).toJson(),
    ];
    await _send(request, 200, {'statuses': statuses});
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

  Future<void> _send(
    HttpRequest request,
    int status,
    Map<String, Object?> body,
  ) async {
    try {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    } catch (_) {}
  }
}

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


