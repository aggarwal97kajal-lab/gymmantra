import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import '../photo.dart' show Avatar;
import '../api.dart';
import '../i18n.dart';
import '../qr_scan.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show PhoneField;
import 'branch.dart' show branchesOf;
import 'reports_kit.dart' show saveAndOffer;
import 'person.dart';

// Boards 50–62: staff, attendance, staff attendance, import, gate, transfer gym.

final staffProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/gym/staff'));
final gateProvider = StreamProvider.autoDispose<dynamic>((ref) => branchGet(ref, '/gym/gate'));

const rightKeys = ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'transfers', 'offers', 'reports', 'plans'];
const presets = {
  'RECEPTION': ['members', 'memberEdit', 'payments', 'checkin', 'requests'],
  'CHECKIN': ['members', 'checkin'],
  'MANAGER': ['members', 'memberEdit', 'payments', 'checkin', 'requests', 'transfers', 'offers', 'reports', 'plans'],
};

String rightLabel(BuildContext context, String k) => switch (k) {
      'members' => context.t('See members'),
      'memberEdit' => context.t('Add / edit members'),
      'payments' => context.t('Take payments'),
      'checkin' => context.t('Check-in and gate'),
      'requests' => context.t('Approve requests'),
      'transfers' => context.t('Branch moves'),
      'offers' => context.t('Send offers and notices'),
      'reports' => context.t('Money reports'),
      _ => context.t('Plans and gym settings'),
    };

String rightSub(BuildContext context, String k) => switch (k) {
      'members' => context.t('Members list and member page'),
      'memberEdit' => context.t('New member, edit details, import'),
      'payments' => context.t('Memberships, payments, freeze'),
      'checkin' => context.t('Manual check-in, see who came, open gate'),
      'requests' => context.t('Join and PT requests'),
      'transfers' => context.t('Move a member to another branch and approve move requests'),
      'offers' => '',
      'reports' => context.t('Collection, dues'),
      _ => '',
    };

String? presetOf(List rights) {
  for (final e in presets.entries) {
    if (e.value.length == rights.length && e.value.every(rights.contains)) return e.key;
  }
  return null;
}

String presetLabel(BuildContext context, String k) => switch (k) {
      'RECEPTION' => context.t('Reception'),
      'CHECKIN' => context.t('Check-in only'),
      'MANAGER' => context.t('Manager'),
      _ => context.t('Custom'),
    };

// ============================================================ staff list (branch-wise)

class StaffListScreen extends ConsumerWidget {
  const StaffListScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(staffProvider);
    final gym = ref.watch(gymProvider).valueOrNull as Map?;
    final bs = branchesOf(gym);
    final bid = Api.instance.branchId ?? (bs.isEmpty ? null : bs.first['id']);
    final bname = bs.firstWhere((b) => b['id'] == bid, orElse: () => const {})['name'] as String?;
    final me = ref.watch(sessionProvider).user?['id'];
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Staff'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: context.c.primary,
        foregroundColor: Colors.white,
        onPressed: () async {
          await context.push('/o/staff/new');
          ref.invalidate(staffProvider);
        },
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: Text(context.t('Add staff')),
      ),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(staffProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(staffProvider),
          builder: (d) {
            final list = (d as List).cast<Map>();
            final owners = list.where((x) => x['role'] == 'OWNER').toList();
            final desk = list.where((x) => x['role'] != 'OWNER').toList();
            Widget tile(Map x) => ListTile(
                  onTap: x['id'] == me
                      ? null
                      : () async {
                          await context.push('/o/staff/edit', extra: x);
                          ref.invalidate(staffProvider);
                        },
                  leading: Avatar(name: (x['user']['name'] as String?) ?? '', url: x['user']['photoUrl'] as String?, size: 42),
                  title: Text('${x['user']['name']}${x['id'] == me ? ' (${context.t('you')})' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    [
                      x['user']['phone'],
                      if (x['role'] != 'OWNER') presetLabel(context, presetOf((x['rights'] as List?) ?? const []) ?? ''),
                      if (x['user']['waitingForLogin'] == true) context.t('Not logged in yet'),
                    ].where((e) => e != null).join(' · '),
                    style: TextStyle(color: context.c.mut, fontSize: 12),
                  ),
                  trailing: _RoleTag(x['role'] as String),
                );
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
              Panel(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(children: [
                  const Icon(Icons.store_mall_directory_rounded, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: Text(context.t('Branch: {b}', {'b': bname ?? '-'}), style: const TextStyle(fontWeight: FontWeight.w700))),
                  Muted(context.t('{n} staff', {'n': desk.length}), size: 12.5),
                ]),
              ),
              const SizedBox(height: 6),
              Muted(context.t('Each branch has its own staff. Switch branch on Home to see another branch.'), size: 12),
              const SizedBox(height: 12),
              SectionTitle(context.t('Front desk')),
              if (desk.isEmpty)
                Panel(child: Muted(context.t('No staff in this branch yet. Tap "Add staff".'), align: TextAlign.center))
              else
                Panel(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: [for (final x in desk) tile(x)])),
              const SizedBox(height: 14),
              SectionTitle(context.t('Owners')),
              Panel(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: [for (final x in owners) tile(x)])),
            ]);
          },
        ),
      ),
    );
  }
}

class _RoleTag extends StatelessWidget {
  const _RoleTag(this.role);
  final String role;
  @override
  Widget build(BuildContext context) {
    final owner = role == 'OWNER';
    final color = owner ? C.ok : C.blue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: color.withAlpha(36), borderRadius: BorderRadius.circular(99)),
      child: Text(owner ? context.t('Owner') : context.t('Front desk'), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

/// Preset chips + switches for each right.
class RightsPicker extends StatelessWidget {
  const RightsPicker({super.key, required this.rights, required this.onChanged});
  final List<String> rights;
  final ValueChanged<List<String>> onChanged;
  @override
  Widget build(BuildContext context) {
    final cur = presetOf(rights) ?? 'CUSTOM';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final k in ['RECEPTION', 'CHECKIN', 'MANAGER', 'CUSTOM'])
          ChoiceChip(
            label: Text(presetLabel(context, k)),
            selected: cur == k,
            showCheckmark: false,
            selectedColor: context.c.primary,
            labelStyle: TextStyle(color: cur == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
            onSelected: (_) {
              if (k != 'CUSTOM') onChanged(List<String>.from(presets[k]!));
            },
          ),
      ]),
      const SizedBox(height: 10),
      Panel(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(children: [
          for (final k in rightKeys)
            SwitchListTile(
              dense: true,
              value: rights.contains(k),
              activeTrackColor: context.c.primary,
              title: Text(rightLabel(context, k), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: rightSub(context, k).isEmpty ? null : Text(rightSub(context, k), style: TextStyle(color: context.c.mut, fontSize: 12)),
              onChanged: (on) => onChanged(on ? [...rights, k] : rights.where((x) => x != k).toList()),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Muted(context.t('What is switched off does not show in their app, and the server refuses it too.'), size: 12),
    ]);
  }
}

// ============================================================ add staff (like Add member)

class AddStaffScreen extends ConsumerStatefulWidget {
  const AddStaffScreen({super.key});
  @override
  ConsumerState<AddStaffScreen> createState() => _AddStaffState();
}

class _AddStaffState extends ConsumerState<AddStaffScreen> {
  final person = PersonDetails();
  final phone = TextEditingController();
  final email = TextEditingController();
  String role = 'FRONT_DESK';
  String? branchId;
  List<String> rights = List<String>.from(presets['RECEPTION']!);
  bool busy = false;
  String? error;

  Future<void> save() async {
    final miss = person.missing(context);
    final ph = phone.text.replaceAll(RegExp(r'\D'), '');
    String? err = miss;
    if (err == null && ph.length < 10) err = context.t('Enter a valid 10-digit mobile number');
    if (err == null && !email.text.contains('@')) err = context.t('Enter the email ID');
    if (err != null) {
      setState(() => error = err);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await Api.instance.post('/gym/staff', {
        ...person.toJson(),
        'phone': ph,
        'email': email.text.trim(),
        'role': role,
        if (role == 'FRONT_DESK') 'branchId': branchId ?? Api.instance.branchId,
        if (role == 'FRONT_DESK') 'rights': rights,
      });
      if (!mounted) return;
      toast(
          context,
          (r is Map && r['invited'] == true)
              ? context.t('This person already has a GymMantra account. We sent them an invite — they become staff when they accept it.')
              : (r is Map && r['accountMade'] == true)
                  ? context.t('Staff added. They log in as "Gym staff" with Google, or set a password first.')
                  : context.t('Staff added'));
      context.pop();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gym = ref.watch(gymProvider).valueOrNull as Map?;
    final bs = branchesOf(gym);
    branchId ??= Api.instance.branchId ?? (bs.isEmpty ? null : bs.first['id'] as String?);
    Widget label(String t) => Padding(padding: const EdgeInsets.only(left: 2, bottom: 6, top: 4), child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.mut)));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Add staff'))),
      body: Stack(children: [
        ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          PersonFields(value: person, between: [
            PhoneField(label: '${context.t('Mobile')} *', controller: phone, bottom: 12),
            label('${context.t('Email')} *'),
            Padding(padding: const EdgeInsets.only(bottom: 12), child: TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(hintText: 'name@gmail.com'))),
          ]),
          label(context.t('Role')),
          Wrap(spacing: 8, children: [
            for (final (k, l) in [('FRONT_DESK', context.t('Front desk')), ('OWNER', context.t('Owner'))])
              ChoiceChip(
                label: Text(l),
                selected: role == k,
                showCheckmark: false,
                selectedColor: context.c.primary,
                labelStyle: TextStyle(color: role == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                onSelected: (_) => setState(() => role = k),
              ),
          ]),
          if (role == 'FRONT_DESK') ...[
            const SizedBox(height: 8),
            label('${context.t('Branch')} *'),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final b in bs)
                ChoiceChip(
                  label: Text(b['name'] as String),
                  selected: branchId == b['id'],
                  showCheckmark: false,
                  selectedColor: context.c.primary,
                  labelStyle: TextStyle(color: branchId == b['id'] ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                  onSelected: (_) => setState(() => branchId = b['id'] as String),
                ),
            ]),
            const SizedBox(height: 8),
            label(context.t('What can they do?')),
            RightsPicker(rights: rights, onChanged: (r) => setState(() => rights = r)),
          ] else
            Padding(padding: const EdgeInsets.only(top: 8), child: Muted(context.t('An owner can do everything, in every branch.'), size: 12.5)),
          const SizedBox(height: 12),
          Panel(
            child: Muted(
              context.t('A GymMantra account is made for them. They choose "Gym staff" in the app and log in with Google (same email) or set a password with "Forgot password?". If they already have an account, it is linked.'),
              size: 12.5,
            ),
          ),
          ErrorText(error),
          const SizedBox(height: 14),
          FilledButton(onPressed: busy ? null : save, child: Text(context.t('Add staff'))),
        ]),
        if (busy) BusyCover(text: context.t('Adding staff…')),
      ]),
    );
  }
}

// ============================================================ edit staff: role, branch, rights, remove

class StaffEditScreen extends ConsumerStatefulWidget {
  const StaffEditScreen({super.key, required this.staff});
  final Map staff;
  @override
  ConsumerState<StaffEditScreen> createState() => _StaffEditState();
}

class _StaffEditState extends ConsumerState<StaffEditScreen> {
  late String role = widget.staff['role'] as String;
  late String? branchId = ((widget.staff['branchIds'] as List?) ?? const []).cast<String>().firstOrNull;
  late List<String> rights = ((widget.staff['rights'] as List?) ?? const []).cast<String>().toList();
  bool busy = false;

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await Api.instance.patch('/gym/staff/${widget.staff['id']}', {
        'role': role,
        if (role == 'FRONT_DESK' && branchId != null) 'branchId': branchId,
        if (role == 'FRONT_DESK') 'rights': rights,
      });
      if (mounted) {
        toast(context, context.t('Saved'));
        context.pop();
      }
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove() async {
    final name = widget.staff['user']['name'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Remove {name}?', {'name': name})),
        content: Text(ctx.t('They leave your gym and can no longer open it in the app. Their GymMantra login stays the same.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Remove'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.delete('/gym/staff/${widget.staff['id']}');
      if (mounted) {
        toast(context, context.t('Removed from gym'));
        context.pop();
      }
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.staff['user'] as Map;
    final bs = branchesOf(ref.watch(gymProvider).valueOrNull as Map?);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Staff'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Panel(
          child: Row(children: [
            Avatar(name: (u['name'] as String?) ?? '', url: u['photoUrl'] as String?, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((u['name'] as String?) ?? '', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                Muted([u['phone'], u['email']].where((x) => x != null).join(' · '), size: 12.5),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        SectionTitle(context.t('Role')),
        Wrap(spacing: 8, children: [
          for (final (k, l) in [('FRONT_DESK', context.t('Front desk')), ('OWNER', context.t('Owner'))])
            ChoiceChip(
              label: Text(l),
              selected: role == k,
              showCheckmark: false,
              selectedColor: context.c.primary,
              labelStyle: TextStyle(color: role == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
              onSelected: (_) => setState(() => role = k),
            ),
        ]),
        if (role == 'FRONT_DESK') ...[
          const SizedBox(height: 14),
          SectionTitle(context.t('Branch')),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final b in bs)
              ChoiceChip(
                label: Text(b['name'] as String),
                selected: branchId == b['id'],
                showCheckmark: false,
                selectedColor: context.c.primary,
                labelStyle: TextStyle(color: branchId == b['id'] ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                onSelected: (_) => setState(() => branchId = b['id'] as String),
              ),
          ]),
          const SizedBox(height: 14),
          SectionTitle(context.t('What can they do?')),
          RightsPicker(rights: rights, onChanged: (r) => setState(() => rights = r)),
        ],
        const SizedBox(height: 16),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save'))),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: C.red, side: const BorderSide(color: C.red)),
          onPressed: remove,
          icon: const Icon(Icons.person_remove_rounded),
          label: Text(context.t('Remove from gym')),
        ),
      ]),
    );
  }
}

// ============================================================ attendance (owner / front desk)

/// One "Attendance" page (board 77): Members, Staff & trainers (owner), My attendance (staff).
class AttendanceHubScreen extends ConsumerWidget {
  const AttendanceHubScreen({super.key, this.tab = false});
  final bool tab;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final owner = s.myGym?['role'] == 'OWNER';
    final today = ref.watch(attendanceDayProvider('')).valueOrNull;
    Widget card(IconData icon, Color tint, String title, String sub, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Panel(
            onTap: onTap,
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              Container(width: 48, height: 48, decoration: BoxDecoration(color: tint.withAlpha(36), borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: tint)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  if (sub.isNotEmpty) Muted(sub, size: 12.5),
                ]),
              ),
              Icon(Icons.chevron_right_rounded, color: context.c.mut),
            ]),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Attendance')), automaticallyImplyLeading: !tab),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        if (s.can('checkin'))
          card(
            Icons.groups_rounded,
            C.orange,
            context.t('Members'),
            today is Map ? context.t('Today {n} check-ins · {b} stopped', {'n': today['checkins'] ?? 0, 'b': today['blocked'] ?? 0}) : context.t('Every check-in, by day · Excel'),
            () => context.push('/o/attendance'),
          ),
        if (owner) card(Icons.badge_rounded, C.blue, context.t('Staff & trainers'), context.t('Present days, month by month · Excel'), () => context.push('/o/staff-attendance')),
        if (s.isStaffDesk) card(Icons.event_available_rounded, C.ok, context.t('My attendance'), context.t('Mark Present at the gym every day'), () => context.push('/o/my-attendance')),
      ]),
    );
  }
}

/// Check-ins of one day at the branch being looked at (every check-in, newest first).
final attendanceDayProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, day) => branchGet(ref, day.isEmpty ? '/attendance/today' : '/attendance/today?day=$day'));

class DeskAttendanceScreen extends ConsumerStatefulWidget {
  const DeskAttendanceScreen({super.key, this.tab = false});
  final bool tab;
  @override
  ConsumerState<DeskAttendanceScreen> createState() => _DeskAttendanceState();
}

class _DeskAttendanceState extends ConsumerState<DeskAttendanceScreen> {
  String day = ''; // '' = today

  String _ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(attendanceDayProvider(day));
    final s = ref.watch(sessionProvider);
    final today = _ymd(DateTime.now());
    final yesterday = _ymd(DateTime.now().subtract(const Duration(days: 1)));
    // Three boxes of the same size, numbers and labels on one line each.
    Widget stat(String n, String label, Color color) => Expanded(
          child: SizedBox(
            height: 82,
            child: Panel(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Text(n, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color)),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.c.mut, fontSize: 12)),
              ]),
            ),
          ),
        );
    final isToday = day.isEmpty || day == today;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.t('Members attendance')),
        automaticallyImplyLeading: !widget.tab,
        actions: [IconButton(tooltip: context.t('Download Excel'), icon: const Icon(Icons.download_rounded), onPressed: () => attendanceExcelSheet(context, ref, kind: 'members'))],
      ),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(attendanceDayProvider(day)),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(attendanceDayProvider(day)),
          builder: (d) {
            final events = ((d['events'] as List?) ?? const []).cast<Map>();
            // How many times each member came in this day (shown as "2×").
            final times = <String, int>{};
            for (final e in events) {
              final id = e['memberId'] as String?;
              if (id != null && e['result'] != 'BLOCKED') times[id] = (times[id] ?? 0) + 1;
            }
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              Row(children: [
                stat('${d['checkins'] ?? 0}', context.t('Check-ins'), C.ok),
                const SizedBox(width: 8),
                stat('${isToday ? d['inGymNow'] ?? 0 : times.length}', isToday ? context.t('In gym now') : context.t('Members came'), context.c.primary),
                const SizedBox(width: 8),
                stat('${d['blocked'] ?? 0}', context.t('Stopped'), C.red),
              ]),
              const SizedBox(height: 12),
              if (s.can('checkin'))
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                  onPressed: () async {
                    await context.push('/o/attendance/manual');
                    ref.invalidate(attendanceDayProvider(day));
                  },
                  icon: const Icon(Icons.edit_note_rounded),
                  label: Text(context.t('Manual entry')),
                ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  ChoiceChip(label: Text(context.t('Today')), selected: isToday, onSelected: (_) => setState(() => day = '')),
                  const SizedBox(width: 6),
                  ChoiceChip(label: Text(context.t('Yesterday')), selected: day == yesterday, onSelected: (_) => setState(() => day = yesterday)),
                  const SizedBox(width: 6),
                  ChoiceChip(
                    avatar: const Icon(Icons.calendar_month_rounded, size: 16),
                    label: Text(!isToday && day != yesterday ? fmtDate(day) : context.t('Pick date')),
                    selected: !isToday && day != yesterday,
                    onSelected: (_) async {
                      final now = DateTime.now();
                      final p = await showDatePicker(context: context, initialDate: now, firstDate: now.subtract(const Duration(days: 365)), lastDate: now);
                      if (p != null) setState(() => day = _ymd(p) == today ? '' : _ymd(p));
                    },
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              SectionTitle(isToday ? context.t('Today') : fmtDate(day), trailing: Muted(context.t('{n} check-ins', {'n': events.length}), size: 12)),
              if (events.isEmpty)
                Panel(child: Muted(isToday ? context.t('No check-ins yet today.') : context.t('No check-ins on this day.'), align: TextAlign.center))
              else
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(children: [
                    for (final e in events)
                      ListTile(
                        onTap: e['memberId'] == null ? null : () => context.push('/o/member/${e['memberId']}'),
                        leading: Avatar(name: (e['member']?['name'] as String?) ?? '', size: 38),
                        title: Text((e['member']?['name'] as String?) ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(
                          [
                            e['member']?['memberCode'],
                            fmtTime(e['scannedAt'] as String?),
                            if ((times[e['memberId']] ?? 0) > 1 && e['result'] != 'BLOCKED') context.t('{n} times today', {'n': times[e['memberId']]}),
                            if (e['result'] == 'BLOCKED') e['reason'],
                          ].where((x) => x != null).join(' · '),
                          style: TextStyle(color: context.c.mut, fontSize: 12),
                        ),
                        trailing: _InOut(blocked: e['result'] == 'BLOCKED'),
                      ),
                  ]),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Excel (CSV, opens in Excel / Google Sheets) of check-ins: staff get members; the owner members or staff.
Future<void> attendanceExcelSheet(BuildContext context, WidgetRef ref, {String? kind}) async {
  final owner = kind == null && ref.read(sessionProvider).myGym?['role'] == 'OWNER'; // choose only when not fixed
  String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final now = DateTime.now();
  var kindNow = kind ?? 'members';
  var range = 7;
  DateTimeRange? custom;
  var busy = false;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(ctx.t('Download Excel'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            Muted(ctx.t('Opens in Excel or Google Sheets.'), size: 12.5),
            const SizedBox(height: 12),
            if (owner)
              Wrap(spacing: 8, children: [
                ChoiceChip(label: Text(ctx.t('Members')), selected: kindNow == 'members', onSelected: (_) => setState(() => kindNow = 'members')),
                ChoiceChip(label: Text(ctx.t('Staff & trainers')), selected: kindNow == 'staff', onSelected: (_) => setState(() => kindNow = 'staff')),
              ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final (n, l) in [(1, ctx.t('Today')), (7, ctx.t('7 days')), (30, ctx.t('This month'))])
                ChoiceChip(label: Text(l), selected: custom == null && range == n, onSelected: (_) => setState(() {
                      range = n;
                      custom = null;
                    })),
              ChoiceChip(
                avatar: const Icon(Icons.date_range_rounded, size: 16),
                label: Text(custom == null ? ctx.t('Pick dates') : '${fmtDate(ymd(custom!.start))} – ${fmtDate(ymd(custom!.end))}'),
                selected: custom != null,
                onSelected: (_) async {
                  final r = await showDateRangePicker(context: ctx, firstDate: now.subtract(const Duration(days: 365)), lastDate: now);
                  if (r != null) setState(() => custom = r);
                },
              ),
            ]),
            Muted(ctx.t('Up to 31 days at a time.'), size: 11.5),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () async {
                      setState(() => busy = true);
                      final from = custom?.start ?? (range == 30 ? DateTime(now.year, now.month, 1) : now.subtract(Duration(days: range - 1)));
                      final to = custom?.end ?? now;
                      try {
                        final b = await Api.instance.bytes('/api/v1/attendance/export?kind=$kindNow&from=${ymd(from)}&to=${ymd(to)}');
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        if (context.mounted) await saveAndOffer(context, '${kindNow == 'staff' ? 'staff' : 'members'}-attendance-${ymd(from)}-to-${ymd(to)}.csv', b, 'text/csv');
                      } catch (e) {
                        if (ctx.mounted) toastError(ctx, e);
                        setState(() => busy = false);
                      }
                    },
              icon: const Icon(Icons.table_view_rounded),
              label: Text(busy ? ctx.t('Please wait…') : ctx.t('Download')),
            ),
          ]),
        ),
      ),
    ),
  );
}

String fmtTime(String? iso) {
  final d = DateTime.tryParse(iso ?? '')?.toLocal();
  if (d == null) return '';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'AM' : 'PM'}';
}

class _InOut extends StatelessWidget {
  const _InOut({required this.blocked});
  final bool blocked;
  @override
  Widget build(BuildContext context) {
    final c = blocked ? C.red : C.ok;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: c.withAlpha(36), borderRadius: BorderRadius.circular(99)),
      child: Text(blocked ? context.t('STOPPED') : 'IN', style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

/// Green "let them in" / red "stop" screen after a desk check-in.
Future<void> showCheckinResult(BuildContext context, Map r) async {
  final ok = r['result'] == 'ALLOWED';
  final m = (r['member'] as Map?) ?? const {};
  final gate = r['gate'];
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(shape: BoxShape.circle, color: (ok ? C.ok : C.red).withAlpha(40)),
            child: Icon(ok ? Icons.check_rounded : Icons.block_rounded, size: 52, color: ok ? C.ok : C.red),
          ),
          const SizedBox(height: 10),
          Text(ok ? ctx.t('Let them in') : ctx.t('Do not let them in'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text([m['name'], m['memberCode']].where((x) => x != null).join(' · '), style: const TextStyle(fontWeight: FontWeight.w700)),
          if (!ok && r['reason'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Muted('${r['reason']}', align: TextAlign.center)),
          if (r['duplicate'] == true) Padding(padding: const EdgeInsets.only(top: 4), child: Muted(ctx.t('Already checked in today'), size: 12)),
          if (gate == 'opened') Padding(padding: const EdgeInsets.only(top: 8), child: Text(ctx.t('Gate opened'), style: const TextStyle(color: C.ok, fontWeight: FontWeight.w800))),
          if (gate == 'offline') Padding(padding: const EdgeInsets.only(top: 8), child: Text(ctx.t('Gate is offline — open it by hand'), style: const TextStyle(color: C.warn, fontWeight: FontWeight.w800))),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('Next scan')))),
        ]),
      ),
    ),
  );
}

class DeskScanScreen extends ConsumerStatefulWidget {
  const DeskScanScreen({super.key});
  @override
  ConsumerState<DeskScanScreen> createState() => _DeskScanState();
}

class _DeskScanState extends ConsumerState<DeskScanScreen> {
  bool busy = false;
  bool torch = false;
  String? error;

  Future<void> onCode(String code) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await Api.instance.post('/attendance/scan', {'token': code.trim()});
      if (mounted) await showCheckinResult(context, r as Map);
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          title: Text(context.t('Scan member QR')),
          actions: [IconButton(onPressed: () => setState(() => torch = !torch), icon: Icon(torch ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded))],
        ),
        body: Stack(children: [
          Positioned.fill(child: QrCamera(onCode: onCode, onError: (c, d) => setState(() => error = d ?? c), torch: torch, paused: busy)),
          Positioned(
            left: 20,
            right: 20,
            bottom: 28,
            child: Column(children: [
              Text(context.t('Scan the QR on the member’s phone'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 4),
              Text(context.t('Member app → QR tab'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
              if (error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(error!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12))),
            ]),
          ),
          if (busy) const Center(child: CircularProgressIndicator(color: Colors.white)),
        ]),
      );
}

class ManualCheckinScreen extends ConsumerStatefulWidget {
  const ManualCheckinScreen({super.key});
  @override
  ConsumerState<ManualCheckinScreen> createState() => _ManualCheckinState();
}

class _ManualCheckinState extends ConsumerState<ManualCheckinScreen> {
  String q = '';
  String? busyId;

  Future<void> checkIn(Map m) async {
    setState(() => busyId = m['id'] as String);
    try {
      final r = await Api.instance.post('/attendance/manual', {'memberId': m['id']});
      if (mounted) await showCheckinResult(context, {...(r as Map), 'member': r['member'] ?? {'name': m['name'], 'memberCode': m['memberCode']}});
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(ownerMembersProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Manual check-in'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(ownerMembersProvider),
        builder: (d) {
          final needle = q.trim().toLowerCase();
          final rows = ((d['rows'] as List?) ?? const []).cast<Map>().where((m) => m['gone'] != true && (needle.isEmpty || '${m['name']} ${m['phone']} ${m['memberCode']}'.toLowerCase().contains(needle))).take(60).toList();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Name, member ID or mobile')),
              onChanged: (t) => setState(() => q = t),
            ),
            const SizedBox(height: 8),
            Muted(context.t('Phone left at home? Find the member and check them in. A second check-in within 2 hours is not counted.'), size: 12),
            const SizedBox(height: 10),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final m in rows)
                  ListTile(
                    leading: Avatar(name: m['name'] as String, url: m['photoUrl'] as String?, size: 40),
                    title: Text(m['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text([m['memberCode'], m['planName']].where((x) => x != null).join(' · '), style: TextStyle(color: context.c.mut, fontSize: 12)),
                    trailing: busyId == m['id']
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 14)),
                            onPressed: busyId == null ? () => checkIn(m) : null,
                            child: Text(context.t('Check in')),
                          ),
                  ),
              ]),
            ),
          ]);
        },
      ),
    );
  }
}

// ============================================================ my attendance (front desk / trainer)

class MyAttendanceScreen extends ConsumerStatefulWidget {
  const MyAttendanceScreen({super.key});
  @override
  ConsumerState<MyAttendanceScreen> createState() => _MyAttendanceState();
}

class _MyAttendanceState extends ConsumerState<MyAttendanceScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  Map? data;
  bool loading = true;
  bool marking = false;
  String? error;

  String get monthKey => '${month.year}-${month.month.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    setState(() => loading = true);
    try {
      final r = await Api.instance.get('/me/staff-attendance?month=$monthKey');
      if (mounted) setState(() => data = r as Map);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> mark() async {
    setState(() {
      marking = true;
      error = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw ApiException(0, context.t('Turn on location (GPS) to mark attendance'));
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw ApiException(0, context.t('Allow location for GymMantra to mark attendance'));
      }
      final p = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 12)));
      await Api.instance.post('/me/staff-attendance', {'lat': p.latitude, 'lng': p.longitude, 'accuracy': p.accuracy, 'mocked': p.isMocked});
      if (mounted) toast(context, context.t('Present marked for today'));
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => marking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final present = ((data?['present'] as List?) ?? const []).cast<String>().toSet();
    final absent = ((data?['absent'] as List?) ?? const []).cast<String>().toSet();
    final today = (data?['today'] as String?) ?? ymd(DateTime.now());
    final isThisMonth = today.startsWith(monthKey);
    final marked = data?['markedToday'] == true;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('My attendance'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Row(children: [
          IconButton(onPressed: () => setState(() {
                month = DateTime(month.year, month.month - 1);
                load();
              }), icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(child: Center(child: Text(monthName(context, month), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))),
          IconButton(
            onPressed: isThisMonth
                ? null
                : () => setState(() {
                      month = DateTime(month.year, month.month + 1);
                      load();
                    }),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ]),
        Center(child: Muted(context.t('{p} present', {'p': present.length}), size: 12.5)),
        const SizedBox(height: 10),
        MonthGrid(month: month, present: present, absent: absent, today: today),
        const SizedBox(height: 14),
        if (data?['branch'] != null) Muted(context.t('Attendance counts only inside {b} (about 20 m).', {'b': data!['branch']['name']}), size: 12.5, align: TextAlign.center),
        ErrorText(error),
        const SizedBox(height: 12),
        if (isThisMonth)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: marked ? C.ok : null),
            onPressed: marked || marking || loading ? null : mark,
            icon: marking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Icon(Icons.check_circle_rounded),
            label: Text(marked ? context.t('Present today ✓') : context.t('Mark today: Present')),
          ),
      ]),
    );
  }
}

String monthName(BuildContext context, DateTime m) {
  const names = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  return '${context.t(names[m.month - 1])} ${m.year}';
}

/// Calendar of one month: green = present, red = absent, orange ring = today.
class MonthGrid extends StatelessWidget {
  const MonthGrid({super.key, required this.month, required this.present, this.absent = const {}, required this.today, this.onTap});
  final DateTime month;
  final Set<String> present;
  final Set<String> absent;
  final String today;
  final void Function(String day)? onTap;
  @override
  Widget build(BuildContext context) {
    final first = DateTime(month.year, month.month, 1);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = first.weekday - 1; // Monday first
    final cells = <Widget>[
      for (final d in ['M', 'T', 'W', 'T', 'F', 'S', 'S']) Center(child: Text(d, style: TextStyle(color: context.c.mut, fontWeight: FontWeight.w700, fontSize: 11))),
      for (var i = 0; i < lead; i++) const SizedBox(),
    ];
    for (var d = 1; d <= days; d++) {
      final key = ymd(DateTime(month.year, month.month, d));
      final p = present.contains(key);
      final a = absent.contains(key);
      final isToday = key == today;
      final future = key.compareTo(today) > 0;
      final bg = p ? C.ok.withAlpha(40) : a ? C.red.withAlpha(36) : context.c.surf;
      final fg = p ? C.ok : a ? C.red : future ? context.c.mut : context.c.fg;
      cells.add(InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap == null || future ? null : () => onTap!(key),
        child: Container(
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: isToday ? context.c.primary : context.c.line, width: isToday ? 2 : 1)),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('$d', style: TextStyle(fontWeight: FontWeight.w700, color: fg, fontSize: 13)),
            if (p || a) Text(p ? 'P' : 'A', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, color: fg)),
          ]),
        ),
      ));
    }
    return GridView.count(
      crossAxisCount: 7,
      mainAxisSpacing: 5,
      crossAxisSpacing: 5,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 0.95,
      children: cells,
    );
  }
}

// ============================================================ staff attendance (owner)

class StaffAttendanceScreen extends ConsumerStatefulWidget {
  const StaffAttendanceScreen({super.key});
  @override
  ConsumerState<StaffAttendanceScreen> createState() => _StaffAttendanceState();
}

class _StaffAttendanceState extends ConsumerState<StaffAttendanceScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  Map? data;
  String? error;
  String get monthKey => '${month.year}-${month.month.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final r = await Api.instance.get('/staff-attendance?month=$monthKey');
      if (mounted) setState(() => data = r as Map);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void share() {
    final rows = ((data?['rows'] as List?) ?? const []).cast<Map>();
    final lines = ['Staff attendance · ${monthName(context, month)}', ''];
    for (final r in rows) {
      final p = (r['present'] as List).cast<String>();
      lines.add('${r['name']} (${r['role'] == 'TRAINER' ? 'Trainer' : 'Front desk'}): ${p.length} days present');
      lines.add('  ${p.map((d) => int.parse(d.substring(8))).join(', ')}');
    }
    Share.share(lines.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final rows = ((data?['rows'] as List?) ?? const []).cast<Map>();
    final soFar = (data?['daysSoFar'] as int?) ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Staff attendance')), actions: [
        IconButton(tooltip: context.t('Download Excel'), onPressed: () => attendanceExcelSheet(context, ref, kind: 'staff'), icon: const Icon(Icons.download_rounded)),
        IconButton(onPressed: data == null ? null : share, icon: const Icon(Icons.share_rounded)),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Row(children: [
          IconButton(onPressed: () => setState(() {
                month = DateTime(month.year, month.month - 1);
                data = null;
                load();
              }), icon: const Icon(Icons.chevron_left_rounded)),
          Expanded(child: Center(child: Text(monthName(context, month), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))),
          IconButton(
            onPressed: DateTime(month.year, month.month + 1).isAfter(DateTime.now())
                ? null
                : () => setState(() {
                      month = DateTime(month.year, month.month + 1);
                      data = null;
                      load();
                    }),
            icon: const Icon(Icons.chevron_right_rounded),
          ),
        ]),
        ErrorText(error),
        if (data == null && error == null) const ListSkeleton(),
        if (data != null && rows.isEmpty) Panel(child: Muted(context.t('No front desk or trainers in this branch.'), align: TextAlign.center)),
        if (rows.isNotEmpty)
          Panel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(children: [
              for (final r in rows)
                ListTile(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _StaffMonthScreen(person: r, month: month, onChanged: load))),
                  leading: Avatar(name: r['name'] as String, size: 40),
                  title: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                    '${r['role'] == 'TRAINER' ? context.t('Trainer') : context.t('Front desk')} · ${context.t('{p} of {n} days present', {'p': (r['present'] as List).length, 'n': soFar})}',
                    style: TextStyle(color: context.c.mut, fontSize: 12),
                  ),
                  trailing: Icon(Icons.chevron_right_rounded, color: context.c.mut),
                ),
            ]),
          ),
        const SizedBox(height: 8),
        Muted(context.t('Tap a person to see their calendar. You can correct a day (with a reason).'), size: 12),
      ]),
    );
  }
}

class _StaffMonthScreen extends StatefulWidget {
  const _StaffMonthScreen({required this.person, required this.month, required this.onChanged});
  final Map person;
  final DateTime month;
  final VoidCallback onChanged;
  @override
  State<_StaffMonthScreen> createState() => _StaffMonthState();
}

class _StaffMonthState extends State<_StaffMonthScreen> {
  late Set<String> present = (widget.person['present'] as List).cast<String>().toSet();
  Set<String> absent = {};

  Future<void> fix(String day) async {
    final note = TextEditingController();
    final was = present.contains(day);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Mark {d} as {s}?', {'d': fmtDate(day), 's': was ? ctx.t('Absent') : ctx.t('Present')})),
        content: TextField(controller: note, decoration: InputDecoration(labelText: ctx.t('Reason'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Save'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.put('/staff-attendance/${widget.person['id']}/$day', {'present': !was, 'note': note.text});
      setState(() {
        if (was) {
          present.remove(day);
          absent.add(day);
        } else {
          present.add(day);
          absent.remove(day);
        }
      });
      widget.onChanged();
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.person['name'] as String)),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          Center(child: Text(monthName(context, widget.month), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
          Center(child: Muted(context.t('{p} present', {'p': present.length}), size: 12.5)),
          const SizedBox(height: 10),
          MonthGrid(month: widget.month, present: present, absent: absent, today: ymd(DateTime.now()), onTap: fix),
          const SizedBox(height: 10),
          Muted(context.t('Tap a day to correct it.'), size: 12, align: TextAlign.center),
        ]),
      );
}

// ============================================================ import members (CSV)

class ImportMembersScreen extends ConsumerStatefulWidget {
  const ImportMembersScreen({super.key});
  @override
  ConsumerState<ImportMembersScreen> createState() => _ImportState();
}

class _ImportState extends ConsumerState<ImportMembersScreen> {
  String? fileName;
  List<Map<String, String>> rows = [];
  List<String> problems = [];
  Map? result;
  bool busy = false;

  /// Reads CSV text: first row = headings (Name, Mobile/Phone, Email, Joined). Commas inside quotes are kept.
  static List<List<String>> parseCsv(String text) {
    final out = <List<String>>[];
    var row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quoted) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            cell.write('"');
            i++;
          } else {
            quoted = false;
          }
        } else {
          cell.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == ',' || ch == ';' || ch == '\t') {
        row.add(cell.toString().trim());
        cell.clear();
      } else if (ch == '\n' || ch == '\r') {
        if (ch == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString().trim());
        cell.clear();
        if (row.any((c) => c.isNotEmpty)) out.add(row);
        row = <String>[];
      } else {
        cell.write(ch);
      }
    }
    row.add(cell.toString().trim());
    if (row.any((c) => c.isNotEmpty)) out.add(row);
    return out;
  }

  Future<void> pick() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['csv', 'txt'], withData: true);
    final f = r?.files.firstOrNull;
    if (f == null || f.bytes == null) return;
    final text = utf8.decode(f.bytes!, allowMalformed: true).replaceAll('﻿', '');
    final table = parseCsv(text);
    if (table.length < 2) {
      if (mounted) toast(context, context.t('The file has no rows'));
      return;
    }
    final head = table.first.map((h) => h.toLowerCase()).toList();
    int col(List<String> names) => head.indexWhere((h) => names.any((n) => h.contains(n)));
    final ni = col(['name']), pi = col(['mobile', 'phone', 'number']), ei = col(['email', 'mail']), ji = col(['join', 'date']);
    if (ni < 0 || pi < 0) {
      if (mounted) toast(context, context.t('The first row must have "Name" and "Mobile" headings'));
      return;
    }
    final list = <Map<String, String>>[];
    final bad = <String>[];
    for (var i = 1; i < table.length; i++) {
      final r = table[i];
      String at(int k) => k >= 0 && k < r.length ? r[k] : '';
      final phone = at(pi).replaceAll(RegExp(r'\D'), '');
      final p10 = phone.length > 10 ? phone.substring(phone.length - 10) : phone;
      if (at(ni).length < 2 || p10.length != 10) {
        bad.add('${context.t('Row {n}', {'n': i + 1})} · ${at(ni).isEmpty ? '-' : at(ni)} · ${context.t('name or mobile is not right')}');
        continue;
      }
      list.add({'name': at(ni), 'phone': p10, if (at(ei).contains('@')) 'email': at(ei), if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(at(ji))) 'joinedOn': at(ji)});
    }
    setState(() {
      fileName = f.name;
      rows = list;
      problems = bad;
      result = null;
    });
  }

  Future<void> upload() async {
    setState(() => busy = true);
    try {
      final r = await Api.instance.post('/members/import', {'rows': rows, if (Api.instance.branchId != null) 'branchId': Api.instance.branchId});
      ref.invalidate(ownerMembersProvider);
      setState(() => result = r as Map);
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = result;
    final added = res == null ? 0 : (((res['results'] as List?) ?? const []).where((x) => x['ok'] == true).length);
    final failed = res == null ? <Map>[] : ((res['results'] as List?) ?? const []).cast<Map>().where((x) => x['ok'] != true).toList();
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Import members'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        if (res != null) ...[
          Panel(
            child: Column(children: [
              const Icon(Icons.check_circle_rounded, color: C.ok, size: 56),
              const SizedBox(height: 6),
              Text(context.t('{n} members added', {'n': added}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
              const SizedBox(height: 4),
              Muted(context.t('They are in "No plan". Start their membership from Members, or send them the gym code so they join the app.'), align: TextAlign.center),
            ]),
          ),
          for (final f in failed) Padding(padding: const EdgeInsets.only(top: 6), child: Muted('${context.t('Row {n}', {'n': f['row']})}: ${f['error']}', size: 12)),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => context.go('/o/members'), child: Text(context.t('See members'))),
        ] else ...[
          Panel(
            child: Column(children: [
              const Icon(Icons.upload_file_rounded, size: 52, color: C.orange),
              const SizedBox(height: 8),
              Text(context.t('Bring your old members'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 19)),
              const SizedBox(height: 4),
              Muted(context.t('Choose a CSV file. First row: Name, Mobile, Email (optional), Joined (optional, YYYY-MM-DD). In Excel: File → Save as → CSV.'), align: TextAlign.center),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: busy ? null : pick, icon: const Icon(Icons.attach_file_rounded), label: Text(context.t('Choose file')))),
            ]),
          ),
          if (fileName != null) ...[
            const SizedBox(height: 12),
            Panel(
              child: Row(children: [
                const IconTile(Icons.description_rounded, size: 38),
                const SizedBox(width: 12),
                Expanded(child: Text(fileName!, style: const TextStyle(fontWeight: FontWeight.w700))),
                Text('${rows.length} ✓', style: const TextStyle(color: C.ok, fontWeight: FontWeight.w800)),
                if (problems.isNotEmpty) Text('  ${problems.length} ✕', style: const TextStyle(color: C.red, fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(height: 8),
            for (final r in rows.take(5)) Muted('✓ ${r['name']} · ${r['phone']}', size: 12.5),
            if (rows.length > 5) Muted('… +${rows.length - 5}', size: 12.5),
            for (final p in problems.take(10)) Text('✕ $p', style: const TextStyle(color: C.red, fontSize: 12.5)),
            const SizedBox(height: 14),
            FilledButton(onPressed: busy || rows.isEmpty ? null : upload, child: Text(context.t('Add {n} members', {'n': rows.length}))),
          ],
        ],
        if (busy) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      ]),
    );
  }
}

// ============================================================ gate

class GateScreen extends ConsumerStatefulWidget {
  const GateScreen({super.key});
  @override
  ConsumerState<GateScreen> createState() => _GateState();
}

class _GateState extends ConsumerState<GateScreen> {
  String type = 'webhook';
  final name = TextEditingController(text: 'Main gate');
  final url = TextEditingController();
  final server = TextEditingController();
  final key = TextEditingController();
  final deviceId = TextEditingController();
  int seconds = 5;
  bool loaded = false;
  bool busy = false;

  void fill(Map d) {
    if (loaded) return;
    loaded = true;
    if (d['set'] != true) return;
    type = (d['type'] as String?) ?? 'webhook';
    name.text = (d['name'] as String?) ?? 'Main gate';
    url.text = (d['url'] as String?) ?? '';
    server.text = (d['shellyServer'] as String?) ?? '';
    deviceId.text = (d['shellyId'] as String?) ?? '';
    seconds = (d['seconds'] as int?) ?? 5;
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await Api.instance.put('/gym/gate', {
        'type': type,
        'name': name.text.trim(),
        'seconds': seconds,
        if (type == 'webhook' && !url.text.contains('•••')) 'url': url.text.trim(),
        if (type == 'shelly') 'shellyServer': server.text.trim(),
        if (type == 'shelly' && key.text.trim().isNotEmpty) 'shellyKey': key.text.trim(),
        if (type == 'shelly') 'shellyId': deviceId.text.trim(),
      });
      ref.invalidate(gateProvider);
      if (mounted) toast(context, context.t('Gate saved'));
    } catch (e) {
      if (mounted) toastError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> openNow() async {
    try {
      final r = await Api.instance.post('/gym/gate/open', {});
      if (mounted) toast(context, (r as Map)['gate'] == 'opened' ? context.t('Gate opened') : context.t('Gate is offline — open it by hand'));
      ref.invalidate(gateProvider);
    } catch (e) {
      if (mounted) toastError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(gateProvider);
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gate'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(gateProvider),
        builder: (d) {
          fill(d as Map);
          final set = d['set'] == true;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            if (set)
              Panel(
                child: Row(children: [
                  IconTile(Icons.door_sliding_rounded, color: d['lastError'] == null ? C.ok : C.red),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((d['name'] as String?) ?? '', style: const TextStyle(fontWeight: FontWeight.w800)),
                      Muted(d['lastError'] == null ? context.t('Opens after every allowed check-in') : '${context.t('Last problem')}: ${d['lastError']}', size: 12),
                    ]),
                  ),
                  FilledButton(onPressed: openNow, child: Text(context.t('Open'))),
                ]),
              ),
            const SizedBox(height: 12),
            Panel(
              child: Muted(
                context.t('The gate needs a small WiFi relay on its electric lock or turnstile (an electrician can fit it). After a member checks in with the QR, GymMantra tells the relay to open. Each branch has its own gate.'),
                size: 12.5,
              ),
            ),
            if (owner) ...[
              const SizedBox(height: 14),
              SectionTitle(context.t('Device')),
              Wrap(spacing: 8, children: [
                for (final (k, l) in [('webhook', context.t('Relay with a web link')), ('shelly', 'Shelly Cloud')])
                  ChoiceChip(
                    label: Text(l),
                    selected: type == k,
                    showCheckmark: false,
                    selectedColor: context.c.primary,
                    labelStyle: TextStyle(color: type == k ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                    onSelected: (_) => setState(() => type = k),
                  ),
              ]),
              const SizedBox(height: 12),
              TextField(controller: name, decoration: InputDecoration(labelText: context.t('Gate name'))),
              const SizedBox(height: 12),
              if (type == 'webhook')
                TextField(controller: url, keyboardType: TextInputType.url, decoration: InputDecoration(labelText: context.t('Open link from the device app'), hintText: 'https://…')),
              if (type == 'shelly') ...[
                TextField(controller: server, keyboardType: TextInputType.url, decoration: InputDecoration(labelText: context.t('Shelly server'), hintText: 'https://shelly-xx-eu.shelly.cloud')),
                const SizedBox(height: 12),
                TextField(controller: key, decoration: InputDecoration(labelText: context.t('Auth key'), hintText: set ? context.t('Saved — type only to change') : null)),
                const SizedBox(height: 12),
                TextField(controller: deviceId, decoration: InputDecoration(labelText: context.t('Device ID'))),
                const SizedBox(height: 6),
                Muted(context.t('Shelly app → User settings → Authorization cloud key (server + key). Device ID: device → Settings → Device information.'), size: 12),
              ],
              const SizedBox(height: 12),
              Text(context.t('Keep open for'), style: TextStyle(color: context.c.mut, fontWeight: FontWeight.w600, fontSize: 13)),
              Wrap(spacing: 8, children: [
                for (final n in [3, 5, 8, 10])
                  ChoiceChip(
                    label: Text('$n s'),
                    selected: seconds == n,
                    showCheckmark: false,
                    selectedColor: context.c.primary,
                    labelStyle: TextStyle(color: seconds == n ? Colors.white : context.c.fg, fontWeight: FontWeight.w700),
                    onSelected: (_) => setState(() => seconds = n),
                  ),
              ]),
              const SizedBox(height: 16),
              FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save gate'))),
              if (set) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () async {
                    await Api.instance.delete('/gym/gate');
                    ref.invalidate(gateProvider);
                    loaded = false;
                  },
                  child: Text(context.t('Remove gate'), style: const TextStyle(color: C.red)),
                ),
              ],
            ],
          ]);
        },
      ),
    );
  }
}

// ============================================================ transfer gym (owner)

class TransferGymScreen extends ConsumerStatefulWidget {
  const TransferGymScreen({super.key});
  @override
  ConsumerState<TransferGymScreen> createState() => _TransferGymState();
}

class _TransferGymState extends ConsumerState<TransferGymScreen> {
  final phone = TextEditingController();
  Map? found;
  String oldOwner = 'remove';
  bool busy = false;
  String? error;

  Future<void> lookup() async {
    final ph = phone.text.replaceAll(RegExp(r'\D'), '');
    if (ph.length < 10) return;
    setState(() {
      error = null;
      found = null;
    });
    try {
      final r = await Api.instance.get('/transfer-owner/lookup?phone=$ph');
      setState(() => found = r as Map);
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  Future<void> transfer() async {
    final gym = ref.read(sessionProvider).myGym;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.t('Give {gym} to {name}?', {'gym': gym?['name'] ?? '', 'name': found?['name'] ?? ''})),
        content: Text(ctx.t('Members, plans, money and history stay the same. Only the owner changes. You cannot undo this yourself.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ctx.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ctx.t('Transfer'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => busy = true);
    try {
      await Api.instance.post('/gym/transfer', {'phone': phone.text.replaceAll(RegExp(r'\D'), ''), 'oldOwner': oldOwner});
      if (!mounted) return;
      toast(context, context.t('Gym transferred'));
      await ref.read(sessionProvider).refreshUser();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(context.t('Transfer gym'))),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          Panel(child: Muted(context.t('Give this gym to a new owner. They need a GymMantra account (they can sign up as "Gym owner" first).'), size: 12.5)),
          const SizedBox(height: 14),
          PhoneField(label: context.t('New owner’s mobile *'), controller: phone, onChanged: (_) => lookup()),
          if (found != null)
            Panel(
              child: Row(children: [
                Avatar(name: found!['name'] as String, size: 40),
                const SizedBox(width: 12),
                Expanded(child: Text(found!['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800))),
                Text(found!['trainer'] == true ? context.t('Trainer — cannot own') : context.t('Found ✓'), style: TextStyle(color: found!['trainer'] == true ? C.red : C.ok, fontWeight: FontWeight.w700)),
              ]),
            ),
          const SizedBox(height: 14),
          SectionTitle(context.t('And you?')),
          RadioListTile<String>(value: 'remove', groupValue: oldOwner, onChanged: (v) => setState(() => oldOwner = v!), title: Text(context.t('Leave the gym'))),
          RadioListTile<String>(value: 'frontdesk', groupValue: oldOwner, onChanged: (v) => setState(() => oldOwner = v!), title: Text(context.t('Stay as front desk'))),
          ErrorText(error),
          const SizedBox(height: 12),
          FilledButton(onPressed: busy || found == null || found!['trainer'] == true ? null : transfer, child: Text(context.t('Transfer gym'))),
        ]),
      );
}

// ============================================================ staff account with no gym

class StaffNoneScreen extends ConsumerWidget {
  const StaffNoneScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: C.warn.withAlpha(40), shape: BoxShape.circle),
              child: const Icon(Icons.badge_rounded, size: 46, color: C.warn),
            ),
            const SizedBox(height: 16),
            Text(context.t('You are not staff at any gym yet'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Muted(context.t('Ask the gym owner to add you: More → Staff → Add staff, with your mobile number.'), align: TextAlign.center),
            const SizedBox(height: 22),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => s.refreshUser(), icon: const Icon(Icons.refresh_rounded), label: Text(context.t('Check again')))),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => s.logout(), child: Text(context.t('Log out')))),
          ]),
        ),
      ),
    );
  }
}
