import 'dart:async';
import 'dart:isolate';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
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

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (_) => true,
    headers: {'x-gm-client': adminApp ? 'admin-app' : 'mobile'},
  ));

  Future<void> load() async {
    final saved = await storage.read(key: 'api_base');
    // Old test builds pointed at a server that no longer exists.
    base = (saved == null || saved.contains('onrender.com')) ? defaultApiBase : saved;
    token = await storage.read(key: 'token');
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

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body ?? {});
  Future<dynamic> patch(String path, Object body) => _send('PATCH', path, body);
  Future<dynamic> put(String path, Object body, {void Function(int sent, int total)? onSendProgress}) => _send('PUT', path, body, onSendProgress);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, [Object? body, void Function(int, int)? onSendProgress]) async {
    Response res;
    // With a progress meter the body goes as bytes so the total size is known.
    final raw = onSendProgress != null && body != null ? utf8.encode(jsonEncode(body)) : null;
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
    } on DioException {
      throw ApiException(0, 'Could not reach GymMantra. Check your internet and try again.');
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
  }

  /// Loads screens' data in the background so they open instantly later.
  Future<void> prefetch(List<String> paths) async {
    await Future.wait(paths.map((p) async {
      try {
        final fresh = await get(p);
        _remember(_k(p), fresh);
      } catch (_) {}
    }));
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
