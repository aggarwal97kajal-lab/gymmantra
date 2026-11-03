import 'dart:async';
import 'dart:isolate';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'prefs.dart';
import 'theme.dart' show adminApp;

/// Server address. Set at build time with --dart-define=API_BASE=...,
/// and can be changed in the app (long-press the logo on the login screen).
const String defaultApiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://gymmantra.aggarwal97kajal.workers.dev');

class ApiException implements Exception {
  ApiException(this.status, this.message, [this.data]);
  final int status;
  final String message;
  /// The full answer from the server (extra fields like "code").
  final Map? data;
  @override
  String toString() => message;
}

class Api {
  Api._();
  static final Api instance = Api._();

  final storage = const FlutterSecureStorage();
  String base = defaultApiBase;
  String? token;

  /// Branch the gym owner / staff is looking at (sent as x-branch-id). Lists, dashboard,
  /// offers, notices, QR codes and notifications follow it.
  String? branchId;
  String _k(String path) => branchId == null ? path : '$path#$branchId';

  /// How the app opens connections to the server.
  /// Mobile networks in India often drop the first packets of a new connection; the phone then
  /// waits 1 s, 3 s, 7 s… before sending again, so a screen hung for many seconds while Chrome
  /// (which tries several ways at once) opened the same server instantly. Here each new
  /// connection is tried on several server addresses at the same time (a new try every 0.3 s),
  /// TLS included, and the first one ready wins. DNS answers are kept for 5 minutes.
  static HttpClient _client() => ipv4First(HttpClient());

  /// Time (ms) the last new connections took, sent with the timing report.
  static final List<int> connectMs = [];

  static HttpClient ipv4First(HttpClient c) {
    c
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 50)
      ..maxConnectionsPerHost = 6;
    c.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) async {
      final host = proxyHost ?? uri.host;
      final port = proxyPort ?? (uri.port == 0 ? (uri.scheme == 'https' ? 443 : 80) : uri.port);
      final tls = uri.scheme == 'https' && proxyHost == null;
      final sw = Stopwatch()..start();
      final sock = _raceConnect(host, port, tls ? uri.host : null).then((s) {
        connectMs.add(sw.elapsedMilliseconds);
        if (connectMs.length > 20) connectMs.removeAt(0);
        return s;
      });
      return ConnectionTask.fromSocket(sock, () {});
    };
    return c;
  }

  static final Map<String, (List<InternetAddress>, DateTime)> _dns = {};

  static Future<List<InternetAddress>> _lookup(String host) async {
    final hit = _dns[host];
    if (hit != null && hit.$2.isAfter(DateTime.now())) return hit.$1;
    try {
      final all = await InternetAddress.lookup(host).timeout(const Duration(seconds: 6));
      if (all.isNotEmpty) _dns[host] = (all, DateTime.now().add(const Duration(minutes: 5)));
      return all;
    } catch (_) {
      if (hit != null) return hit.$1; // old answer is better than none
      rethrow;
    }
  }

  static Future<Socket> _raceConnect(String host, int port, String? tlsHost) async {
    List<InternetAddress> all;
    try {
      all = await _lookup(host);
    } catch (_) {
      all = [];
    }
    final v4 = all.where((a) => a.type == InternetAddressType.IPv4).toList();
    final v6 = all.where((a) => a.type != InternetAddressType.IPv4).toList();
    final List<Object> order = [...v4, ...v6];
    if (order.isEmpty) order.add(host);
    if (order.length < 3) order.add(order.first); // a second try on the same address also beats a lost packet
    Future<Socket> one(Object target) async {
      final s = await Socket.connect(target, port, timeout: const Duration(seconds: 8));
      if (tlsHost == null) return s;
      try {
        return await SecureSocket.secure(s, host: tlsHost).timeout(const Duration(seconds: 8));
      } catch (_) {
        s.destroy();
        rethrow;
      }
    }

    final done = Completer<Socket>();
    var next = 0, failed = 0;
    Object? lastErr;
    void startNext() {
      if (done.isCompleted || next >= order.length) return;
      one(order[next++]).then((s) {
        if (done.isCompleted) {
          s.destroy();
        } else {
          done.complete(s);
        }
      }, onError: (Object e) {
        failed++;
        lastErr = e;
        if (done.isCompleted) return;
        if (failed >= order.length) {
          done.completeError(lastErr ?? 'connect failed');
        } else {
          startNext(); // that address failed fast: try the next one now
        }
      });
    }

    startNext();
    final timer = Timer.periodic(const Duration(milliseconds: 300), (t) {
      if (done.isCompleted || next >= order.length) {
        t.cancel();
      } else {
        startNext();
      }
    });
    try {
      return await done.future.timeout(const Duration(seconds: 12));
    } finally {
      timer.cancel();
    }
  }

  /// Opens a connection to the server right away (app start, back from background),
  /// so the first real screen does not pay for it.
  Future<void> warmConnection() async {
    try {
      await _dio.get('$base/api/v1/ping', options: Options(receiveTimeout: const Duration(seconds: 10)));
    } catch (_) {}
  }

  late final Dio _dio = Dio(BaseOptions(
    // Short waits: a dead connection is noticed fast and tried again, instead of hanging.
    connectTimeout: const Duration(seconds: 10),
    sendTimeout: const Duration(seconds: 25),
    receiveTimeout: const Duration(seconds: 20),
    validateStatus: (_) => true,
    headers: {'x-gm-client': adminApp ? 'admin-app' : 'mobile'},
  ))
    ..httpClientAdapter = IOHttpClientAdapter(createHttpClient: _client);

  Future<void> load() async {
    final saved = await storage.read(key: 'api_base');
    // Old test builds pointed at a server that no longer exists.
    base = (saved == null || saved.contains('onrender.com')) ? defaultApiBase : saved;
    token = await storage.read(key: 'token');
    unawaited(warmConnection());
    branchId = Prefs.getString('u:branch');
  }

  Future<void> setBase(String url) async {
    base = url.trim().replaceAll(RegExp(r'/+$'), '');
    await storage.write(key: 'api_base', value: base);
  }

  Future<void> setToken(String? t) async {
    token = t;
    if (t == null) {
      await storage.delete(key: 'token');
    } else {
      await storage.write(key: 'token', value: t);
    }
  }

  String url(String path) => path.startsWith('http') ? path : '$base$path';
  Map<String, String> get authHeaders => token == null ? {} : {'Authorization': 'Bearer $token'};

  /// GETs for the same path that are already on the way share one request (less load, faster screens).
  final Map<String, Future<dynamic>> _inFlight = {};
  Future<dynamic> get(String path) {
    if (path.startsWith('/auth/')) return _send('GET', path); // login data: never shared
    final key = '${token.hashCode}|${_k(path)}';
    final running = _inFlight[key];
    if (running != null) return running;
    final f = _send('GET', path).whenComplete(() => _inFlight.remove(key));
    _inFlight[key] = f;
    return f;
  }
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body ?? {});
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body);
  Future<dynamic> put(String path, Object body, {void Function(int sent, int total)? onSendProgress}) => _send('PUT', path, body, onSendProgress);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  static final _rand = math.Random();

  /// Wait before try number [attempt] (1, 2, …): exponential backoff with full jitter
  /// (0.4 s, 0.8 s, 1.6 s … each a random part of that), so thousands of phones never retry together.
  static Duration backoff(int attempt) {
    final capMs = math.min(4000, 400 * (1 << (attempt - 1)));
    return Duration(milliseconds: capMs ~/ 2 + _rand.nextInt(capMs ~/ 2 + 1));
  }

  /// Safe to send again: reads, and writes that carry their own idempotency key.
  static bool _retryable(String method, String path, Object? body) => method == 'GET' || (method == 'POST' && path.startsWith('/subscription/payments'));

  // ---- timing reports: slow / failed requests (and the first few after start) go to the server,
  // so a problem on a real phone can be seen and fixed.
  final List<Map<String, Object?>> _diag = [];
  int _seen = 0;
  Timer? _diagTimer;
  void _note(String m, String path, int status, int ms, [String? err]) {
    _seen++;
    if (!(ms > 2500 || status == 0 || status >= 500 || err != null || _seen <= 15)) return;
    _diag.add({'m': m, 'p': path.split('?').first, 's': status, 'ms': ms, if (err != null) 'e': err});
    _diagTimer ??= Timer(const Duration(seconds: 8), _flushDiag);
  }

  Future<void> _flushDiag() async {
    _diagTimer = null;
    if (_diag.isEmpty) return;
    final items = List<Map<String, Object?>>.from(_diag);
    _diag.clear();
    try {
      await _dio.post('$base/api/v1/diag', data: {'v': 'app-${adminApp ? 'admin' : 'main'}', 'net': connectMs.join(','), 'items': items}, options: Options(contentType: 'application/json'));
    } catch (_) {}
  }

  Future<dynamic> _send(String method, String path, [Object? body, void Function(int, int)? onSendProgress]) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _send0(method, path, body, onSendProgress);
      _note(method, path, 200, sw.elapsedMilliseconds);
      return r;
    } on ApiException catch (e) {
      _note(method, path, e.status, sw.elapsedMilliseconds, e.status == 0 || e.status >= 500 ? e.message : null);
      rethrow;
    } catch (e) {
      _note(method, path, -1, sw.elapsedMilliseconds, e.toString());
      rethrow;
    }
  }

  Future<dynamic> _send0(String method, String path, [Object? body, void Function(int, int)? onSendProgress]) async {
    late Response res;
    // With a progress meter the body goes as bytes so the total size is known.
    final raw = onSendProgress != null && body != null ? utf8.encode(jsonEncode(body)) : null;
    final retry = _retryable(method, path, body) && !path.startsWith('/auth/');
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        res = await _dio.request(
          '$base/api/v1$path',
          data: raw ?? body,
          onSendProgress: onSendProgress,
          options: Options(
            method: method,
            headers: {...authHeaders, if (branchId != null) 'x-branch-id': branchId!, if (raw != null) Headers.contentLengthHeader: raw.length},
            contentType: body == null ? null : 'application/json',
          ),
        );
      } on DioException catch (e) {
        if (retry && attempt < 2) {
          await Future.delayed(backoff(attempt));
          continue;
        }
        throw ApiException(0, 'Could not reach GymMantra. Check your internet and try again. (${e.type.name})');
      }
      final sc = res.statusCode ?? 0;
      // Server busy or restarting: wait a little (with jitter) and try again.
      if (retry && attempt < 2 && (sc == 429 || sc == 502 || sc == 503 || sc == 504)) {
        await Future.delayed(backoff(attempt));
        continue;
      }
      break;
    }
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) {
      // Something changed on the server: screens must load fresh data next time.
      if (method != 'GET') _fetchedAt.clear();
      return res.data;
    }
    var msg = 'Something went wrong ($code)';
    final d = res.data;
    if (d is Map && d['message'] != null) {
      msg = d['message'] is List ? (d['message'] as List).first.toString() : d['message'].toString();
    }
    if (code == 401 && !path.startsWith('/auth/')) {
      await setToken(null);
      onLoggedOut?.call();
    }
    throw ApiException(code, msg, d is Map ? d : null);
  }

  void Function()? onLoggedOut;

  /// Downloads a file the app shows (profile photo) with the login attached.
  Future<Uint8List> bytes(String path) async {
    final r = await _dio.get<List<int>>(url(path), options: Options(responseType: ResponseType.bytes, headers: authHeaders));
    final data = r.data;
    if (r.statusCode != 200 || data == null) throw ApiException(r.statusCode ?? 0, 'Photo not available');
    return Uint8List.fromList(data);
  }

  /// Last answer for each path, kept in memory and on the phone.
  final Map<String, dynamic> _mem = {};

  /// When each path was last loaded. Going back and forth between screens within a few
  /// seconds uses what is in memory instead of asking the server again.
  final Map<String, DateTime> _fetchedAt = {};
  static const _freshFor = Duration(seconds: 10);
  bool _isFresh(String key) {
    final t = _fetchedAt[key];
    return t != null && _mem.containsKey(key) && DateTime.now().difference(t) < _freshFor;
  }

  void _remember(String key, dynamic fresh) {
    _mem[key] = fresh;
    _fetchedAt[key] = DateTime.now();
    _save(key, fresh);
  }

  /// Saves a copy on the phone without holding up the screen (the JSON text is made off the main thread).
  final Map<String, Timer> _saveTimers = {};
  void _save(String key, dynamic data) {
    _saveTimers[key]?.cancel();
    _saveTimers[key] = Timer(const Duration(milliseconds: 400), () async {
      _saveTimers.remove(key);
      try {
        final text = await Isolate.run(() => jsonEncode(data));
        await Prefs.setString('c:$key', text);
      } catch (_) {}
    });
  }

  dynamic cached(String path) {
    final key = _k(path);
    final m = _mem[key];
    if (m != null) return m;
    final saved = Prefs.getJson('c:$key');
    if (saved != null) _mem[key] = saved; // read the phone copy only once
    return saved;
  }

  void forget() {
    _mem.clear();
    _fetchedAt.clear();
    _inFlight.clear();
  }

  /// Loads screens' data in the background so they open instantly later.
  /// Three at a time, so the screen in front of the person is never stuck behind them.
  Future<void> prefetch(List<String> paths) async {
    for (var i = 0; i < paths.length; i += 3) {
      await Future.wait(paths.skip(i).take(3).map((p) async {
        try {
          final fresh = await get(p);
          _remember(_k(p), fresh);
        } catch (_) {}
      }));
    }
  }

  /// Background loading a few at a time (e.g. the details of members in a list),
  /// skipping anything already saved on the phone.
  final Set<String> _warming = {};
  Future<void> prefetchSome(List<String> paths, {int at = 4}) async {
    final todo = paths.where((p) => cached(p) == null && _warming.add(p)).toList();
    for (var i = 0; i < todo.length; i += at) {
      await prefetch(todo.sublist(i, i + at > todo.length ? todo.length : i + at));
    }
  }

  /// Gives the saved copy first (instant), then the fresh answer from the server.
  /// If the server can't be reached but a saved copy exists, the saved copy stays.
  Stream<dynamic> cachedGet(String path) async* {
    final key = _k(path);
    final old = cached(path);
    if (old != null) yield old;
    if (_isFresh(key)) return; // just loaded a moment ago
    try {
      final fresh = await get(path);
      _remember(key, fresh);
      yield fresh;
    } catch (e) {
      if (old == null) rethrow;
    }
  }
}


/// Every HttpClient in the app (pictures too) connects over IPv4 first.
class Ipv4FirstOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => Api.ipv4First(super.createHttpClient(context));
}
