import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

class Avatar extends StatelessWidget {
  const Avatar({super.key, required this.name, this.url, this.size = 88});
  final String name;
  final String? url;
  final double size;
  @override
  Widget build(BuildContext context) {
    final initials = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w[0].toUpperCase()).join();
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: C.card2,
      foregroundImage: url == null ? null : NetworkImage(Api.instance.url(url!), headers: Api.instance.authHeaders),
      child: Text(initials, style: TextStyle(fontSize: size / 3, fontWeight: FontWeight.w800, color: C.fg)),
    );
  }
}

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<ProfileScreen> {
  bool busy = false;

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

  Future<void> pickPhoto(ImageSource source) => run(() async {
        final file = await ImagePicker().pickImage(source: source, maxWidth: 600, maxHeight: 600, imageQuality: 80, preferredCameraDevice: CameraDevice.front);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        await Api.instance.post('/me/photo', {'mime': 'image/jpeg', 'base64': base64Encode(bytes)});
        await ref.read(sessionProvider).refreshUser();
      }, done: 'Photo updated');

  void photoSheet(bool hasPhoto) {
    showModalBottomSheet(
      context: context,
      backgroundColor: C.card,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(Icons.photo_camera), title: const Text('Take photo'), onTap: () {
            Navigator.pop(context);
            pickPhoto(ImageSource.camera);
          }),
          ListTile(leading: const Icon(Icons.photo_library), title: const Text('Choose from gallery'), onTap: () {
            Navigator.pop(context);
            pickPhoto(ImageSource.gallery);
          }),
          if (hasPhoto)
            ListTile(leading: const Icon(Icons.delete_outline, color: C.red), title: const Text('Remove photo', style: TextStyle(color: C.red)), onTap: () {
              Navigator.pop(context);
              run(() async {
                await Api.instance.delete('/me/photo');
                await ref.read(sessionProvider).refreshUser();
              }, done: 'Photo removed');
            }),
        ]),
      ),
    );
  }

  Future<void> editName(String current) async {
    final c = TextEditingController(text: current);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: c, textCapitalization: TextCapitalization.words),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))],
      ),
    );
    if (ok == true) {
      await run(() async {
        await Api.instance.patch('/me/profile', {'name': c.text.trim()});
        await ref.read(sessionProvider).refreshUser();
      }, done: 'Saved');
    }
  }

  Future<void> changePassword(bool hasPassword) async {
    final cur = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(hasPassword ? 'Change password' : 'Set a password'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (hasPassword) TextField(controller: cur, obscureText: true, decoration: const InputDecoration(labelText: 'Current password')),
          const SizedBox(height: 10),
          TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'New password (8+ characters)')),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))],
      ),
    );
    if (ok == true) {
      await run(() => Api.instance.post('/auth/change-password', {if (hasPassword) 'current': cur.text, 'next': next.text}), done: 'Password updated');
    }
  }

  Future<void> deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text('This removes your login and personal details. Your gym keeps its own records of your membership.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: C.red))),
        ],
      ),
    );
    if (ok == true) {
      await run(() async {
        await Api.instance.delete('/me');
        await ref.read(sessionProvider).logout();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final u = s.user ?? {};
    final name = (u['name'] as String?) ?? '';
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: GestureDetector(
            onTap: busy ? null : () => photoSheet(u['photoUrl'] != null),
            child: Stack(children: [
              Avatar(name: name, url: u['photoUrl'] as String?),
              Positioned(right: 0, bottom: 0, child: CircleAvatar(radius: 15, backgroundColor: C.lime, child: busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: C.ink)) : const Icon(Icons.camera_alt, size: 16, color: C.ink))),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
        Center(child: Muted([u['phone'], u['email']].where((x) => x != null).join(' · '))),
        const SizedBox(height: 20),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Edit name'), onTap: () => editName(name)),
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('Language'),
              trailing: DropdownButton<String>(
                value: (u['language'] as String?) ?? 'en',
                underline: const SizedBox.shrink(),
                items: const [DropdownMenuItem(value: 'en', child: Text('English')), DropdownMenuItem(value: 'hi', child: Text('हिन्दी'))],
                onChanged: (v) => run(() async {
                  await Api.instance.patch('/me/profile', {'language': v});
                  await s.refreshUser();
                }),
              ),
            ),
            ListTile(leading: const Icon(Icons.notifications_none), title: const Text('Notifications'), onTap: () => context.push('/notifications')),
            ListTile(leading: const Icon(Icons.lock_outline), title: Text(u['hasPassword'] == true ? 'Change password' : 'Set a password'), onTap: () => changePassword(u['hasPassword'] == true)),
          ]),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: [
            ListTile(leading: const Icon(Icons.support_agent), title: const Text('Help & Support'), onTap: () => context.go('/help')),
            ListTile(leading: const Icon(Icons.delete_outline, color: C.red), title: const Text('Delete my account', style: TextStyle(color: C.red)), onTap: deleteAccount),
          ]),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(onPressed: () => s.logout(), icon: const Icon(Icons.logout), label: const Text('Log out')),
        const SizedBox(height: 20),
        const Center(child: Muted('GymMantra · Fitness ka sahi mantra.', size: 12)),
      ]),
    );
  }
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
      appBar: AppBar(title: const Text('Notifications')),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(notificationsProvider),
        builder: (d) {
          final list = (d as List).cast<Map>();
          if (list.isEmpty) return const Center(child: Muted('No notifications yet.'));
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final n = list[i];
              return Panel(
                padding: const EdgeInsets.all(14),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.circle, size: 10, color: n['readAt'] == null ? C.lime : Colors.transparent),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n['title'], style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(n['body'], style: const TextStyle(color: C.mut)),
                    const SizedBox(height: 4),
                    Text(fmtDateTime(n['createdAt']), style: const TextStyle(fontSize: 11, color: C.mut)),
                  ])),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}
