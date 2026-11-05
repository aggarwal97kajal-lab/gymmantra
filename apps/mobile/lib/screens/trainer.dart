import 'package:flutter/material.dart';
import '../haptics.dart';
import '../back.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../photo.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'home.dart' show openUrl;
import 'pt.dart';
import 'billing.dart' show AdsStrip;

class TrainerShell extends StatelessWidget {
  const TrainerShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;
  static const tabs = ['/t/home', '/t/clients', '/t/profile'];
  @override
  Widget build(BuildContext context) {
    final i = tabs.indexWhere((t) => location.startsWith(t));
    return ShellBack(
      location: location,
      home: '/t/home',
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
            NavigationDestination(icon: const Icon(Icons.groups_outlined), selectedIcon: const Icon(Icons.groups_rounded), label: context.t('Clients')),
            NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: context.t('Profile')),
          ],
        ),
      ),
    ),
    );
  }
}

class TrainerHomeScreen extends ConsumerWidget {
  const TrainerHomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final u = s.user ?? {};
    final v = ref.watch(trainerHomeProvider);
    final first = ((u['name'] as String?) ?? '').split(' ').first;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: context.c.primary,
          onRefresh: () async {
            ref.invalidate(trainerHomeProvider);
            ref.invalidate(trainerClientsProvider);
            ref.invalidate(trainerPayoutsProvider);
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 24), children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(context.t('Hi {name} 💪', {'name': first}), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                  Muted(context.t('Trainer'), size: 13.5),
                ]),
              ),
              Material(
                color: context.c.surf,
                shape: CircleBorder(side: BorderSide(color: context.c.line)),
                child: InkWell(customBorder: const CircleBorder(), onTap: () => context.push('/notifications'), child: const SizedBox(width: 42, height: 42, child: Icon(Icons.notifications_none_rounded))),
              ),
              const SizedBox(width: 10),
              GestureDetector(onTap: () => context.go('/t/profile'), child: Avatar(name: (u['name'] as String?) ?? '', url: u['photoUrl'] as String?, size: 42)),
            ]),
            const SizedBox(height: 16),
            const AdsStrip(role: 'TRAINER'),
            AsyncBody(
              value: v,
              onRetry: () => ref.invalidate(trainerHomeProvider),
              loading: const ListSkeleton(first: 110),
              builder: (d) {
                final gyms = (d['gyms'] as List).cast<Map>();
                if (gyms.isEmpty) return _NoGymCard(pending: ((d['pending'] as List?) ?? const []).cast<Map>());
                final clients = ((ref.watch(trainerClientsProvider).valueOrNull?['clients'] as List?) ?? const []).cast<Map>();
                final active = clients.where((c) => c['state'] == 'ACTIVE').toList();
                final pendingPt = clients.where((c) => c['state'] == 'PENDING').toList();
                final today = todayYmd();
                final todays = active.where((c) => (c['log'] as Map?)?[today] != null).toList();
                final soon = active.where((c) => c['endingSoon'] == true).length;
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final g in gyms) ...[
                    for (final n in ((g['notices'] as List?) ?? const []).cast<Map>())
                      NoticeBanner(title: n['title'] as String, message: n['message'] as String, gym: g['name'] as String?, date: n['createdAt'] as String?),
                    for (final o in (g['offers'] as List).cast<Map>())
                      OfferBanner(title: o['title'] as String, details: o['details'] as String?, who: context.t('Only for trainers'), validTill: o['validTill'] as String?, imageUrl: o['imageUrl'] as String?),
                    Panel(
                      onTap: () => context.push('/t/my-attendance'),
                      child: Row(children: [
                        const IconTile(Icons.event_available_rounded, color: C.ok),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(context.t('My attendance'), style: const TextStyle(fontWeight: FontWeight.w800)),
                            Muted(context.t('Mark Present at the gym every day'), size: 12),
                          ]),
                        ),
                        Icon(Icons.chevron_right_rounded, color: context.c.mut),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(onPressed: () => context.push('/checkin'), icon: const Icon(Icons.qr_code_scanner_rounded, size: 18), label: Text(context.t('Scan the gate QR'))),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(child: StatTile(icon: Icons.groups_rounded, value: '${active.length}', label: context.t('PT clients'))),
                      const SizedBox(width: 9),
                      Expanded(child: StatTile(icon: Icons.event_available_rounded, value: '${todays.length}', label: context.t('Sessions today'), color: C.ok)),
                      const SizedBox(width: 9),
                      Expanded(child: StatTile(icon: Icons.schedule_rounded, value: '$soon', label: context.t('Ending soon'), color: C.warn)),
                    ]),
                    for (final p in pendingPt) ...[
                      const SizedBox(height: 10),
                      Material(
                        color: context.c.surf,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: C.warn, width: 1.5)),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            const IconTile(Icons.notifications_active_rounded, color: C.warn),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(context.t('{name} asked for PT', {'name': p['memberName']}), style: const TextStyle(fontWeight: FontWeight.w800)),
                                Muted(context.t('Waiting for owner approval'), size: 12),
                              ]),
                            ),
                          ]),
                        ),
                      ),
                    ],
                    if (active.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      SectionTitle(context.t('My clients'), trailing: TextButton(onPressed: () => context.go('/t/clients'), child: Text(context.t('See all')))),
                      for (final c in (todays.isNotEmpty ? todays : active).take(4))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: PtClientRow(pt: c, onTap: () => context.push('/pt-client', extra: {'pt': c, 'tenantId': g['id'], 'canMark': true})),
                        ),
                    ],
                    const SizedBox(height: 4),
                    const TrainerPayoutsCard(),
                    const SizedBox(height: 12),
                    _GymCard(g: g),
                    const SizedBox(height: 12),
                    _PackagesCard(profile: g['profile'] as Map),
                  ],
                ]);
              },
            ),
          ]),
        ),
      ),
    );
  }
}

/// Trainer who is not at a gym yet: join with the gym code, or wait for the owner.
class _NoGymCard extends ConsumerWidget {
  const _NoGymCard({required this.pending});
  final List<Map> pending;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = pending.isNotEmpty || ref.watch(sessionProvider).mode == 'waiting';
    final gymName = pending.isNotEmpty ? pending.first['name'] as String : context.t('your gym');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            colors: waiting ? const [Color(0xFFFBBF24), C.warn] : const [C.orangeSoft, C.orange, C.orangeDeep],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(waiting ? Icons.hourglass_top_rounded : Icons.storefront_rounded, color: Colors.white, size: 32),
          const SizedBox(height: 10),
          Text(
            waiting ? context.t('Waiting for the owner’s approval') : context.t('Join your gym'),
            style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            waiting
                ? context.t('Your request went to {gym}. Your clients show here as soon as the owner approves.', {'gym': gymName})
                : context.t('Enter your gym code to send a join request. The owner approves it, then your clients show here.'),
            style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 13.5, height: 1.35),
          ),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: waiting ? const Color(0xFFB45309) : C.orangeDeep),
            onPressed: waiting
                ? () async {
                    await ref.read(sessionProvider).refreshUser();
                    ref.invalidate(trainerHomeProvider);
                  }
                : () => context.push('/trainer-join'),
            child: Text(waiting ? context.t('Check again') : context.t('Join with gym code')),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: StatTile(icon: Icons.groups_rounded, value: '0', label: context.t('PT clients'))),
        const SizedBox(width: 9),
        Expanded(child: StatTile(icon: Icons.event_available_rounded, value: '0', label: context.t('Sessions today'), color: C.ok)),
        const SizedBox(width: 9),
        Expanded(child: StatTile(icon: Icons.schedule_rounded, value: '0', label: context.t('Ending soon'), color: C.warn)),
      ]),
      const SizedBox(height: 14),
      Panel(
        onTap: () => context.go('/t/profile'),
        child: Row(children: [
          const IconTile(Icons.person_rounded, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('Complete your profile'), style: const TextStyle(fontWeight: FontWeight.w800)),
              Muted(context.t('Photo and mobile number help the owner and members know you'), size: 12),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: context.c.mut),
        ]),
      ),
      if (waiting) ...[
        const SizedBox(height: 10),
        TextButton(onPressed: () => context.push('/trainer-join'), child: Text(context.t('Join a different gym'))),
      ],
    ]);
  }
}

class _GymCard extends StatelessWidget {
  const _GymCard({required this.g});
  final Map g;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [C.orangeSoft, C.orange, C.orangeDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Row(children: [
          GymLogo(name: g['name'] as String, url: g['logoUrl'] as String?, size: 46, onColor: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text([context.t('My gym'), g['code']].where((x) => x != null).join(' · '), style: const TextStyle(color: Color(0xDDFFFFFF), fontSize: 12, fontWeight: FontWeight.w600)),
              Text(g['name'] as String, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            ]),
          ),
          if (g['phone'] != null)
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: C.orangeDeep),
              onPressed: () => openUrl('tel:${g['phone']}'),
              icon: const Icon(Icons.call_rounded),
            ),
        ]),
      );
}

class _PackagesCard extends StatelessWidget {
  const _PackagesCard({required this.profile});
  final Map profile;
  @override
  Widget build(BuildContext context) {
    final pkgs = (profile['packages'] as List).cast<Map>();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconTile(Icons.sell_rounded, size: 36),
          const SizedBox(width: 10),
          Expanded(child: Text(context.t('My PT packages'), style: const TextStyle(fontWeight: FontWeight.w800))),
          Text(profile['visible'] == true ? context.t('Visible to members') : context.t('Hidden'), style: TextStyle(color: profile['visible'] == true ? C.ok : context.c.mut, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 10),
        if (pkgs.isEmpty) Muted(context.t('The owner has not set your PT price yet.'), size: 12.5),
        for (final p in pkgs)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Expanded(child: Text(context.t('{n} sessions', {'n': p['sessions']}), style: const TextStyle(fontWeight: FontWeight.w700))),
              Muted(context.t('{n} days', {'n': p['days']}), size: 12),
              const SizedBox(width: 10),
              Text(rupees(p['price'] as num?), style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w800)),
            ]),
          ),
        const SizedBox(height: 8),
        Muted(context.t('Prices are set by the gym owner.'), size: 11.5),
      ]),
    );
  }
}

class TrainerClientsScreen extends StatelessWidget {
  const TrainerClientsScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('My PT clients'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.groups_rounded, size: 60, color: context.c.mut),
              const SizedBox(height: 12),
              Text(context.t('No PT clients yet'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Muted(context.t('When a member takes PT with you and the owner approves, they show here with sessions left and the calendar.'), align: TextAlign.center),
            ]),
          ),
        ),
      );
}

/// Trainer edits what members see about them.
class TrainerAboutScreen extends ConsumerStatefulWidget {
  const TrainerAboutScreen({super.key});
  @override
  ConsumerState<TrainerAboutScreen> createState() => _TrainerAboutState();
}

class _TrainerAboutState extends ConsumerState<TrainerAboutScreen> {
  final speciality = TextEditingController();
  final years = TextEditingController();
  final bio = TextEditingController();
  final hours = TextEditingController();
  bool loaded = false;
  bool busy = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(trainerHomeProvider);
    final gyms = (v.valueOrNull?['gyms'] as List?)?.cast<Map>() ?? const [];
    if (!loaded && gyms.isNotEmpty) {
      final p = gyms.first['profile'] as Map;
      speciality.text = p['speciality'] as String? ?? '';
      years.text = p['experienceYears']?.toString() ?? '';
      bio.text = p['bio'] as String? ?? '';
      hours.text = p['hours'] as String? ?? '';
      loaded = true;
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t('About me'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Muted(context.t('Members see this when they look at trainers.'), size: 12.5),
        const SizedBox(height: 12),
        TextField(controller: speciality, decoration: InputDecoration(labelText: context.t('Speciality'))),
        const SizedBox(height: 12),
        TextField(controller: years, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Experience (years)'))),
        const SizedBox(height: 12),
        TextField(controller: hours, decoration: InputDecoration(labelText: context.t('Timing'), hintText: '6–11 am, 5–9 pm')),
        const SizedBox(height: 12),
        TextField(controller: bio, maxLines: 4, decoration: InputDecoration(labelText: context.t('About you'), alignLabelWithHint: true, hintText: context.t('Certifications, results, languages'))),
        ErrorText(error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy || gyms.isEmpty
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  final saved = context.t('Saved');
                  try {
                    await Api.instance.patch('/trainer/profile', {
                      'speciality': speciality.text.trim(),
                      if (int.tryParse(years.text.trim()) != null) 'experienceYears': int.parse(years.text.trim()),
                      'bio': bio.text.trim(),
                      'hours': hours.text.trim(),
                    });
                    ref.invalidate(trainerHomeProvider);
                    if (context.mounted) {
                      toast(context, saved);
                      context.pop();
                    }
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Save')),
        ),
      ]),
    );
  }
}
