import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api.dart';
import 'prefs.dart';

class Session extends ChangeNotifier {
  Session() {
    Api.instance.onLoggedOut = () {
      user = null;
      Prefs.clearUserData();
      Api.instance.forget();
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
    googleClientId = Prefs.getString('googleClientId');
    if (api.token != null) {
      final saved = Prefs.getJson('u:me');
      if (saved is Map) {
        // Open straight away with the saved profile; check it with the server in the background.
        user = Map<String, dynamic>.from(saved);
        ready = true;
        notifyListeners();
        refreshUser().catchError((Object e) {
          if (e is ApiException && e.status == 401) Api.instance.onLoggedOut?.call();
        });
        loadConfig();
        return;
      }
      try {
        await refreshUser();
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
      final id = c['googleClientId'] as String?;
      if (id != googleClientId) {
        googleClientId = id;
        if (id == null) {
          Prefs.remove('googleClientId');
        } else {
          Prefs.setString('googleClientId', id);
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  void _setUser(Map<String, dynamic> u) {
    user = u;
    Prefs.setJson('u:me', u);
  }

  Future<void> _done(dynamic r) async {
    await Prefs.clearUserData();
    api.forget();
    await api.setToken(r['token'] as String);
    _setUser(Map<String, dynamic>.from(r['user']));
    if (user?['language'] == 'hi') AppSettings.instance.setLang('hi');
    try {
      await refreshUser(); // adds the gyms this person runs or trains at
    } catch (_) {}
    notifyListeners();
  }

  Future<void> login(String identifier, String password) async =>
      _done(await api.post('/auth/login', {'identifier': identifier.trim(), 'password': password}));

  Future<void> signup(String name, String email, String phone, String password) async {
    final lang = AppSettings.instance.lang;
    await _done(await api.post('/auth/signup', {'name': name.trim(), 'email': email.trim(), 'phone': phone.trim(), 'password': password}));
    if (lang == 'hi') await setLanguage('hi');
  }

  /// Sends a password reset link. Returns the masked email it went to.
  Future<String> forgot(String identifier) async {
    final r = await api.post('/auth/forgot', {'identifier': identifier.trim()});
    return (r['to'] as String?) ?? '';
  }

  /// Google sign-up creates the account. Google log-in works only after that.
  Future<void> google({required bool signup, String? phone}) async {
    final id = googleClientId;
    if (id == null) throw ApiException(400, 'Google sign-in is not set up yet');
    final g = GoogleSignIn(serverClientId: id, scopes: const ['email']);
    try {
      await g.signOut();
    } catch (_) {}
    final acc = await g.signIn();
    if (acc == null) return; // cancelled
    final auth = await acc.authentication;
    final idToken = auth.idToken;
    if (idToken == null) throw ApiException(400, 'Google did not return a sign-in token. Try again.');
    await _done(await api.post(signup ? '/auth/google/signup' : '/auth/google/login', {
      'idToken': idToken,
      if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
    }));
  }

  Future<void> refreshUser() async {
    final me = await api.get('/auth/me');
    _setUser({...Map<String, dynamic>.from(me['user']), 'gyms': me['gyms'] ?? []});
    notifyListeners();
  }

  /// Which part of the app this person sees.
  /// owner / trainer / waiting (trainer request pending) / registerGym / trainerJoin / member / role (not chosen yet)
  String get mode {
    final u = user;
    if (u == null) return 'none';
    if (u['isOwner'] == true) return 'owner';
    if (u['isTrainer'] == true) return 'trainer';
    if (u['trainerPending'] == true) return 'waiting';
    return switch (u['appRole']) {
      'OWNER' => 'registerGym',
      'TRAINER' => 'trainerJoin',
      'MEMBER' => 'member',
      _ => 'role',
    };
  }

  /// The gym this owner / front desk runs (first one).
  Map<String, dynamic>? get myGym {
    final gyms = (user?['gyms'] as List?) ?? const [];
    for (final g in gyms) {
      if (g is Map && (g['role'] == 'OWNER' || g['role'] == 'FRONT_DESK')) return Map<String, dynamic>.from(g);
    }
    return null;
  }

  Future<void> chooseRole(String role) async {
    await api.patch('/me/profile', {'appRole': role});
    patchUser({'appRole': role});
  }

  /// Updates the profile locally first so the screen changes at once.
  void patchUser(Map<String, dynamic> patch) {
    if (user == null) return;
    _setUser({...user!, ...patch});
    notifyListeners();
  }

  Future<void> setLanguage(String l) async {
    AppSettings.instance.setLang(l);
    if (user == null) return;
    patchUser({'language': l});
    try {
      await api.patch('/me/profile', {'language': l});
    } catch (_) {}
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {}
    await api.setToken(null);
    await Prefs.clearUserData();
    api.forget();
    user = null;
    notifyListeners();
  }
}

final sessionProvider = ChangeNotifierProvider<Session>((ref) => Session());

/// Data providers. Each shows the saved copy first, then the fresh one.
/// Screens call ref.invalidate(...) to refresh.
final gymsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/gyms'));
final membershipProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, memberId) => Api.instance.cachedGet('/me/memberships/$memberId'));
final plansProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, tenantId) => Api.instance.cachedGet('/me/gyms/$tenantId/plans'));
final ticketsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/tickets'));
final ticketProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/me/tickets/$id'));
final notificationsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/notifications'));
final exercisesProvider = StreamProvider<dynamic>((ref) => Api.instance.cachedGet('/exercises'));

// ---- owner / trainer data ----
final dashboardProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/dashboard'));
final ownerMembersProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/members?tab=all'));
final ownerMemberProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/members/$id'));
final joinRequestsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/join-requests'));
final offersProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/offers'));
final trainersProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/trainers'));
final gymProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/gym'));
final trainerHomeProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/trainer/home'));
