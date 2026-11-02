import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'i18n.dart';
import 'prefs.dart';
import 'screens/auth.dart';
import 'screens/gym.dart';
import 'screens/help.dart';
import 'screens/home.dart';
import 'screens/profile.dart';
import 'screens/qr.dart';
import 'screens/workouts.dart';
import 'session.dart';
import 'theme.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Prefs.init();
  AppSettings.instance.load();
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

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    session.start();
    router = GoRouter(
      initialLocation: '/splash',
      refreshListenable: Listenable.merge([session, splashDone]),
      redirect: (context, state) {
        final loc = state.matchedLocation;
        if (!session.ready || !splashDone.value) return loc == '/splash' ? null : '/splash';
        const open = ['/login', '/signup', '/forgot'];
        if (!session.loggedIn) return open.contains(loc) ? null : '/login';
        if (open.contains(loc) || loc == '/splash') return '/home';
        return null;
      },
      routes: [
        GoRoute(path: '/splash', pageBuilder: (_, __) => const NoTransitionPage(child: SplashScreen())),
        GoRoute(path: '/login', pageBuilder: (_, __) => const NoTransitionPage(child: LoginScreen())),
        GoRoute(path: '/signup', builder: (_, __) => const SignupScreen()),
        GoRoute(path: '/forgot', builder: (_, __) => const ForgotScreen()),
        ShellRoute(
          builder: (context, state, child) => HomeShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(path: '/home', pageBuilder: (_, __) => const NoTransitionPage(child: HomeScreen())),
            GoRoute(path: '/qr', pageBuilder: (_, __) => const NoTransitionPage(child: QrScreen())),
            GoRoute(path: '/workouts', pageBuilder: (_, __) => const NoTransitionPage(child: WorkoutsScreen())),
            GoRoute(path: '/help', pageBuilder: (_, __) => const NoTransitionPage(child: HelpScreen())),
            GoRoute(path: '/profile', pageBuilder: (_, __) => const NoTransitionPage(child: ProfileScreen())),
          ],
        ),
        GoRoute(path: '/join', builder: (_, __) => const JoinScreen()),
        GoRoute(path: '/membership/:id', builder: (_, s) => MembershipScreen(memberId: s.pathParameters['id']!)),
        GoRoute(path: '/plans/:tenantId', builder: (_, s) => PlansScreen(tenantId: s.pathParameters['tenantId']!)),
        GoRoute(path: '/exercise', builder: (_, s) => ExerciseScreen(exercise: s.extra as Map)),
        GoRoute(path: '/help/new', builder: (_, __) => const NewTicketScreen()),
        GoRoute(path: '/help/ticket/:id', builder: (_, s) => TicketScreen(id: s.pathParameters['id']!)),
        GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
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
          title: 'GymMantra',
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          darkTheme: buildTheme(Brightness.dark),
          themeMode: settings.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 250),
          routerConfig: router,
        ),
      ),
    );
  }
}

/// Animated splash: the dumbbell drops in and bounces, the heartbeat line
/// draws across it, then the name and tagline rise up (about 1.4 seconds).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashState();
}

class _SplashState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));

  late final drop = CurvedAnimation(parent: a, curve: const Interval(0, 0.42, curve: Curves.bounceOut));
  late final fadeIn = CurvedAnimation(parent: a, curve: const Interval(0, 0.18, curve: Curves.easeOut));
  late final glow = CurvedAnimation(parent: a, curve: const Interval(0.3, 0.7, curve: Curves.easeOut));
  late final pulse = CurvedAnimation(parent: a, curve: const Interval(0.42, 0.72, curve: Curves.easeInOut));
  late final words = CurvedAnimation(parent: a, curve: const Interval(0.6, 0.9, curve: Curves.easeOutCubic));

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

  @override
  Widget build(BuildContext context) {
    final t = translate(AppLang.current, 'Fitness ka sahi mantra.');
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(statusBarColor: Colors.transparent),
      child: Scaffold(
        backgroundColor: C.night,
        body: AnimatedBuilder(
          animation: a,
          builder: (context, _) {
            return Stack(children: [
              // warm glow behind the logo
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.15),
                      radius: 0.9,
                      colors: [C.orange.withAlpha((50 * glow.value).round()), C.night],
                    ),
                  ),
                ),
              ),
              Align(
                alignment: const Alignment(0, -0.12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 200,
                    height: 200,
                    child: Stack(alignment: Alignment.center, children: [
                      Opacity(
                        opacity: (1 - glow.value).clamp(0.0, 1.0) * (glow.value > 0 ? 1 : 0),
                        child: Container(
                          width: 110 + 90 * glow.value,
                          height: 110 + 90 * glow.value,
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.orange.withAlpha(150), width: 2)),
                        ),
                      ),
                      Transform.translate(
                        offset: Offset(0, -160 * (1 - drop.value)),
                        child: Opacity(opacity: fadeIn.value, child: Logo(size: 112, mark: Colors.white, pulse: pulse.value)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Opacity(
                    opacity: words.value,
                    child: Transform.translate(
                      offset: Offset(0, 16 * (1 - words.value)),
                      child: Column(children: [
                        const Wordmark(size: 36, color: Colors.white),
                        const SizedBox(height: 6),
                        Text(t, style: const TextStyle(color: Color(0xFF8B95A5), fontSize: 14)),
                      ]),
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
