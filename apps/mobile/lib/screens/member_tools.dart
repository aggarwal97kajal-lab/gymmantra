import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'desk.dart' show fmtTime;
import 'person.dart' show ymd;

// Board 52: what the website's member page has, in the owner app.

void _refresh(WidgetRef ref, String id) {
  ref.invalidate(ownerMemberProvider(id));
  ref.invalidate(ownerMembersProvider);
  ref.invalidate(dashboardProvider);
}

/// Buttons under the member: Edit · Freeze · Correct · Remove.
class MemberToolsRow extends ConsumerWidget {
  const MemberToolsRow({super.key, required this.id, required this.data});
  final String id;
  final Map data;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final m = data['member'] as Map;
    final st = data['state'] as Map;
    final history = ((data['history'] as List?) ?? const []).cast<Map>();
    final cur = history.where((h) => h['id'] == st['currentId']).firstOrNull;
    final frozen = st['status'] == 'FROZEN';
    Widget btn(IconData icon, String label, VoidCallback? onTap, {Color? color}) => Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(foregroundColor: color, padding: const EdgeInsets.symmetric(horizontal: 8)),
            onPressed: onTap,
            icon: Icon(icon, size: 18),
            label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        );
    return Column(children: [
      Row(children: [
        if (s.can('memberEdit')) btn(Icons.edit_rounded, context.t('Edit'), () => editMemberSheet(context, ref, id, m)),
        if (s.can('memberEdit') && s.can('payments')) const SizedBox(width: 8),
        if (s.can('payments'))
          btn(
            Icons.ac_unit_rounded,
            frozen ? context.t('End freeze') : context.t('Freeze'),
            cur == null ? null : () => frozen ? endFreeze(context, ref, id, cur) : freezeSheet(context, ref, id, cur, (st['freezeDaysLeft'] as int?) ?? 0),
          ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        if (s.can('payments')) btn(Icons.build_rounded, context.t('Correct'), cur == null ? null : () => correctSheet(context, ref, id, cur)),
        if (s.can('payments') && s.myGym?['role'] == 'OWNER') const SizedBox(width: 8),
        if (s.myGym?['role'] == 'OWNER') btn(Icons.person_remove_rounded, context.t('Remove'), () => removeMember(context, ref, id, m), color: C.red),
      ]),
    ]);
  }
}

/// Recent check-ins of this member.
class RecentCheckins extends StatelessWidget {
  const RecentCheckins({super.key, required this.data});
  final Map data;
  @override
  Widget build(BuildContext context) {
    final list = ((data['attendance'] as List?) ?? const []).cast<Map>().take(8).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(context.t('Recent check-ins')),
      if (list.isEmpty)
        Panel(child: Muted(context.t('No check-ins yet.'), align: TextAlign.center))
      else
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            for (final a in list)
              ListTile(
                dense: true,
                leading: Icon(a['result'] == 'BLOCKED' ? Icons.block_rounded : Icons.check_circle_rounded, color: a['result'] == 'BLOCKED' ? C.red : C.ok),
                title: Text('${fmtDate(a['scannedAt'] as String?)} · ${fmtTime(a['scannedAt'] as String?)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: a['result'] == 'BLOCKED' && a['reason'] != null ? Text('${a['reason']}', style: TextStyle(color: context.c.mut, fontSize: 12)) : null,
              ),
          ]),
        ),
    ]);
  }
}

Future<void> editMemberSheet(BuildContext context, WidgetRef ref, String id, Map m) async {
  final name = TextEditingController(text: m['name'] as String? ?? '');
  final phone = TextEditingController(text: m['phone'] as String? ?? '');
  final email = TextEditingController(text: m['email'] as String? ?? '');
  final notes = TextEditingController(text: m['notes'] as String? ?? '');
  var gender = m['gender'] as String?;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        var busy = false;
        return Padding(
          padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(ctx.t('Edit member'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: ctx.t('Name'))),
              const SizedBox(height: 10),
              TextField(controller: phone, keyboardType: TextInputType.phone, decoration: InputDecoration(labelText: ctx.t('Mobile'), prefixText: '+91 ')),
              const SizedBox(height: 10),
              TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: InputDecoration(labelText: ctx.t('Email'))),
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                for (final (k, l) in [('male', 'Male'), ('female', 'Female'), ('other', 'Other')])
                  ChoiceChip(label: Text(ctx.t(l)), selected: gender == k, showCheckmark: false, onSelected: (_) => setState(() => gender = k)),
              ]),
              const SizedBox(height: 10),
              TextField(controller: notes, maxLines: 3, decoration: InputDecoration(labelText: ctx.t('Notes (only staff see this)'))),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() => busy = true);
                        try {
                          await Api.instance.patch('/members/$id', {
                            'name': name.text.trim(),
                            'phone': phone.text.replaceAll(RegExp(r'\D'), ''),
                            'email': email.text.trim(),
                            if (gender != null) 'gender': gender,
                            'notes': notes.text.trim(),
                          });
                          _refresh(ref, id);
                          if (ctx.mounted) Navigator.pop(ctx);
                        } catch (e) {
                          if (ctx.mounted) toastError(ctx, e);
                          setState(() => busy = false);
                        }
                      },
                child: Text(ctx.t('Save')),
              ),
            ]),
          ),
        );
      },
    ),
  );
}

Future<void> freezeSheet(BuildContext context, WidgetRef ref, String id, Map sub, int daysLeft) async {
  if (daysLeft <= 0) {
    toast(context, context.t('No freeze days left in this plan'));
    return;
  }
  var start = DateTime.now();
  var days = daysLeft >= 7 ? 7 : daysLeft;
  final reason = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(ctx.t('Freeze membership'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          Muted(ctx.t('{n} freeze days left in this plan', {'n': daysLeft}), size: 12.5),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: ctx, initialDate: start, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 60)));
              if (d != null) setState(() => start = d);
            },
            icon: const Icon(Icons.event_rounded),
            label: Text('${ctx.t('From')} ${fmtDate(ymd(start))}'),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            for (final n in {3, 7, 10, 15, daysLeft}.where((n) => n <= daysLeft).toList()..sort())
              ChoiceChip(label: Text('$n'), selected: days == n, showCheckmark: false, onSelected: (_) => setState(() => days = n)),
          ]),
          const SizedBox(height: 10),
          TextField(controller: reason, decoration: InputDecoration(labelText: ctx.t('Reason (optional)'))),
          const SizedBox(height: 10),
          Muted(ctx.t('No check-in while frozen. The end date moves {n} days later. Ending early gives the unused days back.', {'n': days}), size: 12),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: () async {
              try {
                await Api.instance.post('/memberships/${sub['id']}/freeze', {'days': days, 'startDate': ymd(start), if (reason.text.trim().isNotEmpty) 'reason': reason.text.trim()});
                _refresh(ref, id);
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (ctx.mounted) toastError(ctx, e);
              }
            },
            child: Text(ctx.t('Freeze {n} days', {'n': days})),
          ),
        ]),
      ),
    ),
  );
}

Future<void> endFreeze(BuildContext context, WidgetRef ref, String id, Map sub) async {
  final f = ((sub['freezes'] as List?) ?? const []).cast<Map>().where((x) => x['endedOn'] == null).lastOrNull;
  if (f == null) return;
  try {
    await Api.instance.post('/freezes/${f['id']}/end', {});
    _refresh(ref, id);
    if (context.mounted) toast(context, context.t('Freeze ended'));
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}

Future<void> correctSheet(BuildContext context, WidgetRef ref, String id, Map sub) async {
  List<Map> plans = const [];
  try {
    plans = ((await Api.instance.get('/plans')) as List).cast<Map>();
  } catch (_) {}
  if (!context.mounted) return;
  var planId = sub['planId'] as String?;
  var start = DateTime.tryParse(sub['startDate'] as String? ?? '') ?? DateTime.now();
  final price = TextEditingController(text: '${sub['total'] ?? ''}');
  final reason = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => Padding(
        padding: EdgeInsets.fromLTRB(18, 16, 18, 16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(ctx.t('Correct membership'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            Muted(ctx.t('The old entry is not changed — a new correct entry is made and the old one shows "Corrected". Money already received moves to the new entry.'), size: 12),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final p in plans)
                ChoiceChip(
                  label: Text(p['name'] as String),
                  selected: planId == p['id'],
                  showCheckmark: false,
                  onSelected: (_) => setState(() {
                    planId = p['id'] as String;
                    price.text = '${p['price']}';
                  }),
                ),
            ]),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(context: ctx, initialDate: start, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365)));
                if (d != null) setState(() => start = d);
              },
              icon: const Icon(Icons.event_rounded),
              label: Text('${ctx.t('Start')} ${fmtDate(ymd(start))}'),
            ),
            const SizedBox(height: 10),
            TextField(controller: price, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: ctx.t('Price'), prefixText: '₹ ')),
            const SizedBox(height: 10),
            TextField(controller: reason, decoration: InputDecoration(labelText: ctx.t('Reason *'), hintText: ctx.t('For example: wrong plan was chosen'))),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: () async {
                if (planId == null || reason.text.trim().isEmpty) {
                  toast(ctx, ctx.t('Choose the plan and write the reason'));
                  return;
                }
                try {
                  await Api.instance.post('/memberships/${sub['id']}/correct', {
                    'planId': planId,
                    'startDate': ymd(start),
                    if (int.tryParse(price.text.trim()) != null) 'price': int.parse(price.text.trim()),
                    'paymentMode': 'NOT_PAID',
                    'note': reason.text.trim(),
                  });
                  _refresh(ref, id);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  if (ctx.mounted) toastError(ctx, e);
                }
              },
              child: Text(ctx.t('Save correction')),
            ),
          ]),
        ),
      ),
    ),
  );
}

Future<void> removeMember(BuildContext context, WidgetRef ref, String id, Map m) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(ctx.t('Remove {name} from the gym?', {'name': m['name']})),
      content: Text(ctx.t('They leave your members list and can no longer check in. Their GymMantra login stays the same. Money already received stays in your reports.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Remove'), style: const TextStyle(color: C.red))),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await Api.instance.delete('/members/$id');
    ref.invalidate(ownerMembersProvider);
    ref.invalidate(dashboardProvider);
    if (context.mounted) {
      toast(context, context.t('Removed from gym'));
      context.pop();
    }
  } catch (e) {
    if (context.mounted) toastError(context, e);
  }
}
