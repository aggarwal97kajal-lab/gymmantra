import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'haptics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'i18n.dart';
import 'prefs.dart';
import 'screens/billing.dart';
import 'screens/help.dart' show TicketScreen, TicketTile, ticketStatuses, ticketStatusLabel, ticketStatusColor, ticketStatusOf;
import 'screens/home.dart' show openUrl;
import 'screens/profile.dart' show ProfileScreen, NotificationsScreen, ProfileDetailsScreen, ChangePasswordScreen;
import 'session.dart';
import 'theme.dart';
import 'ui.dart';

// ============================================================ GymMantra Admin app (super admin only)

/// Admin logo: the dumbbell in gold on indigo, with a crown on top.
class AdminLogo extends StatelessWidget {
  const AdminLogo({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size * 1.12,
        child: Stack(alignment: Alignment.bottomCenter, clipBehavior: Clip.none, children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.28),
              gradient: const LinearGradient(colors: [Color(0xFF3730A3), Color(0xFF0F172A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: [BoxShadow(color: C.indigo.withAlpha(90), blurRadius: size * 0.3, offset: Offset(0, size * 0.08))],
            ),
            alignment: Alignment.center,
            child: Logo(size: size * 0.72, body: C.gold, mark: Colors.white),
          ),
          Positioned(top: -size * 0.02, child: Icon(Icons.workspace_premium_rounded, size: size * 0.34, color: C.gold)),
        ]),
      );
}

final _overview = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/overview'));
final _gyms = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/gyms'));
final _gym = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/super/gyms/$id'));
final _plans = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/saas-plans'));
final _ads = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/ads'));
final _tickets = superTicketsProvider;
final _gymPatch = StateProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) => {});
final _settings = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/settings'));
final _bill = StreamProvider.autoDispose.family<dynamic, String>((ref, key) => Api.instance.cachedGet('/super/gyms/$key'));

GoRouter adminRouter(Session session, Listenable splash, Widget splashScreen, bool Function() splashDone) => GoRouter(
      initialLocation: '/splash',
      refreshListenable: Listenable.merge([session, splash]),
      redirect: (context, state) {
        final loc = state.matchedLocation;
        if (!session.ready || !splashDone()) return loc == '/splash' ? null : '/splash';
        if (!session.loggedIn) return loc == '/login' ? null : '/login';
        if (loc == '/login' || loc == '/splash') return '/a/home';
        return null;
      },
      routes: [
        GoRoute(path: '/splash', pageBuilder: (_, __) => NoTransitionPage(child: splashScreen)),
        GoRoute(path: '/login', builder: (_, __) => const AdminLoginScreen()),
        ShellRoute(
          builder: (context, state, child) => AdminShell(location: state.matchedLocation, child: child),
          routes: [
            GoRoute(path: '/a/home', pageBuilder: (_, __) => const NoTransitionPage(child: AdminHome())),
            GoRoute(path: '/a/gyms', pageBuilder: (_, __) => const NoTransitionPage(child: AdminGyms())),
            GoRoute(path: '/a/plans', pageBuilder: (_, __) => const NoTransitionPage(child: AdminPlans())),
            GoRoute(path: '/a/ads', pageBuilder: (_, __) => const NoTransitionPage(child: AdminAds())),
            GoRoute(path: '/a/more', pageBuilder: (_, __) => const NoTransitionPage(child: AdminMore())),
          ],
        ),
        GoRoute(path: '/a/gym/:id', builder: (_, s) => AdminGym(id: s.pathParameters['id']!)),
        GoRoute(path: '/a/bill/:gym/:id', builder: (_, s) => AdminBill(gym: s.pathParameters['gym']!, id: s.pathParameters['id']!)),
        GoRoute(path: '/a/ads/new', builder: (_, s) => AdEditScreen(ad: s.extra as Map?)),
        GoRoute(path: '/a/tickets', builder: (_, __) => const AdminTickets()),
        GoRoute(path: '/a/ticket/:id', builder: (_, s) => TicketScreen(id: s.pathParameters['id']!, admin: true)),
        GoRoute(path: '/a/settings', builder: (_, __) => const AdminSettings()),
        GoRoute(path: '/a/profile', builder: (_, __) => const ProfileScreen()),
        GoRoute(path: '/notifications', builder: (_, __) => const NotificationsScreen()),
        GoRoute(path: '/profile/details', builder: (_, __) => const ProfileDetailsScreen()),
        GoRoute(path: '/profile/password', builder: (_, __) => const ChangePasswordScreen()),
      ],
    );

class AdminLoginScreen extends ConsumerStatefulWidget {
  const AdminLoginScreen({super.key});
  @override
  ConsumerState<AdminLoginScreen> createState() => _AdminLoginState();
}

class _AdminLoginState extends ConsumerState<AdminLoginScreen> {
  final id = TextEditingController();
  final pw = TextEditingController();
  bool busy = false;
  bool hide = true;
  String? error;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(24, 60, 24, 24), children: [
          const Center(child: AdminLogo(size: 104)),
          const SizedBox(height: 20),
          const Center(child: Wordmark(size: 30)),
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: C.gold.withAlpha(36), borderRadius: BorderRadius.circular(99)),
              child: const Text('SUPER ADMIN', style: TextStyle(color: C.gold, fontWeight: FontWeight.w800, letterSpacing: 2, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 36),
          TextField(controller: id, keyboardType: TextInputType.emailAddress, decoration: InputDecoration(labelText: context.t('Email'), prefixIcon: const Icon(Icons.mail_outline_rounded))),
          const SizedBox(height: 12),
          TextField(
            controller: pw,
            obscureText: hide,
            decoration: InputDecoration(
              labelText: context.t('Password'),
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => hide = !hide)),
            ),
          ),
          ErrorText(error),
          const SizedBox(height: 18),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      error = null;
                    });
                    try {
                      await ref.read(sessionProvider).login(id.text, pw.text);
                    } catch (e) {
                      if (mounted) setState(() => error = e.toString());
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: Text(context.t('Log in')),
          ),
          const SizedBox(height: 12),
          Muted(context.t('Only for the GymMantra admin.'), align: TextAlign.center, size: 12),
        ]),
      ),
    );
  }
}

class AdminShell extends StatelessWidget {
  const AdminShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;
  static const tabs = ['/a/home', '/a/gyms', '/a/plans', '/a/ads', '/a/more'];
  @override
  Widget build(BuildContext context) {
    final i = tabs.indexWhere((t) => location.startsWith(t));
    return Scaffold(
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
            NavigationDestination(icon: const Icon(Icons.space_dashboard_outlined), selectedIcon: const Icon(Icons.space_dashboard_rounded), label: context.t('Home')),
            NavigationDestination(icon: const Icon(Icons.storefront_outlined), selectedIcon: const Icon(Icons.storefront_rounded), label: context.t('Gyms')),
            NavigationDestination(icon: const Icon(Icons.sell_outlined), selectedIcon: const Icon(Icons.sell_rounded), label: context.t('Plans')),
            NavigationDestination(icon: const Icon(Icons.campaign_outlined), selectedIcon: const Icon(Icons.campaign_rounded), label: context.t('Ads')),
            NavigationDestination(icon: const Icon(Icons.more_horiz_rounded), label: context.t('More')),
          ],
        ),
      ),
    );
  }
}

Widget _refresh(BuildContext context, Future<void> Function() fn, Widget child) => RefreshIndicator(color: context.c.primary, onRefresh: fn, child: child);

class AdminHome extends ConsumerWidget {
  const AdminHome({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_overview);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: _refresh(
          context,
          () async => ref.invalidate(_overview),
          ListView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 24), children: [
            Row(children: [
              const AdminLogo(size: 40),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(context.t('Platform'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)), Muted(context.t('Super admin'), size: 12.5)])),
              IconButton(onPressed: () => context.push('/notifications'), icon: const Icon(Icons.notifications_none_rounded)),
            ]),
            const SizedBox(height: 16),
            AsyncBody(
              value: v,
              onRetry: () => ref.invalidate(_overview),
              builder: (d) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: StatTile(icon: Icons.storefront_rounded, value: '${d['gyms']}', label: context.t('Gyms'))),
                  const SizedBox(width: 10),
                  Expanded(child: StatTile(icon: Icons.groups_rounded, value: '${d['members']}', label: context.t('Members'), color: C.ok)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: StatTile(icon: Icons.hourglass_top_rounded, value: '${d['trial']}', label: context.t('On trial'), color: C.warn)),
                  const SizedBox(width: 10),
                  Expanded(child: StatTile(icon: Icons.verified_rounded, value: '${d['active']}', label: context.t('Paid'), color: C.ok)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: StatTile(icon: Icons.person_rounded, value: '${d['users']}', label: context.t('App users'))),
                  const SizedBox(width: 10),
                  Expanded(child: StatTile(icon: Icons.block_rounded, value: '${d['suspended']}', label: context.t('Suspended'), color: C.red)),
                ]),
                const SizedBox(height: 12),
                Panel(
                  onTap: () => context.push('/a/tickets'),
                  child: Row(children: [
                    const IconTile(Icons.confirmation_number_rounded),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.t('{n} support tickets open', {'n': d['openTickets']}), style: const TextStyle(fontWeight: FontWeight.w800))),
                    Icon(Icons.chevron_right_rounded, color: context.c.mut),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ---------------- gyms ----------------

class AdminGyms extends ConsumerStatefulWidget {
  const AdminGyms({super.key});
  @override
  ConsumerState<AdminGyms> createState() => _AdminGymsState();
}

class _AdminGymsState extends ConsumerState<AdminGyms> {
  String f = '';
  String q = '';
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(_gyms);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gyms'))),
      body: _refresh(
        context,
        () async => ref.invalidate(_gyms),
        AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(_gyms),
          builder: (d) {
            final all = (d as List).cast<Map>();
            final list = all.where((g) => (f.isEmpty || g['status'] == f) && (q.isEmpty || '${g['name']} ${g['gymCode']} ${g['city'] ?? ''}'.toLowerCase().contains(q.toLowerCase()))).toList();
            Widget chip(String k, String l) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(label: Text('$l (${k.isEmpty ? all.length : all.where((g) => g['status'] == k).length})'), selected: f == k, onSelected: (_) => setState(() => f = k)),
                );
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              TextField(decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Search gyms')), onChanged: (t) => setState(() => q = t)),
              const SizedBox(height: 10),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [chip('', context.t('All')), chip('ACTIVE', context.t('Paid')), chip('TRIAL', context.t('On trial')), chip('SUSPENDED', context.t('Suspended'))])),
              const SizedBox(height: 10),
              Panel(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(children: [
                  for (final g in list)
                    ListTile(
                      onTap: () => context.push('/a/gym/${g['id']}'),
                      leading: const IconTile(Icons.storefront_rounded, size: 40),
                      title: Text(g['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${g['city'] ?? g['gymCode']} · ${g['_count']['members']} ${context.t('members')}', style: TextStyle(color: context.c.mut, fontSize: 12)),
                      trailing: _GymStatus(g),
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

class _GymStatus extends StatelessWidget {
  const _GymStatus(this.g);
  final Map g;
  @override
  Widget build(BuildContext context) {
    final s = g['status'] as String;
    final (label, col) = switch (s) {
      'ACTIVE' => ((g['saasPlan'] as Map?)?['name'] as String? ?? context.t('Paid'), C.ok),
      'SUSPENDED' => (context.t('Suspended'), C.red),
      _ => (context.t('Trial'), C.warn),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: col.withAlpha(36), borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class AdminGym extends ConsumerWidget {
  const AdminGym({super.key, required this.id});
  final String id;

  /// Changes show at once; the server is told in the background.
  Future<void> patch(BuildContext context, WidgetRef ref, Map<String, dynamic> body) async {
    final n = ref.read(_gymPatch(id).notifier);
    final before = n.state;
    n.state = {...before, ...body};
    toast(context, context.t('Saved'));
    try {
      await Api.instance.patch('/super/gyms/$id', body);
      ref.invalidate(_gym(id));
      ref.invalidate(_gyms);
    } catch (e) {
      n.state = before;
      Drip.showLater(e.toString(), kind: DripKind.error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_gym(id));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gym'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(_gym(id)),
        builder: (g0) {
          final g = {...(g0 as Map), ...ref.watch(_gymPatch(id))};
          final access = g['access'] as Map;
          final owners = (g['owners'] as List).cast<Map>();
          final bills = (g['bills'] as List).cast<Map>();
          return _refresh(
            context,
            () async => ref.invalidate(_gym(id)),
            ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              Text(g['name'] as String, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              Muted([g['gymCode'], g['addressLine'] ?? g['address'], g['city'], g['state'], g['pincode']].whereType<String>().join(' · ')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: StatTile(icon: Icons.groups_rounded, value: '${g['memberCount'] ?? 0}', label: context.t('Members'))),
                const SizedBox(width: 9),
                Expanded(child: StatTile(icon: Icons.sports_rounded, value: '${g['trainers'] ?? 0}', label: context.t('Trainers'))),
                const SizedBox(width: 9),
                Expanded(child: StatTile(icon: Icons.storefront_rounded, value: '${(g['branches'] as List).length}', label: context.t('Branches'))),
              ]),
              const SizedBox(height: 12),
              Panel(
                child: Row(children: [
                  GlowRing(ring: access['ring'] as String?, size: 40, child: const CircleAvatar(radius: 20, child: Icon(Icons.storefront_rounded))),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        access['inTrial'] == true
                            ? context.t('Free trial · {n} days left', {'n': access['trialDaysLeft']})
                            : access['plan'] != null
                                ? '${access['plan']['name']} · ${fmtDate(access['planEndsAt'] as String?)}'
                                : context.t('No active plan'),
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      Muted(context.t('Status: {s}', {'s': g['status']}), size: 12),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _AssignPlanSheet(gymId: id));
                  if (ok == true) {
                    ref.invalidate(_gym(id));
                    ref.invalidate(_gyms);
                  }
                },
                icon: const Icon(Icons.workspace_premium_rounded),
                label: Text(context.t('Record plan payment')),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      final base = DateTime.tryParse((g['trialEndsAt'] as String?) ?? '') ?? DateTime.now();
                      final from = base.isAfter(DateTime.now()) ? base : DateTime.now();
                      final d = from.add(const Duration(days: 30));
                      patch(context, ref, {'status': 'TRIAL', 'trialEndsAt': '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'});
                    },
                    child: Text(context.t('Trial +30 days')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: g['status'] == 'SUSPENDED' ? C.ok : C.red),
                    onPressed: () => patch(context, ref, {'status': g['status'] == 'SUSPENDED' ? (access['plan'] != null ? 'ACTIVE' : 'TRIAL') : 'SUSPENDED'}),
                    child: Text(g['status'] == 'SUSPENDED' ? context.t('Turn back on') : context.t('Suspend gym')),
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              SectionTitle(context.t('Owner')),
              for (final o in owners)
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: const Icon(Icons.person_rounded),
                    title: Text(o['name'] as String? ?? ''),
                    subtitle: Text([o['phone'], o['email']].whereType<String>().join(' · ')),
                    trailing: o['phone'] == null ? null : IconButton(icon: const Icon(Icons.call_rounded, color: C.ok), onPressed: () => openUrl('tel:${o['phone']}')),
                  ),
                ),
              const SizedBox(height: 16),
              SectionTitle(context.t('Plan history')),
              if (bills.isEmpty) Muted(context.t('No bills yet.')),
              for (final b in bills)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    onTap: () => context.push('/a/bill/$id/${b['id']}'),
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${b['planName']} · ${b['number']}', style: const TextStyle(fontWeight: FontWeight.w700)), Muted(fmtDate(b['paidAt'] as String?), size: 12)])),
                      Text(rupees(b['total'] as num?), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
            ]),
          );
        },
      ),
    );
  }
}


class _AssignPlanSheet extends ConsumerStatefulWidget {
  const _AssignPlanSheet({required this.gymId});
  final String gymId;
  @override
  ConsumerState<_AssignPlanSheet> createState() => _AssignPlanSheetState();
}

class _AssignPlanSheetState extends ConsumerState<_AssignPlanSheet> {
  String? planId;
  String cycle = 'ANNUAL';
  String mode = 'UPI';
  final ref2 = TextEditingController();
  final price = TextEditingController();
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(_plans);
    final plans = ((v.valueOrNull?['plans'] as List?) ?? const []).cast<Map>();
    final plan = plans.where((p) => p['id'] == planId).firstOrNull;
    Widget chips<T>(List<(T, String)> items, T value, ValueChanged<T> on) => Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (k, l) in items)
            ChoiceChip(
              label: Text(l),
              selected: value == k,
              showCheckmark: false,
              selectedColor: context.c.primary,
              labelStyle: TextStyle(color: value == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
              onSelected: (_) => on(k),
            ),
        ]);
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.t('Record plan payment'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        Muted(context.t('Turns the plan on and makes the receipt.'), size: 12.5),
        const SizedBox(height: 12),
        chips<String?>([for (final p in plans) (p['id'] as String, p['name'] as String)], planId, (k) => setState(() => planId = k)),
        const SizedBox(height: 10),
        chips<String>([('MONTHLY', context.t('Monthly')), ('ANNUAL', context.t('Yearly'))], cycle, (k) => setState(() => cycle = k)),
        const SizedBox(height: 10),
        chips<String>([('UPI', 'UPI'), ('CASH', context.t('Cash')), ('BANK_TRANSFER', context.t('Bank transfer')), ('FREE', context.t('Free'))], mode, (k) => setState(() => mode = k)),
        const SizedBox(height: 10),
        TextField(
          controller: price,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: context.t('Price (leave empty for plan price)'),
            hintText: plan == null ? null : '${cycle == 'ANNUAL' ? plan['annualPrice'] : plan['monthlyPrice']}',
            prefixText: '₹ ',
          ),
        ),
        const SizedBox(height: 10),
        TextField(controller: ref2, decoration: InputDecoration(labelText: context.t('UPI / bank reference (optional)'))),
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
                    await Api.instance.post('/super/gyms/${widget.gymId}/subscription', {
                      'planId': planId,
                      'cycle': cycle,
                      'mode': mode,
                      if (ref2.text.trim().isNotEmpty) 'ref': ref2.text.trim(),
                      if (int.tryParse(price.text.trim()) != null) 'price': int.parse(price.text.trim()),
                    });
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Save and make receipt')),
        ),
      ]),
    );
  }
}

class AdminBill extends ConsumerWidget {
  const AdminBill({super.key, required this.gym, required this.id});
  final String gym;
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_bill('$gym/bills/$id'));
    return Scaffold(
      backgroundColor: const Color(0xFFE9ECF1),
      appBar: AppBar(backgroundColor: const Color(0xFFE9ECF1), foregroundColor: const Color(0xFF0F172A), title: Text(context.t('Receipt'))),
      body: AsyncBody(value: v, builder: (b) => ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: [ReceiptPaper(bill: b as Map)])),
    );
  }
}

// ---------------- SaaS plans ----------------

class AdminPlans extends ConsumerWidget {
  const AdminPlans({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_plans);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Plans'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(_plans),
        builder: (d) {
          final plans = (d['plans'] as List).cast<Map>();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            Muted(context.t('Free trial: {n} months for new gyms', {'n': d['trialMonths']}), size: 12.5),
            const SizedBox(height: 10),
            for (final p in plans)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Panel(
                  onTap: () async {
                    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _PlanEditSheet(plan: p));
                    if (ok == true) ref.invalidate(_plans);
                  },
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
                      if (p['visible'] != true) Muted(context.t('Hidden'), size: 12),
                      const SizedBox(width: 8),
                      Muted(context.t('{n} gyms', {'n': p['_count']?['tenants'] ?? 0}), size: 12),
                    ]),
                    Text('${rupees(p['monthlyPrice'] as num?)} / ${context.t('month')} · ${rupees(p['annualPrice'] as num?)} / ${context.t('year')}', style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final k in ['offers', 'pt', 'reports', 'branches'])
                        Builder(builder: (_) {
                          final un = (p['unlocks'] as List?)?.contains(k) ?? (unlocksByName(p['name'] as String).contains(k));
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                            decoration: BoxDecoration(color: (un ? C.ok : context.c.mut).withAlpha(30), borderRadius: BorderRadius.circular(99)),
                            child: Text('${un ? '✓' : '🔒'} ${context.t(featureNames[k]!)}', style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: un ? C.ok : context.c.mut)),
                          );
                        }),
                    ]),
                  ]),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

List<String> unlocksByName(String name) {
  final n = name.toLowerCase();
  if (n.contains('starter')) return [];
  if (n.contains('growth')) return ['offers', 'pt'];
  return ['offers', 'pt', 'reports', 'branches'];
}

class _PlanEditSheet extends StatefulWidget {
  const _PlanEditSheet({required this.plan});
  final Map plan;
  @override
  State<_PlanEditSheet> createState() => _PlanEditSheetState();
}

class _PlanEditSheetState extends State<_PlanEditSheet> {
  late final monthly = TextEditingController(text: '${widget.plan['monthlyPrice']}');
  late final annual = TextEditingController(text: '${widget.plan['annualPrice']}');
  late final members = TextEditingController(text: widget.plan['memberLimit']?.toString() ?? '');
  late final Set<String> unlocks = {...((widget.plan['unlocks'] as List?)?.cast<String>() ?? unlocksByName(widget.plan['name'] as String))};
  late bool visible = widget.plan['visible'] == true;
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.plan['name'] as String, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: monthly, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Monthly price'), prefixText: '₹ '))),
          const SizedBox(width: 10),
          Expanded(child: TextField(controller: annual, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Yearly price'), prefixText: '₹ '))),
        ]),
        const SizedBox(height: 10),
        TextField(controller: members, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Member limit (empty = unlimited)'))),
        const SizedBox(height: 10),
        Muted(context.t('Unlocks'), size: 12.5),
        Wrap(spacing: 8, children: [
          for (final k in ['offers', 'pt', 'reports', 'branches'])
            FilterChip(label: Text(context.t(featureNames[k]!)), selected: unlocks.contains(k), onSelected: (on) => setState(() => on ? unlocks.add(k) : unlocks.remove(k))),
        ]),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.t('Show to gyms')), value: visible, onChanged: (v) => setState(() => visible = v)),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await Api.instance.patch('/super/saas-plans/${widget.plan['id']}', {
                      'monthlyPrice': int.tryParse(monthly.text.trim()) ?? 0,
                      'annualPrice': int.tryParse(annual.text.trim()) ?? 0,
                      'memberLimit': int.tryParse(members.text.trim()),
                      'unlocks': unlocks.toList(),
                      'visible': visible,
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
      ]),
    );
  }
}

// ---------------- ads ----------------

class AdminAds extends ConsumerWidget {
  const AdminAds({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_ads);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Ads'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: context.c.primary,
        foregroundColor: Colors.white,
        onPressed: () async {
          await context.push('/a/ads/new');
          ref.invalidate(_ads);
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(context.t('New ad')),
      ),
      body: _refresh(
        context,
        () async => ref.invalidate(_ads),
        AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(_ads),
          builder: (d) {
            final list = (d as List).cast<Map>();
            int sum(Map? m) => m == null ? 0 : m.values.fold<int>(0, (n, x) => n + (x as num).toInt());
            final views = list.fold<int>(0, (n, a) => n + sum(a['views'] as Map?));
            final clicks = list.fold<int>(0, (n, a) => n + sum(a['clicks'] as Map?));
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 90), children: [
              Row(children: [
                Expanded(child: StatTile(icon: Icons.visibility_rounded, value: '$views', label: context.t('Views'))),
                const SizedBox(width: 10),
                Expanded(child: StatTile(icon: Icons.touch_app_rounded, value: '$clicks', label: context.t('Taps'), color: C.ok)),
              ]),
              const SizedBox(height: 12),
              if (list.isEmpty) Muted(context.t('No ads yet. Create one — it shows on the dashboards you choose.'), align: TextAlign.center),
              for (final a in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Panel(
                    onTap: () async {
                      await context.push('/a/ads/new', extra: a);
                      ref.invalidate(_ads);
                    },
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      Container(width: 56, height: 42, decoration: BoxDecoration(color: _hex(a['color'] as String?), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.campaign_rounded, color: Colors.white)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(a['title'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                          Muted(_audience(context, a), size: 11.5),
                          Muted('👁 ${sum(a['views'] as Map?)}  ·  👆 ${sum(a['clicks'] as Map?)}', size: 11.5),
                        ]),
                      ),
                      _QuickSwitch(
                        value: a['active'] == true,
                        onChanged: (on) async {
                          await Api.instance.patch('/super/ads/${a['id']}', {'active': on});
                          ref.invalidate(_ads);
                        },
                      ),
                    ]),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Switch that flips at once and goes back only if saving fails.
class _QuickSwitch extends StatefulWidget {
  const _QuickSwitch({required this.value, required this.onChanged});
  final bool value;
  final Future<void> Function(bool) onChanged;
  @override
  State<_QuickSwitch> createState() => _QuickSwitchState();
}

class _QuickSwitchState extends State<_QuickSwitch> {
  bool? v;
  @override
  void didUpdateWidget(_QuickSwitch old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) v = null;
  }

  @override
  Widget build(BuildContext context) => Switch(
        value: v ?? widget.value,
        activeTrackColor: context.c.primary,
        onChanged: (on) async {
          setState(() => v = on);
          try {
            await widget.onChanged(on);
          } catch (e) {
            if (mounted) {
              setState(() => v = null);
              toastError(context, e);
            }
          }
        },
      );
}

Color _hex(String? h) => Color(int.tryParse('FF${(h ?? '#2563EB').replaceFirst('#', '')}', radix: 16) ?? 0xFF2563EB);

String _audience(BuildContext context, Map a) {
  final who = [if (a['forMembers'] == true) context.t('Members'), if (a['forTrainers'] == true) context.t('Trainers'), if (a['forOwners'] == true) context.t('Gym owners')].join(' + ');
  final states = (a['states'] as List?)?.cast<String>() ?? const [];
  return '$who · ${states.isEmpty ? context.t('All India') : states.join(', ')} · ${fmtDate(a['endsOn'] as String?)}';
}

class AdEditScreen extends ConsumerStatefulWidget {
  const AdEditScreen({super.key, this.ad});
  final Map? ad;
  @override
  ConsumerState<AdEditScreen> createState() => _AdEditState();
}

class _AdEditState extends ConsumerState<AdEditScreen> {
  late final title = TextEditingController(text: widget.ad?['title'] as String? ?? '');
  late final text = TextEditingController(text: widget.ad?['body'] as String? ?? '');
  late final link = TextEditingController(text: widget.ad?['linkValue'] as String? ?? '');
  late String kind = widget.ad?['linkKind'] as String? ?? 'URL';
  late bool members = widget.ad?['forMembers'] as bool? ?? true;
  late bool trainers = widget.ad?['forTrainers'] as bool? ?? false;
  late bool owners = widget.ad?['forOwners'] as bool? ?? false;
  late Set<String> states = {...((widget.ad?['states'] as List?)?.cast<String>() ?? const [])};
  late String color = widget.ad?['color'] as String? ?? '#2563EB';
  late DateTime ends = DateTime.tryParse(widget.ad?['endsOn'] as String? ?? '') ?? DateTime.now().add(const Duration(days: 30));
  String? imageUrl;
  Uint8List? localImage; // picked now, shown in the live preview, uploaded on Save
  bool busy = false;
  String? error;
  static const colors = ['#2563EB', '#E11D48', '#F59E0B', '#7C3AED', '#059669', '#0F172A'];

  @override
  void initState() {
    super.initState();
    imageUrl = widget.ad?['imageUrl'] as String?;
  }

  String get ymd => '${ends.year}-${ends.month.toString().padLeft(2, '0')}-${ends.day.toString().padLeft(2, '0')}';

  Future<String?> save() async {
    final body = {
      'title': title.text.trim(),
      'body': text.text.trim(),
      'linkKind': kind,
      'linkValue': kind == 'NONE' ? null : link.text.trim(),
      'forMembers': members,
      'forTrainers': trainers,
      'forOwners': owners,
      'states': states.toList(),
      'endsOn': ymd,
      'color': color,
    };
    final r = widget.ad == null ? await Api.instance.post('/super/ads', body) : await Api.instance.patch('/super/ads/${widget.ad!['id']}', body);
    return r['id'] as String?;
  }

  Future<void> pickImage() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 92);
    if (f == null) return;
    final c = await ImageCropper().cropImage(
      sourcePath: f.path,
      maxWidth: 1080,
      compressQuality: 80,
      compressFormat: ImageCompressFormat.jpg,
      uiSettings: [AndroidUiSettings(toolbarTitle: 'Ad banner', toolbarColor: C.night, toolbarWidgetColor: Colors.white, activeControlsWidgetColor: C.indigo, initAspectRatio: CropAspectRatioPreset.ratio16x9, lockAspectRatio: true, aspectRatioPresets: [CropAspectRatioPreset.ratio16x9])],
    );
    if (c == null) return;
    final bytes = await c.readAsBytes();
    if (mounted) setState(() => localImage = bytes);
  }

  Future<void> saveAll() async {
    final id = await save() ?? widget.ad?['id'] as String?;
    if (localImage != null && id != null) {
      await Api.instance.post('/super/ads/$id/image', {'mime': 'image/jpeg', 'base64': base64Encode(localImage!)});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    Widget check(String label, bool v, ValueChanged<bool> on) => Expanded(
          child: FilterChip(label: SizedBox(width: double.infinity, child: Text(label, textAlign: TextAlign.center)), selected: v, onSelected: on),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.ad == null ? context.t('New ad') : context.t('Edit ad')),
        actions: [
          if (widget.ad != null)
            IconButton(
              tooltip: context.t('Delete'),
              icon: const Icon(Icons.delete_outline_rounded, color: C.red),
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text(context.t('Delete this ad?')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('Cancel'))),
                      TextButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('Delete'), style: const TextStyle(color: C.red))),
                    ],
                  ),
                );
                if (yes != true) return;
                try {
                  await Api.instance.delete('/super/ads/${widget.ad!['id']}');
                  if (context.mounted) context.pop();
                } catch (e) {
                  if (context.mounted) toastError(context, e);
                }
              },
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: const BoxDecoration(color: C.ok, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Muted(context.t('Live preview'), size: 12.5),
        ]),
        const SizedBox(height: 6),
        // live preview
        Container(
          height: 130,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(color: _hex(color), borderRadius: BorderRadius.circular(18)),
          child: Stack(children: [
            if (localImage != null)
              Positioned.fill(child: Image.memory(localImage!, fit: BoxFit.cover))
            else if (imageUrl != null)
              Positioned.fill(child: Image.network(Api.instance.url(imageUrl!), fit: BoxFit.cover)),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: Colors.black.withAlpha(60), borderRadius: BorderRadius.circular(99)), child: Text(context.t('Sponsored'), style: const TextStyle(color: Colors.white, fontSize: 10.5))),
                const Spacer(),
                Text(title.text.isEmpty ? context.t('Ad title') : title.text, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                if (text.text.isNotEmpty) Text(text.text, style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 12.5)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: busy ? null : pickImage, icon: const Icon(Icons.image_rounded), label: Text(context.t('Banner photo (16:9)'))),
        const SizedBox(height: 12),
        TextField(controller: title, decoration: InputDecoration(labelText: context.t('Title')), onChanged: (_) => setState(() {})),
        const SizedBox(height: 10),
        TextField(controller: text, decoration: InputDecoration(labelText: context.t('Short line (optional)')), onChanged: (_) => setState(() {})),
        const SizedBox(height: 12),
        Wrap(spacing: 10, children: [
          for (final c in colors)
            GestureDetector(
              onTap: () => setState(() => color = c),
              child: Container(width: 34, height: 34, decoration: BoxDecoration(color: _hex(c), shape: BoxShape.circle, border: Border.all(color: color == c ? p.fg : Colors.transparent, width: 3))),
            ),
        ]),
        const SizedBox(height: 14),
        Muted(context.t('On tap'), size: 12.5),
        const SizedBox(height: 6),
        Seg<String>(value: kind, items: [('URL', context.t('Website'), null), ('WHATSAPP', 'WhatsApp', null), ('CALL', context.t('Call'), null), ('NONE', context.t('Nothing'), null)], onChanged: (v) => setState(() => kind = v)),
        if (kind != 'NONE') ...[
          const SizedBox(height: 10),
          TextField(controller: link, keyboardType: kind == 'URL' ? TextInputType.url : TextInputType.phone, decoration: InputDecoration(labelText: kind == 'URL' ? 'https://…' : context.t('Phone number'))),
        ],
        const SizedBox(height: 14),
        Muted(context.t('Who should see it?'), size: 12.5),
        const SizedBox(height: 6),
        Row(children: [
          check(context.t('Members'), members, (v) => setState(() => members = v)),
          const SizedBox(width: 6),
          check(context.t('Trainers'), trainers, (v) => setState(() => trainers = v)),
          const SizedBox(width: 6),
          check(context.t('Gym owners'), owners, (v) => setState(() => owners = v)),
        ]),
        const SizedBox(height: 12),
        Panel(
          onTap: () async {
            final all = (await loadIndia()).map((s) => s.name).toList();
            if (!context.mounted) return;
            final picked = await showModalBottomSheet<Set<String>>(context: context, isScrollControlled: true, builder: (_) => _StatesSheet(all: all, selected: states));
            if (picked != null) setState(() => states = picked);
          },
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const IconTile(Icons.map_rounded, size: 36),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Muted(context.t('Where'), size: 12), Text(states.isEmpty ? context.t('All India') : states.join(', '), style: const TextStyle(fontWeight: FontWeight.w700))])),
          ]),
        ),
        const SizedBox(height: 10),
        Panel(
          onTap: () async {
            final d = await showDatePicker(context: context, initialDate: ends, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
            if (d != null) setState(() => ends = d);
          },
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            const IconTile(Icons.event_rounded, size: 36),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Muted(context.t('Show till'), size: 12), Text(fmtDate(ymd), style: const TextStyle(fontWeight: FontWeight.w700))])),
          ]),
        ),
        if (widget.ad != null) ...[
          const SizedBox(height: 14),
          SectionTitle(context.t('Who saw it')),
          for (final r in ['MEMBER', 'TRAINER', 'OWNER'])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(children: [
                Expanded(child: Text(context.t({'MEMBER': 'Members', 'TRAINER': 'Trainers', 'OWNER': 'Gym owners'}[r]!))),
                Text('👁 ${(widget.ad!['views'] as Map?)?[r] ?? 0}   👆 ${(widget.ad!['clicks'] as Map?)?[r] ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
        ],
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
                    await saveAll();
                    if (context.mounted) context.pop();
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(widget.ad == null ? context.t('Run ad') : context.t('Save')),
        ),
      ]),
    );
  }
}

class _StatesSheet extends StatefulWidget {
  const _StatesSheet({required this.all, required this.selected});
  final List<String> all;
  final Set<String> selected;
  @override
  State<_StatesSheet> createState() => _StatesSheetState();
}

class _StatesSheetState extends State<_StatesSheet> {
  late final Set<String> sel = {...widget.selected};
  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
            child: Row(children: [
              Expanded(child: Text(context.t('States'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
              TextButton(onPressed: () => setState(sel.clear), child: Text(context.t('All India'))),
              FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(80, 40)), onPressed: () => Navigator.pop(context, sel), child: Text(context.t('Done'))),
            ]),
          ),
          Expanded(
            child: ListView(children: [
              for (final s in widget.all) CheckboxListTile(value: sel.contains(s), title: Text(s), onChanged: (v) => setState(() => v == true ? sel.add(s) : sel.remove(s))),
            ]),
          ),
        ]),
      );
}

// ---------------- tickets, settings, more ----------------

class AdminTickets extends ConsumerStatefulWidget {
  const AdminTickets({super.key});
  @override
  ConsumerState<AdminTickets> createState() => _AdminTicketsState();
}

class _AdminTicketsState extends ConsumerState<AdminTickets> {
  String? filter; // null = all

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(_tickets);
    return Scaffold(
      appBar: AppBar(title: const Text('Support tickets')),
      body: _refresh(
        context,
        () async => ref.invalidate(_tickets),
        AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(_tickets),
          builder: (d) {
            final all = (d as List).cast<Map>();
            final count = {for (final st in ticketStatuses) st: all.where((t) => ticketStatusOf(t) == st).length};
            final list = filter == null ? all.where((t) => ticketStatusOf(t) != 'CLOSED').toList() : all.where((t) => ticketStatusOf(t) == filter).toList();
            Widget chip(String? st, String label, int n) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('$label ($n)'),
                    selected: filter == st,
                    showCheckmark: false,
                    selectedColor: st == null ? context.c.primary : ticketStatusColor(context, st),
                    labelStyle: TextStyle(color: filter == st ? Colors.white : context.c.fg, fontWeight: FontWeight.w700, fontSize: 12.5),
                    onSelected: (_) => setState(() => filter = st),
                  ),
                );
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  chip(null, 'Active', all.length - count['CLOSED']!),
                  for (final st in ticketStatuses) chip(st, ticketStatusLabel(st, admin: true), count[st]!),
                ]),
              ),
              const SizedBox(height: 6),
              Muted(
                filter == null ? 'Open tickets first (oldest on top), then in progress, waiting, resolved.' : 'Resolved tickets close by themselves after 7 days.',
                size: 12,
              ),
              const SizedBox(height: 10),
              if (list.isEmpty) Padding(padding: const EdgeInsets.only(top: 60), child: Muted('No tickets here.', align: TextAlign.center)),
              for (final t in list) TicketTile(t: t, admin: true, onTap: () => context.push('/a/ticket/${t['id']}')),
            ]);
          },
        ),
      ),
    );
  }
}

class AdminSettings extends ConsumerStatefulWidget {
  const AdminSettings({super.key});
  @override
  ConsumerState<AdminSettings> createState() => _AdminSettingsState();
}

class _AdminSettingsState extends ConsumerState<AdminSettings> {
  final gstin = TextEditingController();
  final legal = TextEditingController();
  final address = TextEditingController();
  final rate = TextEditingController();
  final wa = TextEditingController();
  final appUrl = TextEditingController();
  final bizName = TextEditingController();
  final bizAddress = TextEditingController();
  final trial = TextEditingController();
  bool registered = false;
  bool inclusive = false;
  DateTime? from;
  bool loaded = false;
  bool busy = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(_settings);
    final s = v.valueOrNull;
    if (!loaded && s != null) {
      final g = s['gst'] as Map;
      registered = g['registered'] == true;
      inclusive = g['inclusive'] == true;
      gstin.text = g['gstin'] as String? ?? '';
      legal.text = g['legalName'] as String? ?? '';
      address.text = g['address'] as String? ?? '';
      rate.text = '${g['rate'] ?? 18}';
      from = DateTime.tryParse(g['from'] as String? ?? '');
      wa.text = (s['supportWhatsapp'] as String? ?? '').replaceFirst('+91', '');
      appUrl.text = s['appUrl'] as String? ?? '';
      bizName.text = s['businessName'] as String? ?? '';
      bizAddress.text = s['businessAddress'] as String? ?? '';
      trial.text = '${s['trialMonths'] ?? 3}';
      loaded = true;
    }
    String? ymd(DateTime? d) => d == null ? null : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Settings'))),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              SectionTitle(context.t('Business')),
              TextField(controller: bizName, decoration: InputDecoration(labelText: context.t('Name on receipts'))),
              const SizedBox(height: 10),
              TextField(controller: bizAddress, decoration: InputDecoration(labelText: context.t('Address on receipts'))),
              const SizedBox(height: 10),
              TextField(controller: wa, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: context.t('Support WhatsApp (gyms message here to buy a plan)'))),
              const SizedBox(height: 12),
              TextField(controller: appUrl, keyboardType: TextInputType.url, decoration: InputDecoration(labelText: context.t('App download link (Play Store)'), helperText: context.t('Goes in the message gyms share on WhatsApp'))),
              const SizedBox(height: 10),
              TextField(controller: trial, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Free trial (months) for new gyms'))),
              const SizedBox(height: 20),
              SectionTitle(context.t('GST')),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.t('GymMantra is GST registered'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    subtitle: Text(registered ? context.t('ON: new bills get GST') : context.t('OFF: bills have no GST')),
                    value: registered,
                    onChanged: (v) => setState(() => registered = v),
                  ),
                  Muted(context.t('When ON, new bills add GST by the gym’s state: Delhi gyms CGST + SGST, other states IGST. Old bills do not change.'), size: 12),
                ]),
              ),
              const SizedBox(height: 10),
              TextField(controller: gstin, textCapitalization: TextCapitalization.characters, maxLength: 15, decoration: InputDecoration(labelText: 'GSTIN', counterText: '')),
              const SizedBox(height: 10),
              TextField(controller: legal, decoration: InputDecoration(labelText: context.t('Legal name'))),
              const SizedBox(height: 10),
              TextField(controller: address, decoration: InputDecoration(labelText: context.t('Registered address'))),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextField(controller: rate, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Rate %')))),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final d = await showDatePicker(context: context, initialDate: from ?? DateTime.now(), firstDate: DateTime(2025), lastDate: DateTime(2035));
                      if (d != null) setState(() => from = d);
                    },
                    child: Text(from == null ? context.t('From: today') : '${context.t('From')}: ${fmtDate(ymd(from))}'),
                  ),
                ),
              ]),
              const SizedBox(height: 10),
              Seg<bool>(
                value: inclusive,
                items: [(false, context.t('GST on top of price'), null), (true, context.t('GST inside price'), null)],
                onChanged: (v) => setState(() => inclusive = v),
              ),
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
                        final saved = context.t('Saved');
                        try {
                          await Api.instance.patch('/super/settings', {
                            'businessName': bizName.text.trim(),
                            'businessAddress': bizAddress.text.trim(),
                            'supportWhatsapp': wa.text.trim(),
                            'appUrl': appUrl.text.trim(),
                            if (int.tryParse(trial.text.trim()) != null) 'trialMonths': int.parse(trial.text.trim()),
                          });
                          await Api.instance.patch('/super/gst', {
                            'gstin': gstin.text.trim(),
                            'legalName': legal.text.trim(),
                            'address': address.text.trim(),
                            'rate': int.tryParse(rate.text.trim()) ?? 18,
                            'from': ymd(from),
                            'inclusive': inclusive,
                            'registered': registered,
                          });
                          ref.invalidate(_settings);
                          if (context.mounted) toast(context, saved);
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

class AdminMore extends ConsumerWidget {
  const AdminMore({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    Widget row(IconData i, String t, VoidCallback onTap) => ListTile(leading: IconTile(i, size: 36), title: Text(t, style: const TextStyle(fontWeight: FontWeight.w600)), trailing: Icon(Icons.chevron_right_rounded, color: context.c.mut), onTap: onTap);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('More'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            row(Icons.confirmation_number_rounded, context.t('Support tickets'), () => context.push('/a/tickets')),
            row(Icons.receipt_long_rounded, context.t('GST and billing'), () => context.push('/a/settings')),
            row(Icons.person_rounded, context.t('Profile & settings'), () => context.push('/a/profile')),
          ]),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () async {
            await s.logout();
            await Prefs.clearUserData();
          },
          icon: const Icon(Icons.logout_rounded),
          label: Text(context.t('Log out')),
        ),
      ]),
    );
  }
}

/// Keeps the import used when HapticFeedback is needed elsewhere in the admin app.
void adminTapFeedback() => HapticFeedback.selectionClick();
