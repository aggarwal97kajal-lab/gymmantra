import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

/// Bottom navigation shell.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;
  static const tabs = ['/home', '/qr', '/workouts', '/help', '/profile'];
  @override
  Widget build(BuildContext context) {
    final i = tabs.indexWhere((t) => location.startsWith(t));
    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: i < 0 ? 0 : i,
        onDestinationSelected: (n) => context.go(tabs[n]),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.qr_code_2), label: 'Check-in'),
          NavigationDestination(icon: Icon(Icons.fitness_center), label: 'Workouts'),
          NavigationDestination(icon: Icon(Icons.support_agent_outlined), selectedIcon: Icon(Icons.support_agent), label: 'Help'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final gyms = ref.watch(gymsProvider);
    final first = (s.user?['name'] as String? ?? '').split(' ').first;
    return Scaffold(
      appBar: AppBar(
        title: const Wordmark(size: 22),
        actions: [IconButton(onPressed: () => context.push('/notifications'), icon: const Icon(Icons.notifications_none))],
      ),
      body: RefreshIndicator(
        color: C.lime,
        onRefresh: () async => ref.invalidate(gymsProvider),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Hi $first 👋', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Muted('Fitness ka sahi mantra.'),
          const SizedBox(height: 18),
          AsyncBody(
            value: gyms,
            onRetry: () => ref.invalidate(gymsProvider),
            builder: (d) {
              final list = (d['memberships'] as List).cast<Map>();
              final pending = (d['pendingRequests'] as List).cast<Map>();
              return Column(children: [
                for (final m in list) ...[_MembershipCard(m), const SizedBox(height: 12)],
                for (final p in pending) ...[
                  Panel(
                    child: Row(children: [
                      const Icon(Icons.hourglass_top, color: C.org),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(p['gym']['name'], style: const TextStyle(fontWeight: FontWeight.w700)), const Muted('Join request sent. Your gym will approve it soon.')])),
                    ]),
                  ),
                  const SizedBox(height: 12),
                ],
                if (list.isEmpty && pending.isEmpty)
                  Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Join your gym', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 6),
                      const Muted('Ask the front desk for the gym code, or find it on the GymMantra poster at your gym.'),
                      const SizedBox(height: 14),
                      FilledButton(onPressed: () => context.push('/join'), child: const Text('Enter gym code')),
                    ]),
                  )
                else
                  OutlinedButton.icon(onPressed: () => context.push('/join'), icon: const Icon(Icons.add), label: const Text('Join another gym')),
              ]);
            },
          ),
          const SizedBox(height: 18),
          Panel(
            onTap: () => context.go('/workouts'),
            child: const Row(children: [
              Icon(Icons.view_in_ar, color: C.lime),
              SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('3D exercise guides', style: TextStyle(fontWeight: FontWeight.w700)), Muted('40 exercises with correct form')])),
              Icon(Icons.chevron_right, color: C.mut),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _MembershipCard extends StatelessWidget {
  const _MembershipCard(this.m);
  final Map m;
  @override
  Widget build(BuildContext context) {
    final status = m['status'] as String;
    final daysLeft = m['daysLeft'] as int?;
    return Panel(
      onTap: () => context.push('/membership/${m['memberId']}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(m['gym']['name'], style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))),
          StatusChip(status),
        ]),
        const SizedBox(height: 4),
        Muted('Member ID ${m['memberCode']}'),
        const SizedBox(height: 14),
        if (m['planName'] != null)
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Muted('Plan', size: 12), Text(m['planName'], style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))])),
            if (daysLeft != null && daysLeft >= 0)
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$daysLeft', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: status == 'ENDING_SOON' ? C.org : C.lime, height: 1)),
                Muted(daysLeft == 1 ? 'day left' : 'days left', size: 12),
              ])
            else
              Muted('Ended ${fmtDate(m['endsOn'])}'),
          ])
        else
          const Muted('No membership yet. Visit the front desk to start one.'),
      ]),
    );
  }
}
