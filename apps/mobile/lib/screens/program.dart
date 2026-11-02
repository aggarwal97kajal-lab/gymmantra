import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../theme.dart';
import '../session.dart';
import '../ui.dart';
import 'pdf.dart';

final myProgramProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/me/program'));

const weekDays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

// ============================================================ member: My plan

class MyPlanScreen extends ConsumerStatefulWidget {
  const MyPlanScreen({super.key});
  @override
  ConsumerState<MyPlanScreen> createState() => _MyPlanState();
}

class _MyPlanState extends ConsumerState<MyPlanScreen> {
  bool workout = false;
  int day = -1;

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(myProgramProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('My plan'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(myProgramProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(myProgramProvider),
          builder: (d) {
            final list = (d as List).cast<Map>();
            final guides = Panel(
              onTap: () => context.go('/workouts'),
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                const IconTile(Icons.view_in_ar_rounded, size: 42),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(context.t('3D exercise guides'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    Muted(context.t('40 exercises with correct form'), size: 12),
                  ]),
                ),
                Icon(Icons.chevron_right_rounded, color: context.c.mut),
              ]),
            );
            if (list.isEmpty) {
              return ListView(padding: const EdgeInsets.all(20), children: [
                const SizedBox(height: 40),
                Icon(Icons.restaurant_menu_rounded, size: 60, color: context.c.mut),
                const SizedBox(height: 12),
                Text(context.t('No plan yet'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Muted(context.t('Take PT with a trainer. Your trainer makes your diet chart and workout here.'), align: TextAlign.center),
                const SizedBox(height: 14),
                Center(child: SizedBox(width: 200, child: FilledButton(onPressed: () => context.go('/trainers'), child: Text(context.t('See trainers'))))),
                const SizedBox(height: 24),
                guides,
              ]);
            }
            final prog = list.first;
            final diet = prog['diet'] as Map?;
            final wk = prog['workout'] as Map?;
            final dietPdf = prog['dietPdf'] as Map?;
            final workoutPdf = prog['workoutPdf'] as Map?;
            final me = ref.watch(sessionProvider).user ?? {};
            final mark = '${me['name'] ?? ''} · ${(prog['gym'] as Map?)?['name'] ?? ''}';
            final tid = (prog['gym'] as Map)['id'] as String;
            final days = ((wk?['days'] as List?) ?? const []).cast<Map>();
            final todayName = weekDays[DateTime.now().weekday - 1];
            if (day < 0 || day >= days.length) {
              final i = days.indexWhere((x) => x['day'] == todayName);
              day = i < 0 ? 0 : i;
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Seg<bool>(
                value: workout,
                items: [(false, context.t('Diet'), Icons.restaurant_rounded), (true, context.t('Workout'), Icons.fitness_center_rounded)],
                onChanged: (v) => setState(() => workout = v),
              ),
              const SizedBox(height: 12),
              if (!workout) ...[
                if (dietPdf != null) PdfCard(meta: dietPdf, tenantId: tid, kind: 'diet', watermark: mark),
                if (diet == null && dietPdf == null)
                  Muted(context.t('Your trainer has not made a diet chart yet.'), align: TextAlign.center)
                else if (diet == null)
                  const SizedBox.shrink()
                else ...[
                  Row(children: [
                    Expanded(child: StatTile(icon: Icons.local_fire_department_rounded, value: diet['kcal'] == null ? '—' : '${diet['kcal']}', label: context.t('kcal a day'), color: C.warn)),
                    const SizedBox(width: 10),
                    Expanded(child: StatTile(icon: Icons.egg_alt_rounded, value: diet['protein'] == null ? '—' : '${diet['protein']} g', label: context.t('Protein'))),
                  ]),
                  const SizedBox(height: 10),
                  for (final m in (diet['meals'] as List).cast<Map>())
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Panel(
                        padding: const EdgeInsets.all(13),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SizedBox(
                            width: 74,
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                              if (m['time'] != null) Muted(m['time'] as String, size: 11.5),
                            ]),
                          ),
                          Expanded(child: Text(m['items'] as String, style: const TextStyle(height: 1.45))),
                        ]),
                      ),
                    ),
                  if (diet['notes'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Muted(diet['notes'] as String)),
                  const SizedBox(height: 6),
                  Muted(context.t('Made by {name} · {date}', {'name': diet['updatedBy'], 'date': fmtDate(diet['updatedAt'] as String?)}), size: 11.5),
                ],
              ] else ...[
                if (workoutPdf != null) PdfCard(meta: workoutPdf, tenantId: tid, kind: 'workout', watermark: mark),
                if (days.isEmpty && workoutPdf == null)
                  Muted(context.t('Your trainer has not made a workout plan yet.'), align: TextAlign.center)
                else if (days.isEmpty)
                  const SizedBox.shrink()
                else ...[
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final (i, x) in days.indexed)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text([context.t(x['day'] as String), if (x['title'] != null) x['title']].join(' · ')),
                            selected: day == i,
                            showCheckmark: false,
                            selectedColor: context.c.primary,
                            labelStyle: TextStyle(color: day == i ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                            onSelected: (_) => setState(() => day = i),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  for (final e in (days[day]['exercises'] as List).cast<Map>())
                    Padding(
                      padding: const EdgeInsets.only(bottom: 9),
                      child: Panel(
                        padding: const EdgeInsets.all(12),
                        child: Row(children: [
                          const IconTile(Icons.fitness_center_rounded, size: 36),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(e['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                              if (e['sets'] != null) Muted(e['sets'] as String, size: 12),
                            ]),
                          ),
                          if (e['weight'] != null) Text(e['weight'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
                        ]),
                      ),
                    ),
                  if (wk?['notes'] != null) Muted(wk!['notes'] as String),
                  const SizedBox(height: 6),
                  Muted(context.t('Made by {name} · {date}', {'name': wk?['updatedBy'], 'date': fmtDate(wk?['updatedAt'] as String?)}), size: 11.5),
                ],
              ],
              const SizedBox(height: 16),
              guides,
            ]);
          },
        ),
      ),
    );
  }
}

// ============================================================ trainer / owner: edit

class _MealRow {
  _MealRow({String name = '', String time = '', String items = ''})
      : name = TextEditingController(text: name),
        time = TextEditingController(text: time),
        items = TextEditingController(text: items);
  final TextEditingController name, time, items;
}

class _ExRow {
  _ExRow({String name = '', String sets = '', String weight = ''})
      : name = TextEditingController(text: name),
        sets = TextEditingController(text: sets),
        weight = TextEditingController(text: weight);
  final TextEditingController name, sets, weight;
}

class _Day {
  _Day(this.day, {String title = '', List<_ExRow>? ex})
      : title = TextEditingController(text: title),
        ex = ex ?? [_ExRow()];
  final String day;
  final TextEditingController title;
  final List<_ExRow> ex;
}

class ProgramEditScreen extends ConsumerStatefulWidget {
  const ProgramEditScreen({super.key, required this.tenantId, required this.memberId, required this.memberName, required this.workout});
  final String tenantId;
  final String memberId;
  final String memberName;
  final bool workout;
  @override
  ConsumerState<ProgramEditScreen> createState() => _ProgramEditState();
}

class _ProgramEditState extends ConsumerState<ProgramEditScreen> {
  bool loading = true;
  bool busy = false;
  String? error;
  final kcal = TextEditingController();
  final protein = TextEditingController();
  final dietNotes = TextEditingController();
  final meals = <_MealRow>[];
  final days = <_Day>[];
  int sel = 0;
  Map? pdf;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final p = await Api.instance.get('/programs/${widget.memberId}?tenantId=${widget.tenantId}');
      final diet = p['diet'] as Map?;
      final wk = p['workout'] as Map?;
      pdf = p[widget.workout ? 'workoutPdf' : 'dietPdf'] as Map?;
      kcal.text = diet?['kcal']?.toString() ?? '';
      protein.text = diet?['protein']?.toString() ?? '';
      dietNotes.text = diet?['notes'] as String? ?? '';
      for (final m in ((diet?['meals'] as List?) ?? const []).cast<Map>()) {
        meals.add(_MealRow(name: m['name'] as String? ?? '', time: m['time'] as String? ?? '', items: m['items'] as String? ?? ''));
      }
      if (meals.isEmpty) {
        meals.addAll([_MealRow(name: 'Breakfast', time: '8:00 am'), _MealRow(name: 'Lunch', time: '1:30 pm'), _MealRow(name: 'Snack', time: '5:00 pm'), _MealRow(name: 'Dinner', time: '8:30 pm')]);
      }
      for (final d in ((wk?['days'] as List?) ?? const []).cast<Map>()) {
        days.add(_Day(
          d['day'] as String? ?? 'Mon',
          title: d['title'] as String? ?? '',
          ex: [for (final e in ((d['exercises'] as List?) ?? const []).cast<Map>()) _ExRow(name: e['name'] as String? ?? '', sets: e['sets'] as String? ?? '', weight: e['weight'] as String? ?? '')],
        ));
      }
      if (days.isEmpty) days.add(_Day('Mon'));
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    final saved = context.t('Saved and sent to {name}', {'name': widget.memberName});
    try {
      final body = widget.workout
          ? {
              'workout': {
                'days': [
                  for (final d in days)
                    {
                      'day': d.day,
                      'title': d.title.text.trim(),
                      'exercises': [for (final e in d.ex) if (e.name.text.trim().isNotEmpty) {'name': e.name.text.trim(), 'sets': e.sets.text.trim(), 'weight': e.weight.text.trim()}],
                    },
                ],
              },
            }
          : {
              'diet': {
                'kcal': int.tryParse(kcal.text.trim()),
                'protein': int.tryParse(protein.text.trim()),
                'notes': dietNotes.text.trim(),
                'meals': [for (final m in meals) if (m.items.text.trim().isNotEmpty) {'name': m.name.text.trim(), 'time': m.time.text.trim(), 'items': m.items.text.trim()}],
              },
            };
      await Api.instance.put('/programs/${widget.memberId}', {'tenantId': widget.tenantId, ...body});
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

  Widget box(TextEditingController c, String label, {int lines = 1, TextInputType? kb}) =>
      TextField(controller: c, maxLines: lines, keyboardType: kb, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: label, isDense: true));

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final title = widget.workout ? context.t('Workout plan') : context.t('Diet chart');
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              Muted(context.t('For {name}', {'name': widget.memberName}), size: 13),
              const SizedBox(height: 12),
              PdfUploadBox(
                tenantId: widget.tenantId,
                memberId: widget.memberId,
                memberName: widget.memberName,
                kind: widget.workout ? 'workout' : 'diet',
                meta: pdf,
                onChanged: (m) => setState(() => pdf = m),
              ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: Divider(color: p.line)),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Muted(context.t('or write it here'), size: 12)),
                Expanded(child: Divider(color: p.line)),
              ]),
              const SizedBox(height: 12),
              if (!widget.workout) ...[
                Row(children: [
                  Expanded(child: box(kcal, context.t('kcal a day'), kb: TextInputType.number)),
                  const SizedBox(width: 10),
                  Expanded(child: box(protein, context.t('Protein (g)'), kb: TextInputType.number)),
                ]),
                const SizedBox(height: 14),
                for (final (i, m) in meals.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Panel(
                      padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Column(children: [
                            Row(children: [Expanded(child: box(m.name, context.t('Meal'))), const SizedBox(width: 8), Expanded(child: box(m.time, context.t('Time')))]),
                            const SizedBox(height: 8),
                            box(m.items, context.t('What to eat'), lines: 2),
                          ]),
                        ),
                        IconButton(onPressed: () => setState(() => meals.removeAt(i)), icon: const Icon(Icons.delete_outline_rounded, color: C.red)),
                      ]),
                    ),
                  ),
                OutlinedButton.icon(onPressed: () => setState(() => meals.add(_MealRow())), icon: const Icon(Icons.add_rounded), label: Text(context.t('Add meal'))),
                const SizedBox(height: 12),
                box(dietNotes, context.t('Notes (optional)'), lines: 2),
              ] else ...[
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final w in weekDays)
                    FilterChip(
                      label: Text(context.t(w)),
                      selected: days.any((d) => d.day == w),
                      selectedColor: p.primary.withAlpha(50),
                      onSelected: (on) => setState(() {
                        if (on) {
                          days.add(_Day(w));
                          days.sort((a, b) => weekDays.indexOf(a.day) - weekDays.indexOf(b.day));
                          sel = days.indexWhere((d) => d.day == w);
                        } else if (days.length > 1) {
                          days.removeWhere((d) => d.day == w);
                          sel = 0;
                        }
                      }),
                    ),
                ]),
                const SizedBox(height: 12),
                Seg<int>(
                  value: sel.clamp(0, days.length - 1),
                  items: [for (final (i, d) in days.indexed) (i, context.t(d.day), null)],
                  onChanged: (v) => setState(() => sel = v),
                ),
                const SizedBox(height: 12),
                Builder(builder: (_) {
                  final d = days[sel.clamp(0, days.length - 1)];
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    box(d.title, context.t('Title (e.g. Legs, Push day)')),
                    const SizedBox(height: 12),
                    for (final (i, e) in d.ex.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Panel(
                          padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
                          child: Row(children: [
                            Expanded(
                              child: Column(children: [
                                box(e.name, context.t('Exercise')),
                                const SizedBox(height: 8),
                                Row(children: [Expanded(child: box(e.sets, context.t('Sets × reps'))), const SizedBox(width: 8), Expanded(child: box(e.weight, context.t('Weight')))]),
                              ]),
                            ),
                            IconButton(onPressed: () => setState(() => d.ex.removeAt(i)), icon: const Icon(Icons.delete_outline_rounded, color: C.red)),
                          ]),
                        ),
                      ),
                    OutlinedButton.icon(onPressed: () => setState(() => d.ex.add(_ExRow())), icon: const Icon(Icons.add_rounded), label: Text(context.t('Add exercise'))),
                  ]);
                }),
              ],
              ErrorText(error),
              const SizedBox(height: 16),
              FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save and send to {name}', {'name': widget.memberName.split(' ').first}))),
            ]),
    );
  }
}
