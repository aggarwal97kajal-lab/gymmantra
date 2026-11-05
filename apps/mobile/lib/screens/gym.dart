import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show PhoneField;
import 'branch.dart' show showAlreadyMember;

class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key});
  @override
  ConsumerState<JoinScreen> createState() => _JoinState();
}

class _JoinState extends ConsumerState<JoinScreen> {
  final code = TextEditingController();
  final phone = TextEditingController();
  Map? gym;
  String? branchId;
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() fn) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Join a gym'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Muted(context.t('Enter the gym code from the poster at your gym or ask the front desk.'), size: 14),
        const SizedBox(height: 14),
        TextField(
          controller: code,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: context.t('Gym code'), hintText: 'LIFE701', prefixIcon: const Icon(Icons.storefront_rounded)),
          onChanged: (_) => setState(() => gym = null),
        ),
        const SizedBox(height: 12),
        if (gym == null)
          FilledButton(
            onPressed: busy ? null : () => run(() async {
                  final g = await Api.instance.get('/me/gym-lookup?code=${Uri.encodeQueryComponent(code.text.trim())}');
                  setState(() {
                    gym = g as Map;
                    branchId = (g['branch'] as Map?)?['id'] as String?;
                  });
                }),
            child: Text(context.t('Find gym')),
          )
        else ...[
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(gym!['name'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              if (gym!['multiBranch'] == true && gym!['branch'] is Map)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    Icon(Icons.place_rounded, size: 16, color: context.c.primary),
                    const SizedBox(width: 4),
                    Expanded(child: Text(context.t('Branch: {b}', {'b': (gym!['branch'] as Map)['name']}), style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700))),
                  ]),
                ),
              if (gym!['address'] != null) Muted(gym!['address']),
              if (gym!['multiBranch'] == true)
                Padding(padding: const EdgeInsets.only(top: 6), child: Muted(context.t('Each branch has its own code. Check this is your branch.'), size: 11.5)),
            ]),
          ),
          if (gym!['already'] is Map) ...[
            const SizedBox(height: 12),
            Builder(builder: (context) {
              final a = gym!['already'] as Map;
              final same = a['sameBranch'] == true;
              final allow = a['allowTransfer'] == true;
              final to = (gym!['branch'] as Map?)?['name'] ?? '';
              return Panel(
                color: C.warn.withAlpha(30),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.info_outline_rounded, color: C.warn),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        same
                            ? context.t('You are already a member of this branch.')
                            : allow
                                ? context.t('You are a member of {from}. A member can be in one branch at a time — ask for a transfer to {to}.', {'from': a['branchName'] ?? '', 'to': to})
                                : context.t('You are a member of {from}. A member can be in one branch at a time. Your gym owner has not enabled transfer of your membership. Ask at the front desk or the gym owner.', {'from': a['branchName'] ?? ''}),
                        style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35),
                      ),
                    ),
                  ]),
                  if (!same && allow) ...[
                    const SizedBox(height: 10),
                    FilledButton.icon(
                      onPressed: () => context.push('/transfer/${gym!['id']}?to=${(gym!['branch'] as Map?)?['id'] ?? ''}'),
                      icon: const Icon(Icons.swap_horiz_rounded),
                      label: Text(context.t('Request transfer to {b}', {'b': to})),
                    ),
                  ],
                ]),
              );
            }),
          ],
          if (ref.watch(sessionProvider).user?['phone'] == null) ...[
            const SizedBox(height: 12),
            PhoneField(label: context.t('Your mobile number'), controller: phone, bottom: 0),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || gym!['already'] is Map
                ? null
                : () => run(() async {
                      final s = ref.read(sessionProvider);
                      if (s.user?['phone'] == null) {
                        if (phone.text.trim().isEmpty) throw ApiException(400, context.t('Enter your mobile number'));
                        final u = await Api.instance.patch('/me/contact', {'phone': phone.text.trim()});
                        s.patchUser({'phone': (u as Map)['phone']});
                      }
                      try {
                        await Api.instance.post('/me/join', {'gymCode': code.text.trim()});
                      } on ApiException catch (e) {
                        if (e.data?['code'] == 'ALREADY_MEMBER' && e.data?['sameBranch'] != true && mounted) {
                          await showAlreadyMember(context, e);
                          return;
                        }
                        rethrow;
                      }
                      ref.invalidate(gymsProvider);
                      if (mounted) {
                        toast(context, context.t('Request sent to {gym}', {'gym': gym!['name']}), kind: DripKind.ok, detail: context.t('The gym will approve it. You will get a notification.'));
                        context.pop();
                      }
                    }),
            child: Text(context.t('Send join request')),
          ),
        ],
        ErrorText(error),
      ]),
    );
  }
}

Future<void> _open(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

class MembershipScreen extends ConsumerWidget {
  const MembershipScreen({super.key, required this.memberId});
  final String memberId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(membershipProvider(memberId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('My membership'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(membershipProvider(memberId)),
        builder: (d) {
          final gym = d['gym'] as Map;
          final cur = d['current'] as Map?;
          final status = d['status'] as String;
          final history = (d['history'] as List).cast<Map>();
          final phone = gym['phone'] as String?;
          final wa = gym['whatsappNumber'] as String?;
          return RefreshIndicator(
            color: context.c.primary,
            onRefresh: () async => ref.invalidate(membershipProvider(memberId)),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Expanded(child: Text(gym['name'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))), StatusChip(status)]),
                  Muted('${context.t('Member ID')} ${d['memberCode']}'),
                  const SizedBox(height: 16),
                  if (cur != null) ...[
                    Text(cur['planName'], style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text('${fmtDate(cur['startDate'])} – ${fmtDate(d['endsOn'])}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (d['daysLeft'] != null && (d['daysLeft'] as int) >= 0) Muted(context.t('{n} days left', {'n': d['daysLeft']})),
                    if (d['frozenUntil'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('❄ ${context.t('Frozen until {date}', {'date': fmtDate(d['frozenUntil'])})}', style: const TextStyle(color: C.blue, fontWeight: FontWeight.w600))),
                    const Divider(height: 28),
                    _row(context.t('Amount'), rupees(cur['total'])),
                    if ((cur['discount'] as int) > 0) _row(context.t('Discount'), rupees(cur['discount'])),
                    _row(context.t('Paid'), rupees(cur['paid'])),
                    if ((d['due'] as int) > 0) _row(context.t('Due'), rupees(d['due']), color: C.red),
                    if ((cur['paymentModes'] as List).isNotEmpty) _row(context.t('Paid by'), (cur['paymentModes'] as List).map((m) => context.t(_mode(m as String))).join(', ')),
                    _row(context.t('Freeze days left'), '${cur['freezeDaysLeft']}'),
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(color: context.c.surf2, borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [const Icon(Icons.verified_rounded, size: 18, color: C.ok), const SizedBox(width: 8), Expanded(child: Muted('${context.t('Updated by your gym')} · ${cur['updatedBy']} · ${fmtDateTime(cur['updatedAt'])}', size: 12))]),
                    ),
                  ] else
                    Muted(status == 'EXPIRED' ? context.t('Your membership ended on {date}. Contact your gym to renew.', {'date': fmtDate(d['endsOn'])}) : context.t('No membership yet. Contact your gym to start one.')),
                ]),
              ),
              const SizedBox(height: 12),
              Row(children: [
                if (phone != null) Expanded(child: OutlinedButton.icon(onPressed: () => _open('tel:$phone'), icon: const Icon(Icons.call), label: Text(context.t('Call gym')))),
                if (phone != null && wa != null) const SizedBox(width: 10),
                if (wa != null)
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: C.wa, foregroundColor: Colors.white),
                      onPressed: () => _open('https://wa.me/${wa.replaceAll(RegExp(r'[^0-9]'), '')}?text=${Uri.encodeComponent('Hi, I am ${d['memberCode']}. I want to renew my membership.')}'),
                      icon: const Icon(Icons.chat),
                      label: const Text('WhatsApp'),
                    ),
                  ),
              ]),
              const SizedBox(height: 10),
              OutlinedButton(onPressed: () => context.push('/plans/${gym['id']}'), child: Text(context.t("See gym's plans"))),
              const SizedBox(height: 20),
              _MyCheckins(memberId: memberId),
              if (history.length > 1) ...[
                SectionTitle(context.t('History')),
                const SizedBox(height: 8),
                for (final h in history)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.all(14),
                      child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(h['planName'], style: const TextStyle(fontWeight: FontWeight.w700)), Muted('${fmtDate(h['startDate'])} – ${fmtDate(h['endDate'])}', size: 12)])),
                        Text(rupees(h['total']), style: const TextStyle(fontWeight: FontWeight.w700)),
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

  static String _mode(String m) => const {'CASH': 'Cash', 'UPI': 'UPI', 'CARD': 'Card', 'BANK_TRANSFER': 'Bank transfer'}[m] ?? m;

  Widget _row(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Muted(k)), Text(v, style: TextStyle(fontWeight: FontWeight.w700, color: color))]),
      );
}

class PlansScreen extends ConsumerStatefulWidget {
  const PlansScreen({super.key, required this.tenantId});
  final String tenantId;
  @override
  ConsumerState<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends ConsumerState<PlansScreen> {
  final busy = <String>{};

  Future<void> interested(Map p) async {
    setState(() => busy.add(p['id'] as String));
    final ok = context.t('The gym knows — they will contact you 👍');
    try {
      await Api.instance.post('/me/gyms/${widget.tenantId}/plans/${p['id']}/interest');
      ref.invalidate(plansProvider(widget.tenantId));
      if (mounted) toast(context, ok);
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy.remove(p['id']));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(plansProvider(widget.tenantId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gym plans'))),
      body: AsyncBody(
        value: v,
        builder: (d) {
          final plans = (d as List).cast<Map>();
          if (plans.isEmpty) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Muted(context.t('Your gym has not listed plans in the app yet.'), align: TextAlign.center)));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Muted(context.t('Tap "Interested" and the gym will contact you to start or change your plan.')),
            const SizedBox(height: 12),
            for (final p in plans) ...[
              Material(
                color: context.c.surf,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: BorderSide(color: p['active'] == true ? C.ok : context.c.line, width: p['active'] == true ? 1.8 : 1),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(p['name'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text.rich(TextSpan(children: [
                            TextSpan(text: rupees(p['price']), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: context.c.primary)),
                            TextSpan(text: '  /  ${context.t('{n} months', {'n': p['months']})}', style: TextStyle(color: context.c.mut)),
                          ])),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      if (p['active'] == true)
                        _PlanTag(icon: Icons.check_rounded, text: context.t('Active plan'), color: C.ok)
                      else if (p['interested'] == true)
                        _PlanTag(icon: Icons.check_rounded, text: context.t('Request sent'), color: context.c.primary)
                      else
                        FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 14), textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                          onPressed: busy.contains(p['id']) ? null : () => interested(p),
                          icon: const Icon(Icons.favorite_border_rounded, size: 16),
                          label: Text(context.t('Interested')),
                        ),
                    ]),
                    if ((p['joiningFee'] as int) > 0) Muted(context.t('+ {fee} joining fee for new members', {'fee': rupees(p['joiningFee'])}), size: 12),
                    if ((p['freezeDays'] as int) > 0) Muted(context.t('{n} freeze days', {'n': p['freezeDays']}), size: 12),
                    if ((p['features'] as List).isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        for (final f in (p['features'] as List))
                          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: context.c.surf2, borderRadius: BorderRadius.circular(99)), child: Text('$f', style: const TextStyle(fontSize: 12))),
                      ]),
                    ],
                  ]),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ]);
        },
      ),
    );
  }
}

class _PlanTag extends StatelessWidget {
  const _PlanTag({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: color.withAlpha(34), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
        ]),
      );
}


final myCheckinsProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/me/memberships/$id/checkins'));

/// Every check-in of the member, grouped by day ("6:10 AM · 7:54 PM").
class _MyCheckins extends ConsumerWidget {
  const _MyCheckins({required this.memberId});
  final String memberId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(myCheckinsProvider(memberId)).valueOrNull;
    final list = (v is List ? v : const []).whereType<Map>().toList();
    if (list.isEmpty) return const SizedBox.shrink();
    final byDay = <String, List<Map>>{};
    for (final c in list) {
      final t = DateTime.tryParse(c['at'] as String? ?? '')?.toUtc().add(const Duration(hours: 5, minutes: 30));
      if (t == null) continue;
      final d = '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
      (byDay[d] ??= []).add(c);
    }
    String time(Map c) {
      final d = DateTime.tryParse(c['at'] as String? ?? '')?.toLocal();
      if (d == null) return '';
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(context.t('My check-ins')),
      const SizedBox(height: 8),
      Panel(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          for (final e in byDay.entries.take(14))
            ListTile(
              dense: true,
              leading: Icon(e.value.any((c) => c['result'] != 'BLOCKED') ? Icons.check_circle_rounded : Icons.block_rounded, color: e.value.any((c) => c['result'] != 'BLOCKED') ? C.ok : C.red),
              title: Text(fmtDate(e.key), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(
                [e.value.reversed.map((c) => c['result'] == 'BLOCKED' ? '${time(c)} (${context.t('stopped')})' : time(c)).join(' · '), if (e.value.length > 1) context.t('{n} times', {'n': e.value.length})].join('  ·  '),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 20),
    ]);
  }
}
