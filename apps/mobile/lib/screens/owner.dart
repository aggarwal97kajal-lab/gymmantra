import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../haptics.dart';
import '../back.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../photo.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'home.dart' show openUrl, waLink;
import 'pt.dart';
import 'billing.dart';
import 'auth.dart' show PhoneField;
import 'dues.dart';
import 'banner.dart';

// ============================================================ shell

class OwnerShell extends ConsumerWidget {
  const OwnerShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;
  static const tabs = ['/o/home', '/o/members', '/o/requests', '/o/offers', '/o/more'];
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i = tabs.indexWhere((t) => location.startsWith(t));
    final dash = ref.watch(dashboardProvider).valueOrNull;
    final pending = ((dash?['joinPending'] as int?) ?? 0) + ((dash?['ptPending'] as int?) ?? 0) + ((ref.watch(leadsProvider).valueOrNull as List?)?.length ?? 0);
    return ShellBack(
      location: location,
      home: '/o/home',
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
            NavigationDestination(icon: const Icon(Icons.groups_outlined), selectedIcon: const Icon(Icons.groups_rounded), label: context.t('Members')),
            NavigationDestination(
              icon: Badge(isLabelVisible: pending > 0, label: Text('$pending'), child: const Icon(Icons.how_to_reg_outlined)),
              selectedIcon: const Icon(Icons.how_to_reg_rounded),
              label: context.t('Requests'),
            ),
            NavigationDestination(icon: const Icon(Icons.local_offer_outlined), selectedIcon: const Icon(Icons.local_offer_rounded), label: context.t('Offers')),
            NavigationDestination(icon: const Icon(Icons.more_horiz_rounded), label: context.t('More')),
          ],
        ),
      ),
    ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap, this.dot = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool dot;
  @override
  Widget build(BuildContext context) => Material(
        color: context.c.surf,
        shape: CircleBorder(side: BorderSide(color: context.c.line)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 42, height: 42, child: Badge(isLabelVisible: dot, smallSize: 8, child: Icon(icon, size: 22))),
        ),
      );
}

String shareGymText(BuildContext context, String gymName, String code) =>
    context.t('Join {gym} on the GymMantra app. Gym code: {code}', {'gym': gymName, 'code': code});

// ============================================================ home

class OwnerHomeScreen extends ConsumerWidget {
  const OwnerHomeScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final gym = s.myGym ?? {};
    final d = ref.watch(dashboardProvider);
    final u = s.user ?? {};
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: context.c.primary,
          onRefresh: () async {
            ref.invalidate(dashboardProvider);
            ref.invalidate(duesProvider);
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 24), children: [
            Row(children: [
              GestureDetector(onTap: () => context.push('/o/subscription'), child: const OwnerAvatar(size: 46)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((gym['name'] as String?) ?? 'GymMantra', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  Muted('${context.t(gym['role'] == 'FRONT_DESK' ? 'Front desk' : 'Owner')} · ${gym['gymCode'] ?? ''}', size: 12.5),
                ]),
              ),
              _RoundIcon(icon: Icons.notifications_none_rounded, onTap: () => context.push('/notifications')),
            ]),
            const SizedBox(height: 16),
            const _PlanStrip(),
            const AdsStrip(role: 'OWNER'),
            AsyncBody(
              value: d,
              onRetry: () => ref.invalidate(dashboardProvider),
              loading: const ListSkeleton(first: 74, rows: 5),
              builder: (data) {
                final t = data['totals'] as Map;
                final today = data['today'] as Map;
                final pending = (data['joinPending'] as int? ?? 0) + (data['ptPending'] as int? ?? 0);
                final due = (data['renewalsDue'] as List).cast<Map>();
                return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: StatTile(icon: Icons.login_rounded, value: '${today['checkins'] ?? 0}', label: context.t('Check-ins today'))),
                    const SizedBox(width: 10),
                    Expanded(child: StatTile(icon: Icons.currency_rupee_rounded, value: rupees(today['collected'] as num?), label: context.t('Collected today'), color: C.ok)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: StatTile(icon: Icons.groups_rounded, value: '${t['active'] ?? 0}', label: context.t('Active members'))),
                    const SizedBox(width: 10),
                    Expanded(child: StatTile(icon: Icons.schedule_rounded, value: '${t['endingSoon'] ?? 0}', label: context.t('Ending in 7 days'), color: C.warn)),
                  ]),
                  const DueCard(),
                  if (pending > 0) ...[
                    const SizedBox(height: 12),
                    Material(
                      color: context.c.surf,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: context.c.primary, width: 1.5)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () => context.go('/o/requests'),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(children: [
                            const IconTile(Icons.how_to_reg_rounded),
                            const SizedBox(width: 12),
                            Expanded(child: Text(context.t('{n} requests waiting', {'n': pending}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              decoration: BoxDecoration(color: context.c.primary, borderRadius: BorderRadius.circular(11)),
                              child: Text(context.t('See'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  _GymCodeCard(name: (gym['name'] as String?) ?? '', code: (gym['gymCode'] as String?) ?? ''),
                  const SizedBox(height: 14),
                  SectionTitle(context.t('Quick actions')),
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 2.6,
                    children: [
                      _Quick(Icons.person_add_alt_1_rounded, context.t('Add member'), () => context.push('/o/members/new')),
                      _Quick(Icons.local_offer_rounded, context.t('Create offer'), () async {
                        if (await checkUnlocked(context, ref, 'offers') && context.mounted) context.push('/o/offers/new');
                      }),
                      _Quick(Icons.sports_rounded, context.t('Trainers'), () async {
                        if (await checkUnlocked(context, ref, 'pt') && context.mounted) context.push('/o/trainers');
                      }),
                      _Quick(Icons.campaign_rounded, context.t('Send notice'), () => context.push('/o/notices/new')),
                    ],
                  ),
                  if (due.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SectionTitle(context.t('Renewals due')),
                    Panel(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        for (final m in due.take(6))
                          ListTile(
                            onTap: () => context.push('/o/member/${m['id']}'),
                            leading: Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 40),
                            title: Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(
                              (m['daysLeft'] as int? ?? 0) >= 0 ? context.t('{n} days left', {'n': m['daysLeft']}) : context.t('Ended {date}', {'date': fmtDate(m['endsOn'] as String?)}),
                              style: TextStyle(color: context.c.mut, fontSize: 12),
                            ),
                            trailing: IconButton(icon: const Icon(Icons.call_rounded, color: C.ok), onPressed: () => openUrl('tel:${m['phone']}')),
                          ),
                      ]),
                    ),
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

class _Quick extends StatelessWidget {
  const _Quick(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Panel(
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [IconTile(icon, size: 34), const SizedBox(width: 10), Expanded(child: Text(label, maxLines: 2, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)))]),
      );
}

class _GymCodeCard extends StatelessWidget {
  const _GymCodeCard({required this.name, required this.code});
  final String name;
  final String code;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(colors: [C.orangeSoft, C.orange, C.orangeDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: Column(children: [
          Text(context.t('Gym code — give it to members and trainers'), textAlign: TextAlign.center, style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 12.5, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(code, style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w800, letterSpacing: 5)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: C.orangeDeep, minimumSize: const Size.fromHeight(44)),
                onPressed: () => context.push('/o/gym-qr?share=1'),
                icon: const Icon(Icons.share_rounded, size: 18),
                label: Text(context.t('Share on WhatsApp')),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 44,
              height: 44,
              child: Material(
                color: Colors.white.withAlpha(56),
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => context.push('/o/gym-qr'),
                  child: const Icon(Icons.qr_code_2_rounded, color: Colors.white, size: 21),
                ),
              ),
            ),
          ]),
        ]),
      );
}

// ============================================================ members

class OwnerMembersScreen extends ConsumerStatefulWidget {
  const OwnerMembersScreen({super.key});
  @override
  ConsumerState<OwnerMembersScreen> createState() => _OwnerMembersState();
}

class _OwnerMembersState extends ConsumerState<OwnerMembersScreen> {
  String q = '';
  String tab = 'all';

  bool inTab(Map m) => switch (tab) {
        'active' => m['status'] == 'ACTIVE',
        'ending' => m['status'] == 'ENDING_SOON',
        'expired' => m['status'] == 'EXPIRED',
        'due' => (m['due'] as num? ?? 0) > 0,
        _ => true,
      };

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(ownerMembersProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Members'))),
      floatingActionButton: FloatingActionButton(
        backgroundColor: context.c.primary,
        foregroundColor: Colors.white,
        onPressed: () async {
          await context.push('/o/members/new');
          ref.invalidate(ownerMembersProvider);
        },
        child: const Icon(Icons.person_add_alt_1_rounded),
      ),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(ownerMembersProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(ownerMembersProvider),
          builder: (d) {
            final all = (d['rows'] as List).cast<Map>();
            // Load photos and the first members' pages in the background, so tapping opens at once.
            PhotoCache.warm(all.map((m) => m['photoUrl'] as String?));
            Api.instance.prefetchSome([for (final m in all.take(30)) '/members/${m['id']}']);
            final needle = q.trim().toLowerCase();
            final rows = all.where((m) => inTab(m) && (needle.isEmpty || '${m['name']} ${m['phone']} ${m['memberCode']}'.toLowerCase().contains(needle))).toList();
            int count(String t) => all.where((m) {
                  final save = tab;
                  tab = t;
                  final r = inTab(m);
                  tab = save;
                  return r;
                }).length;
            Widget chip(String key, String label) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('$label (${count(key)})'),
                    selected: tab == key,
                    showCheckmark: false,
                    selectedColor: context.c.primary,
                    labelStyle: TextStyle(color: tab == key ? Colors.white : context.c.fg, fontWeight: FontWeight.w700, fontSize: 12.5),
                    onSelected: (_) => setState(() => tab = key),
                  ),
                );
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
              TextField(
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Search by name or mobile')),
                onChanged: (t) => setState(() => q = t),
              ),
              const SizedBox(height: 10),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  chip('all', context.t('All')),
                  chip('active', context.t('Active')),
                  chip('ending', context.t('Ending soon')),
                  chip('expired', context.t('Expired')),
                  chip('due', context.t('Due')),
                ]),
              ),
              const SizedBox(height: 8),
              if (rows.isEmpty) Padding(padding: const EdgeInsets.all(30), child: Muted(context.t('No members here.'), align: TextAlign.center)),
              if (rows.isNotEmpty)
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    for (final m in rows)
                      ListTile(
                        onTap: () => context.push('/o/member/${m['id']}'),
                        leading: Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 42),
                        title: Text(m['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          [
                            m['memberCode'],
                            m['planName'],
                            if ((m['due'] as num? ?? 0) > 0) context.t('Due {due} · paid {paid} of {total}', {'due': rupees(m['due'] as num?), 'paid': rupees(m['duePaid'] as num?), 'total': rupees(m['dueTotal'] as num?)}),
                          ].where((x) => x != null).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: context.c.mut, fontSize: 12),
                        ),
                        trailing: StatusChip(m['status'] as String),
                      ),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class AddMemberScreen extends ConsumerStatefulWidget {
  const AddMemberScreen({super.key});
  @override
  ConsumerState<AddMemberScreen> createState() => _AddMemberState();
}

class _AddMemberState extends ConsumerState<AddMemberScreen> {
  final name = TextEditingController();
  final phone = TextEditingController();
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Add member'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: context.t('Full name'))),
        const SizedBox(height: 14),
        PhoneField(label: context.t('Mobile number'), controller: phone, bottom: 6),
        Muted(context.t('If this person already uses the GymMantra app with this number, they get linked automatically.'), size: 12),
        ErrorText(error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    final m = await Api.instance.post('/members', {'name': name.text.trim(), 'phone': phone.text.trim()});
                    ref.invalidate(ownerMembersProvider);
                    if (context.mounted) context.pushReplacement('/o/member/${m['id']}');
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

class OwnerMemberScreen extends ConsumerWidget {
  const OwnerMemberScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(ownerMemberProvider(id));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Member'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(ownerMemberProvider(id)),
        builder: (d) {
          final m = d['member'] as Map;
          final st = d['state'] as Map;
          final history = (d['history'] as List).cast<Map>();
          final cur = history.where((h) => h['id'] == st['currentId']).firstOrNull ?? (history.isEmpty ? null : history.first);
          final status = st['status'] as String;
          final due = st['due'] as num? ?? 0;
          final entry = st['entry'] as Map?;
          final owing = history.where((h) => h['superseded'] != true && ((h['due'] as num?) ?? 0) > 0).toList()
            ..sort((a, b) => ((a['startDate'] as String?) ?? '').compareTo((b['startDate'] as String?) ?? ''));
          Future<void> pay(Map h) async {
            if (await showPaymentSheet(context, h)) {
              ref.invalidate(ownerMemberProvider(id));
              ref.invalidate(ownerMembersProvider);
              ref.invalidate(dashboardProvider);
              ref.invalidate(duesProvider);
            }
          }

          return RefreshIndicator(
            color: context.c.primary,
            onRefresh: () async => ref.invalidate(ownerMemberProvider(id)),
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Center(child: Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 92, ring: true)),
              const SizedBox(height: 10),
              Center(child: Text(m['name'] as String, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
              Center(child: Muted('${m['memberCode']} · ${m['phone']}')),
              const SizedBox(height: 8),
              Center(child: StatusChip(status)),
              const SizedBox(height: 10),
              Center(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MemberProfileScreen(data: d as Map))),
                  icon: const Icon(Icons.badge_outlined, size: 18),
                  label: Text(context.t('Full profile')),
                ),
              ),
              const SizedBox(height: 16),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text((cur?['planName'] as String?) ?? context.t('No plan yet'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                  if (st['endsOn'] != null) Muted(context.t('Ends {date}', {'date': fmtDate(st['endsOn'] as String?)})),
                  if (st['daysLeft'] != null && (st['daysLeft'] as int) >= 0) Muted(context.t('{n} days left', {'n': st['daysLeft']})),
                  if (due <= 0 && history.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      const Icon(Icons.check_circle_rounded, size: 17, color: C.ok),
                      const SizedBox(width: 6),
                      Expanded(child: Text(context.t('Nothing due'), style: const TextStyle(color: C.ok, fontWeight: FontWeight.w700, fontSize: 13))),
                    ]),
                  ],
                  for (final h in owing) OwingBox(sub: h, current: h['id'] == st['currentId'] || h['id'] == st['upcomingId'], onPay: () => pay(h)),
                  if (entry != null) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(entry['result'] == 'BLOCKED' ? Icons.block_rounded : Icons.check_circle_rounded, size: 18, color: entry['result'] == 'BLOCKED' ? C.red : C.ok),
                      const SizedBox(width: 6),
                      Expanded(child: Muted(entry['result'] == 'BLOCKED' ? '${context.t('Entry blocked')}: ${entry['reason'] ?? ''}' : context.t('Entry allowed'), size: 12.5)),
                    ]),
                  ],
                ]),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: () => openUrl('tel:${m['phone']}'), icon: const Icon(Icons.call_rounded), label: Text(context.t('Call')))),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: C.wa),
                    onPressed: () => openUrl(waLink(m['phone'] as String, 'Hi ${m['name']},')),
                    icon: const Icon(Icons.chat_rounded),
                    label: const Text('WhatsApp'),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () async {
                  final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _RenewSheet(memberId: id));
                  if (ok == true) {
                    ref.invalidate(ownerMemberProvider(id));
                    ref.invalidate(ownerMembersProvider);
                    ref.invalidate(dashboardProvider);
                    ref.invalidate(duesProvider);
                  }
                },
                icon: const Icon(Icons.autorenew_rounded),
                label: Text(history.isEmpty ? context.t('Start membership') : context.t('Renew membership')),
              ),
              if (history.isNotEmpty) ...[
                const SizedBox(height: 18),
                SectionTitle(context.t('History')),
                for (final h in history)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(h['planName'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Muted('${fmtDate(h['startDate'] as String?)} – ${fmtDate(h['endDate'] as String?)}', size: 12),
                          ]),
                        ),
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(rupees(h['total'] as num?), style: const TextStyle(fontWeight: FontWeight.w800)),
                          if (h['superseded'] == true)
                            Muted(context.t('Corrected'), size: 11.5)
                          else if (((h['due'] as num?) ?? 0) > 0)
                            Text(context.t('{amount} due', {'amount': rupees(h['due'] as num?)}), style: const TextStyle(color: C.red, fontWeight: FontWeight.w700, fontSize: 11.5))
                          else
                            Text('${context.t('Paid')} ${rupees(h['paid'] as num?)} ✓', style: const TextStyle(color: C.ok, fontWeight: FontWeight.w700, fontSize: 11.5)),
                        ]),
                      ]),
                    ),
                  ),
              ],
            ]),
          );
        },
      ),
    );
  }
}

final _plansProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/plans'));

class _RenewSheet extends ConsumerStatefulWidget {
  const _RenewSheet({required this.memberId});
  final String memberId;
  @override
  ConsumerState<_RenewSheet> createState() => _RenewSheetState();
}

class _RenewSheetState extends ConsumerState<_RenewSheet> {
  String? planId;
  String mode = 'CASH';
  final amount = TextEditingController();
  bool busy = false;
  String? error;
  static const modes = [('CASH', 'Cash'), ('UPI', 'UPI'), ('CARD', 'Card'), ('NOT_PAID', 'Not paid yet')];

  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(_plansProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: AsyncBody(
        value: plans,
        loading: const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        builder: (d) {
          final list = (d as List).cast<Map>().where((p) => p['active'] != false).toList();
          final plan = list.where((p) => p['id'] == planId).firstOrNull;
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('Membership'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            if (list.isEmpty) Muted(context.t('Create membership plans on the website first.')),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in list)
                ChoiceChip(
                  label: Text('${p['name']} · ${rupees(p['price'] as num?)}'),
                  selected: planId == p['id'],
                  showCheckmark: false,
                  selectedColor: context.c.primary,
                  labelStyle: TextStyle(color: planId == p['id'] ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                  onSelected: (_) => setState(() {
                    planId = p['id'] as String;
                    amount.text = '${p['price']}';
                  }),
                ),
            ]),
            const SizedBox(height: 14),
            Muted(context.t('Payment'), size: 12.5),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (k, l) in modes)
                ChoiceChip(
                  label: Text(context.t(l)),
                  selected: mode == k,
                  showCheckmark: false,
                  selectedColor: context.c.primary,
                  labelStyle: TextStyle(color: mode == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                  onSelected: (_) => setState(() => mode = k),
                ),
            ]),
            if (mode != 'NOT_PAID') ...[
              const SizedBox(height: 12),
              TextField(controller: amount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Amount received'), prefixText: '₹ ')),
            ],
            if (plan != null && (plan['joiningFee'] as num? ?? 0) > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Muted(context.t('+ {fee} joining fee for new members', {'fee': rupees(plan['joiningFee'] as num?)}), size: 12)),
            ErrorText(error),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: busy || planId == null
                  ? null
                  : () async {
                      setState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        await Api.instance.post('/members/${widget.memberId}/memberships', {
                          'planId': planId,
                          'paymentMode': mode,
                          if (mode != 'NOT_PAID' && int.tryParse(amount.text.trim()) != null) 'amountReceived': int.parse(amount.text.trim()),
                        });
                        if (context.mounted) Navigator.pop(context, true);
                      } catch (e) {
                        setState(() => error = e.toString());
                      } finally {
                        if (mounted) setState(() => busy = false);
                      }
                    },
              child: Text(context.t('Save')),
            ),
          ]);
        },
      ),
    );
  }
}

// ============================================================ requests

class OwnerRequestsScreen extends ConsumerStatefulWidget {
  const OwnerRequestsScreen({super.key});
  @override
  ConsumerState<OwnerRequestsScreen> createState() => _OwnerRequestsState();
}

class _OwnerRequestsState extends ConsumerState<OwnerRequestsScreen> {
  final busy = <String>{};

  Future<void> act(String id, bool approve) async {
    setState(() => busy.add(id));
    final done = context.t(approve ? 'Approved' : 'Declined');
    try {
      await Api.instance.post('/join-requests/$id/${approve ? 'approve' : 'decline'}', {});
      ref.invalidate(joinRequestsProvider);
      ref.invalidate(dashboardProvider);
      ref.invalidate(ownerMembersProvider);
      ref.invalidate(trainersProvider);
      if (mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  int tab = 0;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(joinRequestsProvider);
    final dash = ref.watch(dashboardProvider).valueOrNull;
    final joinN = (dash?['joinPending'] as int?) ?? 0;
    final ptN = (dash?['ptPending'] as int?) ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('Requests')),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(58),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Seg<int>(
              value: tab,
              items: [
                (0, '${context.t('Join')} ($joinN)', null),
                (1, 'PT ($ptN)', null),
                (2, '${context.t('Plans')} (${((ref.watch(leadsProvider).valueOrNull as List?) ?? const []).length})', null),
              ],
              onChanged: (v) => setState(() => tab = v),
            ),
          ),
        ),
      ),
      body: tab == 2
          ? RefreshIndicator(
              color: context.c.primary,
              onRefresh: () async => ref.invalidate(leadsProvider),
              child: const LeadsList(),
            )
          : tab == 1
          ? RefreshIndicator(
              color: context.c.primary,
              onRefresh: () async => ref.invalidate(ownerPtProvider('PENDING')),
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: const [OwnerPtRequests()]),
            )
          : RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(joinRequestsProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(joinRequestsProvider),
          builder: (d) {
            final list = (d as List).cast<Map>();
            if (list.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 110),
                Icon(Icons.how_to_reg_outlined, size: 56, color: context.c.mut),
                const SizedBox(height: 10),
                Muted(context.t('No requests right now.'), align: TextAlign.center, size: 14),
                const SizedBox(height: 4),
                Muted(context.t('Nobody joins your gym without your approval.'), align: TextAlign.center, size: 12),
              ]);
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Muted(context.t('Approve, and only then they join'), size: 13),
              const SizedBox(height: 8),
              for (final r in list) _RequestCard(r: r, busy: busy.contains(r['id']), onAct: (ok) => act(r['id'] as String, ok)),
            ]);
          },
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({required this.r, required this.busy, required this.onAct});
  final Map r;
  final bool busy;
  final ValueChanged<bool> onAct;
  @override
  Widget build(BuildContext context) {
    final u = r['user'] as Map;
    final trainer = r['kind'] == 'TRAINER';
    final line = trainer
        ? [r['speciality'], if (r['experienceYears'] != null) context.t('{n} years experience', {'n': r['experienceYears']})].where((x) => x != null).join(' · ')
        : [u['phone'], fmtDateTime(r['createdAt'] as String)].where((x) => x != null).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          Row(children: [
            Avatar(name: (u['name'] as String?) ?? '', url: u['photoUrl'] as String?, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((u['name'] as String?) ?? '', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Muted(line, size: 12),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: (trainer ? const Color(0xFF7C3AED) : context.c.primary).withAlpha(36), borderRadius: BorderRadius.circular(99)),
              child: Text(context.t(trainer ? 'Trainer' : 'Member'), style: TextStyle(color: trainer ? const Color(0xFF8B5CF6) : context.c.primary, fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: C.ok, minimumSize: const Size.fromHeight(42)),
                onPressed: busy ? null : () => onAct(true),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text(context.t('Approve')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                onPressed: busy ? null : () => onAct(false),
                child: Text(context.t('Decline')),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ============================================================ offers

String audienceLabel(BuildContext context, Map o) {
  final parts = <String>[];
  if (o['forMembers'] == true) {
    parts.add(switch (o['memberFilter']) {
      'ACTIVE' => context.t('Active members'),
      'EXPIRING' => context.t('Members ending soon'),
      'EXPIRED' => context.t('Expired members'),
      _ => context.t('All members'),
    });
  }
  if (o['forTrainers'] == true) parts.add(context.t('Trainers'));
  return parts.join(' + ');
}

class OwnerOffersScreen extends ConsumerStatefulWidget {
  const OwnerOffersScreen({super.key});
  @override
  ConsumerState<OwnerOffersScreen> createState() => _OwnerOffersState();
}

class _OwnerOffersState extends ConsumerState<OwnerOffersScreen> {
  /// Switch changes shown at once, before the server answers.
  final Map<String, bool> flips = {};
  final Set<String> gone = {};

  Future<void> toggle(Map o, bool on) async {
    final id = o['id'] as String;
    setState(() => flips[id] = on);
    TapHaptics.buzz();
    try {
      await Api.instance.patch('/offers/$id', {'active': on});
      ref.invalidate(offersProvider);
    } catch (e) {
      if (mounted) {
        setState(() => flips.remove(id));
        toast(context, e.toString());
      }
    }
  }

  Future<void> delete(Map o) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(context.t('Delete this offer?')),
        content: Text(context.t('It will be removed from every dashboard.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('Delete'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (yes != true) return;
    final id = o['id'] as String;
    setState(() => gone.add(id));
    try {
      await Api.instance.delete('/offers/$id');
      ref.invalidate(offersProvider);
    } catch (e) {
      if (mounted) {
        setState(() => gone.remove(id));
        toast(context, e.toString());
      }
    }
  }

  Future<void> banner(Map o) async {
    final bytes = await pickBanner(context);
    if (bytes == null) return;
    try {
      await Api.instance.post('/offers/${o['id']}/image', {'mime': 'image/jpeg', 'base64': base64Encode(bytes)});
      ref.invalidate(offersProvider);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(offersProvider);
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Offers'))),
      floatingActionButton: owner
          ? FloatingActionButton.extended(
              backgroundColor: context.c.primary,
              foregroundColor: Colors.white,
              onPressed: () async {
                if (!await checkUnlocked(context, ref, 'offers') || !context.mounted) return;
                await context.push('/o/offers/new');
                ref.invalidate(offersProvider);
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(context.t('New offer')),
            )
          : null,
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(offersProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(offersProvider),
          builder: (d) {
            final list = (d as List).cast<Map>().where((o) => !gone.contains(o['id'])).toList();
            if (list.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 110),
                Icon(Icons.local_offer_outlined, size: 56, color: context.c.mut),
                const SizedBox(height: 10),
                Muted(context.t('No offers yet. Create one — it shows on dashboards.'), align: TextAlign.center, size: 14),
              ]);
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
              for (final o in list)
                Builder(builder: (context) {
                  final active = flips[o['id']] ?? (o['active'] == true);
                  final live = active && ((o['validTill'] as String?) ?? '').compareTo(todayIst()) >= 0;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(children: [
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: live ? 1 : 0.5,
                        child: OfferBanner(title: o['title'] as String, details: o['details'] as String?, who: audienceLabel(context, o), validTill: o['validTill'] as String?, imageUrl: o['imageUrl'] as String?),
                      ),
                      if (owner)
                        Row(children: [
                          Expanded(child: Muted(live ? context.t('Showing now') : context.t('Not showing'), size: 12.5)),
                          IconButton(tooltip: context.t('Banner picture'), onPressed: () => banner(o), icon: Icon(Icons.image_outlined, color: context.c.mut)),
                          IconButton(tooltip: context.t('Delete'), onPressed: () => delete(o), icon: const Icon(Icons.delete_outline_rounded, color: C.red)),
                          Switch(value: active, activeTrackColor: context.c.primary, onChanged: (on) => toggle(o, on)),
                        ]),
                    ]),
                  );
                }),
            ]);
          },
        ),
      ),
    );
  }
}

String todayIst() {
  final n = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

class NewOfferScreen extends ConsumerStatefulWidget {
  const NewOfferScreen({super.key});
  @override
  ConsumerState<NewOfferScreen> createState() => _NewOfferState();
}

class _NewOfferState extends ConsumerState<NewOfferScreen> {
  final title = TextEditingController();
  final details = TextEditingController();
  DateTime till = DateTime.now().add(const Duration(days: 14));
  bool forMembers = true;
  bool forTrainers = false;
  String filter = 'ALL';
  bool busy = false;
  String? error;
  Uint8List? bannerBytes;

  String get ymd => '${till.year}-${till.month.toString().padLeft(2, '0')}-${till.day.toString().padLeft(2, '0')}';

  Widget pick(String label, bool on, VoidCallback tap) => Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: on,
          showCheckmark: true,
          checkmarkColor: Colors.white,
          selectedColor: context.c.primary,
          labelStyle: TextStyle(color: on ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
          onSelected: (_) => tap(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final preview = {'forMembers': forMembers, 'forTrainers': forTrainers, 'memberFilter': filter};
    return Scaffold(
      appBar: AppBar(title: Text(context.t('New offer'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: title, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: context.t('Offer name'), hintText: 'Diwali Dhamaka · 20% off'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        TextField(controller: details, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: context.t('Details (optional)'), hintText: context.t('Renew by 15 Nov')), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        Panel(
          onTap: () async {
            final d = await showDatePicker(context: context, initialDate: till, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
            if (d != null) setState(() => till = d);
          },
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const IconTile(Icons.event_rounded, size: 36),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Muted(context.t('Show till'), size: 12), Text(fmtDate(ymd), style: const TextStyle(fontWeight: FontWeight.w800))])),
            Icon(Icons.edit_calendar_rounded, color: context.c.mut),
          ]),
        ),
        const SizedBox(height: 16),
        Text(context.t('Who should see it?'), style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Wrap(children: [
          pick(context.t('Members'), forMembers, () => setState(() => forMembers = !forMembers)),
          pick(context.t('Trainers'), forTrainers, () => setState(() => forTrainers = !forTrainers)),
        ]),
        if (forMembers) ...[
          Muted(context.t('Which members?'), size: 12.5),
          const SizedBox(height: 6),
          Wrap(children: [
            pick(context.t('All members'), filter == 'ALL', () => setState(() => filter = 'ALL')),
            pick(context.t('Active members'), filter == 'ACTIVE', () => setState(() => filter = 'ACTIVE')),
            pick(context.t('Members ending soon'), filter == 'EXPIRING', () => setState(() => filter = 'EXPIRING')),
            pick(context.t('Expired members'), filter == 'EXPIRED', () => setState(() => filter = 'EXPIRED')),
          ]),
        ],
        const SizedBox(height: 12),
        Text(context.t('Banner picture (optional)'), style: const TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Muted(context.t('A wide picture (2:1) looks best. You see the live preview below.'), size: 12),
        const SizedBox(height: 8),
        BannerPickerBox(
          has: bannerBytes != null,
          onPick: () async {
            final b = await pickBanner(context);
            if (b != null) setState(() => bannerBytes = b);
          },
          onRemove: () => setState(() => bannerBytes = null),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: C.ok, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Muted(context.t('Live preview — this is how members see it'), size: 12.5),
        ]),
        const SizedBox(height: 6),
        OfferBanner(
          title: title.text.trim().isEmpty ? context.t('Your offer name') : title.text.trim(),
          details: details.text.trim(),
          who: audienceLabel(context, preview),
          validTill: ymd,
          local: bannerBytes,
        ),
        ErrorText(error),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    final o = await Api.instance.post('/offers', {
                      'title': title.text.trim(),
                      'details': details.text.trim(),
                      'validTill': ymd,
                      'forMembers': forMembers,
                      'forTrainers': forTrainers,
                      'memberFilter': filter,
                    });
                    if (bannerBytes != null) {
                      await Api.instance.post('/offers/${o['id']}/image', {'mime': 'image/jpeg', 'base64': base64Encode(bannerBytes!)});
                    }
                    if (context.mounted) context.pop();
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Run offer')),
        ),
      ]),
    );
  }
}

// ============================================================ more

class OwnerMoreScreen extends ConsumerWidget {
  const OwnerMoreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final u = s.user ?? {};
    final gym = s.myGym ?? {};
    final sub = ref.watch(subscriptionProvider).valueOrNull;
    Widget row(IconData icon, String title, VoidCallback onTap, {String? sub, String? lock}) {
      final locked = lock != null && !isUnlocked(ref, lock);
      return ListTile(
        leading: Opacity(opacity: locked ? 0.5 : 1, child: IconTile(icon, size: 36)),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: locked ? context.c.mut : null)),
        subtitle: sub == null ? null : Text(sub, style: TextStyle(color: context.c.mut, fontSize: 12)),
        trailing: locked ? LockChip(featurePlan[lock]!) : Icon(Icons.chevron_right_rounded, color: context.c.mut),
        onTap: () async {
          if (lock != null && !await checkUnlocked(context, ref, lock)) return;
          onTap();
        },
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t('More'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Panel(
          onTap: () => context.push('/o/profile'),
          child: Row(children: [
            const OwnerAvatar(size: 52),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((u['name'] as String?) ?? '', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Muted('${gym['name'] ?? ''} · ${context.t(gym['role'] == 'FRONT_DESK' ? 'Front desk' : 'Owner')}', size: 12.5),
              ]),
            ),
            Icon(Icons.chevron_right_rounded, color: context.c.mut),
          ]),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            if (gym['role'] == 'OWNER')
              row(
                Icons.workspace_premium_rounded,
                context.t('Subscription'),
                () => context.push('/o/subscription'),
                sub: sub == null
                    ? null
                    : sub['inTrial'] == true
                        ? context.t('Free trial · {n} days left', {'n': sub['trialDaysLeft']})
                        : sub['plan'] != null
                            ? context.t('{plan} plan', {'plan': sub['plan']['name']})
                            : context.t('Trial ended — choose a plan'),
              ),
            row(Icons.qr_code_2_rounded, context.t('Gym QR'), () => context.push('/o/gym-qr'), sub: context.t('Join QR to share · Check-in QR for the gym')),
            row(Icons.campaign_rounded, context.t('Notices'), () => context.push('/o/notices'), sub: context.t('Gym closed, timing change… to members or trainers')),
            row(Icons.sports_rounded, context.t('Trainers'), () => context.push('/o/trainers'), sub: context.t('PT packages and prices'), lock: 'pt'),
            row(Icons.groups_2_rounded, context.t('PT clients'), () => context.push('/o/pt'), sub: context.t('Sessions and calendar of every trainer'), lock: 'pt'),
            if (gym['role'] == 'OWNER') row(Icons.account_balance_wallet_rounded, context.t('PT accounts'), () => context.push('/o/pt-accounts'), sub: context.t('What each trainer gets'), lock: 'pt'),
            row(Icons.local_offer_rounded, context.t('Offers'), () => context.go('/o/offers'), lock: 'offers'),
            row(Icons.bar_chart_rounded, context.t('Reports'), () => context.push('/o/reports'), sub: context.t('Money, visits and plans'), lock: 'reports'),
            if (gym['role'] == 'OWNER') row(Icons.place_rounded, context.t('Gym address'), () => context.push('/o/address')),
            row(Icons.receipt_long_rounded, context.t('Membership plans'), () => context.push('/o/plans'), sub: context.t('Prices, freeze days, what is included')),
            row(Icons.settings_rounded, context.t('Gym settings · WhatsApp'), () => context.push('/o/settings'), sub: context.t('Name, numbers, branches, join poster')),
            row(Icons.language_rounded, context.t('Full panel on the website'), () => openUrl(Api.instance.base)),
          ]),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            row(Icons.person_rounded, context.t('Profile & settings'), () => context.push('/o/profile'), sub: context.t('Photo, theme, language')),
            row(Icons.notifications_none_rounded, context.t('Notifications'), () => context.push('/notifications')),
          ]),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: () => s.logout(), icon: const Icon(Icons.logout_rounded), label: Text(context.t('Log out'))),
      ]),
    );
  }
}

// ============================================================ trainers (owner)

class OwnerTrainersScreen extends ConsumerWidget {
  const OwnerTrainersScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(trainersProvider);
    final s = ref.watch(sessionProvider);
    final gym = s.myGym ?? {};
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Trainers'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(trainersProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(trainersProvider),
          builder: (d) {
            final list = (d as List).cast<Map>();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Muted(context.t('Trainers join with your gym code. You approve them in Requests and set their PT price here.'), size: 12.5),
              const SizedBox(height: 10),
              if (list.isEmpty)
                Panel(
                  child: Column(children: [
                    Icon(Icons.sports_rounded, size: 44, color: context.c.mut),
                    const SizedBox(height: 8),
                    Muted(context.t('No trainers yet.'), align: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => openUrl('https://wa.me/?text=${Uri.encodeComponent(shareGymText(context, (gym['name'] as String?) ?? '', (gym['gymCode'] as String?) ?? ''))}'),
                      icon: const Icon(Icons.share_rounded),
                      label: Text(context.t('Send gym code to trainers')),
                    ),
                  ]),
                ),
              for (final t in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Panel(
                    onTap: () => context.push('/o/trainer', extra: t),
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Avatar(name: t['name'] as String, url: t['photoUrl'] as String?, size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(t['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                            Muted([t['speciality'], if (t['experienceYears'] != null) context.t('{n} years', {'n': t['experienceYears']})].where((x) => x != null).join(' · '), size: 12),
                            Muted(context.t('Checked in {n} days this month', {'n': t['visitsThisMonth'] ?? 0}), size: 11.5),
                          ]),
                        ),
                        Switch(
                          value: t['visible'] == true,
                          activeTrackColor: context.c.primary,
                          onChanged: (on) async {
                            try {
                              await Api.instance.patch('/trainers/${t['id']}', {'visible': on});
                              ref.invalidate(trainersProvider);
                            } catch (e) {
                              if (context.mounted) toast(context, e.toString());
                            }
                          },
                        ),
                      ]),
                      const SizedBox(height: 8),
                      if ((t['packages'] as List).isEmpty)
                        Muted(context.t('No PT price yet — tap to set'), size: 12.5)
                      else
                        Wrap(spacing: 6, runSpacing: 6, children: [
                          for (final p in (t['packages'] as List).cast<Map>())
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(color: context.c.primary.withAlpha(30), borderRadius: BorderRadius.circular(99)),
                              child: Text('${rupees(p['price'] as num?)} · ${context.t('{n} sessions', {'n': p['sessions']})}', style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700, fontSize: 12)),
                            ),
                        ]),
                    ]),
                  ),
                ),
              if (list.isNotEmpty) Muted(context.t('Switch on = members see this trainer'), size: 12),
            ]);
          },
        ),
      ),
    );
  }
}

class _Pkg {
  _Pkg({this.id, int sessions = 12, int days = 30, int? perWeek = 3, int price = 0})
      : sessions = TextEditingController(text: '$sessions'),
        days = TextEditingController(text: '$days'),
        perWeek = TextEditingController(text: perWeek == null ? '' : '$perWeek'),
        price = TextEditingController(text: price == 0 ? '' : '$price');
  final String? id;
  final TextEditingController sessions, days, perWeek, price;
  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'sessions': int.tryParse(sessions.text.trim()) ?? 0,
        'days': int.tryParse(days.text.trim()) ?? 0,
        if (int.tryParse(perWeek.text.trim()) != null) 'perWeek': int.parse(perWeek.text.trim()),
        'price': int.tryParse(price.text.trim()) ?? 0,
      };
}

class OwnerTrainerScreen extends ConsumerStatefulWidget {
  const OwnerTrainerScreen({super.key, required this.trainer});
  final Map trainer;
  @override
  ConsumerState<OwnerTrainerScreen> createState() => _OwnerTrainerState();
}

class _OwnerTrainerState extends ConsumerState<OwnerTrainerScreen> {
  late final speciality = TextEditingController(text: widget.trainer['speciality'] as String? ?? '');
  late final years = TextEditingController(text: widget.trainer['experienceYears']?.toString() ?? '');
  late final share = TextEditingController(text: '${widget.trainer['sharePercent'] ?? 50}');
  late final List<_Pkg> pkgs = [
    for (final p in (widget.trainer['packages'] as List? ?? []).cast<Map>())
      _Pkg(id: p['id'] as String?, sessions: p['sessions'] as int, days: p['days'] as int, perWeek: p['perWeek'] as int?, price: p['price'] as int),
  ];
  bool busy = false;
  String? error;

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    final saved = context.t('Saved');
    try {
      await Api.instance.patch('/trainers/${widget.trainer['id']}', {
        'speciality': speciality.text.trim(),
        if (int.tryParse(years.text.trim()) != null) 'experienceYears': int.parse(years.text.trim()),
        'sharePercent': int.tryParse(share.text.trim()) ?? 50,
        'packages': pkgs.map((p) => p.toJson()).toList(),
      });
      ref.invalidate(trainersProvider);
      if (mounted) {
        toast(context, saved);
        context.pop();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t('Remove trainer?')),
        content: Text(context.t('{name} will no longer be a trainer at your gym.', {'name': widget.trainer['name']})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.t('Remove'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.post('/trainers/${widget.trainer['id']}/remove', {});
      ref.invalidate(trainersProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.trainer;
    Widget field(TextEditingController c, String label, {String? prefix}) => Expanded(
          child: TextField(controller: c, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: label, prefixText: prefix, isDense: true)),
        );
    return Scaffold(
      appBar: AppBar(title: Text(t['name'] as String)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Center(child: Avatar(name: t['name'] as String, url: t['photoUrl'] as String?, size: 84, ring: true)),
        const SizedBox(height: 8),
        if (t['phone'] != null) Center(child: TextButton.icon(onPressed: () => openUrl('tel:${t['phone']}'), icon: const Icon(Icons.call_rounded, size: 18), label: Text(t['phone'] as String))),
        const SizedBox(height: 8),
        TextField(controller: speciality, decoration: InputDecoration(labelText: context.t('Speciality'))),
        const SizedBox(height: 12),
        Row(children: [
          field(years, context.t('Experience (years)')),
          const SizedBox(width: 10),
          field(share, context.t('Trainer share %')),
        ]),
        const SizedBox(height: 4),
        Muted(context.t('Trainer share = the part of PT money you pay the trainer.'), size: 11.5),
        const SizedBox(height: 18),
        SectionTitle(context.t('PT packages')),
        for (final (i, p) in pkgs.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Panel(
              padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
              child: Row(children: [
                Expanded(
                  child: Column(children: [
                    Row(children: [field(p.sessions, context.t('Sessions')), const SizedBox(width: 8), field(p.price, context.t('Price'), prefix: '₹ ')]),
                    const SizedBox(height: 8),
                    Row(children: [field(p.days, context.t('Valid days')), const SizedBox(width: 8), field(p.perWeek, context.t('Days / week'))]),
                  ]),
                ),
                IconButton(onPressed: () => setState(() => pkgs.removeAt(i)), icon: const Icon(Icons.delete_outline_rounded, color: C.red)),
              ]),
            ),
          ),
        OutlinedButton.icon(onPressed: () => setState(() => pkgs.add(_Pkg())), icon: const Icon(Icons.add_rounded), label: Text(context.t('Add package'))),
        ErrorText(error),
        const SizedBox(height: 16),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save'))),
        const SizedBox(height: 8),
        TextButton(onPressed: remove, child: Text(context.t('Remove trainer'), style: const TextStyle(color: C.red))),
      ]),
    );
  }
}


/// Trial meter / plan line and the "complete your address" reminder on the owner home.
class _PlanStrip extends ConsumerWidget {
  const _PlanStrip();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = ref.watch(subscriptionProvider).valueOrNull;
    if (sub == null) return const SizedBox.shrink();
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    final items = <Widget>[];
    if (sub['inTrial'] == true) {
      final left = sub['trialDaysLeft'] as int? ?? 0;
      final total = sub['trialTotalDays'] as int? ?? 90;
      items.add(Panel(
        onTap: owner ? () => context.push('/o/subscription') : null,
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(value: total == 0 ? 0 : (left / total).clamp(0.0, 1.0), strokeWidth: 5, color: C.ok, backgroundColor: C.ok.withAlpha(40)),
              Text('$left', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('Free trial · all unlocked 🔓'), style: const TextStyle(fontWeight: FontWeight.w800)),
              Muted(context.t('{n} days left', {'n': left}), size: 12),
            ]),
          ),
          if (owner) Icon(Icons.chevron_right_rounded, color: context.c.mut),
        ]),
      ));
    } else if (sub['plan'] == null) {
      items.add(Panel(
        color: C.red.withAlpha(24),
        onTap: owner ? () => context.push('/o/subscription') : null,
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const IconTile(Icons.lock_clock_rounded, color: C.red),
          const SizedBox(width: 12),
          Expanded(child: Text(context.t('Trial ended — choose a plan'), style: const TextStyle(fontWeight: FontWeight.w800))),
          Icon(Icons.chevron_right_rounded, color: context.c.mut),
        ]),
      ));
    }
    if (owner && sub['addressComplete'] == false) {
      items.add(Panel(
        onTap: () => context.push('/o/address'),
        padding: const EdgeInsets.all(14),
        child: Row(children: [
          const IconTile(Icons.place_rounded, color: C.warn),
          const SizedBox(width: 12),
          Expanded(child: Text(context.t('Add your gym’s full address (state, city, PIN)'), style: const TextStyle(fontWeight: FontWeight.w700))),
          Icon(Icons.chevron_right_rounded, color: context.c.mut),
        ]),
      ));
    }
    return Column(children: [for (final w in items) Padding(padding: const EdgeInsets.only(bottom: 12), child: w)]);
  }
}
