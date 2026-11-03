import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../photo.dart';
import '../session.dart';
import '../theme.dart';
import 'trainer.dart' show TrainerClientsScreen;
import '../ui.dart';
import 'home.dart' show openUrl, waLink;

// ============================================================ data

final myPtProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/pt'));
final gymTrainersProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, tid) => Api.instance.cachedGet('/me/gyms/$tid/trainers'));
final trainerClientsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/trainer/clients'));
final trainerPayoutsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/trainer/payouts'));
final ownerPtProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, status) => branchGet(ref, '/pt?status=$status'));
final ptAccountsProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/pt-accounts'));

String ymdOf(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String todayYmd() => ymdOf(DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30)));

// ============================================================ calendar

String _weekday(String ymd) => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][DateTime.parse(ymd).weekday - 1];

/// "7:00 AM" from "07:00".
String fmtTime(String? hm) {
  if (hm == null || !hm.contains(':')) return '';
  final h = int.tryParse(hm.split(':')[0]) ?? 0;
  final m = hm.split(':')[1];
  return '${h % 12 == 0 ? 12 : h % 12}:$m ${h < 12 ? 'AM' : 'PM'}';
}

Future<void> showPlannedSheet(BuildContext context, String ymd, Map? plan) => showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${ctx.t('PT planned')} · ${ctx.t(_weekday(ymd))} ${fmtDate(ymd)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _kv(ctx, ctx.t('For'), '${ctx.t(_weekday(ymd))} ${fmtDate(ymd)}${plan?['time'] != null ? ', ${fmtTime(plan!['time'] as String)}' : ''}'),
                if (plan?['byName'] != null) _kv(ctx, ctx.t('Planned by'), plan!['byName'] as String),
                if (plan?['at'] != null) _kv(ctx, ctx.t('Planned on'), fmtDateTime(plan!['at'] as String)),
                if (plan == null) Muted(ctx.t('Planned before times were saved — no more details.'), size: 12.5),
              ]),
            ),
          ]),
        ),
      ),
    );

Widget _kv(BuildContext context, String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 96, child: Text(k, style: TextStyle(color: context.c.mut, fontSize: 13))),
        Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5))),
      ]),
    );

/// The next planned PT day (today or later), for the member's card.
MapEntry<String, Map?>? nextPlanned(Map pt) {
  final log = (pt['log'] as Map?) ?? const {};
  final plans = (pt['plans'] as Map?) ?? const {};
  final today = todayYmd();
  final days = log.entries.where((e) => e.value == 'PLANNED' && (e.key as String).compareTo(today) >= 0).map((e) => e.key as String).toList()..sort();
  if (days.isEmpty) return null;
  return MapEntry(days.first, plans[days.first] as Map?);
}

const _monthNames = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

/// Month calendar of PT sessions. Green = done, red = missed, dashed = planned.
class PtCalendar extends StatefulWidget {
  const PtCalendar({super.key, required this.log, this.startDate, this.endDate, this.onTapDay, this.selected, this.plans});
  final Map log;
  /// Planned days: {date: {time, byName, at}}. Tapping a planned day shows them.
  final Map? plans;
  final String? startDate;
  final String? endDate;
  final ValueChanged<String>? onTapDay;
  final String? selected;
  @override
  State<PtCalendar> createState() => _PtCalendarState();
}

class _PtCalendarState extends State<PtCalendar> {
  late DateTime month;
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    month = DateTime(now.year, now.month);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final first = DateTime(month.year, month.month, 1);
    final daysIn = DateTime(month.year, month.month + 1, 0).day;
    final lead = first.weekday - 1; // Monday first
    final today = todayYmd();
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    final cells = <Widget>[
      for (final l in labels) Center(child: Text(l, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: p.mut))),
      for (var i = 0; i < lead; i++) const SizedBox(),
      for (var d = 1; d <= daysIn; d++)
        Builder(builder: (_) {
          final ymd = ymdOf(DateTime(month.year, month.month, d));
          final mark = widget.log[ymd] as String?;
          final inRange = (widget.startDate == null || ymd.compareTo(widget.startDate!) >= 0) && (widget.endDate == null || ymd.compareTo(widget.endDate!) <= 0);
          Color? bg;
          Color fg = inRange ? p.fg : p.mut.withAlpha(120);
          Border? border;
          if (mark == 'DONE') {
            bg = C.ok;
            fg = Colors.white;
          } else if (mark == 'MISSED') {
            bg = C.red.withAlpha(40);
            fg = C.red;
          } else if (mark == 'PLANNED') {
            border = Border.all(color: p.primary, width: 1.5);
            fg = p.primary;
          }
          if (ymd == widget.selected) border = Border.all(color: p.primary, width: 2.4);
          final cell = Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: border),
            alignment: Alignment.center,
            child: Text('$d', style: TextStyle(fontWeight: ymd == today ? FontWeight.w900 : FontWeight.w700, fontSize: 13, color: fg, decoration: ymd == today ? TextDecoration.underline : null)),
          );
          if (mark == 'PLANNED' && widget.plans != null) {
            // Planned day: show for which day and time, who planned it and when (trainer, owner and member).
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                if (widget.onTapDay != null && inRange) widget.onTapDay!(ymd);
                showPlannedSheet(context, ymd, widget.plans![ymd] as Map?);
              },
              child: cell,
            );
          }
          if (widget.onTapDay == null || !inRange) return cell;
          return GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => widget.onTapDay!(ymd), child: cell);
        }),
    ];
    Widget legend(Color c, String t, {bool dashed = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: dashed ? null : c, borderRadius: BorderRadius.circular(3), border: dashed ? Border.all(color: c, width: 1.5) : null)),
          const SizedBox(width: 5),
          Text(t, style: TextStyle(fontSize: 11, color: p.mut, fontWeight: FontWeight.w600)),
        ]);
    return Panel(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      child: Column(children: [
        Row(children: [
          IconButton(onPressed: () => setState(() => month = DateTime(month.year, month.month - 1)), icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(child: Center(child: Text('${context.t(_monthNames[month.month - 1])} ${month.year}', style: const TextStyle(fontWeight: FontWeight.w800)))),
          IconButton(onPressed: () => setState(() => month = DateTime(month.year, month.month + 1)), icon: const Icon(Icons.chevron_right_rounded)),
        ]),
        GridView.count(crossAxisCount: 7, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 1.05, children: cells),
        const SizedBox(height: 8),
        Wrap(spacing: 14, children: [legend(C.ok, context.t('Done')), legend(p.primary, context.t('Planned'), dashed: true), legend(C.red, context.t('Missed'))]),
      ]),
    );
  }
}

class _SessionStats extends StatelessWidget {
  const _SessionStats({required this.pt});
  final Map pt;
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: StatTile(icon: Icons.check_rounded, value: '${pt['done'] ?? 0}', label: context.t('Done'), color: C.ok)),
        const SizedBox(width: 9),
        Expanded(child: StatTile(icon: Icons.event_rounded, value: '${pt['left'] ?? 0}', label: context.t('Left'))),
        const SizedBox(width: 9),
        Expanded(child: StatTile(icon: Icons.close_rounded, value: '${pt['missed'] ?? 0}', label: context.t('Missed'), color: C.red)),
      ]);
}

class SessionsBar extends StatelessWidget {
  const SessionsBar({super.key, required this.left, required this.total, this.color, this.onDark = false});
  final int left;
  final int total;
  final Color? color;
  final bool onDark;
  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: LinearProgressIndicator(
          value: total == 0 ? 0 : left / total,
          minHeight: 7,
          backgroundColor: onDark ? Colors.white.withAlpha(70) : context.c.surf2,
          color: onDark ? Colors.white : (color ?? context.c.primary),
        ),
      );
}

String ptStateLabel(BuildContext context, Map pt) => switch (pt['state']) {
      'PENDING' => context.t('Waiting for owner approval'),
      'COMPLETED' => context.t('All sessions done'),
      'EXPIRED' => context.t('PT time is over'),
      _ => pt['endDate'] == null ? '' : context.t('Till {date}', {'date': fmtDate(pt['endDate'] as String?)}),
    };

// ============================================================ member: trainers

class MemberTrainersScreen extends ConsumerStatefulWidget {
  const MemberTrainersScreen({super.key});
  @override
  ConsumerState<MemberTrainersScreen> createState() => _MemberTrainersState();
}

class _MemberTrainersState extends ConsumerState<MemberTrainersScreen> {
  String? tenantId;
  String filter = '';

  @override
  Widget build(BuildContext context) {
    final gyms = ref.watch(gymsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Trainers'))),
      body: AsyncBody(
        value: gyms,
        onRetry: () => ref.invalidate(gymsProvider),
        builder: (g) {
          final list = (g['memberships'] as List).cast<Map>();
          if (list.isEmpty) {
            return Center(child: Padding(padding: const EdgeInsets.all(28), child: Muted(context.t('Join a gym first to see its trainers.'), align: TextAlign.center, size: 14)));
          }
          final tid = tenantId ?? list.first['gym']['id'] as String;
          final v = ref.watch(gymTrainersProvider(tid));
          return RefreshIndicator(
            color: context.c.primary,
            onRefresh: () async => ref.invalidate(gymTrainersProvider(tid)),
            child: AsyncBody(
              value: v,
              onRetry: () => ref.invalidate(gymTrainersProvider(tid)),
              builder: (d) {
                final trainers = (d['trainers'] as List).cast<Map>();
                final mine = (d['myPt'] as List).cast<Map>();
                final myIds = mine.map((p) => p['trainerId']).toSet();
                final specs = trainers.map((t) => t['speciality'] as String?).whereType<String>().toSet().toList();
                final others = trainers.where((t) => !myIds.contains(t['id']) && (filter.isEmpty || t['speciality'] == filter)).toList();
                return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
                  if (list.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Wrap(spacing: 8, children: [
                        for (final m in list)
                          ChoiceChip(label: Text(m['gym']['name'] as String), selected: m['gym']['id'] == tid, onSelected: (_) => setState(() => tenantId = m['gym']['id'] as String)),
                      ]),
                    ),
                  if (mine.isNotEmpty) ...[
                    Muted(context.t('My trainer'), size: 13),
                    const SizedBox(height: 8),
                    for (final p in mine) Padding(padding: const EdgeInsets.only(bottom: 12), child: MyTrainerCard(pt: p, tenantId: tid)),
                  ],
                  if (trainers.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Muted(context.t('Your gym has not added trainers in the app yet.'), align: TextAlign.center)),
                  if (others.isNotEmpty || filter.isNotEmpty) ...[
                    Muted(mine.isEmpty ? context.t('Choose a trainer') : context.t('Other trainers'), size: 13),
                    const SizedBox(height: 8),
                    if (specs.length > 1)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(children: [
                          for (final s in ['', ...specs])
                            Padding(
                              padding: const EdgeInsets.only(right: 8, bottom: 8),
                              child: ChoiceChip(
                                label: Text(s.isEmpty ? context.t('All') : context.t(s)),
                                selected: filter == s,
                                showCheckmark: false,
                                selectedColor: context.c.primary,
                                labelStyle: TextStyle(color: filter == s ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                                onSelected: (_) => setState(() => filter = s),
                              ),
                            ),
                        ]),
                      ),
                    for (final t in others) Padding(padding: const EdgeInsets.only(bottom: 10), child: _TrainerRow(t: t, tenantId: tid)),
                  ],
                ]);
              },
            ),
          );
        },
      ),
    );
  }
}

class _TrainerRow extends StatelessWidget {
  const _TrainerRow({required this.t, required this.tenantId});
  final Map t;
  final String tenantId;
  @override
  Widget build(BuildContext context) {
    final pkgs = (t['packages'] as List).cast<Map>();
    final cheapest = pkgs.isEmpty ? null : pkgs.reduce((a, b) => (a['price'] as num) <= (b['price'] as num) ? a : b);
    return Panel(
      onTap: () => context.push('/trainer-detail', extra: {'trainer': t, 'tenantId': tenantId}),
      padding: const EdgeInsets.all(12),
      child: Row(children: [
        Avatar(name: t['name'] as String, url: t['photoUrl'] as String?, size: 52),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            Muted([t['speciality'], if (t['experienceYears'] != null) context.t('{n} years', {'n': t['experienceYears']})].where((x) => x != null).join(' · '), size: 12),
            if (cheapest != null)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: rupees(cheapest['price'] as num?), style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w800)),
                  TextSpan(text: ' · ${context.t('{n} sessions', {'n': cheapest['sessions']})}', style: TextStyle(color: context.c.mut, fontSize: 12, fontWeight: FontWeight.w600)),
                ])),
              ),
          ]),
        ),
        Icon(Icons.chevron_right_rounded, color: context.c.mut),
      ]),
    );
  }
}

/// Orange "My trainer" card. Tap for sessions and calendar.
class MyTrainerCard extends StatelessWidget {
  const MyTrainerCard({super.key, required this.pt, required this.tenantId});
  final Map pt;
  final String tenantId;
  @override
  Widget build(BuildContext context) {
    final pending = pt['state'] == 'PENDING';
    return Material(
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: pending
              ? const LinearGradient(colors: [Color(0xFF3A4150), Color(0xFF232833)])
              : const LinearGradient(colors: [C.orangeSoft, C.orange, C.orangeDeep], begin: Alignment.topLeft, end: Alignment.bottomRight),
        ),
        child: InkWell(
          onTap: () => context.push('/my-pt', extra: {'pt': pt, 'tenantId': tenantId}),
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white.withAlpha(160), width: 2.5)),
                  child: Avatar(name: pt['trainerName'] as String, url: pt['trainerPhotoUrl'] as String?, size: 48),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.t('MY TRAINER'), style: const TextStyle(color: Color(0xDDFFFFFF), fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                    Text(pt['trainerName'] as String, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.white),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Text(
                    pending ? ptStateLabel(context, pt) : context.t('{left} / {total} sessions left', {'left': pt['left'], 'total': pt['sessions']}),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12.5),
                  ),
                ),
                if (!pending) Text(ptStateLabel(context, pt), style: const TextStyle(color: Color(0xEEFFFFFF), fontWeight: FontWeight.w600, fontSize: 12)),
              ]),
              if (!pending) ...[const SizedBox(height: 6), SessionsBar(left: pt['left'] as int, total: pt['sessions'] as int, onDark: true)],
            ]),
          ),
        ),
      ),
    );
  }
}

class TrainerDetailScreen extends ConsumerStatefulWidget {
  const TrainerDetailScreen({super.key, required this.trainer, required this.tenantId});
  final Map trainer;
  final String tenantId;
  @override
  ConsumerState<TrainerDetailScreen> createState() => _TrainerDetailState();
}

class _TrainerDetailState extends ConsumerState<TrainerDetailScreen> {
  String? packageId;
  bool busy = false;
  String? error;
  bool sent = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.trainer;
    final pkgs = (t['packages'] as List).cast<Map>();
    packageId ??= pkgs.isEmpty ? null : pkgs[pkgs.length > 1 ? 1 : 0]['id'] as String;
    final p = context.c;
    if (sent) {
      return Scaffold(
        appBar: AppBar(),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const SizedBox(height: 20),
          Center(child: Container(width: 96, height: 96, decoration: BoxDecoration(color: C.ok.withAlpha(36), shape: BoxShape.circle), child: const Icon(Icons.check_rounded, size: 48, color: C.ok))),
          const SizedBox(height: 18),
          Text(context.t('PT request sent'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Muted(t['name'] as String, align: TextAlign.center, size: 14),
          const SizedBox(height: 20),
          Panel(
            child: Column(children: [
              _Step(context.t('Trainer got a notification'), C.ok, Icons.check_rounded),
              _Step(context.t('Owner got a notification — only the owner approves'), C.warn, Icons.schedule_rounded),
              _Step(context.t('PT starts — diet and workout plan'), p.line, null),
            ]),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.primary.withAlpha(30), borderRadius: BorderRadius.circular(16)),
            child: Text(context.t('Pay at the gym front desk. PT starts once the owner approves.'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5)),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: () => context.pop(), child: Text(context.t('Done'))),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Trainer'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Row(children: [
          Avatar(name: t['name'] as String, url: t['photoUrl'] as String?, size: 80, ring: true),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t['name'] as String, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              Muted([t['speciality'], if (t['experienceYears'] != null) context.t('{n} years', {'n': t['experienceYears']})].where((x) => x != null).join(' · ')),
              if (t['hours'] != null) ...[
                const SizedBox(height: 6),
                Row(children: [const Icon(Icons.schedule_rounded, size: 15, color: C.ok), const SizedBox(width: 5), Text(t['hours'] as String, style: const TextStyle(color: C.ok, fontWeight: FontWeight.w700, fontSize: 12.5))]),
              ],
            ]),
          ),
        ]),
        if (t['bio'] != null) ...[const SizedBox(height: 14), Text(t['bio'] as String, style: TextStyle(color: p.mut, height: 1.45))],
        const SizedBox(height: 18),
        SectionTitle(context.t('PT packages')),
        if (pkgs.isEmpty) Muted(context.t('No PT packages yet. Ask the gym.')),
        for (final k in pkgs)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: p.surf,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: packageId == k['id'] ? p.primary : p.line, width: packageId == k['id'] ? 2 : 1)),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => setState(() => packageId = k['id'] as String),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(context.t('{n} sessions', {'n': k['sessions']}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        Muted(
                          [context.t('{n} days', {'n': k['days']}), if (k['perWeek'] != null) context.t('{n} days a week', {'n': k['perWeek']})].join(' · '),
                          size: 12,
                        ),
                      ]),
                    ),
                    Text(rupees(k['price'] as num?), style: TextStyle(color: p.primary, fontWeight: FontWeight.w800, fontSize: 17)),
                  ]),
                ),
              ),
            ),
          ),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: busy || packageId == null
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await Api.instance.post('/me/pt', {'tenantId': widget.tenantId, 'trainerId': t['id'], 'packageId': packageId});
                    ref.invalidate(gymTrainersProvider(widget.tenantId));
                    ref.invalidate(myPtProvider);
                    setState(() => sent = true);
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Take PT')),
        ),
      ]),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step(this.text, this.color, this.icon);
  final String text;
  final Color color;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          Container(width: 26, height: 26, decoration: BoxDecoration(color: color, shape: BoxShape.circle), child: icon == null ? null : Icon(icon, size: 15, color: Colors.white)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );
}

/// Member: their PT with one trainer — sessions and calendar.
class MyPtScreen extends ConsumerWidget {
  const MyPtScreen({super.key, required this.pt, required this.tenantId});
  final Map pt;
  final String tenantId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Use the freshest copy if the list has it.
    final fresh = ((ref.watch(myPtProvider).valueOrNull as List?) ?? const []).cast<Map>().where((p) => p['id'] == pt['id']).firstOrNull ?? pt;
    final p = fresh;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('My trainer'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(myPtProvider),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
          Row(children: [
            Avatar(name: p['trainerName'] as String, url: p['trainerPhotoUrl'] as String?, size: 60, ring: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['trainerName'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Muted(
                  p['startDate'] == null
                      ? ptStateLabel(context, p)
                      : '${context.t('{n} sessions', {'n': p['sessions']})} · ${fmtDate(p['startDate'] as String?)} – ${fmtDate(p['endDate'] as String?)}',
                  size: 12.5,
                ),
              ]),
            ),
            if (p['trainerPhone'] != null)
              IconButton.filled(
                style: IconButton.styleFrom(backgroundColor: C.wa.withAlpha(40), foregroundColor: C.wa),
                onPressed: () => openUrl(waLink(p['trainerPhone'] as String, 'Hi ${p['trainerName']},')),
                icon: const Icon(Icons.chat_rounded),
              ),
          ]),
          const SizedBox(height: 14),
          if (p['state'] == 'PENDING')
            Panel(child: Row(children: [const IconTile(Icons.hourglass_top_rounded, color: C.warn), const SizedBox(width: 12), Expanded(child: Text(ptStateLabel(context, p), style: const TextStyle(fontWeight: FontWeight.w700)))]))
          else ...[
            _SessionStats(pt: p),
            const SizedBox(height: 12),
            Builder(builder: (_) {
              final next = nextPlanned(p);
              if (next == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Panel(
                  onTap: () => showPlannedSheet(context, next.key, next.value),
                  child: Row(children: [
                    const IconTile(Icons.event_available_rounded, color: C.blue),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Muted(context.t('Next PT'), size: 12),
                        Text('${context.t(_weekday(next.key))} ${fmtDate(next.key)}${next.value?['time'] != null ? ' · ${fmtTime(next.value!['time'] as String)}' : ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                        if (next.value?['byName'] != null)
                          Muted(context.t('{who} planned it on {date}', {'who': next.value!['byName'], 'date': fmtDate(next.value!['at'] as String?)}), size: 12),
                      ]),
                    ),
                  ]),
                ),
              );
            }),
            PtCalendar(log: (p['log'] as Map?) ?? const {}, plans: (p['plans'] as Map?) ?? const {}, startDate: p['startDate'] as String?, endDate: p['endDate'] as String?),
            const SizedBox(height: 8),
            Muted(context.t('Your trainer marks each session here. Tap a planned (dashed) day to see its time.'), size: 12),
          ],
        ]),
      ),
    );
  }
}

// ============================================================ trainer

class TrainerClientsList extends ConsumerStatefulWidget {
  const TrainerClientsList({super.key});
  @override
  ConsumerState<TrainerClientsList> createState() => _TrainerClientsListState();
}

class _TrainerClientsListState extends ConsumerState<TrainerClientsList> {
  bool soonOnly = false;
  @override
  Widget build(BuildContext context) {
    if (ref.watch(sessionProvider).mode != 'trainer') return const TrainerClientsScreen();
    final v = ref.watch(trainerClientsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('My PT clients'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(trainerClientsProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(trainerClientsProvider),
          builder: (d) {
            final all = (d['clients'] as List).cast<Map>();
            final tid = d['tenantId'] as String;
            final soon = all.where((c) => c['endingSoon'] == true).length;
            final list = soonOnly ? all.where((c) => c['endingSoon'] == true).toList() : all;
            if (all.isEmpty) {
              return ListView(padding: const EdgeInsets.all(28), children: [
                const SizedBox(height: 60),
                Icon(Icons.groups_rounded, size: 60, color: context.c.mut),
                const SizedBox(height: 12),
                Text(context.t('No PT clients yet'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Muted(context.t('When a member takes PT with you and the owner approves, they show here with sessions left and the calendar.'), align: TextAlign.center),
              ]);
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Row(children: [
                ChoiceChip(label: Text('${context.t('All')} (${all.length})'), selected: !soonOnly, onSelected: (_) => setState(() => soonOnly = false)),
                const SizedBox(width: 8),
                ChoiceChip(label: Text('${context.t('Ending soon')} ($soon)'), selected: soonOnly, onSelected: (_) => setState(() => soonOnly = true)),
              ]),
              const SizedBox(height: 10),
              for (final c in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: PtClientRow(pt: c, onTap: () => context.push('/pt-client', extra: {'pt': c, 'tenantId': tid, 'canMark': true}))),
              Muted(context.t('The owner sees the same list.'), size: 12),
            ]);
          },
        ),
      ),
    );
  }
}

class PtClientRow extends StatelessWidget {
  const PtClientRow({super.key, required this.pt, required this.onTap, this.showTrainer = false});
  final Map pt;
  final VoidCallback onTap;
  final bool showTrainer;
  @override
  Widget build(BuildContext context) {
    final pending = pt['state'] == 'PENDING';
    final warn = pt['endingSoon'] == true;
    final col = warn ? C.warn : context.c.primary;
    return Panel(
      onTap: onTap,
      padding: const EdgeInsets.all(13),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Avatar(name: pt['memberName'] as String, url: pt['memberPhotoUrl'] as String?, size: 44),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pt['memberName'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
              Muted(showTrainer ? '${context.t('Trainer')}: ${pt['trainerName']}' : ptStateLabel(context, pt), size: 12),
            ]),
          ),
          if (!pending)
            Text.rich(TextSpan(children: [
              TextSpan(text: '${pt['left']}', style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 18)),
              TextSpan(text: '/${pt['sessions']}', style: TextStyle(color: context.c.mut, fontSize: 12)),
            ]))
          else
            StatusChip('UPCOMING', extra: null),
        ]),
        if (!pending) ...[const SizedBox(height: 8), SessionsBar(left: pt['left'] as int, total: pt['sessions'] as int, color: col)],
        if (warn) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(color: C.warn.withAlpha(36), borderRadius: BorderRadius.circular(99)),
            child: Text(context.t('Ending soon'), style: const TextStyle(color: C.warn, fontWeight: FontWeight.w700, fontSize: 11.5)),
          ),
        ],
      ]),
    );
  }
}

/// One PT client: stats, calendar; the trainer (or owner) taps a date to mark it.
class PtClientScreen extends ConsumerStatefulWidget {
  const PtClientScreen({super.key, required this.pt, required this.tenantId, required this.canMark});
  final Map pt;
  final String tenantId;
  final bool canMark;
  @override
  ConsumerState<PtClientScreen> createState() => _PtClientState();
}

class _PtClientState extends ConsumerState<PtClientScreen> {
  late Map pt = widget.pt;
  String? selected;
  bool busy = false;

  Future<void> mark(String date, String m) async {
    String? time;
    if (m == 'PLANNED') {
      // Time of the planned session (optional): member and owner see it.
      final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 7, minute: 0), helpText: context.t('PT time (optional)'), cancelText: context.t('No time'));
      if (t != null) time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      if (!mounted) return;
    }
    setState(() => busy = true);
    try {
      final r = await Api.instance.post('/pt/${pt['id']}/session', {'tenantId': widget.tenantId, 'date': date, 'mark': m, if (time != null) 'time': time});
      setState(() => pt = {...pt, ...(r as Map)});
      ref.invalidate(trainerClientsProvider);
      ref.invalidate(ownerPtProvider('ACTIVE'));
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final pending = pt['state'] == 'PENDING';
    final sel = selected ?? todayYmd();
    final current = (pt['log'] as Map?)?[sel] as String?;
    final inRange = pt['startDate'] != null && sel.compareTo(pt['startDate'] as String) >= 0 && (pt['endDate'] == null || sel.compareTo(pt['endDate'] as String) <= 0);
    final today = todayYmd();
    final future = sel.compareTo(today) > 0;
    final past = sel.compareTo(today) < 0;
    // Trainers may change Done / Missed only for today and the 2 days before; the owner can fix any day.
    final me = ref.watch(sessionProvider).user ?? {};
    final asTrainer = me['isTrainer'] == true && me['isOwner'] != true;
    final lockedOld = asTrainer && past && sel.compareTo(ymdOf(DateTime.parse('${today}T00:00:00Z').subtract(const Duration(days: 2)))) < 0;
    bool allowed(String m) {
      if (lockedOld) return false;
      if ((m == 'DONE' || m == 'MISSED') && future) return false;
      if (m == 'PLANNED' && past && current != 'PLANNED') return false;
      return true;
    }

    Widget act(String m, String label, Color bg, Color fg, IconData icon) {
      final ok = allowed(m);
      final on = current == m;
      return Expanded(
        child: Material(
          color: ok ? bg : p.surf2,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: busy || !ok ? null : () => mark(sel, on ? 'CLEAR' : m),
            child: SizedBox(
              height: 58,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(!ok ? Icons.lock_outline_rounded : on ? Icons.undo_rounded : icon, size: 19, color: ok ? fg : p.mut),
                const SizedBox(height: 3),
                Text(on && ok ? context.t('Undo') : label, maxLines: 1, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: ok ? fg : p.mut)),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(pt['memberName'] as String)),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
        Row(children: [
          Avatar(name: pt['memberName'] as String, url: pt['memberPhotoUrl'] as String?, size: 58, ring: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(pt['memberName'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              Muted(pending ? ptStateLabel(context, pt) : '${context.t('Trainer')}: ${pt['trainerName']} · ${ptStateLabel(context, pt)}', size: 12.5),
            ]),
          ),
          if (pt['memberPhone'] != null)
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: C.wa.withAlpha(40), foregroundColor: C.wa),
              onPressed: () => openUrl(waLink(pt['memberPhone'] as String, 'Hi ${pt['memberName']},')),
              icon: const Icon(Icons.chat_rounded),
            ),
        ]),
        const SizedBox(height: 14),
        if (pending)
          Panel(child: Row(children: [const IconTile(Icons.hourglass_top_rounded, color: C.warn), const SizedBox(width: 12), Expanded(child: Text(ptStateLabel(context, pt), style: const TextStyle(fontWeight: FontWeight.w700)))]))
        else ...[
          _SessionStats(pt: pt),
          const SizedBox(height: 12),
          PtCalendar(
            log: (pt['log'] as Map?) ?? const {},
            plans: (pt['plans'] as Map?) ?? const {},
            startDate: pt['startDate'] as String?,
            endDate: pt['endDate'] as String?,
            selected: widget.canMark ? sel : null,
            onTapDay: widget.canMark ? (d) => setState(() => selected = d) : null,
          ),
          if (widget.canMark) ...[
            const SizedBox(height: 12),
            Material(
              color: p.surf,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: p.primary, width: 1.5)),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(fmtDate(sel), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  Muted(
                    !inRange
                        ? context.t('This date is outside the PT dates')
                        : lockedOld
                            ? context.t('Locked: older than 2 days. Ask the owner to change it.')
                            : future
                                ? context.t('Coming day: you can only mark it Planned')
                                : context.t('Tap a date on the calendar to change it'),
                    size: 12,
                  ),
                  const SizedBox(height: 12),
                  if (inRange)
                    Row(children: [
                      act('DONE', context.t('Done'), C.ok, Colors.white, Icons.check_rounded),
                      const SizedBox(width: 8),
                      act('MISSED', context.t('Missed'), C.red.withAlpha(40), C.red, Icons.close_rounded),
                      const SizedBox(width: 8),
                      act('PLANNED', context.t('Planned'), C.blue.withAlpha(36), C.blue, Icons.event_rounded),
                    ]),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Muted(context.t('The member and the owner see this calendar too.'), size: 12),
            const SizedBox(height: 16),
            SectionTitle(context.t('Plan')),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final (w, icon, label) in [(false, Icons.restaurant_rounded, context.t('Diet chart')), (true, Icons.fitness_center_rounded, context.t('Workout plan'))])
                  ListTile(
                    leading: IconTile(icon, size: 36),
                    title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(color: p.primary.withAlpha(36), borderRadius: BorderRadius.circular(10)),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.edit_rounded, size: 14, color: p.primary), const SizedBox(width: 4), Text(context.t('Edit'), style: TextStyle(color: p.primary, fontWeight: FontWeight.w700, fontSize: 12.5))]),
                    ),
                    onTap: () => context.push('/program-edit', extra: {'tenantId': widget.tenantId, 'memberId': pt['memberId'], 'memberName': pt['memberName'], 'workout': w}),
                  ),
              ]),
            ),
          ],
        ],
      ]),
    );
  }
}

class TrainerPayoutsCard extends ConsumerWidget {
  const TrainerPayoutsCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(trainerPayoutsProvider).valueOrNull;
    final list = (v as List?)?.cast<Map>() ?? const [];
    if (list.isEmpty) return const SizedBox.shrink();
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const IconTile(Icons.account_balance_wallet_rounded, color: C.ok, size: 36),
          const SizedBox(width: 10),
          Expanded(child: Text(context.t('Payments from the gym'), style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        for (final p in list.take(4))
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(children: [
              Expanded(child: Muted(fmtDateTime(p['at'] as String), size: 12.5)),
              Text(rupees(p['amount'] as num?), style: const TextStyle(fontWeight: FontWeight.w800, color: C.ok)),
            ]),
          ),
      ]),
    );
  }
}

// ============================================================ owner

class OwnerPtRequests extends ConsumerWidget {
  const OwnerPtRequests({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(ownerPtProvider('PENDING'));
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    return AsyncBody(
      value: v,
      onRetry: () => ref.invalidate(ownerPtProvider('PENDING')),
      builder: (d) {
        final list = (d as List).cast<Map>();
        if (list.isEmpty) return Padding(padding: const EdgeInsets.all(30), child: Muted(context.t('No PT requests right now.'), align: TextAlign.center));
        return Column(children: [
          for (final p in list)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Panel(
                padding: const EdgeInsets.all(14),
                child: Column(children: [
                  Row(children: [
                    Avatar(name: p['memberName'] as String, url: p['memberPhotoUrl'] as String?, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${p['memberName']} → ${p['trainerName']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
                        Muted('${context.t('{n} sessions', {'n': p['sessions']})} · ${context.t('{n} days', {'n': p['days']})} · ${rupees(p['price'] as num?)}', size: 12),
                      ]),
                    ),
                  ]),
                  if (owner) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: C.ok, minimumSize: const Size.fromHeight(42)),
                          onPressed: () async {
                            final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _ApprovePtSheet(pt: p));
                            if (ok == true) {
                              ref.invalidate(ownerPtProvider('PENDING'));
                              ref.invalidate(ownerPtProvider('ACTIVE'));
                              ref.invalidate(dashboardProvider);
                            }
                          },
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: Text(context.t('Approve')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                          onPressed: () async {
                            try {
                              await Api.instance.post('/pt/${p['id']}/decline', {});
                              ref.invalidate(ownerPtProvider('PENDING'));
                              ref.invalidate(dashboardProvider);
                            } catch (e) {
                              if (context.mounted) toastError(context, e);
                            }
                          },
                          child: Text(context.t('Decline')),
                        ),
                      ),
                    ]),
                  ],
                ]),
              ),
            ),
        ]);
      },
    );
  }
}

class _ApprovePtSheet extends StatefulWidget {
  const _ApprovePtSheet({required this.pt});
  final Map pt;
  @override
  State<_ApprovePtSheet> createState() => _ApprovePtSheetState();
}

class _ApprovePtSheetState extends State<_ApprovePtSheet> {
  late final amount = TextEditingController(text: '${widget.pt['price']}');
  String mode = 'CASH';
  bool notPaid = false;
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    Widget chip(String k, String l) => ChoiceChip(
          label: Text(context.t(l)),
          selected: (k == 'NOT_PAID' && notPaid) || (!notPaid && mode == k),
          showCheckmark: false,
          selectedColor: context.c.primary,
          labelStyle: TextStyle(color: ((k == 'NOT_PAID' && notPaid) || (!notPaid && mode == k)) ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
          onSelected: (_) => setState(() {
            notPaid = k == 'NOT_PAID';
            if (!notPaid) mode = k;
          }),
        );
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.t('Approve PT'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        Muted('${widget.pt['memberName']} → ${widget.pt['trainerName']} · ${rupees(widget.pt['price'] as num?)}'),
        const SizedBox(height: 14),
        Muted(context.t('PT payment (kept apart from membership)'), size: 12.5),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [chip('CASH', 'Cash'), chip('UPI', 'UPI'), chip('CARD', 'Card'), chip('NOT_PAID', 'Not paid yet')]),
        if (!notPaid) ...[
          const SizedBox(height: 12),
          TextField(controller: amount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Amount received'), prefixText: '₹ ')),
        ],
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    final amt = int.tryParse(amount.text.trim()) ?? 0;
                    await Api.instance.post('/pt/${widget.pt['id']}/approve', {if (!notPaid && amt > 0) ...{'amountReceived': amt, 'paymentMode': mode}});
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Approve and start PT')),
        ),
      ]),
    );
  }
}

/// Owner: every PT client of every trainer.
class OwnerPtClientsScreen extends ConsumerStatefulWidget {
  const OwnerPtClientsScreen({super.key});
  @override
  ConsumerState<OwnerPtClientsScreen> createState() => _OwnerPtClientsState();
}

class _OwnerPtClientsState extends ConsumerState<OwnerPtClientsScreen> {
  String trainer = '';
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(ownerPtProvider('ACTIVE'));
    final tid = ref.watch(sessionProvider).myGym?['id'] as String? ?? '';
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    return Scaffold(
      appBar: AppBar(title: Text(context.t('PT clients'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(ownerPtProvider('ACTIVE')),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(ownerPtProvider('ACTIVE')),
          builder: (d) {
            final all = (d as List).cast<Map>();
            final names = all.map((p) => p['trainerName'] as String).toSet().toList()..sort();
            final list = trainer.isEmpty ? all : all.where((p) => p['trainerName'] == trainer).toList();
            if (all.isEmpty) return ListView(padding: const EdgeInsets.all(30), children: [const SizedBox(height: 60), Muted(context.t('No PT clients yet.'), align: TextAlign.center, size: 14)]);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  for (final n in ['', ...names])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(label: Text(n.isEmpty ? '${context.t('All')} (${all.length})' : n), selected: trainer == n, onSelected: (_) => setState(() => trainer = n)),
                    ),
                ]),
              ),
              const SizedBox(height: 10),
              for (final p in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: PtClientRow(pt: p, showTrainer: true, onTap: () => context.push('/pt-client', extra: {'pt': p, 'tenantId': tid, 'canMark': owner})),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Owner: PT money — what each trainer is owed and payouts.
class PtAccountsScreen extends ConsumerWidget {
  const PtAccountsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(ptAccountsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('PT accounts'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(ptAccountsProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(ptAccountsProvider),
          builder: (d) {
            final rows = (d['trainers'] as List).cast<Map>();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Muted(context.t('This month · kept apart from membership money'), size: 12.5),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: StatTile(icon: Icons.currency_rupee_rounded, value: rupees(d['collected'] as num?), label: context.t('PT money received'), color: C.ok)),
                const SizedBox(width: 10),
                Expanded(child: StatTile(icon: Icons.account_balance_wallet_rounded, value: rupees(d['due'] as num?), label: context.t('To pay trainers'))),
              ]),
              const SizedBox(height: 12),
              if (rows.isEmpty) Muted(context.t('No trainers yet.')),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Panel(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      Row(children: [
                        Avatar(name: r['name'] as String, url: r['photoUrl'] as String?, size: 44),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                            Muted(context.t('{n} clients · {s} sessions this month', {'n': r['clients'], 's': r['sessions']}), size: 12),
                          ]),
                        ),
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Muted(context.t('To pay'), size: 11),
                          Text((r['due'] as num) > 0 ? rupees(r['due'] as num?) : context.t('Clear ✓'), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: (r['due'] as num) > 0 ? context.c.primary : C.ok)),
                        ]),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: Muted(context.t('Share {p}% = {amount}', {'p': r['sharePercent'], 'amount': rupees(r['earned'] as num?)}), size: 12)),
                        Muted('${context.t('Paid')} ${rupees(r['paid'] as num?)}', size: 12),
                      ]),
                      if ((r['due'] as num) > 0) ...[
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                          onPressed: () async {
                            final ok = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, builder: (_) => _PayoutSheet(row: r));
                            if (ok == true) ref.invalidate(ptAccountsProvider);
                          },
                          icon: const Icon(Icons.payments_rounded, size: 18),
                          label: Text(context.t('Pay trainer')),
                        ),
                      ],
                    ]),
                  ),
                ),
              Muted(context.t('Trainer share is set on each trainer’s page.'), size: 12),
            ]);
          },
        ),
      ),
    );
  }
}

class _PayoutSheet extends StatefulWidget {
  const _PayoutSheet({required this.row});
  final Map row;
  @override
  State<_PayoutSheet> createState() => _PayoutSheetState();
}

class _PayoutSheetState extends State<_PayoutSheet> {
  late final amount = TextEditingController(text: '${widget.row['due']}');
  final note = TextEditingController();
  String mode = 'UPI';
  bool busy = false;
  String? error;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.t('Pay trainer'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
        Muted('${widget.row['name']} · ${context.t('To pay')} ${rupees(widget.row['due'] as num?)}'),
        const SizedBox(height: 14),
        TextField(controller: amount, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: context.t('Amount'), prefixText: '₹ ')),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          for (final (k, l) in const [('CASH', 'Cash'), ('UPI', 'UPI'), ('BANK_TRANSFER', 'Bank transfer')])
            ChoiceChip(
              label: Text(context.t(l)),
              selected: mode == k,
              showCheckmark: false,
              selectedColor: context.c.primary,
              labelStyle: TextStyle(color: mode == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
              onSelected: (_) => setState(() => mode = k),
            ),
        ]),
        const SizedBox(height: 10),
        TextField(controller: note, decoration: InputDecoration(labelText: context.t('Note (optional)'))),
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await Api.instance.post('/pt-payouts', {'trainerId': widget.row['trainerId'], 'amount': int.tryParse(amount.text.trim()) ?? 0, 'mode': mode, 'note': note.text.trim()});
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Save payment')),
        ),
        const SizedBox(height: 6),
        Muted(context.t('The trainer sees this payment in their app.'), size: 11.5),
      ]),
    );
  }
}
