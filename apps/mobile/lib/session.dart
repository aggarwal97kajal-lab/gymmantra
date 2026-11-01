import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api.dart';

class Session extends ChangeNotifier {
  Session() {
    Api.instance.onLoggedOut = () {
      user = null;
      notifyListeners();
    };
  }

  bool ready = false;
  Map<String, dynamic>? user;
  String? googleClientId;
  bool get loggedIn => user != null;
  final api = Api.instance;

  Future<void> start() async {
    await api.load();
    if (api.token != null) {
      try {
        final me = await api.get('/auth/me');
        user = Map<String, dynamic>.from(me['user']);
      } catch (_) {
        user = null;
      }
    }
    ready = true;
    notifyListeners();
    loadConfig();
  }

  Future<void> loadConfig() async {
    try {
      final c = await api.get('/auth/config');
      googleClientId = c['googleClientId'] as String?;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _done(dynamic r) async {
    await api.setToken(r['token'] as String);
    user = Map<String, dynamic>.from(r['user']);
    notifyListeners();
  }

  Future<void> login(String identifier, String password) async =>
      _done(await api.post('/auth/login', {'identifier': identifier, 'password': password}));

  Future<void> signup(String name, String email, String phone, String password) async =>
      _done(await api.post('/auth/signup', {'name': name, 'email': email, 'phone': phone, 'password': password}));

  /// Google sign-up creates the account. Google log-in works only after that.
  Future<void> google({required bool signup, String? phone}) async {
    final id = googleClientId;
    if (id == null) throw ApiException(400, 'Google sign-in is not set up yet');
    final g = GoogleSignIn(serverClientId: id, scopes: const ['email']);
    await g.signOut();
    final acc = await g.signIn();
    if (acc == null) return; // cancelled
    final auth = await acc.authentication;
    final idToken = auth.idToken;
    if (idToken == null) throw ApiException(400, 'Google did not return a sign-in token. Try again.');
    _done(await api.post(signup ? '/auth/google/signup' : '/auth/google/login', {
      'idToken': idToken,
      if (phone != null && phone.isNotEmpty) 'phone': phone,
    }));
  }

  Future<void> refreshUser() async {
    final me = await api.get('/auth/me');
    user = Map<String, dynamic>.from(me['user']);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {}
    await api.setToken(null);
    user = null;
    notifyListeners();
  }
}

final sessionProvider = ChangeNotifierProvider<Session>((ref) => Session());

/// Simple GET providers. Screens call ref.invalidate(...) to refresh.
final gymsProvider = FutureProvider.autoDispose((ref) => Api.instance.get('/me/gyms'));
final membershipProvider = FutureProvider.autoDispose.family((ref, String memberId) => Api.instance.get('/me/memberships/$memberId'));
final plansProvider = FutureProvider.autoDispose.family((ref, String tenantId) => Api.instance.get('/me/gyms/$tenantId/plans'));
final ticketsProvider = FutureProvider.autoDispose((ref) => Api.instance.get('/me/tickets'));
final ticketProvider = FutureProvider.autoDispose.family((ref, String id) => Api.instance.get('/me/tickets/$id'));
final notificationsProvider = FutureProvider.autoDispose((ref) => Api.instance.get('/me/notifications'));
final exercisesProvider = FutureProvider((ref) => Api.instance.get('/exercises'));
