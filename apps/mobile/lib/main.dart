import 'dart:async';
import 'dart:io' show HttpOverrides;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'admin.dart';
import 'api.dart';
import 'haptics.dart';
import 'i18n.dart';
import 'prefs.dart';
import 'screens/gym_admin.dart';
import 'screens/checkin.dart';
import 'screens/auth.dart';
import 'screens/billing.dart';
import 'screens/gym.dart';
import 'screens/help.dart';
import 'screens/legal.dart';
import 'screens/home.dart';
import 'screens/profile.dart';
import 'screens/program.dart';
import 'screens/pt.dart';
import 'screens/owner.dart';
import 'screens/desk.dart';
import 'screens/qr.dart';
import 'screens/role.dart';
import 'screens/trainer.dart';
import 'screens/workouts.dart';
import 'screens/branch.dart';
import 'screens/extras.dart';
import 'photo.dart';
import 'session.dart';
import 'push.dart';
import 'theme.dart';
import 'ui.dart';

Future<void> main() async {
  HttpOverrides.global = Ipv4FirstOverrides(); // see Api.ipv4First
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([Prefs.init(), PhotoCache.init()]);
  unawaited(Push.init());
  AppSettings.instance.load();
  TapHaptics.install();
  runApp(const ProviderScope(child: GymMantraApp()));
}

/// Becomes true when the splash animation has played once.
final splashDone = ValueNotifier<bool>(false);

class GymMantraApp extends ConsumerStatefulWidget {
  const GymMantraApp({super.key});
  @override
  ConsumerState<GymMantraApp> createState() => _AppState();
}

class _AppState extends ConsumerState<GymMantraApp> {
  late final GoRouter router;
  AppLifecycleListener? _life;
  DateTime? _hiddenAt;

  /// Back to the app (for example after changing something in GM Admin): open screens load again.
  void _liveRefresh() {
    final session = ref.read(sessionProvider);
    if (session.user == null) return;
    Api.instance.refreshOpenScreens();
    session.checkStillLoggedIn();
  }

  void _openGo(String? go, int tries) {
    final session = ref.read(sessionProvider);
    // Still starting (splash / not logged in yet): try again shortly, for up to ~10 s.
    if (!session.ready || session.user == null || !splashDone.value) {
      if (tries < 20) Future.delayed(const Duration(milliseconds: 500), () => _openGo(go, tries + 1));
      return;
    }
    final r = noteRoute(session.mode, go, staffDesk: session.isStaffDesk);
    if (r == null) return;
    if (r.path.startsWith('@invite:')) {
      final ctx = router.routerDelegate.navigatorKey.currentContext;
      if (ctx != null) answerStaffInvite(ctx, r.path.substring(8));
      return;
    }
    if (r.path == '@membership') {
      membershipPath(_pushTenant).then((p) => p == '/home' ? router.go(p) : router.push(p));
      return;
    }
    if (r.tab) {
      router.go(r.path);
    } else {
      router.push(r.path);
    }
  }

  String? _pushTenant; // the gym a tapped phone notification came from

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    session.start();
    _life = AppLifecycleListener(
      onHide: () => _hiddenAt = DateTime.now(),
      onShow: () {
        final away = _hiddenAt == null ? Duration.zero : DateTime.now().difference(_hiddenAt!);
        if (away > const Duration(seconds: 2)) _liveRefresh();
      },
    );
    // A notification means something changed: load now, and once more a little later
    // (the server may answer from an 8-second memory for a moment).
    Push.onChange = () {
      _liveRefresh();
      Future.delayed(const Duration(seconds: 9), _liveRefresh);
    };
    // A login of this person was ended on the server: log out live if it was this phone.
    Push.onLogout = (note) => ref.read(sessionProvider).checkStillLoggedIn(note ?? 'You were logged out');
    // Tapping a phone notification opens the page it is about (after the app has started).
    Push.onOpen = (go, tenantId) {
      _pushTenant = tenantId;
      _openGo(go, 0);
    };
    final waiting = Push.pendingGo;
    _pushTenant = Push.pendingTenant;
    Push.pendingGo = null;
    if (waiting != null) Future.delayed(const Duration(milliseconds: 600), () => _openGo(waiting, 0));
    if (adminApp) {
      router = adminRouter(session, splashDone, const SplashScreen(), () => splashDone.value);
      return;
    }
    router = GoRouter(
      initialLocation: '/splash',
      refreshListenable: Listenable.merge([session, splashDone]),
      redirect: (context, state) {
        final loc = state.matchedLocation;
        if (!session.ready || !splashDone.value) return loc == '/splash' ? null : '/splash';
        if (loc.startsWith('/legal')) return null; // Terms and Privacy open for everyone
        const open = ['/login', '/signup', '/forgot', '/start'];
        if (!session.loggedIn) {
          // First open: "Who are you?" comes before log-in.
          if (session.pendingRole == null) return loc == '/start' ? null : '/start';
          if (loc == '/start') return null;
          return open.contains(loc) ? null : '/login';
        }
        // Gym-made account on its first (Google) login: choose a password once.
        if (session.user?['needsPassword'] == true) return loc == '/set-password' ? null : '/set-password';
        // Google sign-up: DOB, state, city and PIN are still needed.
        if (session.user?['needsDetails'] == true) return loc == '/complete-details' ? null : '/complete-details';
        // Each kind of person has their own part of the app.
        const shared = ['/notifications', '/support', '/help/new', '/help/ticket', '/pt-client', '/program-edit', '/profile/', '/checkin', '/pdf', '/my-salary'];
        if (shared.any((p) => loc.startsWith(p))) return null;
        // Staff never open the GymMantra plan page (that is for the owner).
        if (loc.startsWith('/o/subscription') && session.isStaffDesk) return '/o/home';
        final (home, prefix) = switch (session.mode) {
          'owner' => ('/o/home', '/o/'),
          'trainer' => ('/t/home', '/t/'),
          // A trainer who has not joined a gym yet still gets the trainer dashboard.
          'waiting' || 'trainerJoin' => ('/t/home', '/t/'),
          'registerGym' => ('/register-gym', '/register-gym'),
          'staffNone' => ('/staff-none', '/staff-none'),
          'role' => ('/role', '/role'),
          _ => ('/home', ''),
        };
        if (prefix.isEmpty) {
          // Member: everything except the other parts.
          const others = ['/o/', '/t/', '/waiting', '/register-gym', '/trainer-join', '/role'];
          if (open.contains(loc) || loc == '/splash' || loc == '/set-password' || loc == '/complete-details' || others.any((p) => loc.startsWith(p))) return home;
          return null;
        }
        if (prefix == '/t/' && (loc.startsWith('/trainer-join') || loc.startsWith('/waiting'))) return null;
        return loc.startsWith(prefix) ? null : home;
      },
      routes: [
        GoRoute(path: '/splash', pageBuilder: (_, __) => const NoTransitionPage(child: SplashScreen())),
        GoRoute(path: '/login', pageBuilder: (_, __) => const NoTransitionPage(child: LoginScreen())),
        GoRoute(path: '/signup', builder: (_, __) => const SignupScreen()),
        GoRoute(path: '/forgot', builder: (_, __) => const ForgotScreen()),
        GoRoute(path: '/legal/:kind', builder: (_, s) => LegalScreen(privacy: s.pathParameters['kind'] == 'privacy')),
        ShellRoute(
          builder: (context, state, child) => HomeShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(path: '/home', pageBuilder: (_, __) => const NoTransitionPage(child: HomeScreen())),
            GoRoute(path: '/qr', pageBuilder: (_, __) => const NoTransitionPage(child: ScanCheckinScreen())),
            GoRoute(path: '/trainers', pageBuilder: (_, __) => const NoTransitionPage(child: MemberTrainersScreen())),
            GoRoute(path: '/my-plan', pageBuilder: (_, __) => const NoTransitionPage(child: MyPlanScreen())),
            GoRoute(path: '/workouts', pageBuilder: (_, __) => const NoTransitionPage(child: WorkoutsScreen())),
            GoRoute(path: '/help', pageBuilder: (_, __) => const NoTransitionPage(child: HelpScreen())),
            GoRoute(path: '/profile', pageBuilder: (_, __) => const NoTransitionPage(child: ProfileScreen())),
          ],
        ),
        GoRoute(path: '/join', builder: (_, __) => const JoinScreen()),
        GoRoute(path: '/my-qr', builder: (_, __) => const QrScreen()),
        GoRoute(path: '/checkin', builder: (_, __) => const ScanCheckinScreen(standalone: true)),
        GoRoute(path: '/membership/:id', builder: (_, s) => MembershipScreen(memberId: s.pathParameters['id']!)),
        GoRoute(path: '/plans/:tenantId', builder: (_, s) => PlansScreen(tenantId: s.pathParameters['tenantId']!)),
        GoRoute(path: '/exercise', builder: (_, s) => ExerciseScreen(exercise: s.extra as Map)),
        GoRoute(path: '/help/new', builder: (_, __) => const NewTicketScreen()),
        GoRoute(path: '/help/ticket/:id', builder: (_, s) => TicketScreen(id: s.pathParameters['id']!)),
        GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
        GoRoute(path: '/support', builder: (_, __) => const HelpScreen()),
        GoRoute(path: '/profile/details', builder: (_, __) => const ProfileDetailsScreen()),
        GoRoute(path: '/profile/password', builder: (_, __) => const ChangePasswordScreen()),
        GoRoute(path: '/profile/devices', builder: (_, __) => const LoginDevicesScreen()),
        GoRoute(path: '/trainer-detail', builder: (_, s) => TrainerDetailScreen(trainer: (s.extra as Map)['trainer'] as Map, tenantId: (s.extra as Map)['tenantId'] as String)),
        GoRoute(path: '/my-pt', builder: (_, s) => MyPtScreen(pt: (s.extra as Map)['pt'] as Map, tenantId: (s.extra as Map)['tenantId'] as String)),
        GoRoute(path: '/pt-client', builder: (_, s) => PtClientScreen(pt: (s.extra as Map)['pt'] as Map, tenantId: (s.extra as Map)['tenantId'] as String, canMark: (s.extra as Map)['canMark'] == true)),
        GoRoute(
          path: '/program-edit',
          builder: (_, s) {
            final x = s.extra as Map;
            return ProgramEditScreen(tenantId: x['tenantId'] as String, memberId: x['memberId'] as String, memberName: x['memberName'] as String, workout: x['workout'] == true);
          },
        ),
        GoRoute(path: '/o/pt', builder: (_, __) => const OwnerPtClientsScreen()),
        GoRoute(path: '/o/subscription', builder: (_, __) => const SubscriptionScreen()),
        GoRoute(path: '/o/bill/:id', builder: (_, s) => BillScreen(id: s.pathParameters['id']!, then: s.uri.queryParameters['do'])),
        GoRoute(path: '/o/address', builder: (_, __) => const GymAddressScreen()),
        GoRoute(path: '/o/branches', builder: (_, __) => const BranchesScreen()),
        GoRoute(path: '/o/staff', builder: (_, __) => const StaffListScreen()),
        GoRoute(path: '/o/staff/new', builder: (_, __) => const AddStaffScreen()),
        GoRoute(path: '/o/staff/edit', builder: (_, s) => StaffEditScreen(staff: s.extra as Map)),
        GoRoute(path: '/o/attendance', builder: (_, __) => const DeskAttendanceScreen()),
        GoRoute(path: '/o/attendance-hub', builder: (_, __) => const AttendanceHubScreen()),
        GoRoute(path: '/o/attendance/scan', builder: (_, __) => const DeskScanScreen()),
        GoRoute(path: '/o/attendance/manual', builder: (_, __) => const ManualCheckinScreen()),
        GoRoute(path: '/o/my-attendance', builder: (_, __) => const MyAttendanceScreen()),
        GoRoute(path: '/t/my-attendance', builder: (_, __) => const MyAttendanceScreen()),
        GoRoute(path: '/o/staff-attendance', builder: (_, __) => const StaffAttendanceScreen()),
        GoRoute(path: '/o/import', builder: (_, __) => const ImportMembersScreen()),
        GoRoute(path: '/o/gate', builder: (_, __) => const GateScreen()),
        GoRoute(path: '/o/transfer-gym', builder: (_, __) => const TransferGymScreen()),
        GoRoute(path: '/staff-none', builder: (_, __) => const StaffNoneScreen()),
        GoRoute(path: '/set-password', builder: (_, __) => const SetPasswordScreen()),
        GoRoute(path: '/complete-details', builder: (_, __) => const CompleteDetailsScreen()),
        GoRoute(path: '/o/reports', builder: (_, __) => const ReportsScreen()),
        GoRoute(path: '/transfer/:tid', builder: (_, s) => MemberTransferScreen(tenantId: s.pathParameters['tid']!, toBranchId: s.uri.queryParameters['to']?.isEmpty == true ? null : s.uri.queryParameters['to'])),
        GoRoute(path: '/o/gym-qr', builder: (_, s) => GymQrScreen(share: s.uri.queryParameters['share'] == '1')),
        GoRoute(path: '/o/notices', builder: (_, __) => const NoticesScreen()),
        GoRoute(path: '/o/notices/new', builder: (_, __) => const NewNoticeScreen()),
        GoRoute(path: '/o/plans', builder: (_, __) => const ManagePlansScreen()),
        GoRoute(path: '/o/settings', builder: (_, __) => const GymSettingsScreen()),
        GoRoute(path: '/o/pt-accounts', builder: (_, __) => const PtAccountsScreen()),
        GoRoute(path: '/o/enquiries', builder: (_, __) => const EnquiriesScreen()),
        GoRoute(path: '/o/enquiries/new', builder: (_, s) => EnquiryFormScreen(enquiry: s.extra as Map?)),
        GoRoute(path: '/o/enquiry/:id', builder: (_, s) => EnquiryScreen(id: s.pathParameters['id']!)),
        GoRoute(path: '/o/lockers', builder: (_, __) => const LockersScreen()),
        GoRoute(path: '/o/salary', builder: (_, __) => const SalaryScreen()),
        GoRoute(path: '/o/salary/setup', builder: (_, s) => SalarySetupScreen(person: s.extra as Map)),
        GoRoute(path: '/o/salary/person', builder: (_, s) => SalaryPersonScreen(person: s.extra as Map)),
        GoRoute(path: '/o/ratings', builder: (_, __) => const RatingsScreen()),
        GoRoute(path: '/o/devices', builder: (_, __) => const DevicesScreen()),
        GoRoute(path: '/my-salary', builder: (_, __) => const MySalaryScreen()),
        GoRoute(path: '/rate', builder: (_, s) => RateScreen(args: s.extra as Map)),
        // ---- choosing a role ----
        GoRoute(path: '/role', pageBuilder: (_, __) => const NoTransitionPage(child: RolePickScreen())),
        GoRoute(path: '/start', pageBuilder: (_, __) => const NoTransitionPage(child: RolePickScreen(beforeLogin: true))),
        GoRoute(path: '/register-gym', builder: (_, __) => const RegisterGymScreen()),
        GoRoute(path: '/trainer-join', builder: (_, __) => const TrainerJoinScreen()),
        GoRoute(path: '/waiting', builder: (_, __) => const WaitingScreen()),
        // ---- gym owner / front desk ----
        ShellRoute(
          builder: (context, state, child) => OwnerShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(path: '/o/home', pageBuilder: (_, __) => const NoTransitionPage(child: OwnerHomeScreen())),
            GoRoute(path: '/o/members', pageBuilder: (_, __) => const NoTransitionPage(child: OwnerMembersScreen())),
            GoRoute(path: '/o/requests', pageBuilder: (_, __) => const NoTransitionPage(child: OwnerRequestsScreen())),
            GoRoute(path: '/o/offers', pageBuilder: (_, __) => const NoTransitionPage(child: OwnerOffersScreen())),
            GoRoute(path: '/o/more', pageBuilder: (_, __) => const NoTransitionPage(child: OwnerMoreScreen())),
            GoRoute(path: '/o/desk', pageBuilder: (_, __) => const NoTransitionPage(child: AttendanceHubScreen(tab: true))),
          ],
        ),
        GoRoute(path: '/o/members/new', builder: (_, s) => AddMemberScreen(enquiry: (s.extra as Map?)?['enquiry'] as Map?)),
        GoRoute(path: '/o/member/:id', builder: (_, s) => OwnerMemberScreen(id: s.pathParameters['id']!)),
        GoRoute(path: '/o/offers/new', builder: (_, __) => const NewOfferScreen()),
        GoRoute(path: '/o/trainers', builder: (_, __) => const OwnerTrainersScreen()),
        GoRoute(path: '/o/trainer', builder: (_, s) => OwnerTrainerScreen(trainer: s.extra as Map)),
        GoRoute(path: '/o/profile', builder: (_, __) => const ProfileScreen()),
        // ---- trainer ----
        ShellRoute(
          builder: (context, state, child) => TrainerShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(path: '/t/home', pageBuilder: (_, __) => const NoTransitionPage(child: TrainerHomeScreen())),
            GoRoute(path: '/t/clients', pageBuilder: (_, __) => const NoTransitionPage(child: TrainerClientsList())),
            GoRoute(path: '/t/profile', pageBuilder: (_, __) => const NoTransitionPage(child: ProfileScreen())),
          ],
        ),
        GoRoute(path: '/t/about', builder: (_, __) => const TrainerAboutScreen()),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return LangScope(
      notifier: settings,
      child: ListenableBuilder(
        listenable: settings,
        builder: (_, __) => MaterialApp.router(
          title: adminApp ? 'GymMantra Admin' : 'GymMantra',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 250),
          routerConfig: router,
          builder: (context, child) {
            final session = ref.read(sessionProvider);
            return ListenableBuilder(
              listenable: session,
              builder: (context, _) => Stack(children: [child ?? const SizedBox(), if (session.ending) LoggingOutCover(note: session.endedNote)]),
            );
          },
        ),
      ),
    );
  }
}

/// Animated splash (2 seconds):
/// 1. the dumbbell drops in with a little spin, bounces and squashes on landing,
/// 2. ripples spread out and the heartbeat line draws across it,
/// 3. it "beats" twice like a heart while sparks float up,
/// 4. the name rises letter by letter with a shine, then the tagline.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashState();
}

class _SplashState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 2000));

  Animation<double> _iv(double b, double e, [Curve c = Curves.easeOut]) => CurvedAnimation(parent: a, curve: Interval(b, e, curve: c));
  late final drop = _iv(0, 0.3, Curves.bounceOut);
  late final fadeIn = _iv(0, 0.12);
  late final spin = _iv(0, 0.34, Curves.easeOutBack);
  late final squash = _iv(0.22, 0.36, Curves.easeInOut);
  late final ripple1 = _iv(0.24, 0.6);
  late final ripple2 = _iv(0.34, 0.72);
  late final pulse = _iv(0.3, 0.52, Curves.easeInOut);
  late final beat1 = _iv(0.52, 0.62, Curves.easeInOut);
  late final beat2 = _iv(0.63, 0.73, Curves.easeInOut);
  late final glow = _iv(0.1, 0.7);
  late final sparks = _iv(0.3, 1, Curves.linear);
  late final words = _iv(0.58, 0.86, Curves.linear);
  late final shine = _iv(0.8, 0.98, Curves.easeInOut);
  late final tagline = _iv(0.78, 0.95);

  @override
  void initState() {
    super.initState();
    if (splashDone.value) return;
    a.forward().whenComplete(() => splashDone.value = true);
  }

  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  /// 0 → 1 → 0 bump used for the squash and the heart beats.
  double _bump(double v) => v <= 0 || v >= 1 ? 0.0 : (v < 0.5 ? v * 2 : (1 - v) * 2);

  Widget _ripple(double v) => Opacity(
        opacity: v <= 0 ? 0.0 : (1 - v).clamp(0.0, 1.0),
        child: Container(
          width: 110 + 110 * v,
          height: 110 + 110 * v,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.orange.withAlpha(170), width: 2)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final tag = translate(AppLang.current, 'Fitness ka sahi mantra.');
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: C.night,
        body: AnimatedBuilder(
          animation: a,
          builder: (context, _) {
            final sq = _bump(squash.value);
            final beat = 1 + 0.12 * _bump(beat1.value) + 0.08 * _bump(beat2.value);
            return Stack(children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.15),
                      radius: 0.8 + 0.25 * glow.value,
                      colors: [C.orange.withAlpha((60 * glow.value + 25 * _bump(beat1.value)).round().clamp(0, 255)), C.night],
                    ),
                  ),
                ),
              ),
              Positioned.fill(child: CustomPaint(painter: _SparksPainter(sparks.value))),
              Align(
                alignment: const Alignment(0, -0.12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 230,
                    height: 230,
                    child: Stack(alignment: Alignment.center, children: [
                      _ripple(ripple1.value),
                      _ripple(ripple2.value),
                      Transform.translate(
                        offset: Offset(0, -190 * (1 - drop.value)),
                        child: Transform.rotate(
                          angle: -0.6 * (1 - spin.value),
                          child: Transform.scale(
                            scaleX: (1 + 0.14 * sq) * beat,
                            scaleY: (1 - 0.16 * sq) * beat,
                            alignment: Alignment.bottomCenter,
                            child: Opacity(opacity: fadeIn.value, child: Logo(size: 116, body: adminApp ? C.gold : C.orange, mark: Colors.white, pulse: pulse.value)),
                          ),
                        ),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  _Letters(progress: words.value, shine: shine.value),
                  const SizedBox(height: 8),
                  Opacity(
                    opacity: tagline.value,
                    child: Transform.translate(
                      offset: Offset(0, 10 * (1 - tagline.value)),
                      child: Text(tag, style: const TextStyle(color: Color(0xFF8B95A5), fontSize: 14, letterSpacing: 0.3)),
                    ),
                  ),
                ]),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 64,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      width: 120,
                      height: 3,
                      child: LinearProgressIndicator(value: a.value, backgroundColor: const Color(0xFF262C36), color: C.orange),
                    ),
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// "GymMantra" rising one letter at a time, then a light sweep across it.
class _Letters extends StatelessWidget {
  const _Letters({required this.progress, required this.shine});
  final double progress;
  final double shine;
  static const text = 'GymMantra';
  @override
  Widget build(BuildContext context) {
    final row = Row(mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < text.length; i++)
        Builder(builder: (_) {
          final start = i / (text.length + 3);
          final v = ((progress - start) * (text.length + 3) / 4).clamp(0.0, 1.0);
          final e = Curves.easeOutBack.transform(v);
          return Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, 22 * (1 - e)),
              child: Text(
                text[i],
                style: TextStyle(fontSize: 38, fontWeight: FontWeight.w800, letterSpacing: -0.8, color: i < 3 ? Colors.white : (adminApp ? C.gold : C.orange), height: 1.1),
              ),
            ),
          );
        }),
    ]);
    if (shine <= 0 || shine >= 1) return row;
    return ShaderMask(
      blendMode: BlendMode.srcATop,
      shaderCallback: (r) => LinearGradient(
        colors: const [Color(0x00FFFFFF), Color(0xCCFFFFFF), Color(0x00FFFFFF)],
        stops: const [0.0, 0.5, 1.0],
        begin: Alignment(-2.5 + 5 * shine, 0),
        end: Alignment(-1.5 + 5 * shine, 0),
      ).createShader(r),
      child: row,
    );
  }
}

/// Small orange sparks drifting up behind the logo.
class _SparksPainter extends CustomPainter {
  _SparksPainter(this.t);
  final double t;
  static const _seeds = [
    (0.18, 0.62, 3.0, 0.0), (0.30, 0.70, 2.0, 0.15), (0.42, 0.58, 2.5, 0.35), (0.58, 0.66, 3.0, 0.1),
    (0.70, 0.60, 2.0, 0.28), (0.82, 0.68, 2.5, 0.05), (0.25, 0.52, 1.8, 0.45), (0.76, 0.50, 1.8, 0.4),
    (0.50, 0.74, 2.2, 0.22), (0.12, 0.56, 1.6, 0.3), (0.88, 0.56, 1.6, 0.18), (0.64, 0.76, 2.4, 0.5),
  ];
  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    for (final (x, y, r, delay) in _seeds) {
      final v = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (v <= 0) continue;
      final alpha = (v < 0.2 ? v / 0.2 : (1 - v) / 0.8).clamp(0.0, 1.0);
      final pos = Offset(size.width * x + 8 * (v - 0.5), size.height * (y - 0.28 * v));
      canvas.drawCircle(pos, r, Paint()..color = C.orange.withAlpha((200 * alpha).round()));
    }
  }

  @override
  bool shouldRepaint(_SparksPainter o) => o.t != t;
}

/// Over the whole app for a moment when the server ended this phone's login.
class LoggingOutCover extends StatelessWidget {
  const LoggingOutCover({super.key, this.note});
  final String? note;
  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: Material(
          color: Colors.black.withAlpha(225),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(width: 46, height: 46, child: CircularProgressIndicator(strokeWidth: 4.5, color: C.orange)),
                const SizedBox(height: 22),
                Text(context.t('Logging out…'), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                if (note != null) ...[
                  const SizedBox(height: 8),
                  Text(context.t(note!), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
                ],
              ]),
            ),
          ),
        ),
      );
}
