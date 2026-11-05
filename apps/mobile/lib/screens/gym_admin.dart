import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api.dart';
import '../haptics.dart';
import '../i18n.dart';
import '../photo.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show LabeledField, PhoneField;
import 'home.dart' show openUrl, waLink;
import 'branch.dart';
import 'banner.dart' show LogoPickerRow, pickLogo, uploadLogo;
import 'billing.dart' show Address, AddressFields;
import 'reports_kit.dart';

// Owner tools that used to be on the website only: reports, membership plans and gym settings.

final reportsProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, q) => branchGet(ref, '/reports?$q'));
final ownerPlansProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/plans'));

// ============================================================ reports

String _ymdR(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

final reportEntriesProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, q) => branchGet(ref, '/reports/entries?$q'));

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});
  @override
  ConsumerState<ReportsScreen> createState() => _ReportsState();
}

class _ReportsState extends ConsumerState<ReportsScreen> {
  int view = 0; // 0 entries, 1 summary
  ReportRange range = ReportRange.days(30);
  ReportRange get summaryRange => !range.custom && range.days! > 90 ? ReportRange.days(90) : range;
  String tab = 'ALL';
  final q = TextEditingController();
  Set<String> types = {}; // MEMBERSHIP, PT (empty = all)
  int? minAmount;

  int get filterCount => (types.isEmpty ? 0 : 1) + (minAmount == null ? 0 : 1);

  List<Map> apply(List<Map> all) {
    final needle = q.text.trim().toLowerCase();
    return all.where((e) {
      if (tab != 'ALL' && e['status'] != tab) return false;
      if (types.isNotEmpty && !types.contains(e['kind'])) return false;
      if (minAmount != null && (e['total'] as num) < minAmount!) return false;
      if (needle.isNotEmpty) {
        final hay = '${e['name']} ${e['memberCode']} ${e['title']}'.toLowerCase();
        if (!hay.contains(needle)) return false;
      }
      return true;
    }).toList();
  }

  Future<void> filters() async {
    var t = {...types};
    var d = range.custom ? 0 : range.days!;
    final min = TextEditingController(text: minAmount?.toString() ?? '');
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final p = ctx.c;
        Widget chip(String label, bool on, VoidCallback tap) => ChoiceChip(
              label: Text(label),
              selected: on,
              showCheckmark: false,
              selectedColor: p.primary,
              labelStyle: TextStyle(color: on ? Colors.white : p.fg, fontWeight: FontWeight.w700),
              onSelected: (_) => set(tap),
            );
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 14), decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(2)))),
            Text(ctx.t('Filter'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Muted(ctx.t('Type'), size: 13),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              chip(ctx.t('Membership'), t.contains('MEMBERSHIP'), () => t.contains('MEMBERSHIP') ? t.remove('MEMBERSHIP') : t.add('MEMBERSHIP')),
              chip('PT', t.contains('PT'), () => t.contains('PT') ? t.remove('PT') : t.add('PT')),
            ]),
            const SizedBox(height: 14),
            Muted(ctx.t('Date'), size: 13),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (n, l) in [(7, '7 days'), (30, '30 days'), (90, '90 days'), (365, 'This year')]) chip(ctx.t(l), d == n, () => d = n),
              if (range.custom) chip('${fmtDate(_ymdR(range.from!))} – ${fmtDate(_ymdR(range.to!))}', d == 0, () => d = 0),
            ]),
            const SizedBox(height: 14),
            Muted(ctx.t('Amount at least (₹)'), size: 13),
            const SizedBox(height: 6),
            TextField(controller: min, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: const InputDecoration(hintText: '1000')),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () => set(() {
                    t = {};
                    d = 30;
                    min.clear();
                  }),
                  child: Text(ctx.t('Clear all')),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Show')))),
            ]),
          ]),
        );
      }),
    );
    if (ok == true) {
      setState(() {
        types = t;
        if (d != 0) range = ReportRange.days(d);
        minAmount = int.tryParse(min.text.trim());
      });
    }
  }

  String get rangeLabel => range.custom ? '${fmtDate(_ymdR(range.from!))} – ${fmtDate(_ymdR(range.to!))}' : 'last ${range.days} days';

  Future<void> download(List<Map> rows, {required bool pdf}) async {
    final gym = (ref.read(sessionProvider).myGym?['name'] as String?) ?? 'Gym';
    final base = '${gym}_report_${range.custom ? '${_ymdR(range.from!)}_${_ymdR(range.to!)}' : '${range.days}d'}';
    final safe = base.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    try {
      if (pdf) {
        final bytes = await simplePdf(
          '$gym · Report · $rangeLabel',
          [for (final e in rows) ['${e['date']}', '${e['name']}', '${e['memberCode']}', '${e['title']}', rupees(e['total'] as num?), rupees(e['paid'] as num?), rupees(e['due'] as num?), '${e['status']}']],
          head: ['Date', 'Member', 'Code', 'Item', 'Total', 'Paid', 'Due', 'Status'],
        );
        if (mounted) await saveAndOffer(context, '$safe.pdf', bytes, 'application/pdf');
      } else {
        String cell(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
        final lines = [
          'Date,Member,Code,Type,Item,Start,End,Total,Paid,Due,Status',
          for (final e in rows) [e['date'], e['name'], e['memberCode'], e['type'], e['title'], e['startDate'], e['endDate'], e['total'], e['paid'], e['due'], e['status']].map(cell).join(','),
        ];
        if (mounted) await saveAndOffer(context, '$safe.csv', utf8.encode('\uFEFF${lines.join('\n')}'), 'text/csv');
      }
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  Future<void> downloadSheet(List<Map> rows) => showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(rangeLabel, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              Muted(ctx.t('{n} entries', {'n': rows.length}), size: 12.5),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      download(rows, pdf: true);
                    },
                    icon: const Icon(Icons.download_rounded),
                    label: Text(ctx.t('Download PDF')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      download(rows, pdf: false);
                    },
                    child: Text(ctx.t('Excel (CSV)')),
                  ),
                ),
              ]),
              const SizedBox(height: 8),
              Muted(ctx.t('The file is saved in the phone\'s Downloads folder. Tap "Open" in the message to see it.'), size: 11.5),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final v = ref.watch(reportEntriesProvider(range.query));
    final all = ((v.valueOrNull as Map?)?['entries'] as List?)?.cast<Map>() ?? const <Map>[];
    final rows = apply(all);
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('Reports')),
        actions: [if (view == 0) IconButton(tooltip: context.t('Download'), onPressed: rows.isEmpty ? null : () => downloadSheet(rows), icon: const Icon(Icons.download_rounded))],
      ),
      body: RefreshIndicator(
        color: p.primary,
        onRefresh: () async {
          ref.invalidate(reportEntriesProvider(range.query));
          ref.invalidate(reportsProvider(summaryRange.query));
        },
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          Seg<int>(value: view, items: [(0, context.t('Entries'), Icons.list_alt_rounded), (1, context.t('Summary'), Icons.bar_chart_rounded)], onChanged: (x) => setState(() => view = x)),
          const SizedBox(height: 12),
          if (view == 1) ...[
            RangePicker(
              value: summaryRange,
              onChanged: (r) {
                TapHaptics.buzz();
                setState(() => range = r);
              },
            ),
            const SizedBox(height: 14),
            AsyncBody(
              value: ref.watch(reportsProvider(summaryRange.query)),
              onRetry: () => ref.invalidate(reportsProvider(summaryRange.query)),
              builder: (d) => _ReportBody(d: d as Map),
            ),
          ] else ...[
            if (v.valueOrNull != null)
              Muted(
                range.custom
                    ? '${context.t('{n} entries · {total}', {'n': all.length, 'total': rupees((v.valueOrNull as Map)['total'] as num?)})} · ${fmtDate(_ymdR(range.from!))} – ${fmtDate(_ymdR(range.to!))}'
                    : context.t('{n} entries · {total} · last {d} days', {'n': all.length, 'total': rupees((v.valueOrNull as Map)['total'] as num?), 'd': range.days}),
                size: 12.5,
              ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: q,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: context.t('Search name, code or plan'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: q.text.isEmpty ? null : IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => setState(q.clear)),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Badge(
                isLabelVisible: filterCount > 0,
                label: Text('$filterCount'),
                backgroundColor: p.primary,
                child: Material(
                  color: p.surf,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: p.line)),
                  child: InkWell(borderRadius: BorderRadius.circular(14), onTap: filters, child: const SizedBox(width: 50, height: 50, child: Icon(Icons.filter_alt_outlined))),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Seg<String>(
              value: tab,
              items: [('ALL', context.t('All'), null), ('PAID', context.t('Paid'), null), ('PENDING', context.t('Pending'), null), ('OVERDUE', context.t('Overdue'), null)],
              onChanged: (x) {
                TapHaptics.buzz();
                setState(() => tab = x);
              },
            ),
            if (filterCount > 0 || range != ReportRange.days(30)) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: [
                InputChip(
                  label: Text('${context.t('Date')}: ${range.custom ? '${fmtDate(_ymdR(range.from!))} – ${fmtDate(_ymdR(range.to!))}' : context.t(range.days == 365 ? 'This year' : '{n} days', {'n': range.days})}'),
                  onDeleted: range == ReportRange.days(30) ? null : () => setState(() => range = ReportRange.days(30)),
                ),
                if (types.isNotEmpty) InputChip(label: Text('${context.t('Type')}: ${types.map((x) => x == 'PT' ? 'PT' : context.t('Membership')).join(', ')}'), onDeleted: () => setState(() => types = {})),
                if (minAmount != null) InputChip(label: Text('${context.t('Amount')} ≥ ${rupees(minAmount)}'), onDeleted: () => setState(() => minAmount = null)),
              ]),
            ],
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: '${rows.length}', style: const TextStyle(fontWeight: FontWeight.w800)), TextSpan(text: ' ${context.t('of {n} entries', {'n': all.length})}')]), style: TextStyle(color: p.mut, fontSize: 12.5))),
              if (filterCount > 0 || tab != 'ALL' || q.text.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() {
                    tab = 'ALL';
                    types = {};
                    minAmount = null;
                    q.clear();
                  }),
                  child: Text(context.t('Clear all')),
                ),
            ]),
            AsyncBody(
              value: v,
              onRetry: () => ref.invalidate(reportEntriesProvider(range.query)),
              builder: (_) => rows.isEmpty
                  ? Padding(padding: const EdgeInsets.all(30), child: Muted(context.t('Nothing here'), align: TextAlign.center))
                  : Panel(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      child: Column(children: [
                        for (var i = 0; i < rows.length; i++) ...[
                          _EntryRow(e: rows[i]),
                          if (i < rows.length - 1) Divider(height: 1, color: p.line),
                        ],
                      ]),
                    ),
            ),
          ],
        ]),
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.e});
  final Map e;
  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (e['status']) {
      'PAID' => (context.t('Paid'), C.ok),
      'OVERDUE' => (context.t('Overdue'), C.red),
      _ => ((e['paid'] as num) > 0 ? context.t('Part paid') : context.t('Pending'), C.warn),
    };
    return InkWell(
      onTap: () => context.push('/o/member/${e['memberId']}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          IconTile(e['kind'] == 'PT' ? Icons.fitness_center_rounded : Icons.card_membership_rounded, size: 36, color: context.c.fg),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(
                '${e['title']} · ${context.t(e['type'] as String)} · ${fmtDate(e['date'] as String?)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: context.c.mut, fontSize: 11.5),
              ),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(rupees(e['total'] as num?), style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: color.withAlpha(34), borderRadius: BorderRadius.circular(99)),
              child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
          ]),
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
        if (p != null) ...[
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: busy
                ? null
                : () async {
                    if (!await confirmDelete(context, context.t('Delete this plan?'))) return;
                    try {
                      await Api.instance.delete('/plans/${p!['id']}');
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      if (mounted) setState(() => error = e.toString());
                    }
                  },
            icon: const Icon(Icons.delete_outline_rounded, color: C.red),
            label: Text(context.t('Delete plan'), style: const TextStyle(color: C.red)),
          ),
        ],
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
  bool allowTransfer = false;
  bool filled = false;
  bool busy = false;
  String? error;
  Uint8List? logoBytes; // logo being uploaded
  double? logoUp; // its upload meter

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
        'allowTransfer': allowTransfer,
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
    final ok = await openBranchForm(context, gym: g);
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
            allowTransfer = g['allowTransfer'] == true;
          }
          final branches = ((g['branches'] as List?) ?? const []).cast<Map>();
          final limits = (g['limits'] as Map?) ?? {};
          final curId = Api.instance.branchId ?? g['currentBranchId'];
          final cur = branches.firstWhere((b) => b['id'] == curId, orElse: () => branches.isEmpty ? const {} : branches.first);
          final code = (cur['code'] as String?) ?? (g['gymCode'] as String);
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            if (!owner) Padding(padding: const EdgeInsets.only(bottom: 12), child: Muted(context.t('Only the gym owner can change these settings.'))),
            if (branches.length > 1) ...[
              SectionTitle(context.t('This branch'), trailing: TextButton(onPressed: () => pickBranch(context, ref), child: Text(context.t('Switch')))),
              Panel(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const IconTile(Icons.place_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${cur['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      Text('${context.t('Code')}: ${cur['code'] ?? '—'}', style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w800)),
                      if ((cur['address'] as String?)?.isNotEmpty == true) Muted(cur['address'] as String, size: 12.5),
                      if ((cur['hours'] as String?)?.isNotEmpty == true) Muted(cur['hours'] as String, size: 12.5),
                    ]),
                  ),
                  if (owner)
                    IconButton(
                      icon: const Icon(Icons.edit_rounded),
                      onPressed: () async {
                        final ok = await openBranchForm(context, gym: g, edit: cur);
                        if (ok == true) ref.invalidate(gymProvider);
                      },
                    ),
                ]),
              ),
              const SizedBox(height: 16),
            ],
            SectionTitle(context.t('Gym profile')),
            Panel(
              child: Column(children: [
                LogoPickerRow(
                  name: (g['name'] as String?) ?? 'G',
                  title: context.t('Gym logo'),
                  hint: context.t('For the gym and its main branch'),
                  url: g['logoUrl'] as String?,
                  local: logoBytes,
                  progress: logoUp,
                  onPick: () async {
                    if (!owner) return;
                    final b = await pickLogo(context);
                    if (b == null) return;
                    setState(() {
                      logoBytes = b;
                      logoUp = 0;
                    });
                    try {
                      await uploadLogo(b, onProgress: (d) {
                        if (mounted) setState(() => logoUp = d);
                      });
                      ref.invalidate(gymProvider);
                      ref.read(sessionProvider).refreshUser().catchError((_) {});
                      if (context.mounted) toast(context, context.t('Logo saved'), kind: DripKind.ok);
                    } catch (e) {
                      if (context.mounted) toastError(context, e);
                    } finally {
                      if (mounted) setState(() => logoUp = null);
                    }
                  },
                  onRemove: owner
                      ? () async {
                          try {
                            await Api.instance.delete('/gym/logo');
                            ref.invalidate(gymProvider);
                          } catch (e) {
                            if (context.mounted) toastError(context, e);
                          }
                        }
                      : null,
                ),
                LabeledField(label: context.t('Gym name'), controller: name, icon: Icons.storefront_rounded, caps: TextCapitalization.words),
                PhoneField(label: context.t('Gym phone'), controller: phone),
                PhoneField(label: context.t('Gym WhatsApp number'), controller: wa),
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
                  title: Text(context.t('Let members in even if payment is pending'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text(
                    context.t('ON: a member who still owes money can check in (you are just warned). OFF: entry stops until they pay. This is the default for new memberships; you can change it for each one.'),
                    style: TextStyle(color: context.c.mut, fontSize: 12),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: allowTransfer,
                  onChanged: owner ? (x) => setState(() => allowTransfer = x) : null,
                  title: Text(context.t('Members can ask to move to another branch'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                  subtitle: Text(
                    context.t('ON: members see “Request transfer” and you approve it in Requests. OFF: only you can move a member (open the member → Branch).'),
                    style: TextStyle(color: context.c.mut, fontSize: 12),
                  ),
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
                    subtitle: Text(
                      ['${context.t('Code')}: ${b['code'] ?? '—'}', b['address'], b['hours']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                    ),
                    onTap: () => showBranchQr(context, ref, b),
                    trailing: owner && branches.length > 1
                        ? IconButton(
                            tooltip: context.t('Delete'),
                            icon: const Icon(Icons.delete_outline_rounded, color: C.red),
                            onPressed: () async {
                              final yes = await confirmDelete(context, context.t('Delete this branch?'));
                              if (!yes) return;
                              try {
                                await Api.instance.delete('/gym/branches/${b['id']}');
                                ref.invalidate(gymProvider);
                              } catch (e) {
                                if (context.mounted) toastError(context, e);
                              }
                            },
                          )
                        : null,
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
                if (branches.length > 1) Text(cur['name'] as String? ?? '', style: const TextStyle(color: Color(0xFF555555), fontWeight: FontWeight.w700)),
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
                  onPressed: () => context.push('/o/gym-qr?share=1'),
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

Future<bool> confirmDelete(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('Delete'), style: const TextStyle(color: C.red))),
        ],
      ),
    ) ==
    true;

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Add or edit a branch: logo, name, full address (state, city, PIN), GST number, timings.
/// The main (first) branch shows the gym's name and saves its address / logo as the gym's.
Future<bool?> openBranchForm(BuildContext context, {required Map gym, Map? edit}) =>
    Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _BranchForm(gym: gym, edit: edit)));

class _BranchForm extends StatefulWidget {
  const _BranchForm({required this.gym, this.edit});
  final Map gym;
  /// A branch to change (null = add a new one).
  final Map? edit;
  @override
  State<_BranchForm> createState() => _BranchFormState();
}

class _BranchFormState extends State<_BranchForm> {
  late final List<Map> branches = ((widget.gym['branches'] as List?) ?? const []).cast<Map>();
  late final bool isMain = widget.edit != null && branches.isNotEmpty && branches.first['id'] == widget.edit!['id'];
  late final name = TextEditingController(text: widget.edit?['name'] as String? ?? '');
  late final hours = TextEditingController(text: widget.edit?['hours'] as String? ?? '');
  late final Address place = () {
    final src = isMain ? widget.gym : (widget.edit ?? const {});
    return Address()
      ..line = (src['addressLine'] as String?) ?? (widget.edit?['addressLine'] == null && !isMain ? ((widget.edit?['address'] as String?) ?? '') : '')
      ..state = src['state'] as String?
      ..city = src['city'] as String?
      ..pin = (src['pincode'] as String?) ?? ''
      ..gstin = (src['gstin'] as String?) ?? '';
  }();
  late String? logoUrl = isMain ? widget.gym['logoUrl'] as String? : widget.edit?['logoUrl'] as String?;
  Uint8List? logo; // picked, not uploaded yet
  bool removeLogo = false;
  double? up; // upload meter 0…1

  /// Editing a branch: the logo goes up as soon as it is picked (with the meter), so Save is quick.
  Future<void> pickAndUpload() async {
    final b = await pickLogo(context);
    if (b == null || !mounted) return;
    setState(() {
      logo = b;
      removeLogo = false;
    });
    if (widget.edit == null) return; // a new branch uploads after it is made
    setState(() => up = 0);
    try {
      logoUrl = await uploadLogo(b, branchId: isMain ? null : widget.edit!['id'] as String, onProgress: (d) {
        if (mounted) setState(() => up = d);
      });
      logo = null;
      changed = true;
      if (mounted) toast(context, context.t('Logo saved'), kind: DripKind.ok);
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => up = null);
    }
  }

  bool changed = false; // logo already saved (go back with "changed")
  bool busy = false;
  String? error;

  Future<void> save() async {
    final need = context.t('Fill the address, state, city and PIN code');
    final p = place.toJson();
    if (place.line.trim().length < 3 || place.state == null || place.city == null || place.pin.trim().length != 6) {
      setState(() => error = need);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      String? id = widget.edit?['id'] as String?;
      final body = {
        'name': isMain ? (widget.edit!['name'] as String) : name.text.trim(),
        'hours': hours.text.trim().isEmpty ? null : hours.text.trim(),
        if (!isMain) ...p,
      };
      if (id == null) {
        final r = await Api.instance.post('/gym/branches', body);
        id = (r as Map)['id'] as String;
      } else {
        await Api.instance.patch('/gym/branches/$id', body);
      }
      if (isMain) await Api.instance.patch('/gym', p);
      final branchId = isMain ? null : id;
      if (logo != null) {
        setState(() => up = 0);
        await uploadLogo(logo!, branchId: branchId, onProgress: (d) {
          if (mounted) setState(() => up = d);
        });
      } else if (removeLogo) {
        await Api.instance.delete(branchId == null ? '/gym/logo' : '/gym/logo?branchId=$branchId');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() {
        busy = false;
        up = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final shownName = isMain ? (widget.gym['name'] as String? ?? '') : (name.text.isEmpty ? '?' : name.text);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, changed);
      },
      child: Scaffold(
      appBar: AppBar(title: Text(context.t(widget.edit == null ? 'Add branch' : 'Edit branch'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 32), children: [
        LogoPickerRow(
          name: shownName,
          title: context.t(isMain ? 'Gym logo' : 'Branch logo'),
          hint: context.t(isMain ? 'For the gym and its main branch' : 'Only for this branch'),
          url: removeLogo ? null : logoUrl,
          local: logo,
          progress: up,
          onPick: pickAndUpload,
          onRemove: () => setState(() {
            logo = null;
            removeLogo = true;
          }),
        ),
        if (isMain)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(shownName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          )
        else
          LabeledField(label: '${context.t('Branch name')} *', controller: name, icon: Icons.storefront_rounded, caps: TextCapitalization.words),
        AddressFields(value: place),
        const SizedBox(height: 12),
        LabeledField(label: context.t('Timings'), controller: hours, icon: Icons.schedule_rounded, hint: '6 AM – 10 PM'),
        Muted(context.t('GST number is optional. Each branch can have its own; it must start with the state code (Delhi = 07).'), size: 12),
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton(onPressed: busy || up != null ? null : save, child: Text(busy ? context.t('Saving…') : context.t(widget.edit == null ? 'Add branch' : 'Save changes'))),
      ]),
    ),
    );
  }
}

// ============================================================ notices

final noticeAudienceProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, f) => branchGet(ref, '/notices/audience?filter=$f'));

/// Who will get the notice — the list appears by itself (e.g. memberships ending in 7 days).
class _Audience extends ConsumerStatefulWidget {
  const _Audience({required this.filter});
  final String filter;
  @override
  ConsumerState<_Audience> createState() => _AudienceState();
}

class _AudienceState extends ConsumerState<_Audience> {
  bool all = false;
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(noticeAudienceProvider(widget.filter));
    final d = v.valueOrNull as Map?;
    if (d == null) return const SizedBox(height: 40, child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))));
    final list = (d['members'] as List).cast<Map>();
    final shown = all ? list : list.take(4).toList();
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          context.t('{n} members · {a} use the app', {'n': d['count'], 'a': d['withApp']}),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: list.isEmpty ? context.c.mut : C.warn),
        ),
        if (list.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Muted(context.t('Nobody in this group right now.'), size: 12.5)),
        for (final m in shown)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 30),
              const SizedBox(width: 10),
              Expanded(child: Text(m['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              Muted(
                widget.filter == 'DUE'
                    ? rupees(m['due'] as num?)
                    : m['daysLeft'] != null && (m['daysLeft'] as int) >= 0
                        ? context.t('{n} days left', {'n': m['daysLeft']})
                        : statusLabel(context, m['status'] as String),
                size: 12,
              ),
              const SizedBox(width: 6),
              Icon(m['hasApp'] == true ? Icons.check_rounded : Icons.phone_android_outlined, size: 16, color: m['hasApp'] == true ? context.c.primary : context.c.mut),
            ]),
          ),
        if (list.length > 4)
          TextButton(onPressed: () => setState(() => all = !all), child: Text(all ? context.t('Show less') : context.t('+{n} more', {'n': list.length - 4}))),
      ]),
    );
  }
}

final noticesProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/notices'));

String _noticeAudience(BuildContext context, Map n) {
  final parts = <String>[];
  if (n['forMembers'] == true) {
    parts.add(switch (n['memberFilter']) {
      'ACTIVE' => context.t('Active members'),
      'EXPIRED' => context.t('Expired members'),
      'ENDING' => context.t('Members ending in 7 days'),
      'DUE' => context.t('Members who owe money'),
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
                            if (context.mounted) toastError(context, e);
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
  Set<String>? branchPick; // null = only this branch
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
        if (branchPick != null) 'branchIds': BranchTarget.body(branchPick, branchesOf(ref.read(gymProvider).valueOrNull as Map?).length),
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
        BranchTarget(picked: branchPick, onChanged: (v) => setState(() => branchPick = v)),
        Row(children: [
          _who(Icons.groups_rounded, context.t('Members'), context.t('On their app dashboard'), members, () => setState(() => members = !members)),
          const SizedBox(width: 10),
          _who(Icons.sports_rounded, context.t('Trainers'), context.t('On the trainer dashboard'), trainers, () => setState(() => trainers = !trainers)),
        ]),
        if (members) ...[
          const SizedBox(height: 12),
          Muted(context.t('Which members?'), size: 13),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (k, l) in [('ALL', 'All'), ('ACTIVE', 'Active'), ('ENDING', 'Ending in 7 days'), ('EXPIRED', 'Expired'), ('DUE', 'Money due')])
              ChoiceChip(
                label: Text(context.t(l)),
                selected: filter == k,
                showCheckmark: false,
                selectedColor: p.primary,
                labelStyle: TextStyle(color: filter == k ? Colors.white : p.fg, fontWeight: FontWeight.w700),
                onSelected: (_) => setState(() => filter = k),
              ),
          ]),
          const SizedBox(height: 10),
          _Audience(filter: filter),
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

// ============================================================ More → Branches

/// Every branch with its code, address and check-in QR, with Edit and Delete. (Was "Gym address".)
class BranchesScreen extends ConsumerWidget {
  const BranchesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(gymProvider);
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    final p = context.c;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Branches'))),
      floatingActionButton: owner
          ? FloatingActionButton.extended(
              onPressed: () async {
                final g = ref.read(gymProvider).valueOrNull as Map?;
                if (g == null) return;
                final ok = await openBranchForm(context, gym: g);
                if (ok == true) ref.invalidate(gymProvider);
              },
              icon: const Icon(Icons.add_rounded),
              label: Text(context.t('Add branch')),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(gymProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(gymProvider),
          builder: (d) {
            final g = d as Map;
            final branches = ((g['branches'] as List?) ?? const []).cast<Map>();
            final limits = (g['limits'] as Map?) ?? {};
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
              Muted(context.t('{n} of {max} branches on your plan', {'n': branches.length, 'max': limits['branchLimit'] ?? 1}), size: 12.5),
              const SizedBox(height: 10),
              for (final (i, b) in branches.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Panel(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        // The main branch shows the gym's name and logo; every other branch only its own logo.
                        GymLogo(name: i == 0 ? '${g['name']}' : '${b['name']}', url: (i == 0 ? (b['logoUrl'] ?? g['logoUrl']) : b['logoUrl']) as String?, size: 46),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text.rich(
                              TextSpan(children: [
                                TextSpan(text: i == 0 ? '${g['name']}' : '${b['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                                if (i == 0 && branches.length > 1) TextSpan(text: '  ${context.t('Main')}', style: const TextStyle(color: C.blue, fontWeight: FontWeight.w700, fontSize: 11.5)),
                              ]),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (i == 0 && (b['address'] as String?)?.isNotEmpty != true && (g['address'] as String?)?.isNotEmpty == true)
                              Muted(g['address'] as String, size: 12.5)
                            else if ((b['address'] as String?)?.isNotEmpty == true)
                              Muted(b['address'] as String, size: 12.5),
                            if ((b['hours'] as String?)?.isNotEmpty == true) Muted(b['hours'] as String, size: 12.5),
                            if (((i == 0 ? g['gstin'] : b['gstin']) as String?)?.isNotEmpty == true) Muted('GSTIN ${i == 0 ? g['gstin'] : b['gstin']}', size: 12),
                          ]),
                        ),
                        const SizedBox(width: 8),
                        Text('${b['code'] ?? '—'}', style: TextStyle(color: p.primary, fontWeight: FontWeight.w800, letterSpacing: 1.2, fontSize: 13)),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: _SmallBtn(icon: Icons.qr_code_2_rounded, label: context.t('QR'), onTap: () => showBranchQr(context, ref, b))),
                        if (owner) ...[
                          const SizedBox(width: 8),
                          Expanded(
                            child: _SmallBtn(
                              icon: Icons.edit_rounded,
                              label: context.t('Edit'),
                              onTap: () async {
                                final ok = await openBranchForm(context, gym: g, edit: b);
                                if (ok == true) ref.invalidate(gymProvider);
                              },
                            ),
                          ),
                          if (branches.length > 1 && i > 0) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: _SmallBtn(
                                icon: Icons.delete_outline_rounded,
                                label: context.t('Delete'),
                                color: C.red,
                                onTap: () async {
                                  final yes = await confirmDelete(context, context.t('Delete {b}?', {'b': b['name']}));
                                  if (!yes) return;
                                  try {
                                    await Api.instance.delete('/gym/branches/${b['id']}');
                                    ref.invalidate(gymProvider);
                                    if (context.mounted) toast(context, context.t('Branch deleted'));
                                  } catch (e) {
                                    if (context.mounted) toastError(context, e);
                                  }
                                },
                              ),
                            ),
                          ],
                        ],
                      ]),
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


/// Small outlined button whose label always stays on one line (shrinks instead of wrapping).
class _SmallBtn extends StatelessWidget {
  const _SmallBtn({required this.icon, required this.label, required this.onTap, this.color});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  @override
  Widget build(BuildContext context) => OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: color ?? context.c.fg,
          side: color == null ? null : BorderSide(color: color!.withAlpha(110)),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          minimumSize: const Size(0, 42),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onTap,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 17),
            const SizedBox(width: 5),
            Text(label, maxLines: 1, softWrap: false, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
          ]),
        ),
      );
}
