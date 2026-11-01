import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

class _Frame extends StatelessWidget {
  const _Frame({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(20, 32, 20, 24), children: [
          Center(
            child: GestureDetector(
              onLongPress: () => _serverDialog(context),
              child: const Column(children: [Logo(size: 72), SizedBox(height: 8), Wordmark(), SizedBox(height: 4), Muted('Fitness ka sahi mantra.', size: 14)]),
            ),
          ),
          const SizedBox(height: 28),
          Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          ...children,
        ]),
      ),
    );
  }
}

/// Hidden setting: long-press the logo to point the app at another server.
Future<void> _serverDialog(BuildContext context) async {
  final c = TextEditingController(text: Api.instance.base);
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Server address'),
      content: TextField(controller: c, keyboardType: TextInputType.url),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save'))],
    ),
  );
  if (ok == true && c.text.trim().startsWith('http')) await Api.instance.setBase(c.text);
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginState();
}

class _LoginState extends ConsumerState<LoginScreen> {
  final id = TextEditingController();
  final pw = TextEditingController();
  bool busy = false;
  bool hide = true;
  String? error;

  Future<void> run(Future<void> Function() fn) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    return _Frame(title: 'Log in', children: [
      TextField(controller: id, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.username], decoration: const InputDecoration(labelText: 'Email or mobile number')),
      const SizedBox(height: 12),
      TextField(
        controller: pw,
        obscureText: hide,
        autofillHints: const [AutofillHints.password],
        decoration: InputDecoration(labelText: 'Password', suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => hide = !hide))),
        onSubmitted: (_) => run(() => s.login(id.text, pw.text)),
      ),
      ErrorText(error),
      const SizedBox(height: 16),
      FilledButton(onPressed: busy ? null : () => run(() => s.login(id.text, pw.text)), child: Text(busy ? 'Logging in…' : 'Log in')),
      if (s.googleClientId != null) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: busy ? null : () => run(() => s.google(signup: false)), icon: const Icon(Icons.g_mobiledata, size: 28), label: const Text('Log in with Google')),
        const Padding(padding: EdgeInsets.only(top: 6), child: Center(child: Muted('Google log-in works after you sign up with Google.', size: 12))),
      ],
      const SizedBox(height: 18),
      Center(child: TextButton(onPressed: () => context.go('/signup'), child: const Text('New here? Create an account', style: TextStyle(color: C.lime)))),
    ]);
  }
}

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});
  @override
  ConsumerState<SignupScreen> createState() => _SignupState();
}

class _SignupState extends ConsumerState<SignupScreen> {
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() fn) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await fn();
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    return _Frame(title: 'Create your account', children: [
      TextField(controller: name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Full name')),
      const SizedBox(height: 12),
      TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
      const SizedBox(height: 12),
      TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Mobile number', hintText: '10-digit number')),
      const SizedBox(height: 12),
      TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Password (at least 8 characters)')),
      const SizedBox(height: 12),
      TextField(controller: pw2, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
      ErrorText(error),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: busy
            ? null
            : () => run(() async {
                  if (pw.text != pw2.text) throw ApiException(400, 'Passwords do not match');
                  await s.signup(name.text, email.text, phone.text, pw.text);
                }),
        child: Text(busy ? 'Creating account…' : 'Sign up'),
      ),
      if (s.googleClientId != null) ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(onPressed: busy ? null : () => run(() => s.google(signup: true, phone: phone.text)), icon: const Icon(Icons.g_mobiledata, size: 28), label: const Text('Sign up with Google')),
        const Padding(padding: EdgeInsets.only(top: 6), child: Center(child: Muted('Fill in your mobile number above so your gym can find you.', size: 12))),
      ],
      const SizedBox(height: 18),
      Center(child: TextButton(onPressed: () => context.go('/login'), child: const Text('Already have an account? Log in', style: TextStyle(color: C.lime)))),
    ]);
  }
}
