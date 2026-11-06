import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api.dart';
import 'prefs.dart';
import 'push.dart';
import 'theme.dart' show adminApp;

class Session extends ChangeNotifier {
  Session() {
    Api.instance.onLoggedOut = () {
      user = null;
      Api.instance.branchId = null;
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
        refreshUser().then((_) => warmUp()).catchError((Object e) {
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
      final app = c['appUrl'] as String?;
      if (app != null) Prefs.setString('appUrl', app);
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
    endedNote = null;
    Prefs.setJson('u:me', u);
  }

  Future<void> _done(dynamic r) async {
    await Prefs.clearUserData();
    api.forget();
    api.branchId = null;
    await api.setToken(r['token'] as String);
    _setUser(Map<String, dynamic>.from(r['user']));
    if (user?['language'] == 'hi') AppSettings.instance.setLang('hi');
    try {
      await refreshUser(); // adds the gyms this person runs or trains at
      // Apply the role chosen on the first screen to a new account.
      final pending = pendingRole;
      if (user?['appRole'] == null && user?['isOwner'] != true && user?['isTrainer'] != true && pending != null) {
        await chooseRole(pending);
      }
      warmUp();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> login(String identifier, String password) async =>
      _done(await api.post('/auth/login', {'identifier': identifier.trim(), 'password': password, ..._roleBody}));

  Future<void> signup(String name, String email, String phone, String password) async {
    final lang = AppSettings.instance.lang;
    await _done(await api.post('/auth/signup', {'name': name.trim(), 'email': email.trim(), 'phone': phone.trim(), 'password': password, ..._roleBody}));
    if (lang == 'hi') await setLanguage('hi');
  }

  /// Sign-up with full details (first/middle/last name, DOB, state, city, PIN).
  Future<void> signupFull(Map<String, dynamic> details, String email, String phone, String password) async {
    final lang = AppSettings.instance.lang;
    await _done(await api.post('/auth/signup', {...details, 'email': email.trim(), 'phone': phone.trim(), 'password': password, ..._roleBody}));
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
      ..._roleBody,
      if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
    }));
  }

  /// "Logging out…" spinner over the whole app, and the reason shown on the login screen.
  bool ending = false;
  String? endedNote;

  /// Is this phone's login still good? If the server ended it (password changed, logged out from
  /// another phone), the app logs out at once with a spinner — not on the next refresh.
  Future<void> checkStillLoggedIn([String? note]) async {
    if (user == null || ending) return;
    try {
      await refreshUser();
      if (note != null) Push.register(); // our login is fine: this phone goes back on the push list
    } on ApiException catch (e) {
      if (e.status != 401 || user == null) return;
      ending = true;
      endedNote = note ?? e.message;
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1400));
      await api.setRefresh(null);
      await api.setToken(null);
      api.onLoggedOut?.call();
      ending = false;
      notifyListeners();
    } catch (_) {} // no internet: checked again when it is back
  }

  Future<void> refreshUser() async {
    final me = await api.get('/auth/me');
    _setUser({...Map<String, dynamic>.from(me['user']), 'gyms': me['gyms'] ?? []});
    notifyListeners();
  }

  /// Owner / staff switches the branch the app shows. Every branch screen reloads.
  void setBranch(String? id) {
    api.branchId = id;
    if (id == null) {
      Prefs.remove('u:branch');
    } else {
      Prefs.setString('u:branch', id);
    }
    notifyListeners();
    warmUp();
  }

  /// Fetches the main screens of this person's part of the app in the background,
  /// so tapping a tab or menu shows data at once instead of waiting for the server.
  void warmUp() {
    Future.delayed(const Duration(milliseconds: 1200), _warmUp); // first let the open screen load
    Future.delayed(const Duration(seconds: 3), Push.register); // phone notifications: token + topics
  }

  void _warmUp() {
    if (user == null) return;
    if (adminApp && user?['isSuperAdmin'] == true) {
      // GM Admin: every tab and every screen under More, so nothing shows grey boxes.
      api.prefetch(const [
        '/super/overview',
        '/super/gyms',
        '/super/saas-plans',
        '/super/ads',
        '/super/tickets',
        '/super/settings',
        '/super/coupons',
        '/super/payments?status=PAID',
        '/super/reports?days=30',
        '/me/notifications',
      ]);
      return;
    }
    final paths = switch (mode) {
      'owner' => [
          '/dashboard',
          '/members?tab=all',
          '/join-requests',
          '/offers',
          '/notices',
          '/dues',
          '/leads',
          '/gym',
          '/plans',
          '/subscription',
          '/trainers',
          '/pt?status=PENDING',
          '/pt?status=ACTIVE',
          '/ads?role=OWNER',
          '/me/notifications',
          '/gym/checkin-qr',
          '/transfers',
          '/reports?days=30',
          '/reports/entries?days=30',
          '/gym/staff',
          '/subscription/payments',
        ],
      'trainer' || 'waiting' || 'trainerJoin' => ['/trainer/home', '/trainer/clients', '/trainer/payouts', '/ads?role=TRAINER', '/me/notifications'],
      'member' => ['/me/gyms', '/me/pt', '/me/program', '/me/notifications', '/me/tickets', '/exercises', '/ads?role=MEMBER'],
      _ => const <String>[],
    };
    // Opening the app again within 10 minutes does not load every tab again (the open screen still refreshes).
    if (paths.isNotEmpty) api.prefetch(paths, always: false);
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
      'STAFF' => 'staffNone',
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

  /// True for front desk staff (not the owner).
  bool get isStaffDesk => myGym?['role'] == 'FRONT_DESK';

  /// What this person may do at their gym (owners: everything). Mirrors the server's rights.
  bool can(String right) {
    final g = myGym;
    if (g == null) return false;
    if (g['role'] == 'OWNER') return true;
    final r = g['rights'];
    if (r is List) return r.contains(right);
    return const ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'offers'].contains(right);
  }

  /// The server checks that the account really has the role picked on the first screen.
  Map<String, dynamic> get _roleBody => pendingRole == null ? const {} : {'role': pendingRole};

  /// Role picked on the first screen (before log-in).
  String? get pendingRole => Prefs.getString('pendingRole');
  void notifyRoleChosen() => notifyListeners();

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

  /// Instant: the phone forgets the login at once; the server is told in the background.
  Future<void> logout() async {
    final old = api.token;
    final oldKey = api.refresh;
    Push.unregisterLater(old);
    // The server ends this login (and its refresh key) too.
    if (old != null) api.postAs(old, '/auth/logout', {if (oldKey != null) 'refresh': oldKey});
    api.refresh = null;
    // Screen changes first; the saved login and the phone copies are wiped right after (secure
    // storage can take a second on some phones, which made log-out feel slow).
    api.token = null;
    api.branchId = null;
    api.forget();
    user = null;
    notifyListeners();
    final wipe = Future.wait([api.setToken(null), Prefs.clearUserData()]);
    await wipe.timeout(const Duration(milliseconds: 300), onTimeout: () => const []);
  }
}

final sessionProvider = ChangeNotifierProvider<Session>((ref) => Session());

/// The branch the owner app shows. Screens that depend on it reload when it changes.
final branchProvider = Provider<String?>((ref) {
  ref.watch(sessionProvider.select((s) => s.api.branchId));
  return Api.instance.branchId;
});

/// The gym as the owner app shows it: code and name of the branch being looked at.
Map<String, dynamic> withBranch(Map g) {
  final out = Map<String, dynamic>.from(g);
  final branches = ((g['branches'] as List?) ?? const []).whereType<Map>().toList();
  if (branches.length < 2) return out;
  final curId = Api.instance.branchId ?? g['currentBranchId'];
  final cur = branches.firstWhere((b) => b['id'] == curId, orElse: () => branches.first);
  out['gymCode'] = cur['code'] ?? g['gymCode'];
  out['branchName'] = cur['name'];
  // Main (first) branch uses the gym's name; any other branch shows only its own name.
  out['name'] = cur['id'] == branches.first['id'] ? g['name'] : cur['name'];
  // Each branch shows only its own logo; the main (first) branch shows the gym's.
  out['logoUrl'] = cur['logoUrl'] ?? (cur['id'] == branches.first['id'] ? g['logoUrl'] : null);
  if (cur['address'] != null && '${cur['address']}'.isNotEmpty) {
    out['addressLine'] = cur['address'];
    out['city'] = null;
  }
  return out;
}

/// cachedGet that reloads when the owner switches branch.
Stream<dynamic> branchGet(Ref ref, String path) {
  ref.watch(branchProvider);
  return Api.instance.cachedGet(path);
}

final transfersProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/transfers'));
final myTransferProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, tid) => Api.instance.cachedGet('/me/gyms/$tid/transfer'));

/// Data providers. Each shows the saved copy first, then the fresh one.
/// Screens call ref.invalidate(...) to refresh.
final gymsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/gyms'));
final membershipProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, memberId) => Api.instance.cachedGet('/me/memberships/$memberId'));
final plansProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, tenantId) => Api.instance.cachedGet('/me/gyms/$tenantId/plans'));
final superTicketsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/tickets'));
final ticketsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/tickets'));
final superTicketProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/super/tickets/$id'));
final ticketProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/me/tickets/$id'));
final notificationsProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/me/notifications'));
final exercisesProvider = StreamProvider<dynamic>((ref) => Api.instance.cachedGet('/exercises'));

// ---- owner / trainer data ----
final dashboardProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/dashboard'));
final ownerMembersProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/members?tab=all'));
final ownerMemberProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => branchGet(ref, '/members/$id'));
final joinRequestsProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/join-requests'));
final offersProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/offers'));
final trainersProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/trainers'));
final gymProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/gym'));
final trainerHomeProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/trainer/home'));

/// Same list as the server (core.ts GO_RULES): notifications saved before "go" existed still open
/// the right page, worked out from their title.
final _goRules = <(RegExp, String)>[
  (RegExp(r'^(New login on your account|Suspicious login stopped)'), 'security'),
  (RegExp(r'^Fingerprint machine offline'), 'devices'),
  (RegExp(r'^Payment due'), 'due'),
  (RegExp(r'^(Payment received|Membership (added|updated|frozen)|Branch changed|Transfer not approved)'), 'membership'),
  (RegExp(r'^(Plan activated|Payment not received)$'), 'subscription'),
  (RegExp(r'(ends in \d+ days$|ends tomorrow$|^Last day of your|has ended$)'), 'subscription'),
  (RegExp(r'^Branch transfer request'), 'requests:move'),
  (RegExp(r'^PT request to approve'), 'requests:pt'),
  (RegExp(r'^New (join|trainer) request'), 'requests'),
  (RegExp(r'^New member added'), 'members'),
  (RegExp(r'^PT payment received'), 'pt-pay'),
  (RegExp(r'^(New PT request|New PT client|PT approved|PT planned|PT sessions ending|PT request declined)'), 'pt'),
  (RegExp(r'^Staff attendance'), 'staffdays'),
  (RegExp(r'^(Mark your attendance|Still not marked)'), 'attendance'),
  (RegExp(r'^(Your plan is updated|New diet chart|New workout plan)'), 'program'),
  (RegExp(r'^(New support ticket|Ticket reply|Reply on ticket|Ticket GM-)'), 'tickets'),
  (RegExp(r'^Plan payment'), 'payments'),
  (RegExp(r'^New gym registered|gym plans? ended', caseSensitive: false), 'gyms'),
  (RegExp(r'^(Welcome!|Request declined|Removed from gym|You are gym staff now|Gym transferred|You own a gym now|Gym closed|Gym reopened)'), 'home'),
];

String? goFromTitle(String? title) {
  if (title == null) return null;
  for (final (re, go) in _goRules) {
    if (re.hasMatch(title)) return go;
  }
  return null;
}

/// What a notification is about: its "go", else worked out from the title (old notifications), else a gym notice.
String? goOfNote(Map n) => (n['go'] as String?) ?? (n['kind'] == 'DUE' ? 'due' : null) ?? goFromTitle(n['title'] as String?) ?? (n['kind'] == 'NOTICE' ? 'home' : null);

/// Where a notification takes the person (by what it is about and who they are). Null: nowhere special.
/// Tab pages are opened with go(), other pages with push() so Back returns. "@membership" is worked out
/// when tapped (the member's own membership page in that gym).
({String path, bool tab})? noteRoute(String mode, String? go, {bool staffDesk = false}) {
  if (go == null || go.isEmpty) return null;
  if (go.startsWith('staff-invite:')) return (path: '@invite:${go.substring(13)}', tab: false); // asks Accept / Decline
  final ticket = go.startsWith('ticket:') ? go.substring(7) : null;
  if (go == 'security') return (path: '/profile/devices', tab: false); // new login / stolen login alerts
  if (adminApp) {
    if (ticket != null) return (path: '/a/ticket/$ticket', tab: false);
    return switch (go) {
      'tickets' => (path: '/a/tickets', tab: false),
      'payments' => (path: '/a/payments', tab: false),
      'gyms' => (path: '/a/gyms', tab: true),
      _ => null,
    };
  }
  if (ticket != null) return (path: '/help/ticket/$ticket', tab: false);
  final member = go.startsWith('member:') ? go.substring(7) : null;
  switch (mode) {
    case 'owner':
      if (member != null) return (path: '/o/member/$member', tab: false);
      return switch (go) {
        'due' || 'membership' || 'members' => (path: '/o/members', tab: true),
        'requests' || 'requests:move' || 'requests:pt' => (path: '/o/requests', tab: true),
        'subscription' => staffDesk ? (path: '/o/home', tab: true) : (path: '/o/subscription', tab: false),
        'staffdays' => (path: '/o/staff-attendance', tab: false),
        'attendance' => (path: '/o/my-attendance', tab: false),
        'pt' || 'pt-pay' => (path: '/o/pt', tab: false),
        'tickets' => (path: '/help/new', tab: false),
        'enquiries' => (path: '/o/enquiries', tab: false),
        'lockers' => (path: '/o/lockers', tab: false),
        'devices' => (path: '/o/devices', tab: false),
        'salary' => (path: '/my-salary', tab: false),
        _ => (path: '/o/home', tab: true),
      };
    case 'trainer' || 'waiting' || 'trainerJoin':
      return switch (go) {
        'pt' || 'program' => (path: '/t/clients', tab: true),
        'attendance' => (path: '/t/my-attendance', tab: false),
        'salary' => (path: '/my-salary', tab: false),
        _ => (path: '/t/home', tab: true),
      };
    case 'member':
      return switch (go) {
        'due' || 'membership' => (path: '@membership', tab: false),
        'program' => (path: '/my-plan', tab: true),
        'pt' => (path: '/trainers', tab: true),
        'tickets' => (path: '/help', tab: true),
        _ => (path: '/home', tab: true),
      };
  }
  return null;
}

/// The member's membership page in a gym (the gym the notification came from, else their first gym).
Future<String> membershipPath(String? tenantId) async {
  try {
    final d = await Api.instance.get('/me/gyms');
    final ms = ((d is Map ? d['memberships'] : null) as List?)?.whereType<Map>().toList() ?? const <Map>[];
    final m = ms.firstWhere((x) => (x['gym'] as Map?)?['id'] == tenantId, orElse: () => ms.isEmpty ? const {} : ms.first);
    if (m['memberId'] != null) return '/membership/${m['memberId']}';
  } catch (_) {}
  return '/home';
}

/// Unread notifications (for the bell's red number).
final unreadCountProvider = Provider.autoDispose<int>((ref) {
  final v = ref.watch(notificationsProvider).valueOrNull;
  if (v is! List) return 0;
  return v.whereType<Map>().where((n) => n['readAt'] == null).length;
});
