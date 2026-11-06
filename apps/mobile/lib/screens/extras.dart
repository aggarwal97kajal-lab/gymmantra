import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show LabeledField, PhoneField;
import 'home.dart' show openUrl, waLink;
import '../photo.dart' show Avatar;
import 'branch.dart' show branchesOf;

// Nov 6: enquiry follow-up, lockers, staff salary, ratings + testimonials, fingerprint machines.

final enquiriesProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, view) => branchGet(ref, '/enquiries?view=$view'));
final enquiryProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => branchGet(ref, '/enquiries/$id'));
final lockersProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/lockers'));
final salaryProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, month) => branchGet(ref, '/salary?month=$month'));
final mySalaryProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/me/salary'));
final trainerRatingsProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/trainer-ratings'));
final gymRatingsProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/gym-ratings'));
final devicesProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/gym/devices?v=2'));
final myTrainerRatingProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/trainer/rating'));

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime get _istNow => DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
String get _todayYmd => _ymd(_istNow);
String get _thisMonth => _todayYmd.substring(0, 7);

Widget _pill(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withAlpha(36), borderRadius: BorderRadius.circular(20)),
      child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800)),
    );

Widget _empty(BuildContext context, IconData icon, String title, String sub) => ListView(padding: const EdgeInsets.all(28), children: [
      const SizedBox(height: 40),
      Icon(icon, size: 60, color: context.c.mut),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Muted(sub, align: TextAlign.center),
    ]);

Future<T?> _run<T>(BuildContext context, Future<T> Function() work, {String? done}) async {
  try {
    final r = await work();
    if (context.mounted && done != null) toast(context, done, kind: DripKind.ok);
    return r;
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return null;
  }
}

/// Small chips to pick one or many.
class _Chips extends StatelessWidget {
  const _Chips({required this.options, required this.selected, required this.onTap});
  final List<(String, String)> options; // value, label
  final Set<String> selected;
  final ValueChanged<String> onTap;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (v, l) in options)
          ChoiceChip(
            label: Text(l),
            selected: selected.contains(v),
            onSelected: (_) => onTap(v),
            selectedColor: context.c.primary,
            labelStyle: TextStyle(color: selected.contains(v) ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
          ),
      ]);
}

Widget _label(BuildContext context, String t) => Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 6, top: 4),
      child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.mut)),
    );

const _payModes = [('CASH', 'Cash'), ('UPI', 'UPI'), ('CARD', 'Card'), ('BANK_TRANSFER', 'Bank')];

/// Pick a member of this gym (search by name, code or mobile).
Future<Map?> pickMember(BuildContext context) => showModalBottomSheet<Map>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _MemberPicker(),
    );

class _MemberPicker extends StatefulWidget {
  const _MemberPicker();
  @override
  State<_MemberPicker> createState() => _MemberPickerState();
}

class _MemberPickerState extends State<_MemberPicker> {
  String q = '';
  List<Map> rows = [];
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => busy = true);
    try {
      final d = await Api.instance.get('/members?tab=all&q=${Uri.encodeComponent(q)}');
      rows = ((d['rows'] as List?) ?? const []).cast<Map>().take(60).toList();
    } catch (_) {}
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.75,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Name, code or mobile')),
                onChanged: (v) {
                  q = v.trim();
                  load();
                },
              ),
            ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(children: [
                for (final m in rows)
                  ListTile(
                    title: Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${m['memberCode'] ?? ''} · ${m['phone'] ?? ''}'),
                    onTap: () => Navigator.pop(context, m),
                  ),
              ]),
            ),
          ]),
        ),
      );
}

// ======================= Enquiries =======================

String _tempLabel(BuildContext context, String? t) => switch (t) {
      'HOT' => context.t('Hot 🔥'),
      'COLD' => context.t('Cold'),
      _ => context.t('Warm'),
    };
Color _tempColor(String? t) => switch (t) {
      'HOT' => C.red,
      'COLD' => C.blue,
      _ => C.warn,
    };
String _when(BuildContext context, String? next) {
  if (next == null) return context.t('No follow-up set');
  final day = next.substring(0, 10);
  final time = next.length > 10 ? next.substring(11, 16) : '';
  final today = _todayYmd;
  final tomorrow = _ymd(_istNow.add(const Duration(days: 1)));
  final d = day == today ? context.t('Today') : day == tomorrow ? context.t('Tomorrow') : fmtDate(day);
  return '$d${time.isEmpty ? '' : ' · $time'}';
}

class EnquiriesScreen extends ConsumerStatefulWidget {
  const EnquiriesScreen({super.key});
  @override
  ConsumerState<EnquiriesScreen> createState() => _EnquiriesState();
}

class _EnquiriesState extends ConsumerState<EnquiriesScreen> {
  String view = 'today';
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(enquiriesProvider(view));
    final d = v.valueOrNull as Map?;
    final counts = (d?['counts'] as Map?) ?? const {};
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Enquiries'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => context.push('/o/enquiries/new'), icon: const Icon(Icons.person_add_alt_1_rounded), label: Text(context.t('New enquiry'))),
      body: Column(children: [
        SizedBox(
          height: 52,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), children: [
            for (final (k, l) in [('today', 'Today'), ('missed', 'Missed'), ('upcoming', 'Later'), ('all', 'All')])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(counts[k] == null ? context.t(l) : '${context.t(l)} (${counts[k]})'),
                  selected: view == k,
                  selectedColor: context.c.primary,
                  labelStyle: TextStyle(color: view == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                  onSelected: (_) => setState(() => view = k),
                ),
              ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            color: context.c.primary,
            onRefresh: () async => ref.invalidate(enquiriesProvider(view)),
            child: AsyncBody(
              value: v,
              onRetry: () => ref.invalidate(enquiriesProvider(view)),
              builder: (d) {
                final rows = ((d['rows'] as List?) ?? const []).cast<Map>();
                final month = (d['month'] as Map?) ?? const {};
                return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
                  Row(children: [
                    Expanded(child: StatTile(icon: Icons.contact_phone_rounded, value: '${month['total'] ?? 0}', label: context.t('Enquiries this month'))),
                    const SizedBox(width: 10),
                    Expanded(child: StatTile(icon: Icons.how_to_reg_rounded, value: '${month['joined'] ?? 0}', label: context.t('Joined'), color: C.ok)),
                  ]),
                  const SizedBox(height: 12),
                  if (rows.isEmpty)
                    Padding(padding: const EdgeInsets.only(top: 30), child: Muted(context.t(view == 'today' ? 'No calls for today' : 'Nothing here'), align: TextAlign.center))
                  else
                    Panel(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(children: [
                        for (final e in rows)
                          ListTile(
                            onTap: () => context.push('/o/enquiry/${e['id']}'),
                            leading: IconTile(Icons.person_rounded, color: _tempColor(e['temp'] as String?), size: 38),
                            title: Text('${e['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text(
                              e['status'] == 'JOINED'
                                  ? context.t('Joined')
                                  : e['status'] == 'LOST'
                                      ? context.t('Not coming')
                                      : '${_when(context, e['next'] as String?)}${e['note'] == null ? '' : ' · ${e['note']}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: view == 'missed' ? C.red : context.c.mut, fontSize: 12.5),
                            ),
                            trailing: _pill(_tempLabel(context, e['temp'] as String?), _tempColor(e['temp'] as String?)),
                          ),
                      ]),
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

/// New enquiry, or edit one (pass it as [enquiry]).
class EnquiryFormScreen extends ConsumerStatefulWidget {
  const EnquiryFormScreen({super.key, this.enquiry});
  final Map? enquiry;
  @override
  ConsumerState<EnquiryFormScreen> createState() => _EnquiryFormState();
}

class _EnquiryFormState extends ConsumerState<EnquiryFormScreen> {
  late final name = TextEditingController(text: widget.enquiry?['name'] as String?);
  late final phone = TextEditingController(text: PhoneField.local(widget.enquiry?['phone']));
  late final note = TextEditingController(text: widget.enquiry?['note'] as String?);
  late Set<String> interests = {...((widget.enquiry?['interests'] as List?) ?? const ['Gym']).cast<String>()};
  late String? source = widget.enquiry?['source'] as String?;
  late String temp = (widget.enquiry?['temp'] as String?) ?? 'WARM';
  late DateTime? next = widget.enquiry?['next'] == null ? _istNow.add(const Duration(days: 1)) : DateTime.tryParse(widget.enquiry!['next'] as String);
  bool busy = false;
  String? error;

  Future<void> pickNext() async {
    final d = await showDatePicker(context: context, initialDate: next ?? _istNow, firstDate: _istNow.subtract(const Duration(days: 1)), lastDate: _istNow.add(const Duration(days: 180)));
    if (d == null || !mounted) return;
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: next?.hour ?? 11, minute: next?.minute ?? 0));
    setState(() => next = DateTime(d.year, d.month, d.day, t?.hour ?? 11, t?.minute ?? 0));
  }

  String? get nextStr => next == null ? null : '${_ymd(next!)}T${next!.hour.toString().padLeft(2, '0')}:${next!.minute.toString().padLeft(2, '0')}';

  Future<void> save() async {
    if (name.text.trim().length < 2) {
      setState(() => error = context.t('Enter the name'));
      return;
    }
    if (phone.text.trim().length != 10) {
      setState(() => error = context.t('Enter a valid 10-digit mobile number'));
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final body = {'name': name.text.trim(), 'phone': phone.text.trim(), 'interests': interests.toList(), 'source': source, 'temp': temp, 'next': nextStr, 'note': note.text.trim().isEmpty ? null : note.text.trim()};
    try {
      if (widget.enquiry == null) {
        await Api.instance.post('/enquiries', body);
      } else {
        await Api.instance.patch('/enquiries/${widget.enquiry!['id']}', body);
      }
      ref.invalidate(enquiriesProvider);
      ref.invalidate(enquiryProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t(widget.enquiry == null ? 'New enquiry' : 'Edit enquiry'))),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          LabeledField(label: '${context.t('Name')} *', controller: name, caps: TextCapitalization.words),
          PhoneField(label: '${context.t('Mobile')} *', controller: phone),
          _label(context, context.t('Interested in')),
          _Chips(
            options: [('Gym', context.t('Gym')), ('PT', 'PT'), ('Zumba', 'Zumba'), ('Yoga', 'Yoga'), ('Cardio', context.t('Cardio'))],
            selected: interests,
            onTap: (v) => setState(() => interests.contains(v) ? interests.remove(v) : interests.add(v)),
          ),
          const SizedBox(height: 10),
          _label(context, context.t('How they heard of us')),
          _Chips(
            options: [('Walk-in', context.t('Walk-in')), ('Instagram', 'Instagram'), ('Friend', context.t('Friend told')), ('Google', 'Google'), ('Poster', context.t('Poster / board'))],
            selected: {if (source != null) source!},
            onTap: (v) => setState(() => source = source == v ? null : v),
          ),
          const SizedBox(height: 10),
          _label(context, context.t('How keen')),
          Seg<String>(value: temp, items: [('HOT', context.t('Hot 🔥'), null), ('WARM', context.t('Warm'), null), ('COLD', context.t('Cold'), null)], onChanged: (v) => setState(() => temp = v)),
          const SizedBox(height: 12),
          _label(context, context.t('Follow up on')),
          OutlinedButton.icon(onPressed: pickNext, icon: const Icon(Icons.event_rounded), label: Text(next == null ? context.t('Choose day and time') : _when(context, nextStr))),
          const SizedBox(height: 10),
          LabeledField(label: context.t('Note'), controller: note, hint: context.t('e.g. Fees felt high, tell about the 3-month offer')),
          ErrorText(error),
          const SizedBox(height: 14),
          FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save'))),
        ]),
      );
}

class EnquiryScreen extends ConsumerWidget {
  const EnquiryScreen({super.key, required this.id});
  final String id;

  Future<void> _log(BuildContext context, WidgetRef ref, Map e, String kind) async {
    final text = TextEditingController();
    DateTime? next;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(ctx.t(switch (kind) { 'CALL' => 'Call done', 'WHATSAPP' => 'WhatsApp sent', 'TRIAL' => 'Trial given', _ => 'Add a note' })),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: text, decoration: InputDecoration(hintText: ctx.t('What did they say?'))),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: _istNow.add(const Duration(days: 2)), firstDate: _istNow, lastDate: _istNow.add(const Duration(days: 180)));
                if (d != null) set(() => next = d);
              },
              icon: const Icon(Icons.event_rounded),
              label: Text(next == null ? ctx.t('Next follow-up (optional)') : fmtDate(_ymd(next!))),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Save'))),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await _run(context, () => Api.instance.post('/enquiries/${e['id']}/log', {'kind': kind, 'text': text.text.trim().isEmpty ? null : text.text.trim(), if (next != null) 'next': _ymd(next!)}));
    ref.invalidate(enquiryProvider(id));
    ref.invalidate(enquiriesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(enquiryProvider(id));
    final gymName = ref.watch(sessionProvider).myGym?['name'] as String? ?? '';
    final me = ref.watch(sessionProvider).user?['name'] as String? ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Enquiry')), actions: [
        if (v.valueOrNull is Map) IconButton(onPressed: () => context.push('/o/enquiries/new', extra: v.valueOrNull), icon: const Icon(Icons.edit_rounded)),
      ]),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(enquiryProvider(id)),
        builder: (d) {
          final e = d as Map;
          final open = e['status'] == 'OPEN';
          final log = ((e['log'] as List?) ?? const []).cast<Map>();
          final first = ((e['name'] as String?) ?? '').split(' ').first;
          final msg = context.t('Namaste {name} ji 🙏 {gym} se {me}. Aapke liye hamara offer: …. Kab aa rahe ho?', {'name': first, 'gym': gymName, 'me': me});
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            Panel(
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${e['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                    Muted([e['phone'], e['source'], ((e['interests'] as List?) ?? const []).join(' + ')].where((x) => x != null && '$x'.isNotEmpty).join(' · '), size: 12.5),
                    const SizedBox(height: 4),
                    Muted('${context.t('Next')}: ${_when(context, e['next'] as String?)}', size: 12.5),
                  ]),
                ),
                _pill(_tempLabel(context, e['temp'] as String?), _tempColor(e['temp'] as String?)),
              ]),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: OutlinedButton.icon(onPressed: () => openUrl('tel:${e['phone']}').then((_) => _log(context, ref, e, 'CALL')), icon: const Icon(Icons.call_rounded), label: Text(context.t('Call')))),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: C.wa),
                  onPressed: () => openUrl(waLink('${e['phone']}', msg)).then((_) => _log(context, ref, e, 'WHATSAPP')),
                  icon: const Icon(Icons.chat_rounded),
                  label: const Text('WhatsApp'),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _log(context, ref, e, 'TRIAL'), child: Text(context.t('Trial given')))),
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton(onPressed: () => _log(context, ref, e, 'NOTE'), child: Text(context.t('Add note')))),
            ]),
            const SizedBox(height: 14),
            SectionTitle(context.t('What happened')),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final l in log)
                  ListTile(
                    dense: true,
                    leading: Icon(switch (l['kind']) { 'CALL' => Icons.call_rounded, 'WHATSAPP' => Icons.chat_rounded, 'VISIT' => Icons.storefront_rounded, 'TRIAL' => Icons.fitness_center_rounded, _ => Icons.notes_rounded }, color: context.c.primary),
                    title: Text(
                      '${context.t(switch (l['kind']) { 'CALL' => 'Call', 'WHATSAPP' => 'WhatsApp', 'VISIT' => 'Came to the gym', 'TRIAL' => 'Trial', _ => 'Note' })} · ${fmtDate(l['at'] as String)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text([if (l['text'] != null) '"${l['text']}"', l['byName']].join(' · ')),
                  ),
              ]),
            ),
            const SizedBox(height: 14),
            if (open) ...[
              FilledButton.icon(
                onPressed: () => context.push('/o/members/new', extra: {'enquiry': e}),
                icon: const Icon(Icons.how_to_reg_rounded),
                label: Text(context.t('Joined — make member')),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await _run(context, () => Api.instance.patch('/enquiries/${e['id']}', {'status': 'LOST', 'next': null}), done: context.t('Marked as not coming'));
                  ref.invalidate(enquiryProvider(id));
                  ref.invalidate(enquiriesProvider);
                },
                child: Text(context.t('Not coming'), style: const TextStyle(color: C.red)),
              ),
            ] else
              Muted(context.t(e['status'] == 'JOINED' ? 'Joined the gym' : 'Marked as not coming'), align: TextAlign.center),
          ]);
        },
      ),
    );
  }
}

// ======================= Lockers =======================

Color _lockerColor(String s) => switch (s) {
      'FREE' => C.ok,
      'ENDING' => C.warn,
      'ENDED' => C.red,
      _ => C.indigo,
    };

class LockersScreen extends ConsumerWidget {
  const LockersScreen({super.key});

  Future<void> _setCount(BuildContext context, WidgetRef ref, int now) async {
    final c = TextEditingController(text: now == 0 ? '' : '$now');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('How many lockers?')),
        content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Save'))),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _run(context, () => Api.instance.put('/lockers/count', {'count': int.tryParse(c.text.trim()) ?? 0}));
    ref.invalidate(lockersProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(lockersProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Lockers')), actions: [
        IconButton(onPressed: () => _setCount(context, ref, ((v.valueOrNull as Map?)?['count'] as int?) ?? 0), icon: const Icon(Icons.tune_rounded)),
      ]),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(lockersProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(lockersProvider),
          builder: (d) {
            final rows = ((d['rows'] as List?) ?? const []).cast<Map>();
            if (rows.isEmpty) {
              return ListView(padding: const EdgeInsets.all(28), children: [
                const SizedBox(height: 40),
                Icon(Icons.lock_outline_rounded, size: 60, color: context.c.mut),
                const SizedBox(height: 12),
                Text(context.t('No lockers yet'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                Muted(context.t('Tell how many lockers this branch has. Then give them to members with a fee and a key deposit.'), align: TextAlign.center),
                const SizedBox(height: 14),
                FilledButton(onPressed: () => _setCount(context, ref, 0), child: Text(context.t('Set number of lockers'))),
              ]);
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              Row(children: [
                Expanded(child: StatTile(icon: Icons.lock_rounded, value: '${d['count']}', label: context.t('Total'))),
                const SizedBox(width: 9),
                Expanded(child: StatTile(icon: Icons.lock_open_rounded, value: '${d['free']}', label: context.t('Free'), color: C.ok)),
                const SizedBox(width: 9),
                Expanded(child: StatTile(icon: Icons.timer_off_rounded, value: '${d['ended']}', label: context.t('Time over'), color: C.red)),
              ]),
              const SizedBox(height: 12),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                children: [
                  for (final r in rows)
                    Material(
                      color: _lockerColor(r['state'] as String).withAlpha(context.c.dark ? 50 : 34),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _lockerSheet(context, ref, r),
                        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Text('${r['n']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _lockerColor(r['state'] as String))),
                          Text(
                            context.t(switch (r['state']) { 'FREE' => 'Free', 'ENDING' => '{n} days', 'ENDED' => 'Over', _ => 'Given' }, {'n': r['daysLeft']}),
                            style: TextStyle(fontSize: 11, color: _lockerColor(r['state'] as String), fontWeight: FontWeight.w700),
                          ),
                        ]),
                      ),
                    ),
                ],
              ),
            ]);
          },
        ),
      ),
    );
  }
}

Future<void> _lockerSheet(BuildContext context, WidgetRef ref, Map r) async {
  final n = r['n'];
  final use = r['use'] as Map?;
  if (use == null) {
    await showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _GiveLocker(n: n as int));
  } else {
    await showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(ctx.t('Locker {n}', {'n': n}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 4),
          Text('${use['name']} · ${use['phone']}', style: const TextStyle(fontWeight: FontWeight.w700)),
          Muted(ctx.t('{from} to {to} · deposit {d}', {'from': fmtDate(use['from'] as String), 'to': fmtDate(use['to'] as String), 'd': rupees(use['deposit'] as num?)})),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await showModalBottomSheet(context: context, isScrollControlled: true, showDragHandle: true, builder: (_) => _GiveLocker(n: n as int, renew: use));
            },
            child: Text(ctx.t('Renew')),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _run(context, () => Api.instance.post('/lockers/$n/free', {}), done: context.t('Locker empty. Give back deposit {d}', {'d': rupees(use['deposit'] as num?)}));
              ref.invalidate(lockersProvider);
            },
            child: Text(ctx.t('Empty it · give deposit back')),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _run(context, () => Api.instance.post('/lockers/$n/free', {'keepDeposit': true}), done: context.t('Locker empty. Deposit kept'));
              ref.invalidate(lockersProvider);
            },
            child: Text(ctx.t('Key lost · keep deposit'), style: const TextStyle(color: C.red)),
          ),
        ]),
      ),
    );
  }
}

class _GiveLocker extends ConsumerStatefulWidget {
  const _GiveLocker({required this.n, this.renew});
  final int n;
  final Map? renew;
  @override
  ConsumerState<_GiveLocker> createState() => _GiveLockerState();
}

class _GiveLockerState extends ConsumerState<_GiveLocker> {
  Map? member;
  int months = 3;
  final fee = TextEditingController();
  final deposit = TextEditingController(text: '200');
  String mode = 'CASH';
  bool busy = false;

  String get to {
    final start = widget.renew == null ? _istNow : DateTime.parse(widget.renew!['to'] as String);
    return _ymd(DateTime(start.year, start.month + months, start.day).subtract(const Duration(days: 1)));
  }

  Future<void> save() async {
    if (widget.renew == null && member == null) {
      toast(context, context.t('Choose a member'), kind: DripKind.error);
      return;
    }
    setState(() => busy = true);
    final f = int.tryParse(fee.text.trim()) ?? 0;
    final ok = await _run(
      context,
      () => widget.renew == null
          ? Api.instance.post('/lockers/${widget.n}/assign', {'memberId': member!['id'], 'to': to, 'fee': f, 'deposit': int.tryParse(deposit.text.trim()) ?? 0, 'mode': mode})
          : Api.instance.post('/lockers/${widget.n}/renew', {'to': to, 'fee': f, 'mode': mode}),
      done: context.t('Locker {n} given till {to}', {'n': widget.n, 'to': fmtDate(to)}),
    );
    ref.invalidate(lockersProvider);
    if (mounted) {
      setState(() => busy = false);
      if (ok != null) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(18, 0, 18, 18 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(context.t(widget.renew == null ? 'Give locker {n}' : 'Renew locker {n}', {'n': widget.n}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 10),
          if (widget.renew == null)
            OutlinedButton.icon(
              onPressed: () async {
                final m = await pickMember(context);
                if (m != null) setState(() => member = m);
              },
              icon: const Icon(Icons.search_rounded),
              label: Text(member == null ? context.t('Choose member') : '${member!['name']} · ${member!['phone'] ?? ''}'),
            ),
          const SizedBox(height: 10),
          _label(context, context.t('For how long')),
          Seg<int>(value: months, items: [(1, context.t('1 month'), null), (3, context.t('3 months'), null), (6, context.t('6 months'), null), (12, context.t('1 year'), null)], onChanged: (v) => setState(() => months = v)),
          Padding(padding: const EdgeInsets.only(top: 6), child: Muted(context.t('Till {date}', {'date': fmtDate(to)}), size: 12)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: LabeledField(label: context.t('Fee (₹)'), controller: fee, keyboard: TextInputType.number)),
            if (widget.renew == null) ...[const SizedBox(width: 10), Expanded(child: LabeledField(label: context.t('Key deposit (₹)'), controller: deposit, keyboard: TextInputType.number))],
          ]),
          Seg<String>(value: mode, items: [for (final (k, l) in _payModes) (k, context.t(l), null)], onChanged: (v) => setState(() => mode = v)),
          const SizedBox(height: 14),
          FilledButton(onPressed: busy ? null : save, child: Text(context.t(widget.renew == null ? 'Give locker' : 'Renew'))),
        ]),
      );
}

/// Member: their locker (on the home page and the membership page).
class MyLockerCard extends StatelessWidget {
  const MyLockerCard({super.key, required this.locker});
  final Map locker;
  @override
  Widget build(BuildContext context) {
    final to = locker['to'] as String;
    final left = DateTime.parse(to).difference(DateTime.parse(_todayYmd)).inDays;
    final color = left < 0 ? C.red : left <= 3 ? C.warn : C.indigo;
    return Panel(
      child: Row(children: [
        IconTile(Icons.lock_rounded, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('My locker: {n}', {'n': locker['n']}), style: const TextStyle(fontWeight: FontWeight.w800)),
            Muted(left < 0 ? context.t('Time over on {date}. Renew at the desk.', {'date': fmtDate(to)}) : context.t('Till {date} · {n} days left', {'date': fmtDate(to), 'n': left}), size: 12.5),
          ]),
        ),
      ]),
    );
  }
}

// ======================= Staff salary =======================

String _monthLabel(String ym) {
  const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${names[int.parse(ym.substring(5, 7)) - 1]} ${ym.substring(0, 4)}';
}

String _shiftMonth(String ym, int by) {
  final d = DateTime(int.parse(ym.substring(0, 4)), int.parse(ym.substring(5, 7)) + by, 1);
  return '${d.year}-${d.month.toString().padLeft(2, '0')}';
}

/// Owner with several branches (staff stay in one branch).
bool hasBranches(WidgetRef ref) => branchesOf(ref.watch(gymProvider).valueOrNull as Map?).length > 1 && !ref.watch(sessionProvider).isStaffDesk;

String currentBranchName(WidgetRef ref) {
  final g = ref.watch(gymProvider).valueOrNull as Map?;
  final list = branchesOf(g);
  final id = Api.instance.branchId ?? g?['currentBranchId'];
  return (list.firstWhere((b) => b['id'] == id, orElse: () => list.isEmpty ? const {} : list.first)['name'] as String?) ?? '';
}

/// One card per branch (gym reviews, trainer ratings).
class BranchCards extends StatelessWidget {
  const BranchCards({super.key, required this.items, required this.onPick, this.note});
  final List<({String id, String name, String sub, String? right, Color? rightColor})> items;
  final void Function(String id) onPick;
  final String? note;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final b in items) ...[
          Panel(
            onTap: () => onPick(b.id),
            child: Row(children: [
              const IconTile(Icons.store_mall_directory_rounded, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.name, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(height: 2),
                  Muted(b.sub, size: 12),
                ]),
              ),
              if (b.right != null) Text(b.right!, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: b.rightColor)),
              Icon(Icons.chevron_right_rounded, color: context.c.mut),
            ]),
          ),
          const SizedBox(height: 10),
        ],
        if (note != null) Muted(note!, size: 12),
      ]);
}

class SalaryScreen extends ConsumerStatefulWidget {
  const SalaryScreen({super.key});
  @override
  ConsumerState<SalaryScreen> createState() => _SalaryState();
}

class _SalaryState extends ConsumerState<SalaryScreen> {
  String month = _thisMonth;
  Widget monthBar() => Row(children: [
        IconButton(onPressed: () => setState(() => month = _shiftMonth(month, -1)), icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(child: Text(_monthLabel(month), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
        IconButton(onPressed: month == _thisMonth ? null : () => setState(() => month = _shiftMonth(month, 1)), icon: const Icon(Icons.chevron_right_rounded)),
      ]);
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(salaryProvider(month));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Staff salary'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/o/salary/setup', extra: {'id': 'new', 'name': '', 'noApp': true}),
        icon: const Icon(Icons.person_add_alt_rounded),
        label: Text(context.t('Person without app')),
      ),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(salaryProvider(month)),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(salaryProvider(month)),
          builder: (d) {
            final rows = ((d['rows'] as List?) ?? const []).cast<Map>();
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 96), children: [
              if (hasBranches(ref)) Padding(padding: const EdgeInsets.only(bottom: 2), child: Muted('📍 ${currentBranchName(ref)} · ${context.t('change branch from Home')}', size: 12.5, align: TextAlign.center)),
              monthBar(),
              Row(children: [
                Expanded(child: StatTile(icon: Icons.payments_rounded, value: rupees(d['total'] as num?), label: context.t('Total salary'))),
                const SizedBox(width: 9),
                Expanded(child: StatTile(icon: Icons.check_circle_rounded, value: rupees(d['paid'] as num?), label: context.t('Paid'), color: C.ok)),
                const SizedBox(width: 9),
                Expanded(child: StatTile(icon: Icons.pending_rounded, value: rupees(d['due'] as num?), label: context.t('Due'), color: C.red)),
              ]),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                Muted(context.t('No front desk staff or trainers in this branch yet.'), align: TextAlign.center)
              else
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    for (final r in rows)
                      ListTile(
                        onTap: () => context.push(r['cfg'] == null ? '/o/salary/setup' : '/o/salary/person', extra: {...r, 'month': month}),
                        leading: IconTile(r['role'] == 'TRAINER' ? Icons.sports_rounded : r['role'] == 'OTHER' ? Icons.cleaning_services_rounded : Icons.badge_rounded, size: 38),
                        title: Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          r['slip'] == null
                              ? context.t('Salary not set — tap to set')
                              : '${r['noApp'] == true ? context.t('No app') : context.t('{p} days present', {'p': r['slip']['present']})} · ${rupees(r['slip']['total'] as num?)}',
                          style: TextStyle(fontSize: 12.5, color: context.c.mut),
                        ),
                        trailing: r['slip'] == null
                            ? null
                            : ((r['slip']['due'] as num?) ?? 0) > 0
                                ? _pill(context.t('{amt} due', {'amt': rupees(r['slip']['due'] as num?)}), C.red)
                                : _pill(context.t('Paid ✓'), C.ok),
                      ),
                  ]),
                ),
              const SizedBox(height: 10),
              Muted(context.t('PT money is paid separately in PT accounts.'), size: 12, align: TextAlign.center),
            ]);
          },
        ),
      ),
    );
  }
}

class SalarySetupScreen extends ConsumerStatefulWidget {
  const SalarySetupScreen({super.key, required this.person});
  final Map person;
  @override
  ConsumerState<SalarySetupScreen> createState() => _SalarySetupState();
}

class _SalarySetupState extends ConsumerState<SalarySetupScreen> {
  Map get cfg => (widget.person['cfg'] as Map?) ?? const {};
  late final name = TextEditingController(text: widget.person['name'] as String?);
  late final amount = TextEditingController(text: cfg['amount'] == null ? '' : '${cfg['amount']}');
  late final workDays = TextEditingController(text: '${cfg['workDays'] ?? 26}');
  late final freeLeaves = TextEditingController(text: '${cfg['freeLeaves'] ?? 2}');
  late String mode = (cfg['mode'] as String?) ?? 'MONTH';
  late bool cut = (cfg['cutAbsent'] as bool?) ?? true;
  bool busy = false;
  String? error;
  bool get noApp => widget.person['noApp'] == true;

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Api.instance.put('/salary/${widget.person['id']}', {
        if (noApp) 'name': name.text.trim(),
        'amount': int.tryParse(amount.text.trim()) ?? 0,
        'mode': mode,
        'workDays': int.tryParse(workDays.text.trim()) ?? 26,
        'freeLeaves': int.tryParse(freeLeaves.text.trim()) ?? 0,
        'cutAbsent': cut,
      });
      ref.invalidate(salaryProvider);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(noApp && widget.person['id'] == 'new' ? context.t('Person without app') : context.t('Salary · {name}', {'name': widget.person['name']}))),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          if (noApp) LabeledField(label: '${context.t('Name and work (e.g. Ramesh – cleaning)')} *', controller: name, caps: TextCapitalization.words),
          Seg<String>(value: mode, items: [('MONTH', context.t('Fixed a month'), null), ('DAY', context.t('Per day'), null)], onChanged: (v) => setState(() => mode = v)),
          const SizedBox(height: 12),
          LabeledField(label: context.t(mode == 'MONTH' ? 'Salary a month (₹)' : 'Pay a day (₹)'), controller: amount, keyboard: TextInputType.number),
          if (mode == 'MONTH') ...[
            Row(children: [
              Expanded(child: LabeledField(label: context.t('Work days a month'), controller: workDays, keyboard: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: LabeledField(label: context.t('Free leaves'), controller: freeLeaves, keyboard: TextInputType.number)),
            ]),
            if (!noApp)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: cut,
                onChanged: (v) => setState(() => cut = v),
                title: Text(context.t('Cut pay for absent days'), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(context.t('Days without "Present", after the free leaves')),
              ),
          ],
          if (mode == 'DAY' && !noApp) Muted(context.t('Pay = days marked Present × pay a day.'), size: 12),
          ErrorText(error),
          const SizedBox(height: 14),
          FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save'))),
        ]),
      );
}

class SalaryPersonScreen extends ConsumerStatefulWidget {
  const SalaryPersonScreen({super.key, required this.person});
  final Map person;
  @override
  ConsumerState<SalaryPersonScreen> createState() => _SalaryPersonState();
}

class _SalaryPersonState extends ConsumerState<SalaryPersonScreen> {
  String get month => widget.person['month'] as String;
  String get id => widget.person['id'] as String;

  Future<void> _adjust() async {
    String kind = 'ADVANCE';
    final amt = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(ctx.t('Advance / bonus / cut')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Seg<String>(value: kind, items: [('ADVANCE', ctx.t('Advance'), null), ('BONUS', ctx.t('Bonus'), null), ('CUT', ctx.t('Cut'), null)], onChanged: (v) => set(() => kind = v)),
            const SizedBox(height: 10),
            TextField(controller: amt, keyboardType: TextInputType.number, decoration: const InputDecoration(prefixText: '₹ ')),
            const SizedBox(height: 8),
            TextField(controller: note, decoration: InputDecoration(hintText: ctx.t('Note (optional)'))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Save'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _run(context, () => Api.instance.post('/salary/$id/adjust', {'month': month, 'kind': kind, 'amount': int.tryParse(amt.text.trim()) ?? 0, 'note': note.text.trim().isEmpty ? null : note.text.trim()}));
    ref.invalidate(salaryProvider(month));
  }

  Future<void> _pay(num due) async {
    String mode = 'UPI';
    final amt = TextEditingController(text: '${due.round()}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(ctx.t('Pay salary')),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: amt, keyboardType: TextInputType.number, decoration: const InputDecoration(prefixText: '₹ ')),
            const SizedBox(height: 10),
            Seg<String>(value: mode, items: [for (final (k, l) in _payModes) (k, ctx.t(l), null)], onChanged: (v) => set(() => mode = v)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Pay'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _run(context, () => Api.instance.post('/salary/$id/pay', {'month': month, 'amount': int.tryParse(amt.text.trim()) ?? 0, 'mode': mode}), done: context.t('Salary paid'));
    ref.invalidate(salaryProvider(month));
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(salaryProvider(month));
    final rows = (((v.valueOrNull as Map?)?['rows'] as List?) ?? const []).cast<Map>();
    final r = rows.firstWhere((x) => x['id'] == id, orElse: () => widget.person);
    final s = r['slip'] as Map?;
    return Scaffold(
      appBar: AppBar(title: Text('${r['name']} · ${_monthLabel(month)}'), actions: [
        IconButton(onPressed: () => context.push('/o/salary/setup', extra: r), icon: const Icon(Icons.edit_rounded)),
      ]),
      body: s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              SalarySlip(slip: s, name: r['name'] as String, gym: ref.watch(sessionProvider).myGym?['name'] as String? ?? '', noApp: r['noApp'] == true),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: _adjust, child: Text(context.t('+ Advance / bonus')))),
                const SizedBox(width: 8),
                Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: C.ok), onPressed: ((s['due'] as num?) ?? 0) > 0 ? () => _pay(s['due'] as num) : null, child: Text(context.t('Pay {amt}', {'amt': rupees(s['due'] as num?)})))),
              ]),
              const SizedBox(height: 14),
              if (((s['pays'] as List?) ?? const []).isNotEmpty) ...[
                SectionTitle(context.t('Payments')),
                for (final p in (s['pays'] as List).cast<Map>()) Muted('${fmtDate(p['at'] as String)} · ${rupees(p['amount'] as num?)} · ${p['mode']}', size: 13),
              ],
            ]),
    );
  }
}

class SalarySlip extends StatelessWidget {
  const SalarySlip({super.key, required this.slip, required this.name, required this.gym, this.noApp = false});
  final Map slip;
  final String name;
  final String gym;
  final bool noApp;
  @override
  Widget build(BuildContext context) {
    Widget line(String k, String v, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(k, style: TextStyle(color: context.c.mut, fontSize: 13.5))),
            Text(v, style: TextStyle(color: color, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, fontSize: bold ? 15 : 13.5)),
          ]),
        );
    final s = slip;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Muted(context.t('Salary slip'), align: TextAlign.center, size: 12),
        Text(gym, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        Muted('$name · ${_monthLabel(s['month'] as String)}${s['running'] == true ? ' · ${context.t('month running')}' : ''}', align: TextAlign.center, size: 12),
        const Divider(height: 20),
        if (!noApp) line(context.t('Present'), context.t('{p} days', {'p': s['present']})),
        line(context.t('Salary'), rupees(s['base'] as num?)),
        if (((s['cut'] as num?) ?? 0) > 0) line(context.t('Absent days ({n})', {'n': s['absent']}), '− ${rupees(s['cut'] as num?)}', color: C.red),
        if (((s['otherCut'] as num?) ?? 0) > 0) line(context.t('Cut'), '− ${rupees(s['otherCut'] as num?)}', color: C.red),
        if (((s['bonus'] as num?) ?? 0) > 0) line(context.t('Bonus'), '+ ${rupees(s['bonus'] as num?)}', color: C.ok),
        line(context.t('Total'), rupees(s['total'] as num?), bold: true),
        if (((s['advance'] as num?) ?? 0) > 0) line(context.t('Advance given'), rupees(s['advance'] as num?)),
        line(context.t('Paid'), rupees(((s['paid'] as num?) ?? 0) - ((s['advance'] as num?) ?? 0))),
        line(context.t('Due'), rupees(s['due'] as num?), color: ((s['due'] as num?) ?? 0) > 0 ? C.red : C.ok, bold: true),
      ]),
    );
  }
}

/// Staff / trainer: my salary slips.
class MySalaryScreen extends ConsumerWidget {
  const MySalaryScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(mySalaryProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('My salary'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(mySalaryProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(mySalaryProvider),
          builder: (d) {
            final months = ((d['months'] as List?) ?? const []).cast<Map>();
            if (months.isEmpty) return _empty(context, Icons.payments_outlined, context.t('No salary set yet'), context.t('Your gym owner has not set your salary in the app yet.'));
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              for (final m in months) ...[SalarySlip(slip: m, name: d['name'] as String? ?? '', gym: d['gymName'] as String? ?? ''), const SizedBox(height: 12)],
              Muted(context.t('Only you and the owner see your salary.'), align: TextAlign.center, size: 12),
            ]);
          },
        ),
      ),
    );
  }
}

// ======================= Ratings =======================

class Stars extends StatelessWidget {
  const Stars(this.n, {super.key, this.size = 16, this.onTap});
  final num n;
  final double size;
  final ValueChanged<int>? onTap;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            onTap: onTap == null ? null : () => onTap!(i),
            child: Icon(i <= n.round() ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: i <= n.round() ? C.gold : context.c.mut),
          ),
      ]);
}

const _trainerTags = ['On time', 'Explains well', 'Helps with diet', 'Motivates', 'On the phone a lot'];
const _gymTags = ['Clean', 'Good machines', 'Good trainers', 'Not crowded', 'AC / fans', 'Safe for ladies'];

/// Member: rate a trainer (extra: {tenantId, trainerId, name, mine}) or the gym (extra: {tenantId, gymName}).
class RateScreen extends ConsumerStatefulWidget {
  const RateScreen({super.key, required this.args});
  final Map args;
  @override
  ConsumerState<RateScreen> createState() => _RateState();
}

class _RateState extends ConsumerState<RateScreen> {
  bool get forTrainer => widget.args['trainerId'] != null;
  late Map mine = (widget.args['mine'] as Map?) ?? const {};
  late int stars = (mine['stars'] as int?) ?? 0;
  late Set<String> tags = {...((mine['tags'] as List?) ?? const []).cast<String>()};
  late final comment = TextEditingController(text: mine['comment'] as String?);
  late bool allowShow = (mine['allowShow'] as bool?) ?? true;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (!forTrainer) {
      Api.instance.get('/me/gyms/${widget.args['tenantId']}/rating').then((r) {
        if (r is Map && mounted) {
          setState(() {
            mine = r;
            stars = (r['stars'] as int?) ?? 0;
            tags = {...((r['tags'] as List?) ?? const []).cast<String>()};
            comment.text = (r['comment'] as String?) ?? '';
            allowShow = (r['allowShow'] as bool?) ?? true;
          });
        }
      }).catchError((_) {});
    }
  }

  Future<void> save() async {
    if (stars == 0) {
      toast(context, context.t('Tap the stars first'), kind: DripKind.error);
      return;
    }
    setState(() => busy = true);
    final t = widget.args['tenantId'];
    final body = {'stars': stars, 'tags': tags.toList(), 'comment': comment.text.trim().isEmpty ? null : comment.text.trim(), if (!forTrainer) 'allowShow': allowShow};
    final ok = await _run(context, () => Api.instance.put(forTrainer ? '/me/gyms/$t/trainers/${widget.args['trainerId']}/rating' : '/me/gyms/$t/rating', body), done: context.t('Thank you!'));
    if (mounted) {
      setState(() => busy = false);
      if (ok != null) context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = forTrainer ? (widget.args['name'] as String? ?? '') : (widget.args['gymName'] as String? ?? '');
    final tagList = forTrainer ? _trainerTags : _gymTags;
    return Scaffold(
      appBar: AppBar(title: Text(context.t(forTrainer ? 'Rate trainer' : 'Rate gym'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 28), children: [
        Panel(
          child: Column(children: [
            Text(forTrainer ? title : context.t('How is {gym}?', {'gym': title}), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            const SizedBox(height: 10),
            Stars(stars, size: 42, onTap: (v) => setState(() => stars = v)),
            const SizedBox(height: 12),
            Wrap(alignment: WrapAlignment.center, spacing: 8, runSpacing: 8, children: [
              for (final t in tagList)
                FilterChip(
                  label: Text(context.t(t)),
                  selected: tags.contains(t),
                  selectedColor: context.c.primary.withAlpha(60),
                  onSelected: (_) => setState(() => tags.contains(t) ? tags.remove(t) : tags.add(t)),
                ),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        _label(context, context.t(forTrainer ? 'Anything else? (only the owner sees it)' : 'In your own words')),
        TextField(controller: comment, maxLines: 3, maxLength: 500),
        if (!forTrainer)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: allowShow,
            onChanged: (v) => setState(() => allowShow = v ?? false),
            title: Text(context.t('The gym may show this with my name'), style: const TextStyle(fontSize: 13.5)),
          ),
        if (forTrainer) Muted(context.t('The trainer sees only the stars and tags, not your name or words.'), size: 12),
        const SizedBox(height: 14),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Send'))),
      ]),
    );
  }
}

/// Testimonials slider (member, trainer and staff dashboards): the reviewer's photo, stars and words.
/// Long words are cut on the card; "Read full" opens the whole review.
class TestimonialsSlider extends StatelessWidget {
  const TestimonialsSlider({super.key, required this.items, this.avg, this.count});
  final List<Map> items;
  final num? avg;
  final int? count;
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(context.t('What members say'), trailing: avg == null ? null : Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.star_rounded, color: C.gold, size: 18), Text(' $avg · ${count ?? 0}', style: const TextStyle(fontWeight: FontWeight.w700))])),
      SizedBox(
        height: 158,
        child: PageView(controller: PageController(viewportFraction: items.length == 1 ? 1 : 0.88), padEnds: false, children: [
          for (final t in items)
            Padding(
              padding: EdgeInsets.only(right: items.length == 1 ? 0 : 10),
              child: Panel(
                padding: const EdgeInsets.all(13),
                onTap: () => _showReview(context, t),
                child: LayoutBuilder(builder: (context, box) {
                  final text = '"${t['text']}"';
                  const style = TextStyle(height: 1.3, fontSize: 13.5);
                  final tp = TextPainter(text: TextSpan(text: text, style: style), maxLines: 3, textDirection: TextDirection.ltr)..layout(maxWidth: box.maxWidth);
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Avatar(name: '${t['name']}', url: t['photoUrl'] as String?, size: 34),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${t['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                          Stars((t['stars'] as num?) ?? 5, size: 14),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 7),
                    Expanded(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: style)),
                    if (tp.didExceedMaxLines) Text('${context.t('Read full')} ›', style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700, fontSize: 12.5)),
                  ]);
                }),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
    ]);
  }
}

void _showReview(BuildContext context, Map t) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Avatar(name: '${t['name']}', url: t['photoUrl'] as String?, size: 52),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${t['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                  Stars((t['stars'] as num?) ?? 5, size: 18),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            Text('"${t['text']}"', style: const TextStyle(fontSize: 15.5, height: 1.45)),
          ]),
        ),
      ),
    );

/// Staff home: the branch's rating and the testimonials the owner chose.
final _staffTestimonialsProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, tenantId) => branchGet(ref, '/gyms/$tenantId/testimonials'));

class StaffTestimonials extends ConsumerWidget {
  const StaffTestimonials({super.key, required this.tenantId});
  final String tenantId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(_staffTestimonialsProvider(tenantId)).valueOrNull as Map?;
    if (d == null) return const SizedBox.shrink();
    return TestimonialsSlider(items: ((d['items'] as List?) ?? const []).cast<Map>(), avg: d['avg'] as num?, count: d['count'] as int?);
  }
}

/// Member home: locker, testimonials, and "rate" buttons for one gym.
class MemberGymExtras extends StatelessWidget {
  const MemberGymExtras({super.key, required this.m});
  final Map m;
  @override
  Widget build(BuildContext context) {
    final gym = (m['gym'] as Map?) ?? const {};
    final tm = (m['testimonials'] as Map?) ?? const {};
    final items = ((tm['items'] as List?) ?? const []).cast<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (m['locker'] is Map) ...[MyLockerCard(locker: m['locker'] as Map), const SizedBox(height: 12)],
      TestimonialsSlider(items: items, avg: tm['avg'] as num?, count: tm['count'] as int?),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => context.push('/rate', extra: {'tenantId': gym['id'], 'gymName': gym['gymName'] ?? gym['name']}),
            icon: const Icon(Icons.star_rate_rounded, color: C.gold),
            label: Text(context.t('Rate gym')),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _pickTrainerToRate(context, gym['id'] as String),
            icon: const Icon(Icons.sports_rounded),
            label: Text(context.t('Rate trainer')),
          ),
        ),
      ]),
      const SizedBox(height: 12),
    ]);
  }
}

Future<void> _pickTrainerToRate(BuildContext context, String tenantId) async {
  List<Map> list = const [];
  try {
    list = ((await Api.instance.get('/me/gyms/$tenantId/trainer-ratings')) as List).cast<Map>();
  } catch (e) {
    if (context.mounted) toastError(context, e);
    return;
  }
  if (!context.mounted) return;
  if (list.isEmpty) {
    toast(context, context.t('This gym has no trainers in the app yet'));
    return;
  }
  final t = list.length == 1
      ? list.first
      : await showModalBottomSheet<Map>(
          context: context,
          showDragHandle: true,
          builder: (ctx) => ListView(shrinkWrap: true, children: [
            for (final x in list)
              ListTile(
                leading: const Icon(Icons.sports_rounded),
                title: Text('${x['name']}'),
                trailing: x['mine'] == null ? null : Stars((x['mine'] as Map)['stars'] as num, size: 14),
                onTap: () => Navigator.pop(ctx, x),
              ),
          ]),
        );
  if (t != null && context.mounted) context.push('/rate', extra: {'tenantId': tenantId, 'trainerId': t['trainerId'], 'name': t['name'], 'mine': t['mine']});
}

/// Trainer home: my rating, my salary, testimonials.
class TrainerGymExtras extends ConsumerWidget {
  const TrainerGymExtras({super.key, required this.g});
  final Map g;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = ref.watch(myTrainerRatingProvider).valueOrNull as Map?;
    final gr = (g['rating'] as Map?) ?? const {};
    // Same tiles as the three above (same size), side by side.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 9),
      Row(children: [
        Expanded(child: StatTile(icon: Icons.star_rounded, color: C.gold, value: r?['avg'] == null ? '—' : '${r!['avg']}', label: context.t('My rating · {n}', {'n': r?['count'] ?? 0}))),
        const SizedBox(width: 9),
        Expanded(child: StatTile(icon: Icons.payments_rounded, color: C.ok, value: context.t('Salary'), label: '${context.t('My slips')} ›', onTap: () => context.push('/my-salary'))),
      ]),
      const SizedBox(height: 12),
      TestimonialsSlider(items: ((g['testimonials'] as List?) ?? const []).cast<Map>(), avg: gr['avg'] as num?, count: gr['count'] as int?),
    ]);
  }
}

/// Owner: trainer ratings and gym reviews (choose which reviews show on dashboards).
class RatingsScreen extends ConsumerStatefulWidget {
  const RatingsScreen({super.key});
  @override
  ConsumerState<RatingsScreen> createState() => _RatingsState();
}

class _RatingsState extends ConsumerState<RatingsScreen> {
  String tab = 'gym';
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('Ratings & reviews'))),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Seg<String>(value: tab, items: [('gym', context.t('Gym reviews'), Icons.storefront_rounded), ('trainers', context.t('Trainers'), Icons.sports_rounded)], onChanged: (v) => setState(() => tab = v)),
          ),
          Expanded(child: tab == 'gym' ? const _GymReviews() : const _TrainerRatings()),
        ]),
      );
}

/// Gym reviews, branch wise (board 93): one card per branch; open it for that branch's reviews.
/// A review shown on dashboards is seen only by the people of its own branch.
class _GymReviews extends ConsumerStatefulWidget {
  const _GymReviews();
  @override
  ConsumerState<_GymReviews> createState() => _GymReviewsState();
}

class _GymReviewsState extends ConsumerState<_GymReviews> {
  String? branch;
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(gymRatingsProvider);
    return RefreshIndicator(
      color: context.c.primary,
      onRefresh: () async => ref.invalidate(gymRatingsProvider),
      child: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(gymRatingsProvider),
        builder: (d) {
          final all = ((d['rows'] as List?) ?? const []).cast<Map>();
          final branches = ((d['branches'] as List?) ?? const []).cast<Map>();
          // One branch: straight to its reviews.
          if (branches.length > 1 && branch == null) {
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              for (final b in branches) ...[
                Panel(
                  onTap: () => setState(() => branch = b['id'] as String),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${b['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 2),
                        Muted(context.t('{n} ratings · {s} on dashboards', {'n': b['count'] ?? 0, 's': b['shown'] ?? 0}), size: 12),
                      ]),
                    ),
                    const Icon(Icons.star_rounded, color: C.gold, size: 20),
                    Text(' ${b['avg'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                    Icon(Icons.chevron_right_rounded, color: context.c.mut),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
              Muted(context.t('Reviews you show on dashboards are seen only by members, trainers and staff of that branch.'), size: 12),
            ]);
          }
          final b = branches.length > 1 ? branches.firstWhere((x) => x['id'] == branch, orElse: () => branches.first) : (branches.isEmpty ? d as Map : branches.first);
          final rows = branches.length > 1 ? all.where((r) => r['branchId'] == b['id']).toList() : all;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            if (branches.length > 1)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(onPressed: () => setState(() => branch = null), icon: const Icon(Icons.arrow_back_rounded, size: 18), label: Text(context.t('All branches'))),
              ),
            if (branches.length > 1) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${b['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
            Row(children: [
              Expanded(child: StatTile(icon: Icons.star_rounded, value: '${b['avg'] ?? '—'}', label: context.t('{n} ratings', {'n': b['count'] ?? 0}), color: C.gold)),
              const SizedBox(width: 10),
              Expanded(child: StatTile(icon: Icons.trending_up_rounded, value: '+${b['thisMonth'] ?? 0}', label: context.t('This month'), color: C.ok)),
            ]),
            const SizedBox(height: 12),
            if (rows.isEmpty) Padding(padding: const EdgeInsets.only(top: 20), child: Muted(context.t('No reviews yet'), align: TextAlign.center)),
            for (final r in rows) ...[
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [Avatar(name: '${r['name']}', url: r['photoUrl'] as String?, size: 32), const SizedBox(width: 9), Expanded(child: Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w800))), Stars(r['stars'] as num, size: 15)]),
                  if (r['comment'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('"${r['comment']}"', style: const TextStyle(height: 1.3))),
                  if (((r['tags'] as List?) ?? const []).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Muted((r['tags'] as List).map((t) => context.t('$t')).join(' · '), size: 12)),
                  const SizedBox(height: 8),
                  if (r['allowShow'] == true && r['comment'] != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: r['shown'] == true
                          ? FilledButton.icon(
                              onPressed: () async {
                                await _run(context, () => Api.instance.post('/gym-ratings/${r['id'] ?? r['userId']}/show', {'show': false}));
                                ref.invalidate(gymRatingsProvider);
                              },
                              icon: const Icon(Icons.check_rounded, size: 18),
                              label: Text(context.t('On dashboards')),
                            )
                          : OutlinedButton(
                              onPressed: () async {
                                await _run(context, () => Api.instance.post('/gym-ratings/${r['id'] ?? r['userId']}/show', {'show': true}), done: context.t('Shown on dashboards'));
                                ref.invalidate(gymRatingsProvider);
                              },
                              child: Text(context.t('Show on dashboards')),
                            ),
                    )
                  else
                    Muted(context.t('Only for you (the member did not allow showing it)'), size: 11.5),
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

/// Trainer ratings, branch wise: one card per branch (each branch has its own trainers).
class _TrainerRatings extends ConsumerStatefulWidget {
  const _TrainerRatings();
  @override
  ConsumerState<_TrainerRatings> createState() => _TrainerRatingsState();
}

class _TrainerRatingsState extends ConsumerState<_TrainerRatings> {
  String? branch;
  @override
  Widget build(BuildContext context) {
    final v = ref.watch(trainerRatingsProvider);
    final g = ref.watch(gymProvider).valueOrNull as Map?;
    final branches = branchesOf(g);
    return AsyncBody(
      value: v,
      onRetry: () => ref.invalidate(trainerRatingsProvider),
      builder: (d) {
        final all = (d as List).cast<Map>();
        if (branches.length > 1 && branch == null) {
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            BranchCards(
              items: [
                for (final b in branches)
                  () {
                    final mine = all.where((t) => t['branchId'] == b['id']).toList();
                    final rated = mine.where((t) => t['avg'] != null).toList();
                    final avg = rated.isEmpty ? null : (rated.map((t) => (t['avg'] as num) * (t['count'] as num)).reduce((x, y) => x + y) / rated.map((t) => t['count'] as num).reduce((x, y) => x + y));
                    return (
                      id: b['id'] as String,
                      name: '${b['name']}',
                      sub: context.t('{n} trainers · {r} ratings', {'n': mine.length, 'r': mine.fold<num>(0, (n, t) => n + ((t['count'] as num?) ?? 0))}),
                      right: avg == null ? null : '★ ${avg.toStringAsFixed(1)}',
                      rightColor: C.gold,
                    );
                  }(),
              ],
              onPick: (id) => setState(() => branch = id),
            ),
          ]);
        }
        final rows = branches.length > 1 ? all.where((t) => t['branchId'] == branch).toList() : all;
        return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          if (branches.length > 1) ...[
            Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => setState(() => branch = null), icon: const Icon(Icons.arrow_back_rounded, size: 18), label: Text(context.t('All branches')))),
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('${branches.firstWhere((b) => b['id'] == branch, orElse: () => const {})['name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
          ],
          if (rows.isEmpty) Padding(padding: const EdgeInsets.only(top: 20), child: Muted(context.t('No trainers in this branch yet'), align: TextAlign.center)),
          for (final t in rows) ...[
            Panel(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${t['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
                  if (t['avg'] != null) ...[Stars(t['avg'] as num, size: 15), Text(' ${t['avg']} · ${t['count']}', style: const TextStyle(fontWeight: FontWeight.w700))] else Muted(context.t('No ratings yet'), size: 12),
                ]),
                if (t['avg'] != null && (t['avg'] as num) < 3.5) Padding(padding: const EdgeInsets.only(top: 4), child: _pill(context.t('Needs attention'), C.red)),
                if (((t['tags'] as List?) ?? const []).isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Muted((t['tags'] as List).cast<Map>().map((x) => '${context.t(x['tag'] as String)} ${x['n']}').join(' · '), size: 12)),
                for (final c in ((t['comments'] as List?) ?? const []).cast<Map>().take(3)) Padding(padding: const EdgeInsets.only(top: 6), child: Muted('"${c['comment']}" — ${c['name']}', size: 12.5)),
              ]),
            ),
            const SizedBox(height: 10),
          ],
        ]);
      },
    );
  }
}

// ======================= Fingerprint machines =======================

// ============================================================ fingerprint / face machines (boards 99-105)

const _kinds = {
  'adms': ('eSSL / ZKTeco', Icons.fingerprint_rounded),
  'hik': ('Hikvision', Icons.face_retouching_natural_rounded),
  'link': ('Other (web link)', Icons.link_rounded),
  'file': ('Pen drive file', Icons.usb_rounded),
};

String _seen(BuildContext context, Map d) {
  final kind = d['kind'] ?? 'adms';
  if (kind == 'file') return context.t('Upload its attendance file from a pen drive');
  if (d['lastSeen'] == null) return context.t('Not connected yet');
  return kind == 'adms' ? context.t('Last contact {t}', {'t': fmtDateTime(d['lastSeen'] as String)}) : context.t('Last punch {t}', {'t': fmtDateTime(d['lastSeen'] as String)});
}

/// Attendance → Fingerprint machines: the branch's switch, door option and its machines.
class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});
  @override
  ConsumerState<DevicesScreen> createState() => _DevicesState();
}

class _DevicesState extends ConsumerState<DevicesScreen> {
  bool? fpOn;
  bool? gateOn;

  Future<void> setMode({bool? on, bool? gate}) async {
    if (on == true) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.fingerprint_rounded, size: 40),
          title: Text(ctx.t('Attendance only by fingerprint?')),
          content: Text(ctx.t('At this branch:\n✗ Members cannot check in with the QR\n✗ Staff and trainers cannot mark Present from the app\n✗ The check-in QR is hidden\n✓ Desk manual check-in still works (if the machine is down)\n✓ You can still correct staff attendance')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Yes, turn on'))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() {
      if (on != null) fpOn = on;
      if (gate != null) gateOn = gate;
    });
    final r = await _run(context, () => Api.instance.put('/gym/fingerprint-mode', {if (on != null) 'on': on, if (gate != null) 'gate': gate}));
    if (!mounted) return;
    if (r == null) {
      setState(() {
        fpOn = null;
        gateOn = null;
      });
    }
    ref.invalidate(devicesProvider);
  }

  Future<void> add() async {
    final made = await Navigator.of(context).push<Map>(MaterialPageRoute(builder: (_) => const _AddMachine()));
    ref.invalidate(devicesProvider);
    if (made != null && mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => MachineScreen(serial: made['serial'] as String)));
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(devicesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Fingerprint machines'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(devicesProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(devicesProvider),
          builder: (d0) {
            final d = d0 is Map ? d0 : {'machines': d0};
            final list = ((d['machines'] as List?) ?? const []).cast<Map>();
            final on = fpOn ?? d['fingerprintOnly'] == true;
            final gate = gateOn ?? d['fpGate'] == true;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              if (d['branchName'] != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Muted('📍 ${d['branchName']}', size: 12.5)),
              Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(context.t('Attendance only by fingerprint machine'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 2),
                        Muted(on ? context.t('On: QR check-in and app "Present" are off at this branch') : context.t('Turns off QR check-in and app "Present" at this branch'), size: 12),
                      ]),
                    ),
                    Switch(value: on, onChanged: (x) => setMode(on: x)),
                  ]),
                  const Divider(height: 20),
                  Text(context.t('Who opens the door?'), style: const TextStyle(fontWeight: FontWeight.w700)),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: false,
                    groupValue: gate,
                    onChanged: (x) => setMode(gate: false),
                    title: Text(context.t('A. Attendance only')),
                    subtitle: Text(context.t('Staff or the machine opens the door. The desk is told if someone with no valid plan comes in.')),
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    value: true,
                    groupValue: gate,
                    onChanged: (x) => setMode(gate: true),
                    title: Text(context.t('B. GymMantra opens the gate')),
                    subtitle: Text(context.t('The door lock is on the WiFi relay (More → Gate). It opens only for members who may enter.')),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              SectionTitle(context.t('Machines')),
              if (list.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Muted(context.t('No machine yet. Add one below.'), align: TextAlign.center)),
              for (final m in list) ...[
                Panel(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MachineScreen(serial: m['serial'] as String))).then((_) => ref.invalidate(devicesProvider)),
                  child: Row(children: [
                    IconTile(_kinds[m['kind']]?.$2 ?? Icons.fingerprint_rounded, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                        Muted('${context.t(_kinds[m['kind']]?.$1 ?? 'eSSL / ZKTeco')} · ${_seen(context, m)}', size: 11.5),
                        if (((m['unknown'] as List?) ?? const []).isNotEmpty) Text(context.t('{n} numbers not linked', {'n': (m['unknown'] as List).length}), style: const TextStyle(color: C.warn, fontWeight: FontWeight.w700, fontSize: 12)),
                      ]),
                    ),
                    if (m['kind'] != 'file') _pill(context.t(m['online'] == true ? 'Online' : 'Offline'), m['online'] == true ? C.ok : C.red),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
              FilledButton.icon(onPressed: add, icon: const Icon(Icons.add_rounded), label: Text(context.t('Add machine'))),
              const SizedBox(height: 10),
              Muted(context.t('Machine user number = the number in the Member ID (LF-1023 → 1023): the app links the member by itself.'), size: 12, align: TextAlign.center),
            ]);
          },
        ),
      ),
    );
  }
}

class _AddMachine extends StatefulWidget {
  const _AddMachine();
  @override
  State<_AddMachine> createState() => _AddMachineState();
}

class _AddMachineState extends State<_AddMachine> {
  String kind = 'adms';
  final serial = TextEditingController();
  final name = TextEditingController();
  bool busy = false;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('Add machine'))),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          Text(context.t('1. Which machine?'), style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in _kinds.entries)
              ChoiceChip(
                avatar: Icon(e.value.$2, size: 18),
                label: Text(context.t(e.value.$1)),
                selected: kind == e.key,
                onSelected: (_) => setState(() => kind = e.key),
              ),
          ]),
          const SizedBox(height: 8),
          Muted(
            context.t({
              'adms': 'eSSL, ZKTeco, Realtime, Identix with a "Cloud server / ADMS" option.',
              'hik': 'Hikvision face or fingerprint terminals with "HTTP Listening".',
              'link': 'Matrix, Suprema or any machine / software that can send each punch to a web link.',
              'file': 'A machine without internet: download its attendance to a pen drive and upload the file here.',
            }[kind]!),
            size: 12.5,
          ),
          const SizedBox(height: 16),
          if (kind == 'adms') ...[
            LabeledField(label: context.t('2. Serial number (on the back of the machine or in its menu)'), controller: serial, caps: TextCapitalization.characters, hint: 'CGXH2034'),
            const SizedBox(height: 12),
          ],
          LabeledField(label: context.t('Name (optional)'), controller: name, hint: context.t('Reception machine')),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    final r = await _run(context, () => Api.instance.post('/gym/devices', {'kind': kind, if (kind == 'adms') 'serial': serial.text.trim(), if (name.text.trim().isNotEmpty) 'name': name.text.trim()}));
                    if (!mounted) return;
                    setState(() => busy = false);
                    if (r is Map) Navigator.of(context).pop(r);
                  },
            child: Text(context.t('Add')),
          ),
        ]),
      );
}

/// One machine: how to set it up, its numbers, pen-drive upload.
class MachineScreen extends ConsumerStatefulWidget {
  const MachineScreen({super.key, required this.serial});
  final String serial;
  @override
  ConsumerState<MachineScreen> createState() => _MachineState();
}

class _MachineState extends ConsumerState<MachineScreen> {
  bool uploading = false;
  String? progress;

  Future<void> link(String pin) async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.person_rounded), title: Text(ctx.t('A member')), onTap: () => Navigator.pop(ctx, 'member')),
        ListTile(leading: const Icon(Icons.badge_rounded), title: Text(ctx.t('Staff or trainer')), onTap: () => Navigator.pop(ctx, 'staff')),
        const SizedBox(height: 12),
      ]),
    );
    if (kind == null || !mounted) return;
    Map? who;
    if (kind == 'member') {
      who = await pickMember(context);
    } else {
      final d = await _run(context, () => Api.instance.get('/staff-attendance'));
      final rows = (((d as Map?)?['rows'] as List?) ?? const []).cast<Map>();
      if (!mounted) return;
      who = await showModalBottomSheet<Map>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => ListView(shrinkWrap: true, children: [for (final r in rows) ListTile(title: Text('${r['name']}'), subtitle: Text(ctx.t(r['role'] == 'TRAINER' ? 'Trainer' : 'Front desk')), onTap: () => Navigator.pop(ctx, r))]),
      );
    }
    if (who == null || !mounted) return;
    await _run(context, () => Api.instance.put('/gym/devices/${widget.serial}/pins/$pin', {'kind': kind, 'id': who!['id']}), done: context.t('Linked'));
    ref.invalidate(devicesProvider);
  }

  Future<void> upload() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    final bytes = r?.files.firstOrNull?.bytes;
    if (bytes == null || !mounted) return;
    final text = utf8.decode(bytes, allowMalformed: true).replaceAll('\u0000', '');
    final dry = await _run(context, () => Api.instance.post('/gym/devices/${widget.serial}/import', {'text': text, 'dry': true}));
    if (dry is! Map || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Found {n} entries', {'n': dry['total']})),
        content: Text(ctx.t('{from} to {to}\n✓ {m} member check-ins\n✓ {s} staff Present\n? {u} numbers not linked (you can link them later)', {
          'from': fmtDate('${(dry['days'] as Map?)?['from']}'),
          'to': fmtDate('${(dry['days'] as Map?)?['to']}'),
          'm': dry['members'],
          's': dry['staff'],
          'u': dry['unknown'],
        })),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Add')))],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => uploading = true);
    var offset = 0;
    try {
      while (true) {
        final p = await Api.instance.post('/gym/devices/${widget.serial}/import', {'text': text, 'offset': offset}) as Map;
        if (!mounted) return;
        setState(() => progress = '${p['done']} / ${p['total']}');
        if (p['more'] != true) break;
        offset = p['next'] as int;
      }
      if (mounted) toast(context, context.t('Attendance added'), kind: DripKind.ok);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
    if (mounted) {
      setState(() {
        uploading = false;
        progress = null;
      });
    }
    ref.invalidate(devicesProvider);
  }

  Widget copyRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Muted(label, size: 11.5), SelectableText(value, style: const TextStyle(fontWeight: FontWeight.w800))])),
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              toast(context, context.t('Copied'), kind: DripKind.ok);
            },
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(devicesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Machine'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(devicesProvider),
        builder: (d0) {
          final list = ((d0 is Map ? d0['machines'] : d0) as List? ?? const []).cast<Map>();
          final m = list.firstWhere((x) => x['serial'] == widget.serial, orElse: () => const {});
          if (m.isEmpty) return Center(child: Muted(context.t('Machine not found')));
          final kind = m['kind'] ?? 'adms';
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            Row(children: [
              IconTile(_kinds[kind]?.$2 ?? Icons.fingerprint_rounded, size: 44),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)), Muted('${context.t(_kinds[kind]?.$1 ?? '')} · ${_seen(context, m)}', size: 12)])),
              if (kind != 'file') _pill(context.t(m['online'] == true ? 'Online' : 'Offline'), m['online'] == true ? C.ok : C.red),
            ]),
            const SizedBox(height: 12),
            Panel(
              color: C.warn.withAlpha(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(context.t('Set up'), style: const TextStyle(fontWeight: FontWeight.w800)),
                if (kind == 'adms') ...[
                  Muted(context.t('On the machine: Menu → Comm → Cloud Server Setting (ADMS). Turn the proxy off. Then enter:'), size: 12.5),
                  copyRow(context.t('Server address'), '${m['server']}'),
                  copyRow(context.t('Port'), '443 (HTTPS on) · ${context.t('or')} 80'),
                  copyRow(context.t('Serial number'), '${m['serial']}'),
                ] else if (kind == 'hik') ...[
                  Muted(context.t('On the machine (web page or iVMS-4200): Network → Advanced → HTTP Listening / Event alarm host. Put this link, method POST:'), size: 12.5),
                  copyRow(context.t('Link (keep it secret)'), '${m['url']}'),
                ] else if (kind == 'link') ...[
                  Muted(context.t('Tell the machine or software to send each punch to this link (POST) with the person\'s number and time, e.g. {"pin": "1023", "time": "2026-11-06 07:12"}.'), size: 12.5),
                  copyRow(context.t('Link (keep it secret)'), '${m['url']}'),
                ] else ...[
                  Muted(context.t('On the machine: USB / Pen drive → Download attendance (attlog). Put the pen drive in a phone (OTG) or copy the file, then upload it here. Last 31 days are added; the same file twice adds nothing.'), size: 12.5),
                  const SizedBox(height: 8),
                  FilledButton.icon(onPressed: uploading ? null : upload, icon: const Icon(Icons.upload_file_rounded), label: Text(uploading ? '${context.t('Adding…')} ${progress ?? ''}' : context.t('Upload attendance file'))),
                ],
              ]),
            ),
            const SizedBox(height: 14),
            SectionTitle(context.t('Machine numbers')),
            for (final u in ((m['unknown'] as List?) ?? const []).cast<Map>())
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Panel(
                child: Row(children: [
                  _pill('${u['pin']}', C.warn),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(context.t('Number {pin} is not linked', {'pin': u['pin']}), style: const TextStyle(fontWeight: FontWeight.w700)), Muted(fmtDateTime('${u['at']}'.replaceFirst(' ', 'T')), size: 11.5)])),
                  FilledButton(onPressed: () => link('${u['pin']}'), child: Text(context.t('Link'))),
                ]),
              ),
              ),
            for (final p in ((m['pins'] as List?) ?? const []).cast<Map>())
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: _pill('${p['pin']}', C.indigo),
                title: Text('${p['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(context.t(p['kind'] == 'member' ? 'Member' : 'Staff / trainer')),
                trailing: IconButton(
                  icon: const Icon(Icons.link_off_rounded),
                  onPressed: () async {
                    await _run(context, () => Api.instance.delete('/gym/devices/${widget.serial}/pins/${p['pin']}'));
                    ref.invalidate(devicesProvider);
                  },
                ),
              ),
            TextButton.icon(
              onPressed: () async {
                final pin = TextEditingController();
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(ctx.t('Machine user number')),
                    content: TextField(controller: pin, keyboardType: TextInputType.number, autofocus: true),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Next')))],
                  ),
                );
                if (ok == true && pin.text.trim().isNotEmpty && mounted) await link(pin.text.trim());
              },
              icon: const Icon(Icons.add_link_rounded),
              label: Text(context.t('Link a machine number')),
            ),
            const SizedBox(height: 10),
            TextButton(
              onPressed: () async {
                final r = await _run(context, () => Api.instance.delete('/gym/devices/${widget.serial}'), done: context.t('Machine removed'));
                ref.invalidate(devicesProvider);
                if (r != null && mounted) Navigator.of(context).pop();
              },
              child: Text(context.t('Remove machine'), style: const TextStyle(color: C.red)),
            ),
          ]);
        },
      ),
    );
  }
}
