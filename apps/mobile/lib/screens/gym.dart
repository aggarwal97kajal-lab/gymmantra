import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key});
  @override
  ConsumerState<JoinScreen> createState() => _JoinState();
}

class _JoinState extends ConsumerState<JoinScreen> {
  final code = TextEditingController();
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
    final branches = (gym?['branches'] as List?)?.cast<Map>() ?? [];
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
                    final bs = (g['branches'] as List);
                    branchId = bs.length == 1 ? bs.first['id'] as String : null;
                  });
                }),
            child: Text(context.t('Find gym')),
          )
        else ...[
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(gym!['name'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              if (gym!['address'] != null) Muted(gym!['address']),
            ]),
          ),
          if (branches.length > 1) ...[
            const SizedBox(height: 12),
            Muted(context.t('Choose your branch')),
            for (final b in branches)
              RadioListTile<String>(
                value: b['id'] as String,
                groupValue: branchId,
                onChanged: (v) => setState(() => branchId = v),
                title: Text(b['name']),
                activeColor: context.c.primary,
                contentPadding: EdgeInsets.zero,
              ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || (branches.length > 1 && branchId == null)
                ? null
                : () => run(() async {
                      await Api.instance.post('/me/join', {'gymCode': code.text.trim(), if (branchId != null) 'branchId': branchId});
                      ref.invalidate(gymsProvider);
                      if (mounted) {
                        toast(context, context.t('Request sent to {gym}', {'gym': gym!['name']}));
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

class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key, required this.tenantId});
  final String tenantId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(plansProvider(tenantId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gym plans'))),
      body: AsyncBody(
        value: v,
        builder: (d) {
          final plans = (d as List).cast<Map>();
          if (plans.isEmpty) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Muted(context.t('Your gym has not listed plans in the app yet.'), align: TextAlign.center)));
          return ListView(padding: const EdgeInsets.all(16), children: [
            Muted(context.t('To buy or renew, contact your gym. They will update your membership here.')),
            const SizedBox(height: 12),
            for (final p in plans) ...[
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p['name'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: rupees(p['price']), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: context.c.primary)),
                    TextSpan(text: '  /  ${context.t('{n} months', {'n': p['months']})}', style: TextStyle(color: context.c.mut)),
                  ])),
                  if ((p['joiningFee'] as int) > 0) Muted(context.t('+ {fee} joining fee for new members', {'fee': rupees(p['joiningFee'])}), size: 12),
                  if ((p['freezeDays'] as int) > 0) Muted(context.t('{n} freeze days', {'n': p['freezeDays']}), size: 12),
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final f in (p['features'] as List))
                      Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: context.c.surf2, borderRadius: BorderRadius.circular(99)), child: Text('$f', style: const TextStyle(fontSize: 12))),
                  ]),
                ]),
              ),
              const SizedBox(height: 10),
            ],
          ]);
        },
      ),
    );
  }
}
