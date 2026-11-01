import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: GymMantraApp()));
}

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
      initialLocation: '/home',
      refreshListenable: session,
      redirect: (context, state) {
        final loc = state.matchedLocation;
        if (!session.ready) return loc == '/splash' ? null : '/splash';
        final authPage = loc == '/login' || loc == '/signup';
        if (!session.loggedIn) return authPage ? null : '/login';
        if (authPage || loc == '/splash') return '/home';
        return null;
      },
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => const _Splash()),
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
        GoRoute(path: '/signup', builder: (_, __) => const SignupScreen()),
        ShellRoute(
          builder: (context, state, child) => HomeShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(path: '/home', builder: (_, __) => const HomeScreen()),
            GoRoute(path: '/qr', builder: (_, __) => const QrScreen()),
            GoRoute(path: '/workouts', builder: (_, __) => const WorkoutsScreen()),
            GoRoute(path: '/help', builder: (_, __) => const HelpScreen()),
            GoRoute(path: '/profile', builder: (_, __) => const ProfileScreen()),
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
    return MaterialApp.router(title: 'GymMantra', debugShowCheckedModeBanner: false, theme: buildTheme(), routerConfig: router);
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Logo(size: 96), SizedBox(height: 12), Wordmark(), SizedBox(height: 6), Muted('Fitness ka sahi mantra.')])),
      );
}
