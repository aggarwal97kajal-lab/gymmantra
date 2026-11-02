import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../i18n.dart';
import '../photo.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'pt.dart' show MyTrainerCard, myPtProvider;

/// Bottom navigation shell.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;
  static const tabs = ['/home', '/qr', '/trainers', '/my-plan', '/profile'];
  @override
  Widget build(BuildContext context) {
    final i = tabs.indexWhere((t) => location.startsWith(t));
    return Scaffold(
      body: child,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: context.c.line))),
        child: NavigationBar(
          selectedIndex: i < 0 ? 0 : i,
          onDestinationSelected: (n) => context.go(tabs[n]),
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: context.t('Home')),
            NavigationDestination(icon: const Icon(Icons.qr_code_2_rounded), label: context.t('Check-in')),
            NavigationDestination(icon: const Icon(Icons.sports_outlined), selectedIcon: const Icon(Icons.sports_rounded), label: context.t('Trainers')),
            NavigationDestination(icon: const Icon(Icons.assignment_outlined), selectedIcon: const Icon(Icons.assignment_rounded), label: context.t('My plan')),
            NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: context.t('Profile')),
          ],
        ),
      ),
    );
  }
}

const _lines = [
  'Leg day hai aaj? 💪',
  'Consistency beats motivation.',
  'One more rep. You got this.',
  'Drink water, lift heavy, sleep well.',
  'Small steps every day.',
];

Future<void> openUrl(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
String waLink(String number, String text) => 'https://wa.me/${number.replaceAll(RegExp(r'[^0-9]'), '')}?text=${Uri.encodeComponent(text)}';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final gyms = ref.watch(gymsProvider);
    final u = s.user ?? {};
    final name = (u['name'] as String?) ?? '';
    final first = name.split(' ').first;
    final line = _lines[DateTime.now().weekday % _lines.length];
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: context.c.primary,
          onRefresh: () async => ref.invalidate(gymsProvider),
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 24), children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(context.t('Hi {name} 👋', {'name': first}), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  const SizedBox(height: 2),
                  Muted(context.t(line), size: 13.5),
                ]),
              ),
              _RoundIcon(icon: Icons.notifications_none_rounded, onTap: () => context.push('/notifications')),
              const SizedBox(width: 10),
              GestureDetector(onTap: () => context.go('/profile'), child: Avatar(name: name, url: u['photoUrl'] as String?, size: 42)),
            ]),
            const SizedBox(height: 18),
            AsyncBody(
              value: gyms,
              onRetry: () => ref.invalidate(gymsProvider),
              loading: const ListSkeleton(first: 210),
              builder: (d) {
                final list = (d['memberships'] as List).cast<Map>();
                final pending = (d['pendingRequests'] as List).cast<Map>();
                final main = list.isEmpty ? null : list.first;
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final m in list)
                    for (final o in ((m['offers'] as List?) ?? const []).cast<Map>())
                      OfferBanner(title: o['title'] as String, details: o['details'] as String?, who: m['gym']['name'] as String?, validTill: o['validTill'] as String?),
                  for (final m in list) ...[_MembershipCard(m), const SizedBox(height: 12)],
                  for (final p in ((ref.watch(myPtProvider).valueOrNull as List?) ?? const []).cast<Map>().where((p) => p['state'] == 'ACTIVE'))
                    Padding(padding: const EdgeInsets.only(bottom: 12), child: MyTrainerCard(pt: p, tenantId: (p['gym'] as Map)['id'] as String)),
                  for (final p in pending) ...[
                    Panel(
                      child: Row(children: [
                        const IconTile(Icons.hourglass_top_rounded, color: C.warn),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(p['gym']['name'], style: const TextStyle(fontWeight: FontWeight.w700)),
                            Muted(context.t('Join request sent. Your gym will approve it soon.')),
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (list.isEmpty && pending.isEmpty) const _JoinCard(),
                  if (main != null) ...[
                    Row(children: [
                      Expanded(child: _Stat(icon: Icons.calendar_month_rounded, value: '${main['visitsThisMonth'] ?? 0}', label: context.t('Visits this month'))),
                      const SizedBox(width: 12),
                      Expanded(child: _Stat(icon: Icons.local_fire_department_rounded, value: _lastVisit(context, main['lastVisitAt'] as String?), label: context.t('Last visit'), color: C.warn)),
                    ]),
                    const SizedBox(height: 12),
                  ],
                  Panel(
                    onTap: () => context.go('/workouts'),
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      const IconTile(Icons.view_in_ar_rounded, size: 46),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(context.t('3D exercise guides'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                          Muted(context.t('40 exercises with correct form'), size: 12.5),
                        ]),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(color: context.c.primary, borderRadius: BorderRadius.circular(99)),
                        child: Text(context.t('Open'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5)),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 18),
                  _QuickActions(main: main),
                  if (list.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    OutlinedButton.icon(onPressed: () => context.push('/join'), icon: const Icon(Icons.add_rounded), label: Text(context.t('Join another gym'))),
                  ],
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }

  static String _lastVisit(BuildContext context, String? at) {
    if (at == null) return '—';
    final d = daysAgo(at);
    if (d <= 0) return context.t('Today');
    if (d == 1) return context.t('Yesterday');
    return context.t('{n}d ago', {'n': d});
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: context.c.surf,
        shape: CircleBorder(side: BorderSide(color: context.c.line)),
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 42, height: 42, child: Icon(icon, size: 22))),
      );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.label, this.color});
  final IconData icon;
  final String value;
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 20, color: color ?? context.c.primary),
            const SizedBox(width: 8),
            Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.1))),
          ]),
          const SizedBox(height: 4),
          Muted(label, size: 12),
        ]),
      );
}

class _JoinCard extends StatelessWidget {
  const _JoinCard();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [C.orangeSoft, C.orange, C.orangeDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Logo(size: 46, body: Colors.white, mark: C.orange),
          const SizedBox(height: 10),
          Text(context.t('Join your gym'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 6),
          Text(context.t('Ask the front desk for the gym code, or find it on the GymMantra poster at your gym.'), style: const TextStyle(color: Color(0xFFFFF1EA), height: 1.35)),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: C.orangeDeep),
            onPressed: () => context.push('/join'),
            child: Text(context.t('Enter gym code')),
          ),
        ]),
      );
}

class _MembershipCard extends StatelessWidget {
  const _MembershipCard(this.m);
  final Map m;
  @override
  Widget build(BuildContext context) {
    final status = m['status'] as String;
    final daysLeft = m['daysLeft'] as int?;
    final planName = m['planName'] as String?;
    final ends = m['endsOn'] as String?;
    final starts = m['startsOn'] as String?;
    var fraction = 0.0;
    if (daysLeft != null && ends != null && starts != null) {
      final total = DateTime.parse(ends).difference(DateTime.parse(starts)).inDays + 1;
      if (total > 0) fraction = daysLeft / total;
    }
    final live = daysLeft != null && daysLeft >= 0 && (status == 'ACTIVE' || status == 'ENDING_SOON' || status == 'FROZEN');
    final gradient = live
        ? const LinearGradient(colors: [C.orangeSoft, C.orange, C.orangeDeep], begin: Alignment.topLeft, end: Alignment.bottomRight)
        : const LinearGradient(colors: [Color(0xFF3A4150), Color(0xFF232833)], begin: Alignment.topLeft, end: Alignment.bottomRight);
    return Material(
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(gradient: gradient),
        child: InkWell(
          onTap: () => context.push('/membership/${m['memberId']}'),
          child: Stack(children: [
            Positioned(right: -30, top: -30, child: Opacity(opacity: 0.12, child: Logo(size: 170, body: Colors.white, mark: Colors.white))),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text('${m['gym']['name']} · ${context.t('My membership')}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  StatusChip(status, onColor: true),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(planName ?? context.t('No plan yet'), style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.15)),
                      const SizedBox(height: 4),
                      Text(
                        planName == null
                            ? context.t('Visit the front desk to start one.')
                            : live
                                ? context.t('Ends {date}', {'date': fmtDate(ends)})
                                : context.t('Ended {date}', {'date': fmtDate(ends)}),
                        style: const TextStyle(color: Color(0xFFFFEDE5), fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text('ID ${m['memberCode']}', style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
                    ]),
                  ),
                  if (live) DaysRing(days: daysLeft, fraction: fraction, label: context.t('days left')),
                ]),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: live ? C.orangeDeep : C.night, minimumSize: const Size.fromHeight(48)),
                    onPressed: () => live ? context.go('/qr') : context.push('/membership/${m['memberId']}'),
                    icon: Icon(live ? Icons.qr_code_2_rounded : Icons.autorenew_rounded),
                    label: Text(live ? context.t('Show check-in QR') : context.t('Renew membership')),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.main});
  final Map? main;
  @override
  Widget build(BuildContext context) {
    final gym = main?['gym'] as Map?;
    final phone = gym?['phone'] as String?;
    final wa = gym?['whatsappNumber'] as String?;
    final items = <(IconData, String, VoidCallback?)>[
      (Icons.receipt_long_rounded, context.t('Gym plans'), gym == null ? null : () => context.push('/plans/${gym['id']}')),
      (Icons.call_rounded, context.t('Call gym'), phone == null ? null : () => openUrl('tel:$phone')),
      (Icons.view_in_ar_rounded, context.t('3D guides'), () => context.go('/workouts')),
      (Icons.chat_rounded, 'WhatsApp', wa == null ? null : () => openUrl(waLink(wa, 'Hi, I am ${main!['memberCode']}.'))),
    ];
    return Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      for (final (icon, label, onTap) in items)
        Expanded(
          child: Opacity(
            opacity: onTap == null ? 0.4 : 1.0,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(color: context.c.surf, borderRadius: BorderRadius.circular(18), border: Border.all(color: context.c.line)),
                    child: Icon(icon, color: icon == Icons.chat_rounded ? C.wa : context.c.primary),
                  ),
                  const SizedBox(height: 7),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}
