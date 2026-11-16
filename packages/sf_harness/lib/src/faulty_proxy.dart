import 'dart:io';
import 'dart:math';

/// Sits between the phone and the real server, and misbehaves on purpose.
final class FaultyProxy {
  FaultyProxy._(
    this._http,
    this._upstream,
    this._random,
    this.failRate,
    this.dropRate,
  );

  static Future<FaultyProxy> start({
    required Uri upstream,
    double failRate = 0.2,
    double dropRate = 0.2,
    int seed = 1,
  }) async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = FaultyProxy._(
      http,
      upstream,
      Random(seed),
      failRate,
      dropRate,
    );
    http.listen(proxy._handle);
    return proxy;
  }

  final HttpServer _http;
  final Uri _upstream;
  final Random _random;
  final HttpClient _client = HttpClient();

  /// Share of requests where the "server" fails before doing anything.
  final double failRate;

  /// Share of requests where the server does the work but the reply is lost.
  final double dropRate;

  /// Turned off at the end, so everything can finish syncing.
  bool faultsOn = true;

  int failed = 0;
  int dropped = 0;

  Uri get url => Uri.parse('http://127.0.0.1:${_http.port}');

  Future<void> close() async {
    _client.close(force: true);
    await _http.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final body = await request.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      final roll = _random.nextDouble();

      // Fault 1: the server fails before doing anything.
      if (faultsOn && roll < failRate) {
        failed++;
        request.response.statusCode = 503;
        await request.response.close();
        return;
      }

      // Forward to the real server: it really applies the changes.
      final upstream = await _client.openUrl(
        request.method,
        _upstream.resolve(request.uri.path),
      );
      upstream.headers.contentType = ContentType.json;
      upstream.add(body);
      final response = await upstream.close();
      final answer = await response.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );

      // Fault 2: the work is done, but the reply is lost on the way back.
      if (faultsOn && roll < failRate + dropRate) {
        dropped++;
        final socket = await request.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }

      request.response
        ..statusCode = response.statusCode
        ..headers.contentType = ContentType.json
        ..add(answer);
      await request.response.close();
    } catch (_) {
      // The phone was killed mid-request. That is the whole point of the test.
    }
  }
}
