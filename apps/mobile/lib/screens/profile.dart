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
  Future<void> pickPhoto(ImageSource source, bool circle) async {
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
          cropStyle: circle ? CropStyle.circle : CropStyle.rectangle,
          aspectRatioPresets: [
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.square,
            _Ratio4x5(),
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        IOSUiSettings(title: cropTitle, cropStyle: circle ? CropStyle.circle : CropStyle.rectangle),
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
    var circle = Prefs.getString('cropShape') != 'free';
    showModalBottomSheet(
      context: context,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('Profile photo'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Muted(context.t('After choosing, crop it any way you like: square, 4:5, 16:9 or free. You can also rotate and zoom.'), size: 12.5),
              const SizedBox(height: 14),
              Muted(context.t('Crop shape'), size: 12),
              const SizedBox(height: 6),
              Seg<bool>(
                value: circle,
                items: [(true, context.t('Circle'), Icons.circle_outlined), (false, context.t('Rectangle'), Icons.crop_free_rounded)],
                onChanged: (v) {
                  setSheet(() => circle = v);
                  Prefs.setString('cropShape', v ? 'circle' : 'free');
                },
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const IconTile(Icons.photo_camera_rounded),
                title: Text(context.t('Take photo')),
                onTap: () {
                  Navigator.pop(sheet);
                  pickPhoto(ImageSource.camera, circle);
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const IconTile(Icons.photo_library_rounded),
                title: Text(context.t('Choose from gallery')),
                onTap: () {
                  Navigator.pop(sheet);
                  pickPhoto(ImageSource.gallery, circle);
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
      ),
    );
  }

  Future<void> editName(String current) async {
    final c = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.t('Your name')),
        content: TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.t('Save'))),
        ],
      ),
    );
    if (ok == true && mounted) {
      final s = ref.read(sessionProvider);
      await run(() async {
        await Api.instance.patch('/me/profile', {'name': c.text.trim()});
        s.patchUser({'name': c.text.trim()});
      }, done: context.t('Saved'));
    }
  }

  Future<void> changePassword(bool hasPassword) async {
    final cur = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(hasPassword ? context.t('Change password') : context.t('Set a password')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (hasPassword) TextField(controller: cur, obscureText: true, decoration: InputDecoration(labelText: context.t('Current password'))),
          const SizedBox(height: 10),
          TextField(controller: next, obscureText: true, decoration: InputDecoration(labelText: context.t('New password (8+ characters)'))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(context.t('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(context.t('Save'))),
        ],
      ),
    );
    if (ok == true && mounted) {
      await run(() => Api.instance.post('/auth/change-password', {if (hasPassword) 'current': cur.text, 'next': next.text}), done: context.t('Password updated'));
    }
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
            _Row(Icons.edit_outlined, context.t('Edit name'), () => editName(name)),
            _Row(Icons.notifications_none_rounded, context.t('Notifications'), () => context.push('/notifications')),
            _Row(Icons.key_outlined, u['hasPassword'] == true ? context.t('Change password') : context.t('Set a password'), () => changePassword(u['hasPassword'] == true)),
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
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final n = list[i];
                return Panel(
                  padding: const EdgeInsets.all(14),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const IconTile(Icons.notifications_rounded, size: 38),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(n['title'], style: const TextStyle(fontWeight: FontWeight.w700))),
                          if (n['readAt'] == null) Container(width: 8, height: 8, decoration: const BoxDecoration(color: C.orange, shape: BoxShape.circle)),
                        ]),
                        const SizedBox(height: 2),
                        Text(n['body'], style: TextStyle(color: context.c.mut, height: 1.35)),
                        const SizedBox(height: 6),
                        Muted(fmtDateTime(n['createdAt']), size: 11),
                      ]),
                    ),
                  ]),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
