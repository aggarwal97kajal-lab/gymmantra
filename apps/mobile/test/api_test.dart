// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymmantra/api.dart';
import 'package:gymmantra/prefs.dart';
import 'package:gymmantra/session.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Screens must get their data: a small local server answers like the real one.
void main() {
  late HttpServer server;
  var hits = <String>[];
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.init();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      hits.add(req.uri.path);
      await Future.delayed(const Duration(milliseconds: 300));
      req.response.headers.contentType = ContentType.json;
      final body = req.uri.path.endsWith('/me/gyms') ? {'memberships': [], 'pendingRequests': []} : {'ok': true, 'items': []};
      req.response.write(jsonEncode(body));
      await req.response.close();
    });
    // Plain Dart HttpClient first, before the app's connection code is switched on.
    final plain = HttpClient();
    final r0 = await (await plain.getUrl(Uri.parse('http://127.0.0.1:${server.port}/x'))).close().timeout(const Duration(seconds: 5));
        print('plain client: ${r0.statusCode}');
    final mine = Api.ipv4First(HttpClient());
    final r1 = await (await mine.getUrl(Uri.parse('http://127.0.0.1:${server.port}/x')).timeout(const Duration(seconds: 5))).close().timeout(const Duration(seconds: 5));
        print('app client: ${r1.statusCode}');
    final u = 'http://127.0.0.1:${server.port}/api/v1/me/pt';
    try {
      final d1 = await Dio().get(u).timeout(const Duration(seconds: 5));
      print('dio default: ${d1.statusCode}');
    } catch (e) {
      print('dio default FAILED: $e');
    }
    try {
      final d2 = await (Dio()..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => Api.ipv4First(HttpClient()))).get(u).timeout(const Duration(seconds: 5));
      print('dio + app connector: ${d2.statusCode}');
    } catch (e) {
      print('dio + app connector FAILED: $e');
    }
    HttpOverrides.global = Ipv4FirstOverrides();
    try {
      final d3 = await (Dio()..httpClientAdapter = IOHttpClientAdapter(createHttpClient: () => Api.ipv4First(HttpClient()))).get(u).timeout(const Duration(seconds: 5));
      print('dio + app connector + overrides: ${d3.statusCode}');
    } catch (e) {
      print('dio + app connector + overrides FAILED: $e');
    }
    try {
      final d4 = await Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), sendTimeout: const Duration(seconds: 25), receiveTimeout: const Duration(seconds: 20), validateStatus: (_) => true)).get(u).timeout(const Duration(seconds: 5));
      print('dio + app options: ${d4.statusCode}');
    } catch (e) {
      print('dio + app options FAILED: $e');
    }
    print('server hits so far: $hits');
    Api.instance.base = 'http://127.0.0.1:${server.port}';
    Api.instance.token = 'test-token';
  });
  tearDownAll(() => server.close(force: true));

  test('plain get', () async {
    final r = await Api.instance.get('/me/pt').timeout(const Duration(seconds: 8), onTimeout: () {
      print('TIMEOUT; server hits: $hits');
      throw TimeoutException('get');
    });
    expect(r, isA<Map>());
  });

  test('cachedGet while prefetch is loading the same path', () async {
    Api.instance.forget();
    unawaited(Api.instance.prefetch(['/me/gyms', '/me/pt', '/me/program']));
    final v = await Api.instance.cachedGet('/me/gyms').first.timeout(const Duration(seconds: 8));
    expect(v, isA<Map>());
  });

  test('gymsProvider gets data', () async {
    Api.instance.forget();
    final c = ProviderContainer();
    final done = Completer<void>();
    final sub = c.listen(gymsProvider, (_, next) {
      if (next.hasValue && !done.isCompleted) done.complete();
      if (next.hasError && !done.isCompleted) done.completeError(next.error!);
    }, fireImmediately: true);
    await done.future.timeout(const Duration(seconds: 8));
    sub.close();
    c.dispose();
  });

  test('provider closed while loading, then opened again (switching tabs)', () async {
    Api.instance.forget();
    final c = ProviderContainer();
    var sub = c.listen(gymsProvider, (_, __) {}, fireImmediately: true);
    await Future.delayed(const Duration(milliseconds: 50));
    sub.close();
    await Future.delayed(const Duration(milliseconds: 20));
    final done = Completer<void>();
    sub = c.listen(gymsProvider, (_, next) {
      if (next.hasValue && !done.isCompleted) done.complete();
    }, fireImmediately: true);
    await done.future.timeout(const Duration(seconds: 8));
    c.dispose();
  });

  test('many at once (start of the app)', () async {
    Api.instance.forget();
    final paths = ['/me/gyms', '/me/pt', '/me/program', '/me/notifications', '/me/tickets', '/exercises', '/ads?role=MEMBER'];
    final all = await Future.wait(paths.map((p) => Api.instance.cachedGet(p).first)).timeout(const Duration(seconds: 10));
    expect(all.length, paths.length);
  });
}
