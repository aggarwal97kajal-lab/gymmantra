import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import 'package:go_router/go_router.dart';
import '../i18n.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show LabeledField, LangSwitch, PhoneField;
import 'extras.dart' show TestimonialsSlider;
import 'banner.dart' show LogoPickerRow, pickLogo;
import 'billing.dart' show Address, AddressFields;

/// "Aap kaun ho?" — Member, Gym owner or Trainer.
class RolePickScreen extends ConsumerStatefulWidget {
  const RolePickScreen({super.key, this.beforeLogin = false});

  /// Shown first, before log-in: the choice is kept and applied after log-in / sign-up.
  final bool beforeLogin;
  @override
  ConsumerState<RolePickScreen> createState() => _RolePickState();
}

class _RolePickState extends ConsumerState<RolePickScreen> {
  String role = Prefs.getString('pendingRole') ?? 'MEMBER';
  bool busy = false;
  String? error;

  Future<void> go() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Prefs.setString('pendingRole', role);
      if (widget.beforeLogin) {
        if (mounted) context.go('/login');
        return;
      }
      await ref.read(sessionProvider).chooseRole(role);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget card(String value, IconData icon, String title, String sub) {
      final on = role == value;
      final p = context.c;
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Material(
          color: p.surf,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: on ? p.primary : p.line, width: on ? 2 : 1)),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => setState(() => role = value),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                IconTile(icon, size: 50),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Muted(sub, size: 12.5),
                  ]),
                ),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: on ? p.primary : Colors.transparent, border: Border.all(color: on ? p.primary : p.line, width: 2)),
                  child: on ? const Icon(Icons.check_rounded, size: 15, color: Colors.white) : null,
                ),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
          const Row(children: [Logo(size: 38), SizedBox(width: 8), Wordmark(size: 21), Spacer(), LangSwitch()]),
          const SizedBox(height: 30),
          Text(context.t('Who are you? 👋'), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          const SizedBox(height: 4),
          Muted(context.t('One app, made for your work'), size: 14.5),
          const SizedBox(height: 22),
          card('MEMBER', Icons.person_rounded, context.t('Member'), context.t('Membership, check-in QR, PT and diet plan')),
          card('OWNER', Icons.storefront_rounded, context.t('Gym owner'), context.t('Members, money, trainers, offers — all in one place')),
          card('TRAINER', Icons.sports_rounded, context.t('Trainer'), context.t('Your PT clients, sessions, diet and workouts')),
          card('STAFF', Icons.badge_rounded, context.t('Gym staff'), context.t('Front desk: members, payments, check-in, attendance')),
          ErrorText(error),
          const SizedBox(height: 12),
          FilledButton(onPressed: busy ? null : go, child: Text(context.t('Continue'))),
          const SizedBox(height: 10),
          if (!widget.beforeLogin) Center(child: TextButton(onPressed: () => ref.read(sessionProvider).logout(), child: Text(context.t('Log out')))),
        ]),
      ),
    );
  }
}

class _BackToRole extends ConsumerWidget {
  const _BackToRole();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Material(
        color: context.c.surf,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.c.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () async {
            final s = ref.read(sessionProvider);
            try {
              await s.api.patch('/me/profile', {'appRole': 'NONE'});
            } catch (_) {}
            s.patchUser({'appRole': null});
          },
          child: const SizedBox(width: 42, height: 42, child: Icon(Icons.chevron_left_rounded)),
        ),
      );
}

/// Owner: register the gym (it starts on the free trial).
class RegisterGymScreen extends ConsumerStatefulWidget {
  const RegisterGymScreen({super.key});
  @override
  ConsumerState<RegisterGymScreen> createState() => _RegisterGymState();
}

class _RegisterGymState extends ConsumerState<RegisterGymScreen> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final place = Address();
  Uint8List? logo;
  double? up; // upload meter while the gym and its logo are sent
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    phone.text = ((ref.read(sessionProvider).user?['phone'] as String?) ?? '').replaceFirst('+91', '');
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final body = {
        'name': name.text.trim(),
        'phone': phone.text.trim(),
        ...place.toJson(),
        if (logo != null) 'logo': {'mime': 'image/jpeg', 'base64': base64Encode(logo!)},
      };
      if (logo != null) {
        setState(() => up = 0);
        await Api.instance.postProgress('/gyms', body, (sent, total) {
          if (mounted && total > 0) setState(() => up = (sent / total).clamp(0.0, 1.0).toDouble());
        });
      } else {
        await Api.instance.post('/gyms', body);
      }
      await ref.read(sessionProvider).refreshUser();
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
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
          const Row(children: [_BackToRole()]),
          const SizedBox(height: 20),
          Align(alignment: Alignment.centerLeft, child: _Chip(Icons.storefront_rounded, context.t('Gym owner'))),
          const SizedBox(height: 10),
          Text(context.t('Register your gym'), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          const SizedBox(height: 4),
          Muted(context.t('First 3 months free. No card needed.'), size: 14.5),
          const SizedBox(height: 22),
          LogoPickerRow(
            name: name.text.isEmpty ? 'G' : name.text,
            title: context.t('Gym logo'),
            hint: context.t('Optional · shown to your members, trainers and staff'),
            local: logo,
            progress: up,
            onPick: () async {
              final b = await pickLogo(context);
              if (b != null) setState(() => logo = b);
            },
            onRemove: () => setState(() => logo = null),
          ),
          LabeledField(label: context.t('Gym name'), controller: name, icon: Icons.storefront_rounded, caps: TextCapitalization.words),
          PhoneField(label: context.t('Gym phone number'), controller: phone),
          AddressFields(value: place),
          const SizedBox(height: 4),
          ErrorText(error),
          const SizedBox(height: 10),
          FilledButton(onPressed: busy ? null : save, child: Text(busy ? context.t('Please wait…') : context.t('Register gym'))),
        ]),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: context.c.primary.withAlpha(36), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: context.c.primary),
          const SizedBox(width: 6),
          Text(text, style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      );
}

/// Trainer: join a gym with its code. The owner must approve.
class TrainerJoinScreen extends ConsumerStatefulWidget {
  const TrainerJoinScreen({super.key});
  @override
  ConsumerState<TrainerJoinScreen> createState() => _TrainerJoinState();
}

class _TrainerJoinState extends ConsumerState<TrainerJoinScreen> {
  final code = TextEditingController();
  final years = TextEditingController();
  final phone = TextEditingController();
  Map? gym;
  final specs = <String>{};
  bool busy = false;
  String? error;
  static const specialities = ['Weight loss', 'Strength', 'Bodybuilding', 'Yoga', 'CrossFit', 'Cardio', 'Zumba', 'Functional', 'Powerlifting', 'Calisthenics', 'Rehab', 'Nutrition'];

  Future<void> run(Future<void> Function() fn) async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
          Row(children: [
            Material(
              color: context.c.surf,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.c.line)),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => context.canPop() ? context.pop() : context.go('/t/home'),
                child: const SizedBox(width: 42, height: 42, child: Icon(Icons.chevron_left_rounded)),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Align(alignment: Alignment.centerLeft, child: _Chip(Icons.sports_rounded, context.t('Trainer'))),
          const SizedBox(height: 10),
          Text(context.t('Join your gym'), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
          const SizedBox(height: 4),
          Muted(context.t('Get the gym code from the owner or the poster'), size: 14.5),
          const SizedBox(height: 22),
          LabeledField(label: context.t('Gym code'), controller: code, icon: Icons.storefront_rounded, caps: TextCapitalization.characters, hint: 'LIFE701'),
          if (gym == null)
            FilledButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                        final g = await Api.instance.get('/me/gym-lookup?code=${Uri.encodeQueryComponent(code.text.trim())}');
                        setState(() => gym = g as Map);
                      }),
              child: Text(context.t('Find gym')),
            )
          else ...[
            Panel(
              child: Row(children: [
                const IconTile(Icons.storefront_rounded, size: 46),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(gym!['name'], style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                    if (gym!['address'] != null) Muted(gym!['address'], size: 12.5),
                  ]),
                ),
                const Icon(Icons.check_circle_rounded, color: C.ok),
              ]),
            ),
            if (gym!['testimonials'] is Map) ...[
              const SizedBox(height: 12),
              TestimonialsSlider(items: (((gym!['testimonials'] as Map)['items'] as List?) ?? const []).cast<Map>(), avg: (gym!['testimonials'] as Map)['avg'] as num?, count: (gym!['testimonials'] as Map)['count'] as int?),
            ],
            const SizedBox(height: 16),
            Muted(context.t('What do you teach? (choose one or more)'), size: 13),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in specialities)
                FilterChip(
                  label: Text(context.t(s)),
                  selected: specs.contains(s),
                  selectedColor: p.primary,
                  checkmarkColor: Colors.white,
                  labelStyle: TextStyle(color: specs.contains(s) ? Colors.white : p.fg, fontWeight: FontWeight.w700),
                  onSelected: (on) => setState(() => on ? specs.add(s) : specs.remove(s)),
                ),
            ]),
            if (specs.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Muted(context.t('{n} chosen · members see these in the trainer list', {'n': specs.length}), size: 12)),
            const SizedBox(height: 14),
            LabeledField(label: context.t('Experience (years)'), controller: years, icon: Icons.timeline_rounded, keyboard: TextInputType.number),
            if (ref.watch(sessionProvider).user?['phone'] == null)
              PhoneField(label: context.t('Your mobile number'), controller: phone),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => run(() async {
                        if (specs.isEmpty) throw ApiException(400, context.t('Choose at least one thing you teach'));
                        final s = ref.read(sessionProvider);
                        if (s.user?['phone'] == null) {
                          if (phone.text.trim().isEmpty) throw ApiException(400, context.t('Enter your mobile number'));
                          final u = await Api.instance.patch('/me/contact', {'phone': phone.text.trim()});
                          s.patchUser({'phone': (u as Map)['phone']});
                        }
                        await Api.instance.post('/me/join', {
                          'gymCode': code.text.trim(),
                          'as': 'TRAINER',
                          if (specs.isNotEmpty) 'speciality': specialities.where(specs.contains).join(', '),
                          if (int.tryParse(years.text.trim()) != null) 'experienceYears': int.parse(years.text.trim()),
                        });
                        await ref.read(sessionProvider).refreshUser();
                        ref.invalidate(trainerHomeProvider);
                        if (mounted && context.canPop()) context.pop();
                      }),
              child: Text(context.t('Send join request')),
            ),
          ],
          ErrorText(error),
        ]),
      ),
    );
  }
}

/// Trainer waits for the owner's approval. Checks again every 20 seconds.
class WaitingScreen extends ConsumerStatefulWidget {
  const WaitingScreen({super.key});
  @override
  ConsumerState<WaitingScreen> createState() => _WaitingState();
}

class _WaitingState extends ConsumerState<WaitingScreen> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 20), (_) => ref.read(sessionProvider).refreshUser().catchError((_) {}));
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = ref.watch(trainerHomeProvider);
    final pending = home.valueOrNull?['pending'] as List?;
    final gymName = pending != null && pending.isNotEmpty ? pending.first['name'] as String : context.t('your gym');
    Widget step(String t, String d, Color col, IconData? icon) => Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: col, shape: BoxShape.circle),
              child: icon == null ? null : Icon(icon, size: 15, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t, style: const TextStyle(fontWeight: FontWeight.w700)), Muted(d, size: 12.5)])),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          color: context.c.primary,
          onRefresh: () => ref.read(sessionProvider).refreshUser(),
          child: ListView(padding: const EdgeInsets.fromLTRB(22, 40, 22, 28), children: [
            Center(
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(color: C.warn.withAlpha(40), shape: BoxShape.circle),
                child: const Icon(Icons.hourglass_top_rounded, size: 44, color: C.warn),
              ),
            ),
            const SizedBox(height: 18),
            Text(context.t('Waiting for the owner’s approval'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Muted(context.t('Your request went to {gym}. Your dashboard opens as soon as the owner approves.', {'gym': gymName}), align: TextAlign.center, size: 14),
            const SizedBox(height: 20),
            Panel(
              child: Column(children: [
                step(context.t('Request sent'), context.t('Done'), C.ok, Icons.check_rounded),
                step(context.t('Owner approves'), context.t('The owner got a notification'), C.warn, Icons.schedule_rounded),
                step(context.t('Dashboard opens'), context.t('Your full trainer panel'), context.c.line, null),
              ]),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: context.c.primary.withAlpha(30), borderRadius: BorderRadius.circular(16)),
              child: Row(children: [
                Icon(Icons.lock_outline_rounded, size: 18, color: context.c.primary),
                const SizedBox(width: 10),
                Expanded(child: Text(context.t('Member or trainer — nobody joins a gym without the owner'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5))),
              ]),
            ),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: () => ref.read(sessionProvider).refreshUser(), child: Text(context.t('Check again'))),
            const SizedBox(height: 8),
            Center(child: TextButton(onPressed: () => ref.read(sessionProvider).logout(), child: Text(context.t('Log out')))),
          ]),
        ),
      ),
    );
  }
}

Future<void> openLink(String url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
