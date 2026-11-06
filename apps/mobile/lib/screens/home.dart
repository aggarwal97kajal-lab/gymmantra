import 'package:flutter/material.dart';
import '../haptics.dart';
import '../back.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../i18n.dart';
import '../photo.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import 'profile.dart' show NotificationBell;
import '../ui.dart';
import 'pt.dart' show MyTrainerCard, myPtProvider;
import 'billing.dart' show AdsStrip;
import 'extras.dart' show MemberGymExtras;

/// Bottom navigation shell.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;
  static const tabs = ['/home', '/qr', '/trainers', '/my-plan', '/profile'];
  @override
  Widget build(BuildContext context) {
    final i = tabs.indexWhere((t) => location.startsWith(t));
    return ShellBack(
      location: location,
      home: '/home',
      child: Scaffold(
      body: child,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: context.c.line))),
        child: NavigationBar(
          selectedIndex: i < 0 ? 0 : i,
          onDestinationSelected: (n) {
            TapHaptics.buzz();
            context.go(tabs[n]);
          },
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: context.t('Home')),
            NavigationDestination(icon: const Icon(Icons.qr_code_2_rounded), label: context.t('Check-in')),
            NavigationDestination(icon: const Icon(Icons.sports_outlined), selectedIcon: const Icon(Icons.sports_rounded), label: context.t('Trainers')),
            NavigationDestination(icon: const Icon(Icons.assignment_outlined), selectedIcon: const Icon(Icons.assignment_rounded), label: context.t('My plan')),
            NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: context.t('Profile')),
          ],
        ),
      ),
    ),
    );
  }
}

/// "₹7,500 due" card on the member's home, plus a pop-up once a day when they open the app.
class _DueBanner extends StatefulWidget {
  const _DueBanner(this.m);
  final Map m;
  @override
  State<_DueBanner> createState() => _DueBannerState();
}

class _DueBannerState extends State<_DueBanner> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _popup());
  }

  Future<void> _popup() async {
    final n = DateTime.now();
    final key = 'duePopup:${widget.m['memberId']}';
    final today = '${n.year}-${n.month}-${n.day}';
    if (Prefs.getString(key) == today || !mounted) return;
    await Prefs.setString(key, today);
    if (!mounted) return;
    showDialog(context: context, builder: (_) => _DueDialog(m: widget.m));
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final blocked = (m['entry'] as Map?)?['result'] == 'BLOCKED';
    return Material(
      color: C.red.withAlpha(context.c.dark ? 30 : 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: C.red.withAlpha(90))),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => showDialog(context: context, builder: (_) => _DueDialog(m: m)),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const IconTile(Icons.currency_rupee_rounded, color: C.red),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('{amount} due', {'amount': rupees(m['due'] as num?)}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: C.red)),
                Muted(context.t('Paid {paid} of {total}', {'paid': rupees(m['duePaid'] as num?), 'total': rupees(m['dueTotal'] as num?)}), size: 12.5),
                if (blocked) Muted(context.t('Entry is stopped until you pay'), size: 12),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: context.c.mut),
          ]),
        ),
      ),
    );
  }
}

class _DueDialog extends StatelessWidget {
  const _DueDialog({required this.m});
  final Map m;
  @override
  Widget build(BuildContext context) {
    final gym = m['gym'] as Map;
    final paid = (m['duePaid'] as num?) ?? 0;
    final total = (m['dueTotal'] as num?) ?? 0;
    final wa = (gym['whatsappNumber'] ?? gym['phone']) as String?;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 14),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 64, height: 64, decoration: BoxDecoration(color: C.red.withAlpha(30), shape: BoxShape.circle), child: const Icon(Icons.currency_rupee_rounded, color: C.red, size: 32)),
          const SizedBox(height: 12),
          Text(context.t('{amount} due', {'amount': rupees(m['due'] as num?)}), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Muted('${gym['name']}${m['duePlan'] != null ? ' · ${m['duePlan']}' : ''}', align: TextAlign.center),
          Muted(context.t('Paid {paid} of {total}', {'paid': rupees(paid), 'total': rupees(total)}), align: TextAlign.center),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: total <= 0 ? 0 : (paid / total).clamp(0, 1).toDouble(), minHeight: 8, backgroundColor: context.c.surf2, valueColor: const AlwaysStoppedAnimation(C.ok)),
          ),
          const SizedBox(height: 12),
          Muted(context.t('Please pay at the front desk, or your entry may be stopped.'), align: TextAlign.center, size: 12.5),
          const SizedBox(height: 16),
          if (wa != null)
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: C.wa, minimumSize: const Size.fromHeight(48)),
              onPressed: () => openUrl(waLink(wa, 'Hi, I am ${m['memberCode']}. About my due payment of ${rupees(m['due'] as num?)}.')),
              icon: const Icon(Icons.chat_rounded),
              label: Text(context.t('WhatsApp the gym')),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('OK'))),
        ]),
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
              const NotificationBell(),
              const SizedBox(width: 10),
              GestureDetector(onTap: () => context.go('/profile'), child: Avatar(name: name, url: u['photoUrl'] as String?, size: 42)),
            ]),
            const SizedBox(height: 18),
            const AdsStrip(role: 'MEMBER'),
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
                    for (final n in ((m['notices'] as List?) ?? const []).cast<Map>())
                      NoticeBanner(title: n['title'] as String, message: n['message'] as String, gym: m['gym']['name'] as String?, date: n['createdAt'] as String?),
                  for (final m in list)
                    for (final o in ((m['offers'] as List?) ?? const []).cast<Map>())
                      OfferBanner(title: o['title'] as String, details: o['details'] as String?, who: m['gym']['name'] as String?, validTill: o['validTill'] as String?, imageUrl: o['imageUrl'] as String?),
                  for (final m in list)
                    if (((m['due'] as num?) ?? 0) > 0) ...[_DueBanner(m), const SizedBox(height: 12)],
                  for (final m in list)
                    if ((m['gym'] as Map?)?['closed'] == true)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Panel(
                          child: Column(children: [
                            const Icon(Icons.lock_rounded, size: 34),
                            const SizedBox(height: 6),
                            Text(context.t('{gym} is closed', {'gym': m['gym']['name']}), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                            const SizedBox(height: 4),
                            Muted(context.t('Your membership history stays here. To join another gym, enter its gym code.'), align: TextAlign.center),
                            const SizedBox(height: 10),
                            FilledButton.icon(onPressed: () => context.push('/join'), icon: const Icon(Icons.add_rounded), label: Text(context.t('Join another gym'))),
                          ]),
                        ),
                      )
                    else ...[_MembershipCard(m), const SizedBox(height: 12), MemberGymExtras(m: m)],
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
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(value, maxLines: 1, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, height: 1.1)))),
          ]),
          const SizedBox(height: 4),
          Muted(label, size: 12, maxLines: 1),
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
    final fp = (m['gym'] as Map?)?['fingerprintOnly'] == true; // attendance only by fingerprint machine at this branch
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
                  // The logo of the member's own branch (a new branch's logo after a transfer).
                  GymLogo(name: '${m['gym']['name']}', url: m['gym']['logoUrl'] as String?, size: 40, onColor: true),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${m['gym']['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                      Text([m['gym']['code'], context.t('My membership')].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xDDFFFFFF), fontWeight: FontWeight.w600, fontSize: 12)),
                    ]),
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
                                ? context.t('Ends {date}', {'date': fmtDate(ends)}) + ((m['frozenDays'] as int? ?? 0) > 0 ? ' (${context.t('+{n} days freeze', {'n': m['frozenDays']})})' : '')
                                : context.t('Ended {date}', {'date': fmtDate(ends)}),
                        style: const TextStyle(color: Color(0xFFFFEDE5), fontSize: 13),
                      ),
                      const SizedBox(height: 2),
                      Text('ID ${m['memberCode']}', style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12)),
                      if (m['multiBranch'] == true && m['branch'] is Map)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => context.push('/transfer/${m['gym']['id']}'),
                          child: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.place_rounded, size: 15, color: Colors.white),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text('${m['branch']['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(color: Colors.white.withAlpha(50), borderRadius: BorderRadius.circular(8)),
                                child: Text(context.t('Change'), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                              ),
                            ]),
                          ),
                        ),
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
                    icon: Icon(live ? (fp ? Icons.fingerprint_rounded : Icons.qr_code_2_rounded) : Icons.autorenew_rounded),
                    label: Text(live ? (fp ? context.t('Check in via fingerprint machine at gate') : context.t('Show check-in QR')) : context.t('Renew membership')),
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
