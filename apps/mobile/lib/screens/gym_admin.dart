import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api.dart';
import '../haptics.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show LabeledField;
import 'home.dart' show openUrl, waLink;

// Owner tools that used to be on the website only: reports, membership plans and gym settings.

final reportsProvider = StreamProvider.autoDispose.family<dynamic, int>((ref, days) => Api.instance.cachedGet('/reports?days=$days'));
final ownerPlansProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/plans'));

// ============================================================ reports

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsState();
}

class _ReportsState extends ConsumerState<ReportsScreen> {
  int days = 30;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(reportsProvider(days));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Reports'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(reportsProvider(days)),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          Seg<int>(
            value: days,
            items: [(7, context.t('7 days'), null), (30, context.t('30 days'), null), (90, context.t('90 days'), null)],
            onChanged: (d) {
              TapHaptics.buzz();
              setState(() => days = d);
            },
          ),
          const SizedBox(height: 14),
          AsyncBody(
            value: v,
            onRetry: () => ref.invalidate(reportsProvider(days)),
            builder: (d) => _ReportBody(d: d as Map),
          ),
        ]),
      ),
    );
  }
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.d});
  final Map d;
  @override
  Widget build(BuildContext context) {
    final t = d['totals'] as Map;
    final series = (d['series'] as List).cast<Map>();
    final status = (d['status'] as Map?) ?? {};
    final plans = (d['plans'] as List).cast<Map>();
    final due = (d['topDue'] as List).cast<Map>();
    Widget pair(Widget a, Widget b) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Muted('${fmtDate(d['from'] as String)} – ${fmtDate(d['to'] as String)}', size: 12.5),
      const SizedBox(height: 10),
      pair(
        StatTile(icon: Icons.payments_rounded, value: rupees(t['collected'] as num), label: context.t('Money collected'), color: C.ok),
        StatTile(icon: Icons.receipt_rounded, value: '${t['payments']}', label: context.t('Payments')),
      ),
      pair(
        StatTile(icon: Icons.card_membership_rounded, value: '${t['sold']}', label: context.t('Memberships sold')),
        StatTile(icon: Icons.person_add_alt_1_rounded, value: '${t['newMembers']}', label: context.t('New members'), color: C.blue),
      ),
      pair(
        StatTile(icon: Icons.login_rounded, value: '${t['checkins']}', label: context.t('Check-ins')),
        StatTile(icon: Icons.av_timer_rounded, value: '${t['avgCheckins']}', label: context.t('Check-ins a day')),
      ),
      const SizedBox(height: 6),
      SectionTitle(context.t('Money collected')),
      Panel(child: _Bars(values: [for (final s in series) (s['collected'] as num).toDouble()], dates: [for (final s in series) s['date'] as String], color: C.ok, money: true)),
      const SizedBox(height: 14),
      SectionTitle(context.t('Check-ins')),
      Panel(child: _Bars(values: [for (final s in series) (s['checkins'] as num).toDouble()], dates: [for (final s in series) s['date'] as String], color: context.c.primary)),
      const SizedBox(height: 14),
      SectionTitle(context.t('Members now')),
      Panel(
        child: Column(children: [
          for (final k in ['ACTIVE', 'ENDING_SOON', 'EXPIRED', 'FROZEN', 'UPCOMING', 'NO_PLAN'])
            if ((status[k] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  StatusChip(k),
                  const Spacer(),
                  Text('${status[k]}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                ]),
              ),
          if (status.isEmpty) Muted(context.t('No members yet')),
          const Divider(height: 20),
          Row(children: [
            Expanded(child: Text(context.t('Total members'), style: const TextStyle(fontWeight: FontWeight.w700))),
            Text('${t['members']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ]),
        ]),
      ),
      const SizedBox(height: 14),
      SectionTitle(context.t('Plans')),
      if (plans.isEmpty)
        Muted(context.t('No memberships in this period'))
      else
        Panel(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(children: [
            for (final p in plans)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      Muted(context.t('{n} active · {s} sold', {'n': p['active'], 's': p['sold']}), size: 12),
                    ]),
                  ),
                  Text(rupees(p['amount'] as num), style: const TextStyle(fontWeight: FontWeight.w800)),
                ]),
              ),
          ]),
        ),
      const SizedBox(height: 14),
      SectionTitle(context.t('Money due'), trailing: Text(rupees(t['dueAmount'] as num), style: const TextStyle(fontWeight: FontWeight.w800, color: C.red))),
      if (due.isEmpty)
        Muted(context.t('Nobody owes money. Nice!'))
      else
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (final m in due)
              ListTile(
                dense: true,
                title: Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${m['memberCode']}${m['planName'] != null ? ' · ${m['planName']}' : ''}'),
                trailing: Text(rupees(m['due'] as num), style: const TextStyle(fontWeight: FontWeight.w800, color: C.red)),
                onTap: () => context.push('/o/member/${m['id']}'),
              ),
          ]),
        ),
    ]);
  }
}

/// Simple bar chart; tap a bar to see that day's number.
class _Bars extends StatefulWidget {
  const _Bars({required this.values, required this.dates, required this.color, this.money = false});
  final List<double> values;
  final List<String> dates;
  final Color color;
  final bool money;
  @override
  State<_Bars> createState() => _BarsState();
}

class _BarsState extends State<_Bars> {
  int? sel;
  @override
  Widget build(BuildContext context) {
    final vals = widget.values;
    final max = vals.fold<double>(0, (m, v) => v > m ? v : m);
    final total = vals.fold<double>(0, (n, v) => n + v);
    final i = sel;
    String fmt(double v) => widget.money ? rupees(v) : v.round().toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(i == null ? fmt(total) : fmt(vals[i]), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      Muted(i == null ? context.t('Total') : fmtDate(widget.dates[i]), size: 12),
      const SizedBox(height: 12),
      SizedBox(
        height: 120,
        child: LayoutBuilder(builder: (context, box) {
          final n = vals.length;
          final gap = n > 40 ? 1.0 : 3.0;
          final w = (box.maxWidth - gap * (n - 1)) / n;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (e) => setState(() => sel = (e.localPosition.dx / (w + gap)).floor().clamp(0, n - 1)),
            onHorizontalDragUpdate: (e) => setState(() => sel = (e.localPosition.dx / (w + gap)).floor().clamp(0, n - 1)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (var k = 0; k < n; k++) ...[
                if (k > 0) SizedBox(width: gap),
                Container(
                  width: w,
                  height: max == 0 ? 3 : 3 + (vals[k] / max) * 117,
                  decoration: BoxDecoration(
                    color: sel == null || sel == k ? widget.color : widget.color.withAlpha(90),
                    borderRadius: BorderRadius.circular(w > 6 ? 4 : 1.5),
                  ),
                ),
              ],
            ]),
          );
        }),
      ),
      const SizedBox(height: 6),
      Row(children: [Muted(fmtDate(widget.dates.first), size: 11), const Spacer(), Muted(fmtDate(widget.dates.last), size: 11)]),
    ]);
  }
}

// ============================================================ membership plans

class ManagePlansScreen extends ConsumerWidget {
  const ManagePlansScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    final v = ref.watch(ownerPlansProvider);
    Future<void> edit([Map? plan]) async {
      final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => _PlanSheet(plan: plan));
      if (ok == true) ref.invalidate(ownerPlansProvider);
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t('Membership plans'))),
      floatingActionButton: owner
          ? FloatingActionButton.extended(onPressed: () => edit(), icon: const Icon(Icons.add_rounded), label: Text(context.t('New plan')))
          : null,
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(ownerPlansProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(ownerPlansProvider),
          builder: (d) {
            final plans = (d as List).cast<Map>();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
              if (!owner) Padding(padding: const EdgeInsets.only(bottom: 12), child: Muted(context.t('Only the gym owner can create or change plans.'))),
              if (plans.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 40),
                  child: Muted(context.t('No plans yet. Create your first plan, for example Monthly, Quarterly and Annual.'), align: TextAlign.center),
                ),
              for (final p in plans) ...[
                Opacity(
                  opacity: p['active'] == false ? 0.55 : 1,
                  child: Panel(
                    onTap: owner ? () => edit(p) : null,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(p['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                        if (p['showInApp'] == false) _Tag(context.t('Hidden in app')),
                        if (p['active'] == false) ...[const SizedBox(width: 6), _Tag(context.t('Inactive'))],
                        if (owner) Icon(Icons.edit_rounded, size: 18, color: context.c.mut),
                      ]),
                      const SizedBox(height: 6),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: rupees(p['price'] as num), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                        TextSpan(text: '  / ${context.t(p['months'] == 1 ? '1 month' : '{n} months', {'n': p['months']})}', style: TextStyle(color: context.c.mut)),
                      ])),
                      const SizedBox(height: 4),
                      Muted(
                        '${(p['joiningFee'] ?? 0) > 0 ? context.t('Joining fee {fee}', {'fee': rupees(p['joiningFee'] as num)}) : context.t('No joining fee')} · ${context.t('{n} freeze days', {'n': p['freezeDays'] ?? 0})}',
                        size: 12.5,
                      ),
                      if ((p['features'] as List?)?.isNotEmpty == true) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 6, runSpacing: 6, children: [for (final f in (p['features'] as List)) _Tag(f as String)]),
                      ],
                      const Divider(height: 22),
                      Muted(context.t('{n} active members', {'n': p['activeMembers'] ?? 0}), size: 12.5),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: context.c.surf2, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: context.c.mut)),
      );
}

class _PlanSheet extends StatefulWidget {
  const _PlanSheet({this.plan});
  final Map? plan;
  @override
  State<_PlanSheet> createState() => _PlanSheetState();
}

class _PlanSheetState extends State<_PlanSheet> {
  late final p = widget.plan;
  late final name = TextEditingController(text: p?['name'] as String? ?? '');
  late final months = TextEditingController(text: '${p?['months'] ?? 1}');
  late final price = TextEditingController(text: p == null ? '' : '${p!['price']}');
  late final fee = TextEditingController(text: '${p?['joiningFee'] ?? 0}');
  late final freeze = TextEditingController(text: '${p?['freezeDays'] ?? 0}');
  late final features = TextEditingController(text: ((p?['features'] as List?) ?? const []).join('\n'));
  late bool showInApp = p?['showInApp'] != false;
  late bool active = p?['active'] != false;
  bool busy = false;
  String? error;

  int n(TextEditingController c) => int.tryParse(c.text.trim()) ?? 0;

  Future<void> save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final body = {
        'name': name.text.trim(),
        'months': n(months),
        'price': n(price),
        'joiningFee': n(fee),
        'freezeDays': n(freeze),
        'features': features.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        'showInApp': showInApp,
        'active': active,
      };
      if (p == null) {
        await Api.instance.post('/plans', body);
      } else {
        await Api.instance.patch('/plans/${p!['id']}', body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const kb = TextInputType.number;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
        Text(context.t(p == null ? 'New plan' : 'Edit plan'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        LabeledField(label: context.t('Plan name'), controller: name, hint: context.t('e.g. Quarterly'), caps: TextCapitalization.words),
        Row(children: [
          Expanded(child: LabeledField(label: context.t('Duration (months)'), controller: months, keyboard: kb)),
          const SizedBox(width: 10),
          Expanded(child: LabeledField(label: context.t('Price (₹)'), controller: price, keyboard: kb)),
        ]),
        Row(children: [
          Expanded(child: LabeledField(label: context.t('Joining fee (₹)'), controller: fee, keyboard: kb)),
          const SizedBox(width: 10),
          Expanded(child: LabeledField(label: context.t('Freeze days allowed'), controller: freeze, keyboard: kb)),
        ]),
        Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(context.t("What's included (one per line)"), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.mut))),
        TextField(controller: features, minLines: 3, maxLines: 6, decoration: InputDecoration(hintText: context.t('Gym floor\nLocker\nDiet chart'))),
        const SizedBox(height: 8),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: showInApp, onChanged: (v) => setState(() => showInApp = v), title: Text(context.t('Show in member app'))),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setState(() => active = v), title: Text(context.t('Active (can be assigned)'))),
        if (p != null && '${p!['price']}' != price.text.trim())
          Muted(context.t('Price changes apply to new and renewed memberships only. Existing members keep their recorded price.'), size: 12.5),
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t(busy ? 'Saving…' : 'Save plan'))),
      ]),
    );
  }
}

// ============================================================ gym settings

class GymSettingsScreen extends ConsumerStatefulWidget {
  const GymSettingsScreen({super.key});
  @override
  ConsumerState<GymSettingsScreen> createState() => _GymSettingsState();
}

class _GymSettingsState extends ConsumerState<GymSettingsScreen> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final wa = TextEditingController();
  final prefix = TextEditingController();
  bool allowDue = false;
  bool filled = false;
  bool busy = false;
  String? error;

  String local(dynamic s) => ((s as String?) ?? '').replaceFirst('+91', '');

  Future<void> save() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    final saved = context.t('Saved');
    try {
      await Api.instance.patch('/gym', {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        'whatsappNumber': wa.text.trim(),
        'memberCodePrefix': prefix.text.trim().toUpperCase(),
        'allowEntryWhenDue': allowDue,
      });
      ref.invalidate(gymProvider);
      await ref.read(sessionProvider).refreshUser();
      if (mounted) toast(context, saved);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addBranch(Map g) async {
    final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, useSafeArea: true, builder: (_) => const _BranchSheet());
    if (ok == true) ref.invalidate(gymProvider);
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(gymProvider);
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gym settings'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(gymProvider),
        builder: (d) {
          final g = d as Map;
          if (!filled) {
            filled = true;
            name.text = (g['name'] as String?) ?? '';
            phone.text = local(g['phone']);
            wa.text = local(g['whatsappNumber']);
            prefix.text = (g['memberCodePrefix'] as String?) ?? '';
            allowDue = g['allowEntryWhenDue'] == true;
          }
          final branches = ((g['branches'] as List?) ?? const []).cast<Map>();
          final limits = (g['limits'] as Map?) ?? {};
          final code = g['gymCode'] as String;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            if (!owner) Padding(padding: const EdgeInsets.only(bottom: 12), child: Muted(context.t('Only the gym owner can change these settings.'))),
            SectionTitle(context.t('Gym profile')),
            Panel(
              child: Column(children: [
                LabeledField(label: context.t('Gym name'), controller: name, icon: Icons.storefront_rounded, caps: TextCapitalization.words),
                LabeledField(label: context.t('Gym phone'), controller: phone, icon: Icons.call_rounded, keyboard: TextInputType.phone),
                LabeledField(label: context.t('Gym WhatsApp number'), controller: wa, icon: Icons.chat_rounded, keyboard: TextInputType.phone),
                Padding(
                  padding: const EdgeInsets.only(top: 0, bottom: 12),
                  child: Muted(context.t('Shown to members. Reminders and receipts go from this number.'), size: 12),
                ),
                LabeledField(label: context.t('Member ID prefix'), controller: prefix, icon: Icons.badge_rounded, caps: TextCapitalization.characters),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Muted(context.t('New members get IDs like {id}', {'id': '${prefix.text.isEmpty ? 'GM' : prefix.text.toUpperCase()}-1001'}), size: 12),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: allowDue,
                  onChanged: owner ? (x) => setState(() => allowDue = x) : null,
                  title: Text(context.t('"Not paid yet" members can enter by default'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text(context.t('Staff can still change it for each membership.'), style: TextStyle(color: context.c.mut, fontSize: 12)),
                ),
                ErrorText(error),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: FilledButton(onPressed: busy || !owner ? null : save, child: Text(context.t(busy ? 'Saving…' : 'Save changes')))),
              ]),
            ),
            const SizedBox(height: 16),
            SectionTitle(
              context.t('Branches'),
              trailing: Muted(context.t('{n} of {max} on your plan', {'n': branches.length, 'max': limits['branchLimit'] ?? 1}), size: 12),
            ),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final b in branches)
                  ListTile(
                    leading: const IconTile(Icons.place_rounded, size: 36),
                    title: Text(b['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text([b['address'], b['hours']].where((x) => x != null && '$x'.isNotEmpty).join(' · ').ifEmpty('—')),
                  ),
                if (owner)
                  ListTile(
                    leading: Icon(Icons.add_circle_outline_rounded, color: context.c.primary),
                    title: Text(context.t('Add branch'), style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700)),
                    onTap: () => addBranch(g),
                  ),
              ]),
            ),
            const SizedBox(height: 16),
            SectionTitle(context.t('Join poster')),
            Panel(
              color: Colors.white,
              child: Column(children: [
                Text(g['name'] as String, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF0F1110), fontWeight: FontWeight.w900, fontSize: 22)),
                const SizedBox(height: 2),
                Text(context.t('Join us on the GymMantra app'), style: const TextStyle(color: Color(0xFF0F1110), fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                QrImageView(data: 'gymmantra-join:$code', size: 190, backgroundColor: Colors.white),
                const SizedBox(height: 6),
                Text(context.t('or enter gym code'), style: const TextStyle(color: Color(0xFF0F1110), fontSize: 13)),
                Text(code, style: const TextStyle(color: Color(0xFF0F1110), fontWeight: FontWeight.w900, fontSize: 30, letterSpacing: 2)),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: code));
                    toast(context, context.t('Gym code copied'));
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(context.t('Copy code')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: C.wa),
                  onPressed: () => openUrl(waLink('', context.t('Join {gym} on the GymMantra app. Gym code: {code}', {'gym': g['name'], 'code': code}))),
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: Text(context.t('Share')),
                ),
              ),
            ]),
          ]);
        },
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _BranchSheet extends StatefulWidget {
  const _BranchSheet();
  @override
  State<_BranchSheet> createState() => _BranchSheetState();
}

class _BranchSheetState extends State<_BranchSheet> {
  final name = TextEditingController();
  final address = TextEditingController();
  final hours = TextEditingController();
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), children: [
          Text(context.t('Add branch'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          LabeledField(label: context.t('Branch name'), controller: name, icon: Icons.storefront_rounded, caps: TextCapitalization.words),
          LabeledField(label: context.t('Address'), controller: address, icon: Icons.place_rounded),
          LabeledField(label: context.t('Timings'), controller: hours, icon: Icons.schedule_rounded, hint: '6 AM – 10 PM'),
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
                      await Api.instance.post('/gym/branches', {
                        'name': name.text.trim(),
                        if (address.text.trim().isNotEmpty) 'address': address.text.trim(),
                        if (hours.text.trim().isNotEmpty) 'hours': hours.text.trim(),
                      });
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      if (mounted) setState(() => error = e.toString());
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: Text(context.t('Add branch')),
          ),
        ]),
      );
}

// ============================================================ notices

final noticesProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/notices'));

String _noticeAudience(BuildContext context, Map n) {
  final parts = <String>[];
  if (n['forMembers'] == true) {
    parts.add(switch (n['memberFilter']) {
      'ACTIVE' => context.t('Active members'),
      'EXPIRED' => context.t('Expired members'),
      _ => context.t('All members'),
    });
  }
  if (n['forTrainers'] == true) parts.add(context.t('Trainers'));
  return parts.join(' + ');
}

String _noticeShareText(Map n, String? gym) => '📢 ${gym ?? ''}\n*${n['title']}*\n${n['message']}';

class NoticesScreen extends ConsumerWidget {
  const NoticesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(noticesProvider);
    final gymName = ref.watch(sessionProvider).myGym?['name'] as String?;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Notices'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/o/notices/new'),
        icon: const Icon(Icons.campaign_rounded),
        label: Text(context.t('New notice')),
      ),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(noticesProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(noticesProvider),
          builder: (d) {
            final list = (d as List).cast<Map>();
            if (list.isEmpty) {
              return ListView(padding: const EdgeInsets.all(28), children: [
                const SizedBox(height: 40),
                Icon(Icons.campaign_outlined, size: 64, color: context.c.mut),
                const SizedBox(height: 12),
                Text(context.t('No notices yet'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Muted(context.t('Tell members or trainers about a holiday, gym closed, new timings or anything else. It shows on their dashboard and in notifications.'), align: TextAlign.center),
              ]);
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
              for (final n in list) ...[
                Panel(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: (n['live'] == true ? C.ok : context.c.mut).withAlpha(40), borderRadius: BorderRadius.circular(20)),
                        child: Text(context.t(n['live'] == true ? 'Showing' : 'Ended'),
                            style: TextStyle(color: n['live'] == true ? C.ok : context.c.mut, fontSize: 11, fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Muted(_noticeAudience(context, n), size: 12, maxLines: 1)),
                      Muted(fmtDate(n['createdAt'] as String), size: 11.5),
                    ]),
                    const SizedBox(height: 8),
                    Text(n['title'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 2),
                    Text(n['message'] as String, style: const TextStyle(height: 1.35)),
                    const SizedBox(height: 6),
                    Muted(context.t('Shows till {date}', {'date': fmtDate(n['showTill'] as String)}), size: 12),
                    const Divider(height: 18),
                    Row(children: [
                      TextButton.icon(
                        onPressed: () => openUrl(waLink('', _noticeShareText(n, gymName))),
                        icon: const Icon(Icons.share_rounded, size: 18, color: C.wa),
                        label: Text(context.t('WhatsApp'), style: const TextStyle(color: C.wa)),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (c) => AlertDialog(
                              title: Text(context.t('Remove this notice?')),
                              content: Text(context.t('Members and trainers will no longer see it.')),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('Cancel'))),
                                TextButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('Remove'), style: const TextStyle(color: C.red))),
                              ],
                            ),
                          );
                          if (ok != true) return;
                          try {
                            await Api.instance.delete('/notices/${n['id']}');
                            ref.invalidate(noticesProvider);
                          } catch (e) {
                            if (context.mounted) toast(context, e.toString());
                          }
                        },
                        icon: const Icon(Icons.delete_outline_rounded, size: 18, color: C.red),
                        label: Text(context.t('Remove'), style: const TextStyle(color: C.red)),
                      ),
                    ]),
                  ]),
                ),
                const SizedBox(height: 12),
              ],
            ]);
          },
        ),
      ),
    );
  }
}

class NewNoticeScreen extends ConsumerStatefulWidget {
  const NewNoticeScreen({super.key});
  @override
  ConsumerState<NewNoticeScreen> createState() => _NewNoticeState();
}

class _NewNoticeState extends ConsumerState<NewNoticeScreen> {
  final title = TextEditingController();
  final message = TextEditingController();
  bool members = true;
  bool trainers = false;
  String filter = 'ALL';
  int showDays = 2; // today + 2 more days
  DateTime? custom;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    title.addListener(() => setState(() {}));
  }

  static const templates = [
    ('Gym closed tomorrow', 'The gym will stay closed tomorrow. See you the day after!'),
    ('Holiday', 'The gym is closed on the holiday. Normal timings from the next day.'),
    ('Timing change', 'From tomorrow the gym opens at 6 AM and closes at 10 PM.'),
    ('Renew your membership', 'Your membership is ending soon. Renew at the front desk to keep training.'),
  ];

  DateTime get _istToday {
    final n = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
    return DateTime(n.year, n.month, n.day);
  }

  DateTime get till => custom ?? _istToday.add(Duration(days: showDays));
  String ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> send() async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    final sent = context.t('Notice sent');
    try {
      await Api.instance.post('/notices', {
        'title': title.text.trim(),
        'message': message.text.trim(),
        'forMembers': members,
        'forTrainers': trainers,
        'memberFilter': filter,
        'showTill': ymd(till),
      });
      ref.invalidate(noticesProvider);
      if (mounted) {
        toast(context, sent);
        context.pop();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _who(IconData icon, String label, String sub, bool on, VoidCallback tap) {
    final p = context.c;
    return Expanded(
      child: Material(
        color: on ? p.primary.withAlpha(30) : p.surf,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: on ? p.primary : p.line, width: on ? 1.6 : 1)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: tap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: on ? p.primary : p.mut),
                const Spacer(),
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined, size: 20, color: on ? p.primary : p.mut),
              ]),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
              Muted(sub, size: 11.5),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final gymName = ref.watch(sessionProvider).myGym?['name'] as String?;
    Widget dayChip(String label, int d) {
      final on = custom == null && showDays == d;
      return ChoiceChip(
        label: Text(label),
        selected: on,
        showCheckmark: false,
        selectedColor: p.primary,
        labelStyle: TextStyle(color: on ? Colors.white : p.fg, fontWeight: FontWeight.w700),
        onSelected: (_) => setState(() {
          custom = null;
          showDays = d;
        }),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(context.t('New notice'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Muted(context.t('Quick start'), size: 13),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (t, m) in templates)
            ActionChip(
              avatar: const Icon(Icons.bolt_rounded, size: 16),
              label: Text(context.t(t)),
              onPressed: () => setState(() {
                title.text = context.t(t);
                message.text = context.t(m);
              }),
            ),
        ]),
        const SizedBox(height: 16),
        LabeledField(label: context.t('Heading'), controller: title, icon: Icons.title_rounded, hint: context.t('e.g. Gym closed tomorrow'), caps: TextCapitalization.sentences),
        Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(context.t('Message'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.mut))),
        TextField(
          controller: message,
          minLines: 3,
          maxLines: 6,
          maxLength: 600,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(hintText: context.t('Write what members or trainers should know')),
        ),
        const SizedBox(height: 10),
        Text(context.t('Send to'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 8),
        Row(children: [
          _who(Icons.groups_rounded, context.t('Members'), context.t('On their app dashboard'), members, () => setState(() => members = !members)),
          const SizedBox(width: 10),
          _who(Icons.sports_rounded, context.t('Trainers'), context.t('On the trainer dashboard'), trainers, () => setState(() => trainers = !trainers)),
        ]),
        if (members) ...[
          const SizedBox(height: 12),
          Muted(context.t('Which members?'), size: 13),
          const SizedBox(height: 6),
          Seg<String>(
            value: filter,
            items: [('ALL', context.t('All'), null), ('ACTIVE', context.t('Active'), null), ('EXPIRED', context.t('Expired'), null)],
            onChanged: (v) => setState(() => filter = v),
          ),
        ],
        const SizedBox(height: 16),
        Text(context.t('Show on dashboard till'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          dayChip(context.t('Today'), 0),
          dayChip(context.t('Tomorrow'), 1),
          dayChip(context.t('3 days'), 2),
          dayChip(context.t('1 week'), 6),
          ActionChip(
            avatar: Icon(Icons.event_rounded, size: 16, color: custom != null ? Colors.white : p.fg),
            backgroundColor: custom != null ? p.primary : null,
            label: Text(custom != null ? fmtDate(ymd(custom!)) : context.t('Pick date'), style: TextStyle(color: custom != null ? Colors.white : p.fg, fontWeight: FontWeight.w700)),
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: till, firstDate: _istToday, lastDate: _istToday.add(const Duration(days: 90)));
              if (d != null) setState(() => custom = d);
            },
          ),
        ]),
        const SizedBox(height: 6),
        Muted(context.t('It also stays in their notifications.'), size: 12),
        const SizedBox(height: 18),
        Muted(context.t('Preview'), size: 13),
        const SizedBox(height: 8),
        NoticeBanner(
          title: title.text.trim().isEmpty ? context.t('Heading') : title.text.trim(),
          message: message.text.trim().isEmpty ? context.t('Message') : message.text.trim(),
          gym: gymName,
        ),
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: busy || (!members && !trainers) ? null : send,
          icon: const Icon(Icons.send_rounded, size: 18),
          label: Text(context.t(busy ? 'Sending…' : 'Send notice')),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => openUrl(waLink('', _noticeShareText({'title': title.text.trim(), 'message': message.text.trim()}, gymName))),
          icon: const Icon(Icons.share_rounded, size: 18, color: C.wa),
          label: Text(context.t('Also share on WhatsApp group'), style: const TextStyle(color: C.wa)),
        ),
      ]),
    );
  }
}
