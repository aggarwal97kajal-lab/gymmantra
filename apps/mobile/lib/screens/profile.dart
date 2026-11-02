import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../api.dart';
import '../i18n.dart';
import '../photo.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'auth.dart' show PhoneField;

class _Ratio4x5 implements CropAspectRatioPresetData {
  @override
  (int, int)? get data => (4, 5);
  @override
  String get name => '4:5';
}

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<ProfileScreen> {
  bool busy = false;
  bool uploading = false;
  Uint8List? localPhoto;

  Future<void> run(Future<void> Function() fn, {String? done}) async {
    setState(() => busy = true);
    try {
      await fn();
      if (done != null && mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Pick → crop (any shape) → show at once → upload in the background.
  Future<void> pickPhoto(ImageSource source) async {
    final cropTitle = context.t('Crop photo');
    final doneMsg = context.t('Photo updated');
    final XFile? file;
    try {
      file = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 92, preferredCameraDevice: CameraDevice.front);
    } catch (e) {
      if (mounted) toast(context, e.toString());
      return;
    }
    if (file == null) return;
    final cropped = await ImageCropper().cropImage(
      sourcePath: file.path,
      maxWidth: 720,
      maxHeight: 720,
      compressQuality: 82,
      compressFormat: ImageCompressFormat.jpg,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: cropTitle,
          toolbarColor: C.night,
          toolbarWidgetColor: Colors.white,
          backgroundColor: Colors.black,
          activeControlsWidgetColor: C.orange,
          dimmedLayerColor: const Color(0xAA000000),
          cropFrameColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: false,
          cropStyle: CropStyle.rectangle,
          aspectRatioPresets: [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            _Ratio4x5(),
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        IOSUiSettings(title: cropTitle),
      ],
    );
    if (cropped == null) return;
    final bytes = await cropped.readAsBytes();
    if (!mounted) return;
    setState(() {
      localPhoto = bytes;
      uploading = true;
    });
    try {
      final r = await Api.instance.post('/me/photo', {'mime': 'image/jpeg', 'base64': base64Encode(bytes)});
      final url = r['photoUrl'] as String;
      PhotoCache.put(url, bytes);
      ref.read(sessionProvider).patchUser({'photoUrl': url});
      if (mounted) toast(context, doneMsg);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) {
        setState(() {
          uploading = false;
          localPhoto = null;
        });
      }
    }
  }

  void photoSheet(bool hasPhoto) {
    showModalBottomSheet(
      context: context,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('Profile photo'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const IconTile(Icons.photo_camera_rounded),
              title: Text(context.t('Take photo')),
              onTap: () {
                Navigator.pop(sheet);
                pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const IconTile(Icons.photo_library_rounded),
              title: Text(context.t('Choose from gallery')),
              onTap: () {
                Navigator.pop(sheet);
                pickPhoto(ImageSource.gallery);
              },
            ),
            if (hasPhoto)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const IconTile(Icons.delete_outline_rounded, color: C.red),
                title: Text(context.t('Remove photo'), style: const TextStyle(color: C.red)),
                onTap: () {
                  Navigator.pop(sheet);
                  final s = ref.read(sessionProvider);
                  run(() async {
                    await Api.instance.delete('/me/photo');
                    s.patchUser({'photoUrl': null});
                  }, done: context.t('Photo removed'));
                },
              ),
          ]),
        ),
      ),
    );
  }

  Future<void> deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t('Delete account?')),
        content: Text(context.t('This removes your login and personal details. Your gym keeps its own records of your membership.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.t('Delete'), style: const TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok == true && mounted) {
      final s = ref.read(sessionProvider);
      await run(() async {
        await Api.instance.delete('/me');
        await s.logout();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final settings = AppSettings.instance;
    final u = s.user ?? {};
    final name = (u['name'] as String?) ?? '';
    final p = context.c;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Profile'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Center(
          child: GestureDetector(
            onTap: busy || uploading ? null : () => photoSheet(u['photoUrl'] != null),
            child: Stack(children: [
              Avatar(name: name, url: u['photoUrl'] as String?, local: localPhoto, size: 96, ring: true),
              if (uploading)
                const Positioned.fill(
                  child: Padding(padding: EdgeInsets.all(3), child: CircularProgressIndicator(strokeWidth: 3, color: C.orange)),
                ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(color: C.orange, shape: BoxShape.circle, border: Border.all(color: p.bg, width: 3)),
                  child: const Icon(Icons.photo_camera_rounded, size: 15, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text(name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
        const SizedBox(height: 2),
        Center(child: Muted([u['phone'], u['email']].where((x) => x != null).join(' · '), align: TextAlign.center)),
        const SizedBox(height: 20),
        Panel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Label(Icons.dark_mode_outlined, context.t('Theme')),
            Seg<ThemeMode>(
              value: settings.themeMode,
              items: [
                (ThemeMode.light, context.t('Light'), Icons.light_mode_rounded),
                (ThemeMode.dark, context.t('Dark'), Icons.dark_mode_rounded),
                (ThemeMode.system, context.t('Auto'), Icons.phone_android_rounded),
              ],
              onChanged: settings.setTheme,
            ),
            const SizedBox(height: 16),
            _Label(Icons.translate_rounded, 'Language / भाषा'),
            Seg<String>(
              value: settings.lang,
              items: const [('en', 'English', null), ('hi', 'हिन्दी', null)],
              onChanged: (v) => s.setLanguage(v),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.vibration_rounded, size: 18, color: p.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(context.t('Vibrate on tap'), style: const TextStyle(fontWeight: FontWeight.w700))),
              Switch(value: settings.haptics, activeTrackColor: p.primary, onChanged: settings.setHaptics),
            ]),
          ]),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            _Row(Icons.badge_outlined, context.t('Personal details'), () => context.push('/profile/details')),
            _Row(Icons.notifications_none_rounded, context.t('Notifications'), () => context.push('/notifications')),
            _Row(Icons.key_outlined, u['hasPassword'] == true ? context.t('Change password') : context.t('Set a password'), () => context.push('/profile/password')),
            if (s.mode == 'trainer') _Row(Icons.badge_outlined, context.t('About me'), () => context.push('/t/about')),
            _Row(Icons.help_outline_rounded, context.t('Help & Support'), () => s.mode == 'member' ? context.go('/help') : context.push('/support')),
            _Row(Icons.delete_outline_rounded, context.t('Delete my account'), deleteAccount, color: C.red, last: true),
          ]),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: () => s.logout(), icon: const Icon(Icons.logout_rounded), label: Text(context.t('Log out'))),
        const SizedBox(height: 22),
        Center(
          child: Column(children: [
            Opacity(opacity: 0.6, child: Logo(size: 30, mark: p.fg)),
            const SizedBox(height: 4),
            Muted('GymMantra · ${context.t('Fitness ka sahi mantra.')}', size: 12),
          ]),
        ),
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [Icon(icon, size: 18, color: context.c.primary), const SizedBox(width: 8), Text(text, style: const TextStyle(fontWeight: FontWeight.w700))]),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.text, this.onTap, {this.color, this.last = false});
  final IconData icon;
  final String text;
  final VoidCallback onTap;
  final Color? color;
  final bool last;
  @override
  Widget build(BuildContext context) => Column(children: [
        ListTile(
          leading: IconTile(icon, color: color ?? context.c.fg, size: 36),
          title: Text(text, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
          trailing: Icon(Icons.chevron_right_rounded, color: context.c.mut),
          onTap: onTap,
        ),
        if (!last) const Divider(indent: 68, endIndent: 16),
      ]);
}

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});
  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsState();
}

class _NotificationsState extends ConsumerState<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    Api.instance.post('/me/notifications/read').catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(notificationsProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Notifications'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(notificationsProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(notificationsProvider),
          builder: (d) {
            final list = (d as List).cast<Map>();
            if (list.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 120),
                Icon(Icons.notifications_off_outlined, size: 54, color: context.c.mut),
                const SizedBox(height: 10),
                Muted(context.t('No notifications yet.'), align: TextAlign.center, size: 14),
              ]);
            }
            // Grouped by day: Today, Yesterday, then dates.
            String dayOf(Map n) {
              final t = DateTime.tryParse(n['createdAt'] as String? ?? '')?.toUtc().add(const Duration(hours: 5, minutes: 30));
              return t == null ? '' : '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
            }
            final today = todayYmdIst();
            final yesterday = addDaysYmd(today, -1);
            final rows = <Widget>[];
            String? lastDay;
            for (final n in list) {
              final d = dayOf(n);
              if (d != lastDay) {
                lastDay = d;
                final label = d == today ? context.t('Today') : d == yesterday ? context.t('Yesterday') : fmtDate(d);
                rows.add(Padding(
                  padding: EdgeInsets.fromLTRB(4, rows.isEmpty ? 0 : 10, 4, 8),
                  child: Text(label.toUpperCase(), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: context.c.mut)),
                ));
              }
              rows.add(Padding(padding: const EdgeInsets.only(bottom: 10), child: _NoteCard(n: n)));
            }
            return ListView(padding: const EdgeInsets.all(16), children: rows);
          },
        ),
      ),
    );
  }
}


/// One notification; the icon follows what it is about.
class _NoteCard extends StatelessWidget {
  const _NoteCard({required this.n});
  final Map n;
  @override
  Widget build(BuildContext context) {
    final title = (n['title'] as String?) ?? '';
    final kind = (n['kind'] as String?) ?? (title.startsWith('Payment due') ? 'DUE' : '');
    final (IconData icon, Color color) = switch (kind) {
      'NOTICE' => (Icons.campaign_rounded, C.warn),
      'DUE' => (Icons.currency_rupee_rounded, C.red),
      _ => title.contains('PT') || title.contains('plan') || title.contains('diet')
          ? (Icons.fitness_center_rounded, C.orange)
          : title.contains('approved') || title.contains('renew')
              ? (Icons.check_circle_rounded, C.ok)
              : (Icons.notifications_rounded, C.orange),
    };
    final t = DateTime.tryParse(n['createdAt'] as String? ?? '')?.toLocal();
    final time = t == null ? '' : TimeOfDay.fromDateTime(t).format(context);
    return Panel(
      padding: const EdgeInsets.all(14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconTile(icon, color: color, size: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (n['from'] != null) Text(n['from'] as String, style: TextStyle(color: context.c.mut, fontSize: 12, fontWeight: FontWeight.w600)),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
              const SizedBox(width: 8),
              Muted(time, size: 11),
              if (n['readAt'] == null) Container(margin: const EdgeInsets.only(left: 6, top: 4), width: 8, height: 8, decoration: const BoxDecoration(color: C.orange, shape: BoxShape.circle)),
            ]),
            const SizedBox(height: 2),
            Text((n['body'] as String?) ?? '', style: TextStyle(color: context.c.mut, height: 1.35)),
          ]),
        ),
      ]),
    );
  }
}

String todayYmdIst() {
  final n = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

String addDaysYmd(String ymd, int days) {
  final d = DateTime.utc(int.parse(ymd.substring(0, 4)), int.parse(ymd.substring(5, 7)), int.parse(ymd.substring(8, 10))).add(Duration(days: days));
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// ============================================================ personal details

class ProfileDetailsScreen extends ConsumerStatefulWidget {
  const ProfileDetailsScreen({super.key});
  @override
  ConsumerState<ProfileDetailsScreen> createState() => _ProfileDetailsState();
}

class _ProfileDetailsState extends ConsumerState<ProfileDetailsScreen> {
  late final Map u = ref.read(sessionProvider).user ?? {};
  late final first = TextEditingController(text: u['firstName'] as String? ?? '');
  late final middle = TextEditingController(text: u['middleName'] as String? ?? '');
  late final last = TextEditingController(text: u['lastName'] as String? ?? '');
  late final address = TextEditingController(text: u['address'] as String? ?? '');
  late String? dob = u['dob'] as String?;
  late String? gender = u['gender'] as String?;
  late final phone = TextEditingController(text: PhoneField.local(u['phone']));
  late final email = TextEditingController(text: u['email'] as String? ?? '');
  final pw = TextEditingController();
  bool busy = false;
  String? error;

  bool get phoneChanged => phone.text.trim() != PhoneField.local(u['phone']);
  bool get emailChanged => email.text.trim().toLowerCase() != ((u['email'] as String?) ?? '').toLowerCase();

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    final saved = context.t('Saved');
    try {
      final r = await Api.instance.patch('/me/profile', {
        'firstName': first.text.trim(),
        'middleName': middle.text.trim(),
        'lastName': last.text.trim(),
        'dob': dob,
        'gender': gender,
        'address': address.text.trim(),
      });
      ref.read(sessionProvider).patchUser(Map<String, dynamic>.from(r as Map));
      if (phoneChanged || emailChanged) {
        final hasPw = u['hasPassword'] == true;
        final c = await Api.instance.patch('/me/contact', {
          if (phoneChanged) 'phone': phone.text.trim(),
          if (emailChanged) 'email': email.text.trim(),
          if (hasPw) 'password': pw.text,
        });
        ref.read(sessionProvider).patchUser(Map<String, dynamic>.from(c as Map));
      }
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

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(sessionProvider).user ?? {};
    Widget field(TextEditingController c, String label, {bool required = false, int lines = 1}) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(controller: c, maxLines: lines, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: required ? '$label *' : label)),
        );
    Widget tap(IconData icon, String label, String value, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: InputDecorator(
              decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon), suffixIcon: const Icon(Icons.edit_rounded, size: 18)),
              child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        );
    final dobText = dob == null ? context.t('Choose date') : fmtDate(dob);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Personal details'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        field(first, context.t('First name'), required: true),
        field(middle, context.t('Middle name')),
        field(last, context.t('Last name')),
        tap(Icons.cake_outlined, context.t('Date of birth'), dobText, () async {
          final init = DateTime.tryParse(dob ?? '') ?? DateTime(1998, 1, 1);
          final d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(1930), lastDate: DateTime.now(), initialEntryMode: DatePickerEntryMode.calendarOnly);
          if (d != null) setState(() => dob = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
        }),
        Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Muted(context.t('Gender'), size: 12.5)),
        Seg<String?>(
          value: gender,
          items: [('male', context.t('Male'), Icons.male_rounded), ('female', context.t('Female'), Icons.female_rounded), ('other', context.t('Other'), null)],
          onChanged: (v) => setState(() => gender = v),
        ),
        const SizedBox(height: 12),
        field(address, context.t('Address'), lines: 2),
        const SizedBox(height: 4),
        SectionTitle(context.t('Login details')),
        PhoneField(label: context.t('Mobile number'), controller: phone, onChanged: (_) => setState(() {}), bottom: 12),
        TextField(
          controller: email,
          keyboardType: TextInputType.emailAddress,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(labelText: context.t('Email'), prefixIcon: const Icon(Icons.mail_outline_rounded)),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: (phoneChanged || emailChanged) && cur['hasPassword'] == true
              ? Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextField(
                    controller: pw,
                    obscureText: true,
                    decoration: InputDecoration(labelText: context.t('Current password'), helperText: context.t('Needed to change your mobile number or email'), prefixIcon: const Icon(Icons.lock_outline_rounded)),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 4),
        ErrorText(error),
        const SizedBox(height: 12),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save'))),
      ]),
    );
  }
}

// ============================================================ change password

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});
  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordState();
}

class _ChangePasswordState extends ConsumerState<ChangePasswordScreen> {
  final cur = TextEditingController();
  final next = TextEditingController();
  final again = TextEditingController();
  bool hide = true;
  bool busy = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final hasPw = ref.watch(sessionProvider).user?['hasPassword'] == true;
    Widget box(TextEditingController c, String label) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: c,
            obscureText: hide,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: const Icon(Icons.lock_outline_rounded),
              suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: () => setState(() => hide = !hide)),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(hasPw ? context.t('Change password') : context.t('Set a password'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        if (hasPw) box(cur, context.t('Current password')),
        box(next, context.t('New password (8+ characters)')),
        box(again, context.t('New password again')),
        ErrorText(error),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  final mismatch = context.t('Passwords do not match');
                  final short = context.t('Password (at least 8 characters)');
                  final done = context.t('Password updated');
                  if (next.text.length < 8) {
                    setState(() => error = short);
                    return;
                  }
                  if (next.text != again.text) {
                    setState(() => error = mismatch);
                    return;
                  }
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await Api.instance.post('/auth/change-password', {if (hasPw) 'current': cur.text, 'next': next.text});
                    await ref.read(sessionProvider).refreshUser().catchError((_) {});
                    if (context.mounted) {
                      toast(context, done);
                      context.pop();
                    }
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(context.t('Save')),
        ),
      ]),
    );
  }
}
