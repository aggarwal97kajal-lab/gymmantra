import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../haptics.dart';
import '../i18n.dart';
import '../photo.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'home.dart' show openUrl, waLink;

// Money due: the dashboard card, the list with one-tap reminders, taking a payment,
// and the member's own profile details for the gym.

final duesProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/dues'));

/// "Paid ₹5,000 of ₹12,500" with a thin progress bar.
class PaidBar extends StatelessWidget {
  const PaidBar({super.key, required this.paid, required this.total, this.compact = false});
  final num paid;
  final num total;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final f = total <= 0 ? 0.0 : (paid / total).clamp(0, 1).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(context.t('Paid {paid} of {total}', {'paid': rupees(paid), 'total': rupees(total)}), style: TextStyle(color: context.c.mut, fontSize: compact ? 11.5 : 12.5)),
      const SizedBox(height: 5),
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(value: f, minHeight: compact ? 5 : 7, backgroundColor: context.c.surf2, valueColor: const AlwaysStoppedAnimation(C.ok)),
      ),
    ]);
  }
}

/// Owner dashboard: "3 members owe money" with faces and a Review button.
class DueCard extends ConsumerWidget {
  const DueCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(duesProvider).valueOrNull;
    if (d == null || (d['count'] as int? ?? 0) == 0) return const SizedBox.shrink();
    final list = (d['members'] as List).cast<Map>();
    PhotoCache.warm(list.map((m) => m['photoUrl'] as String?));
    final sentToday = _isToday(d['remindedAt'] as String?);
    final oldest = list.isEmpty ? 0 : list.map((m) => m['daysLate'] as int? ?? 0).reduce((a, b) => a > b ? a : b);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Panel(
        onTap: () => showDueSheet(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconTile(sentToday ? Icons.check_rounded : Icons.currency_rupee_rounded, color: sentToday ? C.ok : C.red),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('{n} members owe money', {'n': d['count']}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                Text(
                  sentToday
                      ? context.t('Reminder sent today')
                      : context.t('{amount} due · oldest {n} days', {'amount': rupees(d['total'] as num?), 'n': oldest}),
                  style: TextStyle(color: sentToday ? C.ok : context.c.mut, fontSize: 12.5, fontWeight: sentToday ? FontWeight.w700 : FontWeight.w500),
                ),
              ]),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(
              width: 22.0 * (list.take(4).length) + 10,
              height: 30,
              child: Stack(children: [
                for (var i = 0; i < list.take(4).length; i++)
                  Positioned(
                    left: i * 22.0,
                    child: Container(
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: context.c.surf, width: 2)),
                      child: Avatar(name: list[i]['name'] as String, url: list[i]['photoUrl'] as String?, size: 26),
                    ),
                  ),
              ]),
            ),
            Expanded(child: Muted(context.t('{n} members', {'n': d['count']}), size: 12)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(color: sentToday ? C.ok : context.c.fg, borderRadius: BorderRadius.circular(99)),
              child: Text(context.t(sentToday ? 'Sent' : 'Review'), style: TextStyle(color: sentToday ? Colors.white : context.c.bg, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ]),
        ]),
      ),
    );
  }
}

bool _isToday(String? iso) {
  if (iso == null) return false;
  final t = DateTime.tryParse(iso)?.toLocal();
  final n = DateTime.now();
  return t != null && t.year == n.year && t.month == n.month && t.day == n.day;
}

Future<void> showDueSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _DueSheet(),
    );

class _DueSheet extends ConsumerStatefulWidget {
  const _DueSheet();
  @override
  ConsumerState<_DueSheet> createState() => _DueSheetState();
}

class _DueSheetState extends ConsumerState<_DueSheet> {
  bool busy = false;
  bool sent = false;
  String? note;

  Future<void> remind() async {
    setState(() => busy = true);
    try {
      final r = await Api.instance.post('/dues/remind');
      HapticFeedback.mediumImpact();
      setState(() {
        sent = true;
        final noApp = r['noApp'] as int? ?? 0;
        note = noApp > 0 ? context.t('{n} members don’t use the app — send them WhatsApp from the list', {'n': noApp}) : null;
      });
      ref.invalidate(duesProvider);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(duesProvider);
    final gymName = (ref.watch(sessionProvider).myGym?['name'] as String?) ?? '';
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => AsyncBody(
        value: v,
        builder: (d) {
          final list = ((d as Map)['members'] as List).cast<Map>();
          final alreadyToday = _isToday(d['remindedAt'] as String?);
          final done = sent || alreadyToday;
          return ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(20, 4, 20, 24), children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: context.c.line, borderRadius: BorderRadius.circular(2)))),
            Text(context.t('Money due'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            Text(context.t('{amount} · {n} members', {'amount': rupees(d['total'] as num?), 'n': d['count']}), style: const TextStyle(color: C.red, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (list.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Muted(context.t('Nobody owes money. Nice!'), align: TextAlign.center)),
            for (final m in list)
              InkWell(
                onTap: () {
                  Navigator.pop(context);
                  context.push('/o/member/${m['id']}');
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(children: [
                    Stack(clipBehavior: Clip.none, children: [
                      Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 42),
                      if (done && m['hasApp'] == true)
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            width: 17,
                            height: 17,
                            decoration: BoxDecoration(color: C.ok, shape: BoxShape.circle, border: Border.all(color: context.c.surf, width: 2)),
                            child: const Icon(Icons.check_rounded, size: 10, color: Colors.white),
                          ),
                        ),
                    ]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text.rich(
                          TextSpan(children: [
                            TextSpan(text: '${m['memberCode']} · '),
                            TextSpan(text: context.t('{n} days', {'n': m['daysLate']}), style: const TextStyle(color: C.red)),
                            if (m['hasApp'] != true) TextSpan(text: ' · ${context.t('no app')}'),
                          ]),
                          style: TextStyle(color: context.c.mut, fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        PaidBar(paid: m['paid'] as num, total: m['total'] as num, compact: true),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(rupees(m['due'] as num?), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.chat_rounded, color: C.wa, size: 20),
                        onPressed: () => openUrl(waLink(
                          m['phone'] as String,
                          'Hi ${m['name']}, a reminder from $gymName: ${rupees(m['due'] as num?)} is due (paid ${rupees(m['paid'] as num?)} of ${rupees(m['total'] as num?)}). Please pay at the front desk. Thank you!',
                        )),
                      ),
                    ]),
                  ]),
                ),
              ),
            const SizedBox(height: 12),
            if (list.isNotEmpty)
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: done ? C.ok : context.c.fg, foregroundColor: done ? Colors.white : context.c.bg, minimumSize: const Size.fromHeight(52)),
                onPressed: busy || done ? null : remind,
                icon: Icon(done ? Icons.check_rounded : Icons.send_rounded, size: 19),
                label: Text(done ? context.t('Reminder sent') : context.t('Send reminder to {n} members', {'n': list.length})),
              ),
            const SizedBox(height: 8),
            Muted(
              note ?? (done ? context.t('Members see it in notifications and when they open the app. You can send again tomorrow.') : context.t('Each member gets a notification and sees it when they open the app.')),
              size: 12,
              align: TextAlign.center,
            ),
          ]);
        },
      ),
    );
  }
}

/// What still has money due, per membership, with a "Take payment" button.
class OwingBox extends StatelessWidget {
  const OwingBox({super.key, required this.sub, required this.onPay, this.current = false});
  final Map sub;
  final VoidCallback onPay;
  final bool current;
  @override
  Widget build(BuildContext context) {
    final due = (sub['due'] as num?) ?? 0;
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.red.withAlpha(16), borderRadius: BorderRadius.circular(14), border: Border.all(color: C.red.withAlpha(70))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${sub['planName']}${current ? '' : ' · ${context.t('earlier')}'}', style: const TextStyle(fontWeight: FontWeight.w700)),
              Muted('${fmtDate(sub['startDate'] as String?)} – ${fmtDate(sub['endDate'] as String?)}', size: 11.5),
            ]),
          ),
          Text(context.t('{amount} due', {'amount': rupees(due)}), style: const TextStyle(color: C.red, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 8),
        PaidBar(paid: sub['paid'] as num, total: sub['total'] as num, compact: true),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: C.ok, minimumSize: const Size.fromHeight(44)),
            onPressed: onPay,
            icon: const Icon(Icons.currency_rupee_rounded, size: 18),
            label: Text(context.t('Take payment ({amount})', {'amount': rupees(due)})),
          ),
        ),
      ]),
    );
  }
}

/// Records money received for one membership. Returns true when saved.
Future<bool> showPaymentSheet(BuildContext context, Map sub) async =>
    await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => _PaymentSheet(sub: sub)) == true;

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.sub});
  final Map sub;
  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  late final num due = (widget.sub['due'] as num?) ?? 0;
  late final amount = TextEditingController(text: '${due.round()}');
  String mode = 'UPI';
  bool busy = false;
  String? error;
  static const modes = [('CASH', 'Cash'), ('UPI', 'UPI'), ('CARD', 'Card'), ('BANK_TRANSFER', 'Bank')];

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final quick = <num>{due, if (due > 1000) (due / 2).roundToDouble(), if (due > 2000) 1000}.where((x) => x > 0).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(2)))),
        Text(context.t('Take payment'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        Muted('${widget.sub['planName']} · ${context.t('{amount} due', {'amount': rupees(due)})}'),
        const SizedBox(height: 14),
        TextField(
          controller: amount,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(prefixText: '₹ '),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          for (final q in quick)
            ChoiceChip(
              label: Text(q == due ? context.t('Full {amount}', {'amount': rupees(q)}) : rupees(q)),
              selected: amount.text == '${q.round()}',
              showCheckmark: false,
              selectedColor: p.primary,
              labelStyle: TextStyle(color: amount.text == '${q.round()}' ? Colors.white : p.fg, fontWeight: FontWeight.w700),
              onSelected: (_) => setState(() => amount.text = '${q.round()}'),
            ),
        ]),
        const SizedBox(height: 14),
        Muted(context.t('How was it paid?'), size: 13),
        const SizedBox(height: 6),
        Seg<String>(value: mode, items: [for (final (k, l) in modes) (k, context.t(l), null)], onChanged: (v) => setState(() => mode = v)),
        if ((num.tryParse(amount.text) ?? 0) >= due) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.ok.withAlpha(28), borderRadius: BorderRadius.circular(12)),
            child: Text(context.t('Full payment: entry opens and "Due" disappears from the member’s app.'), style: const TextStyle(color: C.ok, fontWeight: FontWeight.w700, fontSize: 12.5)),
          ),
        ],
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: busy
              ? null
              : () async {
                  final a = int.tryParse(amount.text.trim()) ?? 0;
                  if (a <= 0) return setState(() => error = context.t('Enter the amount'));
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await Api.instance.post('/memberships/${widget.sub['id']}/payments', {'amount': a, 'mode': mode});
                    TapHaptics.buzz();
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    if (mounted) setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t(busy ? 'Saving…' : 'Save payment')),
        ),
      ]),
    );
  }
}

/// What the member filled in their own app profile (read-only for the gym).
class MemberProfileScreen extends StatelessWidget {
  const MemberProfileScreen({super.key, required this.data});
  final Map data;
  @override
  Widget build(BuildContext context) {
    final m = data['member'] as Map;
    final p = (data['profile'] as Map?) ?? {};
    final visits = (data['visits'] as Map?) ?? {};
    String age(String? dob) {
      final d = DateTime.tryParse(dob ?? '');
      if (d == null) return '';
      final n = DateTime.now();
      var y = n.year - d.year;
      if (n.month < d.month || (n.month == d.month && n.day < d.day)) y--;
      return ' · ${context.t('{n} years', {'n': y})}';
    }

    final fullName = [p['firstName'], p['middleName'], p['lastName']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
    final gender = switch (p['gender'] ?? m['gender']) { 'male' => context.t('Male'), 'female' => context.t('Female'), 'other' => context.t('Other'), _ => null };
    final rows = <(IconData, String, String?)>[
      (Icons.badge_outlined, context.t('Full name'), fullName.isEmpty ? m['name'] as String? : fullName),
      (Icons.cake_outlined, context.t('Date of birth'), p['dob'] == null ? null : '${fmtDate(p['dob'] as String)}${age(p['dob'] as String?)}'),
      (Icons.wc_rounded, context.t('Gender'), gender),
      (Icons.mail_outline_rounded, context.t('Email'), (p['email'] ?? m['email']) as String?),
      (Icons.phone_iphone_rounded, context.t('Mobile number'), (p['phone'] ?? m['phone']) as String?),
      (Icons.place_outlined, context.t('Address'), p['address'] as String?),
      (Icons.event_outlined, context.t('Joined'), fmtDate(m['joinedOn'] as String?)),
      (
        Icons.login_rounded,
        context.t('Last visit'),
        visits['lastAt'] == null ? null : '${fmtDateTime(visits['lastAt'] as String)} · ${context.t('{n} visits this month', {'n': visits['thisMonth'] ?? 0})}'
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.t('{name}’s profile', {'name': (m['name'] as String).split(' ').first}))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Center(child: Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 84, ring: true)),
        const SizedBox(height: 14),
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            for (var i = 0; i < rows.length; i++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  IconTile(rows[i].$1, size: 34, color: context.c.fg),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Muted(rows[i].$2, size: 12),
                      Text(rows[i].$3 ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ]),
              ),
              if (i < rows.length - 1) Divider(height: 1, color: context.c.line),
            ],
          ]),
        ),
        const SizedBox(height: 10),
        Muted(
          m['hasApp'] == true ? context.t('The member fills these in their app. Only they can change them.') : context.t('This member does not use the app yet, so only the details you added are shown.'),
          size: 12,
        ),
      ]),
    );
  }
}

// ============================================================ plan "Interested" requests

final leadsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/leads'));

class LeadsList extends ConsumerWidget {
  const LeadsList({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(leadsProvider);
    final gymName = (ref.watch(sessionProvider).myGym?['name'] as String?) ?? '';
    return AsyncBody(
      value: v,
      onRetry: () => ref.invalidate(leadsProvider),
      builder: (d) {
        final list = (d as List).cast<Map>();
        if (list.isEmpty) {
          return ListView(padding: const EdgeInsets.all(30), children: [
            const SizedBox(height: 60),
            Icon(Icons.favorite_border_rounded, size: 52, color: context.c.mut),
            const SizedBox(height: 10),
            Muted(context.t('When a member taps "Interested" on a plan, they show here.'), align: TextAlign.center),
          ]);
        }
        return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          for (final l in list) ...[
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Avatar(name: l['name'] as String, url: l['photoUrl'] as String?, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Muted('${context.t('Interested in {plan}', {'plan': l['planName']})} · ${fmtDateTime(l['createdAt'] as String)}', size: 12),
                    ]),
                  ),
                  IconButton(
                    tooltip: context.t('Done'),
                    icon: Icon(Icons.close_rounded, color: context.c.mut),
                    onPressed: () async {
                      await Api.instance.post('/leads/${l['id']}/done').catchError((_) => null);
                      ref.invalidate(leadsProvider);
                    },
                  ),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  if (l['phone'] != null)
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: C.wa),
                        onPressed: () => openUrl(waLink(l['phone'] as String, 'Hi ${l['name']}, thanks for your interest in the ${l['planName']} plan at $gymName. ')),
                        icon: const Icon(Icons.chat_rounded, size: 18),
                        label: const Text('WhatsApp'),
                      ),
                    ),
                  if (l['phone'] != null && l['memberId'] != null) const SizedBox(width: 10),
                  if (l['memberId'] != null)
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () async {
                          await Api.instance.post('/leads/${l['id']}/done').catchError((_) => null);
                          ref.invalidate(leadsProvider);
                          if (context.mounted) context.push('/o/member/${l['memberId']}');
                        },
                        icon: const Icon(Icons.autorenew_rounded, size: 18),
                        label: Text(context.t('Start plan')),
                      ),
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
          ],
        ]);
      },
    );
  }
}
