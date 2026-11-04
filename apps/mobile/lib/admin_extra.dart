import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'screens/billing.dart' show loadIndia;
import 'i18n.dart';
import 'theme.dart';
import 'ui.dart';
import 'screens/reports_kit.dart';

// ============================================================ GM Admin: coupons, UPI payments, reports, receipt & signature

final _coupons = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/coupons'));
final _payments = StreamProvider.autoDispose.family<dynamic, String>((ref, status) => Api.instance.cachedGet('/super/payments?status=$status'));
// (Plan payments turn the plan on at once; the super admin only stops one whose money never came.)
final _plansList = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/saas-plans'));
final _settingsX = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/settings'));

String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

String couponLine(BuildContext context, Map c) {
  final off = c['kind'] == 'PERCENT' ? '${c['value']}% ${context.t('off')}' : '${rupees(c['value'] as num?)} ${context.t('off')}';
  final plans = (c['planIds'] as List?)?.isEmpty ?? true ? context.t('All plans') : context.t('{n} plans', {'n': (c['planIds'] as List).length});
  return '$off · $plans';
}

/// Super admin picks one of the live coupons (for an ad).
Future<String?> pickCoupon(BuildContext context) async {
  List list;
  try {
    list = (await Api.instance.get('/super/coupons')) as List;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return null;
  }
  if (!context.mounted) return null;
  final live = list.cast<Map>().where((c) => c['live'] == true).toList();
  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(ctx.t('Choose a coupon'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
        if (live.isEmpty) Padding(padding: const EdgeInsets.all(20), child: Muted(ctx.t('No live coupons. Make one in More → Coupons.'))),
        for (final c in live)
          ListTile(
            leading: const Icon(Icons.sell_rounded, color: C.indigo),
            title: Text(c['code'] as String, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
            subtitle: Text('${couponLine(ctx, c)} · ${ctx.t('till {date}', {'date': fmtDate(c['validTill'] as String?)})}'),
            onTap: () => Navigator.pop(ctx, c['code'] as String),
          ),
        const SizedBox(height: 10),
      ]),
    ),
  );
}

class AdminCoupons extends ConsumerWidget {
  const AdminCoupons({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_coupons);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Coupons'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.indigo,
        foregroundColor: Colors.white,
        onPressed: () async {
          await context.push('/a/coupon');
          ref.invalidate(_coupons);
        },
        icon: const Icon(Icons.add_rounded),
        label: Text(context.t('New coupon')),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(_coupons),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(_coupons),
          builder: (d) {
            final list = (d as List).cast<Map>();
            if (list.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 120),
                const Icon(Icons.sell_outlined, size: 48, color: C.indigo),
                const SizedBox(height: 10),
                Center(child: Text(context.t('No coupons yet'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
                const SizedBox(height: 4),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 40), child: Muted(context.t('Make a coupon. Gym owners type the code when they buy a plan.'), align: TextAlign.center)),
              ]);
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
              for (final c in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Panel(
                    onTap: () async {
                      await context.push('/a/coupon', extra: c);
                      ref.invalidate(_coupons);
                    },
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: C.indigo.withAlpha(140))),
                            child: Text(c['code'] as String, style: const TextStyle(color: C.indigo, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                          ),
                          const SizedBox(height: 8),
                          Text(couponLine(context, c), style: const TextStyle(fontWeight: FontWeight.w700)),
                          Muted(
                            '${context.t('Till {date}', {'date': fmtDate(c['validTill'] as String?)})} · ${context.t('used {n}', {'n': '${c['used']}${c['maxUses'] == null ? '' : ' / ${c['maxUses']}'}'})}',
                            size: 12,
                          ),
                        ]),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: (c['live'] == true ? C.ok : context.c.mut).withAlpha(34), borderRadius: BorderRadius.circular(99)),
                        child: Text(context.t(c['live'] == true ? 'Active' : 'Ended'), style: TextStyle(color: c['live'] == true ? C.ok : context.c.mut, fontWeight: FontWeight.w700, fontSize: 12)),
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

class CouponEditScreen extends ConsumerStatefulWidget {
  const CouponEditScreen({super.key, this.coupon});
  final Map? coupon;
  @override
  ConsumerState<CouponEditScreen> createState() => _CouponEditState();
}

class _CouponEditState extends ConsumerState<CouponEditScreen> {
  late final code = TextEditingController(text: widget.coupon?['code'] as String? ?? '');
  late final value = TextEditingController(text: widget.coupon == null ? '' : '${widget.coupon!['value']}');
  late final maxUses = TextEditingController(text: widget.coupon?['maxUses'] == null ? '' : '${widget.coupon!['maxUses']}');
  late String kind = widget.coupon?['kind'] as String? ?? 'PERCENT';
  late Set<String> planIds = {...((widget.coupon?['planIds'] as List?)?.cast<String>() ?? const [])};
  late DateTime till = DateTime.tryParse(widget.coupon?['validTill'] as String? ?? '') ?? DateTime.now().add(const Duration(days: 15));
  late bool once = widget.coupon?['oncePerGym'] as bool? ?? true;
  late bool active = widget.coupon?['active'] as bool? ?? true;
  bool busy = false;
  String? error;

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final body = {
        'code': code.text.trim(),
        'kind': kind,
        'value': int.tryParse(value.text.trim()) ?? 0,
        'planIds': planIds.toList(),
        'validTill': _ymd(till),
        'maxUses': maxUses.text.trim().isEmpty ? null : int.tryParse(maxUses.text.trim()),
        'oncePerGym': once,
        'active': active,
      };
      if (widget.coupon == null) {
        await Api.instance.post('/super/coupons', body);
      } else {
        await Api.instance.patch('/super/coupons/${widget.coupon!['id']}', body);
      }
      if (mounted) {
        toast(context, context.t('Saved'), kind: DripKind.ok);
        context.pop();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final plans = (((ref.watch(_plansList).valueOrNull as Map?)?['plans'] as List?) ?? const []).cast<Map>();
    Widget label(String t) => Padding(padding: const EdgeInsets.only(left: 2, bottom: 6, top: 4), child: Muted(t, size: 13));
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.coupon == null ? context.t('New coupon') : context.t('Edit coupon')),
        actions: [
          if (widget.coupon != null)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded, color: C.red),
              onPressed: () async {
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text(context.t('Delete this coupon?')),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.t('Cancel'))),
                      TextButton(onPressed: () => Navigator.pop(c, true), child: Text(context.t('Delete'), style: const TextStyle(color: C.red))),
                    ],
                  ),
                );
                if (yes != true) return;
                try {
                  await Api.instance.delete('/super/coupons/${widget.coupon!['id']}');
                  if (context.mounted) context.pop();
                } catch (e) {
                  if (context.mounted) toastError(context, e);
                }
              },
            ),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        label(context.t('Code')),
        TextField(
          controller: code,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')), LengthLimitingTextInputFormatter(20)],
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.4),
          decoration: const InputDecoration(hintText: 'DIWALI20'),
        ),
        const SizedBox(height: 8),
        label(context.t('Discount')),
        Seg<String>(value: kind, items: [('PERCENT', context.t('% Percent'), null), ('AMOUNT', context.t('₹ Amount'), null)], onChanged: (v) => setState(() => kind = v)),
        const SizedBox(height: 10),
        label(context.t('Value')),
        TextField(
          controller: value,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(suffixText: kind == 'PERCENT' ? '%' : null, prefixText: kind == 'AMOUNT' ? '₹ ' : null),
        ),
        const SizedBox(height: 8),
        label(context.t('Plans')),
        Wrap(spacing: 8, runSpacing: 6, children: [
          FilterChip(label: Text(context.t('All plans')), selected: planIds.isEmpty, onSelected: (_) => setState(() => planIds.clear())),
          for (final p in plans)
            FilterChip(
              label: Text(p['name'] as String),
              selected: planIds.contains(p['id']),
              onSelected: (v) => setState(() => v ? planIds.add(p['id'] as String) : planIds.remove(p['id'])),
            ),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              label(context.t('Valid till')),
              InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () async {
                  final d = await showDatePicker(context: context, initialDate: till, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
                  if (d != null) setState(() => till = d);
                },
                child: InputDecorator(decoration: const InputDecoration(), child: Text(fmtDate(_ymd(till)), style: const TextStyle(fontWeight: FontWeight.w600))),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              label(context.t('Max uses')),
              TextField(controller: maxUses, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly], decoration: InputDecoration(hintText: context.t('No limit'))),
            ]),
          ),
        ]),
        const SizedBox(height: 6),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.t('A gym can use it only once')), value: once, onChanged: (v) => setState(() => once = v)),
        if (widget.coupon != null) SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(context.t('Active')), value: active, onChanged: (v) => setState(() => active = v)),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: C.indigo),
          onPressed: busy ? null : save,
          child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : Text(widget.coupon == null ? context.t('Create coupon') : context.t('Save')),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- UPI payments to check

class AdminPayments extends ConsumerStatefulWidget {
  const AdminPayments({super.key});
  @override
  ConsumerState<AdminPayments> createState() => _AdminPaymentsState();
}

class _AdminPaymentsState extends ConsumerState<AdminPayments> {
  String status = 'PAID';

  /// Money never reached the bank: stop the plan and mark the receipt cancelled.
  Future<void> cancel(Map p) async {
    final c = TextEditingController(text: 'Payment not found in the bank account');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Payment not received?')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(ctx.t('The plan of {gym} stops at once and the receipt shows CANCELLED. The owner gets a notification to pay again.', {'gym': p['gymName']}), style: const TextStyle(fontSize: 13.5)),
          const SizedBox(height: 12),
          TextField(controller: c, decoration: InputDecoration(labelText: ctx.t('Reason (the owner sees it)'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Stop the plan'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.post('/super/payments/${p['id']}/cancel', {'reason': c.text.trim()});
      if (mounted) toast(context, context.t('Plan stopped'), kind: DripKind.info);
      ref.invalidate(_payments);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(_payments(status));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Plan payments'))),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Seg<String>(value: status, items: [('PAID', context.t('Paid'), null), ('CANCELLED', context.t('Cancelled'), null), ('FAILED', context.t('Failed'), null)], onChanged: (x) => setState(() => status = x)),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(_payments),
            child: AsyncBody(
              value: v,
              onRetry: () => ref.invalidate(_payments),
              builder: (d) {
                final list = ((d as Map)['payments'] as List).cast<Map>();
                return ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), children: [
                  if (status == 'PAID')
                    Row(children: [
                      Expanded(child: StatBox(value: rupees(d['monthTotal'] as num?), label: context.t('This month'), color: C.indigo)),
                      const SizedBox(width: 10),
                      Expanded(child: StatBox(value: '${d['monthCount']}', label: context.t('Payments'), color: C.ok)),
                    ]),
                  const SizedBox(height: 10),
                  if (list.isEmpty) Padding(padding: const EdgeInsets.only(top: 60), child: Center(child: Muted(context.t('Nothing here.')))),
                  for (final p in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Panel(
                        onTap: p['billId'] == null ? null : () => context.push('/a/bill/${p['tenantId']}/${p['billId']}'),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text('${p['gymName']} · ${p['gymCode']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                            Text(rupees(p['amount'] as num?), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                          ]),
                          const SizedBox(height: 4),
                          Muted('${p['planName']} · ${context.t(p['cycle'] == 'ANNUAL' ? '1 year' : '1 month')}${p['couponCode'] != null ? ' · ${p['couponCode']}' : ''}', size: 12.5),
                          Muted('${p['payId']}${p['app'] != null ? ' · ${p['app']}' : ''}${p['upiRef'] != null ? ' · Ref ${p['upiRef']}' : ''} · ${fmtDateTime((p['paidAt'] ?? p['createdAt']) as String)}', size: 12),
                          if (p['reason'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(p['reason'] as String, style: const TextStyle(color: C.red, fontSize: 12.5))),
                          if (p['status'] == 'PAID') ...[
                            const SizedBox(height: 8),
                            Row(children: [
                              if (p['billId'] != null) Expanded(child: OutlinedButton.icon(onPressed: () => context.push('/a/bill/${p['tenantId']}/${p['billId']}'), icon: const Icon(Icons.receipt_long_rounded, size: 18), label: Text(context.t('Receipt')))),
                              const SizedBox(width: 8),
                              Expanded(child: OutlinedButton(onPressed: () => cancel(p), child: Text(context.t('Not received'), style: const TextStyle(color: C.red)))),
                            ]),
                          ],
                        ]),
                      ),
                    ),
                ]);
              },
            ),
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- GymMantra reports

class AdminReports extends StatefulWidget {
  const AdminReports({super.key});
  @override
  State<AdminReports> createState() => _AdminReportsState();
}

class _AdminReportsState extends State<AdminReports> {
  ReportRange range = ReportRange.days(30);
  Map? data;
  String? error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final d = await Api.instance.get('/super/reports?${range.query}');
      if (mounted) setState(() => data = d as Map);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _csv(Map d) {
    final b = StringBuffer('Date,Plan income,Bills,New gyms\n');
    for (final s in (d['series'] as List).cast<Map>()) {
      b.writeln('${s['date']},${s['income']},${s['bills']},${s['newGyms']}');
    }
    b.writeln();
    b.writeln('Plan,Gyms');
    for (final p in (d['byPlan'] as List).cast<Map>()) {
      b.writeln('${p['name']},${p['count']}');
    }
    b.writeln();
    b.writeln('Top gyms,Code,Members');
    for (final g in (d['topGyms'] as List).cast<Map>()) {
      b.writeln('"${g['name']}",${g['gymCode']},${g['members']}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Reports'))),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          RangePicker(
            value: range,
            accent: C.indigo,
            onChanged: (r) {
              setState(() => range = r);
              load();
            },
          ),
          const SizedBox(height: 12),
          if (error != null) ErrorText(error),
          if (d == null && loading) const ListSkeleton(),
          if (d != null) ...[
            Row(children: [
              Expanded(child: StatBox(value: shortRupees(d['totals']['income'] as num), label: context.t('Plan income'), color: C.indigo)),
              const SizedBox(width: 10),
              Expanded(child: StatBox(value: '${d['totals']['newGyms']}', label: context.t('New gyms'), color: C.ok)),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: StatBox(value: '${d['totals']['activeGyms']}', label: context.t('Active gyms'), color: C.indigo)),
              const SizedBox(width: 10),
              Expanded(child: StatBox(value: '${d['totals']['members']}', label: context.t('Members total'), color: C.warn)),
            ]),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('Plan income'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                SizedBox(height: 120, child: LineChartMini(values: [for (final s in (d['series'] as List).cast<Map>()) (s['income'] as num).toDouble()], color: C.indigo)),
              ]),
            ),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('New gyms per week'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                SizedBox(height: 110, child: BarsMini(values: weekly([for (final s in (d['series'] as List).cast<Map>()) (s['newGyms'] as num).toDouble()]), color: C.indigo)),
              ]),
            ),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('Gyms by plan'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                DonutWithLegend(items: [for (final p in (d['byPlan'] as List).cast<Map>()) (p['name'] as String, (p['count'] as num).toDouble())]),
              ]),
            ),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('Tickets'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Row(children: [
                  for (final (k, l, c) in [('OPEN', 'Open', C.orange), ('IN_PROGRESS', 'In progress', C.blue), ('WAITING', 'Waiting', C.warn), ('RESOLVED', 'Resolved', C.ok)])
                    Expanded(
                      child: Column(children: [
                        Text('${d['tickets'][k] ?? 0}', style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 20)),
                        Muted(context.t(l), size: 11.5, align: TextAlign.center),
                      ]),
                    ),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.t('Top gyms by members'), style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                for (final g in (d['topGyms'] as List).cast<Map>())
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [Expanded(child: Text(g['name'] as String)), Text('${g['members']}', style: const TextStyle(fontWeight: FontWeight.w800))]),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            DownloadButtons(
              accent: C.indigo,
              fileBase: 'GymMantra_${d['from']}_${d['to']}',
              csv: () => _csv(d),
              pdfTitle: 'GymMantra report · ${fmtDate(d['from'] as String?)} – ${fmtDate(d['to'] as String?)}',
              pdfRows: () => [
                ['Plan income', rupees(d['totals']['income'] as num?)],
                ['Receipts', '${d['totals']['bills']}'],
                ['New gyms', '${d['totals']['newGyms']}'],
                ['Active gyms', '${d['totals']['activeGyms']}'],
                ['Members total', '${d['totals']['members']}'],
                for (final p in (d['byPlan'] as List).cast<Map>()) ['Gyms on ${p['name']}', '${p['count']}'],
                for (final g in (d['topGyms'] as List).cast<Map>()) ['${g['name']} (${g['gymCode']})', '${g['members']} members'],
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- receipt details & signature

class AdminReceiptSettings extends ConsumerStatefulWidget {
  const AdminReceiptSettings({super.key});
  @override
  ConsumerState<AdminReceiptSettings> createState() => _AdminReceiptSettingsState();
}

class _AdminReceiptSettingsState extends ConsumerState<AdminReceiptSettings> {
  final name = TextEditingController();
  final address = TextEditingController();
  final pan = TextEditingController();
  final upi = TextEditingController();
  String? gstin;
  String? signature; // data URL
  bool sigChanged = false;
  bool loaded = false;
  bool busy = false;
  String? error;

  Future<void> upload() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 900, imageQuality: 85);
    if (f == null) return;
    final bytes = await f.readAsBytes();
    if (bytes.length > 280 * 1024) {
      if (mounted) toast(context, context.t('Picture is too big. Crop it closer to the signature.'), kind: DripKind.error);
      return;
    }
    final mime = f.path.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    setState(() {
      signature = 'data:$mime;base64,${base64Encode(bytes)}';
      sigChanged = true;
    });
  }

  Future<void> draw() async {
    final png = await Navigator.of(context).push<Uint8List>(MaterialPageRoute(builder: (_) => const SignaturePad(), fullscreenDialog: true));
    if (png == null) return;
    setState(() {
      signature = 'data:image/png;base64,${base64Encode(png)}';
      sigChanged = true;
    });
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Api.instance.patch('/super/settings', {'businessName': name.text.trim(), 'businessAddress': address.text.trim(), 'businessPan': pan.text.trim(), 'upiId': upi.text.trim()});
      if (sigChanged) await Api.instance.put('/super/signature', {'dataUrl': signature});
      if (mounted) {
        toast(context, context.t('Saved'), kind: DripKind.ok);
        context.pop();
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(_settingsX).valueOrNull as Map?;
    if (!loaded && s != null) {
      loaded = true;
      name.text = s['businessName'] as String? ?? 'GymMantra';
      address.text = s['businessAddress'] as String? ?? '';
      pan.text = s['businessPan'] as String? ?? '';
      upi.text = s['upiId'] as String? ?? '';
      gstin = (s['gst'] as Map?)?['gstin'] as String?;
      signature = s['signature'] as String?;
    }
    Widget label(String t) => Padding(padding: const EdgeInsets.only(left: 2, bottom: 6, top: 8), child: Muted(t, size: 13));
    final sigBytes = signature == null ? null : base64Decode(signature!.split(',').last);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Receipt & signature'))),
      body: s == null
          ? const ListSkeleton()
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              label(context.t('Business name')),
              TextField(controller: name, textCapitalization: TextCapitalization.words),
              label(context.t('Address')),
              TextField(controller: address, maxLines: 2, textCapitalization: TextCapitalization.words),
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    label('PAN'),
                    TextField(controller: pan, textCapitalization: TextCapitalization.characters, maxLength: 10, decoration: InputDecoration(hintText: context.t('(optional)'), counterText: '')),
                  ]),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    label('GSTIN'),
                    InputDecorator(decoration: const InputDecoration(), child: Text(gstin ?? context.t('(when GST is on)'), style: TextStyle(color: context.c.mut))),
                  ]),
                ),
              ]),
              label(context.t('UPI ID (gyms pay plans here)')),
              TextField(controller: upi, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: '7827862630@ptaxis')),
              label(context.t('Signature')),
              Container(
                height: 130,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: context.c.line)),
                alignment: Alignment.center,
                child: sigBytes == null ? Text(context.t('No signature yet'), style: const TextStyle(color: Colors.black45)) : Padding(padding: const EdgeInsets.all(10), child: Image.memory(sigBytes, fit: BoxFit.contain)),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: upload, icon: const Icon(Icons.photo_rounded), label: Text(context.t('Upload photo')))),
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton.icon(onPressed: draw, icon: const Icon(Icons.draw_rounded), label: Text(context.t('Draw here')))),
              ]),
              if (signature != null)
                Center(
                  child: TextButton(
                    onPressed: () => setState(() {
                      signature = null;
                      sigChanged = true;
                    }),
                    child: Text(context.t('Remove signature'), style: const TextStyle(color: C.red)),
                  ),
                ),
              ErrorText(error),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: C.indigo),
                onPressed: busy ? null : save,
                child: busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white)) : Text(context.t('Save')),
              ),
              const SizedBox(height: 8),
              Muted(context.t('This name, address and signature go on every receipt.'), size: 12, align: TextAlign.center),
            ]),
    );
  }
}

/// Draw the signature with a finger. Returns a PNG.
class SignaturePad extends StatefulWidget {
  const SignaturePad({super.key});
  @override
  State<SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<SignaturePad> {
  final strokes = <List<Offset>>[];
  Size area = Size.zero;

  Future<void> done() async {
    final pts = strokes.expand((x) => x).toList();
    if (pts.isEmpty) return;
    // Cut the picture to just the signature (plus a little space), so it fits the receipt nicely.
    var minX = pts.first.dx, maxX = pts.first.dx, minY = pts.first.dy, maxY = pts.first.dy;
    for (final p in pts) {
      minX = math.min(minX, p.dx);
      maxX = math.max(maxX, p.dx);
      minY = math.min(minY, p.dy);
      maxY = math.max(maxY, p.dy);
    }
    const pad = 12.0;
    final box = Rect.fromLTRB(minX - pad, minY - pad, maxX + pad, maxY + pad);
    const scale = 2.0;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.scale(scale);
    canvas.translate(-box.left, -box.top);
    _SigPainter(strokes, Colors.black).paint(canvas, area);
    final img = await rec.endRecording().toImage(math.max(1, (box.width * scale).round()), math.max(1, (box.height * scale).round()));
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (mounted && data != null) Navigator.pop(context, data.buffer.asUint8List());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(context.t('Draw your signature')),
          actions: [
            TextButton(onPressed: () => setState(strokes.clear), child: Text(context.t('Clear'))),
            TextButton(onPressed: done, child: Text(context.t('Done'))),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFC7D2FE), width: 2)),
              clipBehavior: Clip.antiAlias,
              // The whole white area takes the pen — every stroke, anywhere, as many times as needed.
              child: LayoutBuilder(builder: (_, box) {
                area = Size(box.maxWidth, box.maxHeight);
                return Stack(children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      dragStartBehavior: DragStartBehavior.down,
                      onPanStart: (d) => setState(() => strokes.add([d.localPosition])),
                      onPanUpdate: (d) => setState(() {
                        if (strokes.isEmpty) strokes.add([]);
                        strokes.last.add(d.localPosition);
                      }),
                      child: CustomPaint(painter: _SigPainter(strokes, const Color(0xFF1E3A8A), version: strokes.fold(0, (n, s) => n + s.length))),
                    ),
                  ),
                  if (strokes.isEmpty)
                    IgnorePointer(child: Center(child: Text(context.t('Sign anywhere here'), style: const TextStyle(color: Colors.black38, fontSize: 16)))),
                ]);
              }),
            ),
          ),
        ),
      );
}

class _SigPainter extends CustomPainter {
  _SigPainter(this.strokes, this.color, {this.version = 0});
  final List<List<Offset>> strokes;
  final Color color;
  final int version; // number of points; a change means repaint
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    for (final s in strokes) {
      if (s.length == 1) {
        canvas.drawCircle(s.first, 1.5, p..style = PaintingStyle.fill);
        p.style = PaintingStyle.stroke;
        continue;
      }
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final o in s.skip(1)) {
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_SigPainter o) => true; // the stroke list grows in place, so always repaint
}

// ============================================================ people

/// GM Admin → People: find anyone by mobile number or email and delete their account,
/// so the same mobile and email can sign up again.
class AdminPeople extends StatefulWidget {
  const AdminPeople({super.key});
  @override
  State<AdminPeople> createState() => _AdminPeopleState();
}

class _AdminPeopleState extends State<AdminPeople> {
  final q = TextEditingController();
  List<Map>? rows;
  bool busy = false;
  String? error;

  Future<void> search() async {
    final text = q.text.trim();
    if (text.length < 3) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await Api.instance.get('/super/users?q=${Uri.encodeQueryComponent(text)}');
      setState(() => rows = (r as List).cast<Map>());
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> delete(Map p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Delete {name}?', {'name': p['name']})),
        content: Text(ctx.t('Their login and personal details are deleted. Gyms see them as "No longer available". The same mobile number and email can sign up again.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Delete'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.post('/super/users/${p['id']}/delete', {});
      if (!mounted) return;
      toast(context, context.t('Account deleted'));
      setState(() => rows = rows?.where((x) => x['id'] != p['id']).toList());
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  String roleName(BuildContext context, String? r) => switch (r) {
        'OWNER' => context.t('Gym owner'),
        'FRONT_DESK' => context.t('Front desk'),
        'TRAINER' => context.t('Trainer'),
        'MEMBER' => context.t('Member'),
        _ => context.t('Member'),
      };

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('People'))),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          TextField(
            controller: q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => search(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: context.t('Full mobile number or email'),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: search),
            ),
          ),
          const SizedBox(height: 8),
          Muted(context.t('Delete an account when someone asks, so they can sign up again with the same mobile number and email.'), size: 12),
          const SizedBox(height: 12),
          if (busy) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(color: C.indigo))),
          if (error != null) ErrorText(error),
          if (!busy && rows != null && rows!.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Muted(context.t('No account with this mobile number or email.'), align: TextAlign.center)),
          if (!busy)
            for (final p in rows ?? const <Map>[])
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Panel(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(p['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    const SizedBox(height: 2),
                    Muted([p['phone'], p['email'], roleName(context, p['appRole'] as String?), if (p['google'] == true) 'Google'].where((x) => x != null).join(' · '), size: 12.5),
                    for (final g in ((p['gyms'] as List?) ?? const []).cast<Map>()) Muted('${g['name']} · ${roleName(context, g['role'] as String?)}', size: 12),
                    const SizedBox(height: 10),
                    if (p['runsGym'] == true)
                      Muted(context.t('Runs a gym — remove them from the gym first.'), size: 12)
                    else
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(foregroundColor: C.red, side: const BorderSide(color: C.red)),
                        onPressed: () => delete(p),
                        icon: const Icon(Icons.delete_outline_rounded, size: 18),
                        label: Text(context.t('Delete account')),
                      ),
                  ]),
                ),
              ),
        ]),
      );
}

// ============================================================ gym transfer / close (board 54)

Future<void> adminTransferGym(BuildContext context, WidgetRef ref, String id, VoidCallback done) async {
  final phone = TextEditingController();
  var oldOwner = 'remove';
  Map? found;
  String? err;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(ctx.t('Transfer gym'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Muted(ctx.t('Members, plans, money and history stay the same. Only the owner changes.'), size: 12.5),
          const SizedBox(height: 12),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: ctx.t('New owner’s mobile *'), prefixText: '+91 '),
            onChanged: (t) async {
              final ph = t.replaceAll(RegExp(r'\D'), '');
              if (ph.length != 10) return;
              try {
                final r = await Api.instance.get('/transfer-owner/lookup?phone=$ph');
                setState(() {
                  found = r as Map;
                  err = null;
                });
              } catch (e) {
                setState(() {
                  found = null;
                  err = e.toString();
                });
              }
            },
          ),
          if (found != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${found!['name']} ✓', style: const TextStyle(color: C.ok, fontWeight: FontWeight.w800))),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: C.red, fontSize: 12.5))),
          const SizedBox(height: 10),
          Text(ctx.t('Old owner'), style: const TextStyle(fontWeight: FontWeight.w700)),
          RadioListTile<String>(value: 'remove', groupValue: oldOwner, onChanged: (v) => setState(() => oldOwner = v!), title: Text(ctx.t('Remove from the gym'))),
          RadioListTile<String>(value: 'frontdesk', groupValue: oldOwner, onChanged: (v) => setState(() => oldOwner = v!), title: Text(ctx.t('Make front desk'))),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.indigo),
            onPressed: found == null || found!['trainer'] == true
                ? null
                : () async {
                    try {
                      await Api.instance.post('/super/gyms/$id/transfer', {'phone': phone.text.replaceAll(RegExp(r'\D'), ''), 'oldOwner': oldOwner});
                      done();
                      if (ctx.mounted) {
                        Navigator.pop(ctx);
                        toast(ctx, ctx.t('Gym transferred'));
                      }
                    } catch (e) {
                      setState(() => err = e.toString());
                    }
                  },
            child: Text(found == null ? ctx.t('Transfer') : ctx.t('Transfer to {name}', {'name': found!['name']})),
          ),
        ]),
      ),
    ),
  );
}

Future<void> adminCloseGym(BuildContext context, String id, String code, VoidCallback done) async {
  final confirm = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Close this gym?')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(ctx.t('Nobody can use the gym any more: no check-in, payment or join. Members see "This gym is closed". Owner and staff leave the gym, so their accounts can then be deleted from People. All records stay. You can reopen within 30 days.')),
        const SizedBox(height: 12),
        TextField(controller: confirm, textCapitalization: TextCapitalization.characters, decoration: InputDecoration(labelText: ctx.t('Type the gym code to confirm'), hintText: code)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Close gym'), style: const TextStyle(color: C.red))),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await Api.instance.post('/super/gyms/$id/close', {'confirm': confirm.text.trim()});
    done();
    if (context.mounted) toast(context, context.t('Gym closed'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

Future<void> adminReopenGym(BuildContext context, String id, VoidCallback done) async {
  try {
    await Api.instance.post('/super/gyms/$id/reopen', {});
    done();
    if (context.mounted) toast(context, context.t('Gym reopened'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

// ============================================================ send notification (board 59)

final _broadcasts = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/super/broadcasts'));

class AdminBroadcast extends ConsumerStatefulWidget {
  const AdminBroadcast({super.key});
  @override
  ConsumerState<AdminBroadcast> createState() => _AdminBroadcastState();
}

class _AdminBroadcastState extends ConsumerState<AdminBroadcast> {
  final title = TextEditingController();
  final message = TextEditingController();
  Set<String> roles = {'ALL'};
  String? state;
  bool busy = false;

  Future<void> send() async {
    if (title.text.trim().length < 2 || message.text.trim().length < 2) {
      toast(context, context.t('Write the title and the message'));
      return;
    }
    setState(() => busy = true);
    try {
      await Api.instance.post('/super/broadcasts', {'title': title.text.trim(), 'message': message.text.trim(), 'roles': roles.toList(), if (state != null) 'state': state});
      title.clear();
      message.clear();
      ref.invalidate(_broadcasts);
      if (mounted) toast(context, context.t('Sent'));
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = ((ref.watch(_broadcasts).valueOrNull as List?) ?? const []).cast<Map>();
    Widget chip(String k, String l) => ChoiceChip(
          label: Text(l),
          selected: roles.contains(k),
          showCheckmark: false,
          selectedColor: C.indigo,
          labelStyle: TextStyle(color: roles.contains(k) ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
          onSelected: (_) => setState(() {
            if (k == 'ALL') {
              roles = {'ALL'};
            } else {
              roles.remove('ALL');
              roles.contains(k) ? roles.remove(k) : roles.add(k);
              if (roles.isEmpty) roles = {'ALL'};
            }
          }),
        );
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Send notification'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Text(context.t('Who gets it'), style: TextStyle(color: context.c.mut, fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          chip('ALL', context.t('Everyone')),
          chip('OWNER', context.t('Owners')),
          chip('STAFF', context.t('Staff')),
          chip('TRAINER', context.t('Trainers')),
          chip('MEMBER', context.t('Members')),
        ]),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            final states = await loadIndia();
            if (!context.mounted) return;
            final s = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              builder: (ctx) => SafeArea(
                child: SizedBox(
                  height: MediaQuery.of(ctx).size.height * 0.7,
                  child: ListView(children: [
                    ListTile(title: Text(ctx.t('All states')), onTap: () => Navigator.pop(ctx, '')),
                    for (final st in states) ListTile(title: Text(st.name), onTap: () => Navigator.pop(ctx, st.name)),
                  ]),
                ),
              ),
            );
            if (s != null) setState(() => state = s.isEmpty ? null : s);
          },
          icon: const Icon(Icons.place_rounded),
          label: Text(state ?? context.t('All states')),
        ),
        const SizedBox(height: 12),
        TextField(controller: title, decoration: InputDecoration(labelText: context.t('Title'))),
        const SizedBox(height: 10),
        TextField(controller: message, maxLines: 4, decoration: InputDecoration(labelText: context.t('Message'))),
        const SizedBox(height: 14),
        FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: C.indigo), onPressed: busy ? null : send, icon: const Icon(Icons.campaign_rounded), label: Text(context.t('Send notification'))),
        const SizedBox(height: 6),
        Muted(context.t('It shows in Notifications in their app.'), size: 12),
        if (list.isNotEmpty) ...[
          const SizedBox(height: 18),
          SectionTitle(context.t('Sent')),
          for (final b in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(b['title'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                      Muted(b['body'] as String, size: 12.5),
                      Muted('${(b['roles'] as List).join(', ')}${b['state'] == null ? '' : ' · ${b['state']}'} · ${fmtDate(b['createdAt'] as String?)}', size: 11.5),
                    ]),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, color: C.red),
                    onPressed: () async {
                      await Api.instance.delete('/super/broadcasts/${b['id']}');
                      ref.invalidate(_broadcasts);
                    },
                  ),
                ]),
              ),
            ),
        ],
      ]),
    );
  }
}
