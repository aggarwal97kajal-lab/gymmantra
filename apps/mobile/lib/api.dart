import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Server address. Set at build time with --dart-define=API_BASE=...,
/// and can be changed in the app (long-press the logo on the login screen).
const String defaultApiBase = String.fromEnvironment('API_BASE', defaultValue: 'https://gymmantra.onrender.com');

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class Api {
  Api._();
  static final Api instance = Api._();

  final storage = const FlutterSecureStorage();
  String base = defaultApiBase;
  String? token;

  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 60), // free servers can take a while to wake up
    receiveTimeout: const Duration(seconds: 60),
    validateStatus: (_) => true,
    headers: {'x-gm-client': 'mobile'},
  ));

  Future<void> load() async {
    base = await storage.read(key: 'api_base') ?? defaultApiBase;
    token = await storage.read(key: 'token');
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
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, [Object? body]) async {
    Response res;
    try {
      res = await _dio.request(
        '$base/api/v1$path',
        data: body,
        options: Options(method: method, headers: authHeaders, contentType: body == null ? null : 'application/json'),
      );
    } on DioException {
      throw ApiException(0, 'Could not reach GymMantra. Check your internet and try again.');
    }
    final code = res.statusCode ?? 0;
    if (code >= 200 && code < 300) return res.data;
    var msg = 'Something went wrong ($code)';
    final d = res.data;
    if (d is Map && d['message'] != null) {
      msg = d['message'] is List ? (d['message'] as List).first.toString() : d['message'].toString();
    }
    if (code == 401 && !path.startsWith('/auth/')) {
      await setToken(null);
      onLoggedOut?.call();
    }
    throw ApiException(code, msg);
  }

  void Function()? onLoggedOut;
}
