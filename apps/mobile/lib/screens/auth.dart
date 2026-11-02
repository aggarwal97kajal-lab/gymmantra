import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

/// Label above a text field, as on the designs.
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.icon,
    this.hint,
    this.keyboard,
    this.obscure = false,
    this.suffix,
    this.autofill,
    this.onSubmitted,
    this.caps = TextCapitalization.none,
    this.action,
  });
  final String label;
  final TextEditingController controller;
  final IconData? icon;
  final String? hint;
  final TextInputType? keyboard;
  final bool obscure;
  final Widget? suffix;
  final Iterable<String>? autofill;
  final ValueChanged<String>? onSubmitted;
  final TextCapitalization caps;
  final TextInputAction? action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.mut))),
          TextField(
            controller: controller,
            keyboardType: keyboard,
            obscureText: obscure,
            autofillHints: autofill,
            textCapitalization: caps,
            textInputAction: action,
            onSubmitted: onSubmitted,
            decoration: InputDecoration(hintText: hint, prefixIcon: icon == null ? null : Icon(icon, size: 20), suffixIcon: suffix),
          ),
        ]),
      );
}

/// Small EN / हि switch for screens before log-in.
class LangSwitch extends StatelessWidget {
  const LangSwitch({super.key});
  @override
  Widget build(BuildContext context) {
    final hi = context.isHindi;
    final p = context.c;
    Widget item(String code, String label) => GestureDetector(
          onTap: () => AppSettings.instance.setLang(code),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: (code == 'hi') == hi ? p.primary : Colors.transparent, borderRadius: BorderRadius.circular(99)),
            child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: (code == 'hi') == hi ? Colors.white : p.mut)),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(99), border: Border.all(color: p.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [item('en', 'EN'), item('hi', 'हिं')]),
    );
  }
}

class _AuthFrame extends StatelessWidget {
  const _AuthFrame({required this.title, required this.subtitle, required this.children, this.back = false});
  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool back;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
          Row(children: [
            if (back)
              _BackButton(onTap: () => context.canPop() ? context.pop() : context.go('/login'))
            else
              GestureDetector(
                onLongPress: () => _serverDialog(context),
                child: const Row(children: [Logo(size: 40), SizedBox(width: 8), Wordmark(size: 22)]),
              ),
            const Spacer(),
            const LangSwitch(),
          ]),
          const SizedBox(height: 34),
          Text(title, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.6, height: 1.15)),
          const SizedBox(height: 6),
          Muted(subtitle, size: 14.5),
          const SizedBox(height: 26),
          ...children,
        ]),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: context.c.surf,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: context.c.line)),
        child: InkWell(borderRadius: BorderRadius.circular(12), onTap: onTap, child: const SizedBox(width: 42, height: 42, child: Icon(Icons.chevron_left_rounded))),
      );
}

/// Hidden setting: long-press the logo to point the app at another server.
Future<void> _serverDialog(BuildContext context) async {
  final c = TextEditingController(text: Api.instance.base);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Server address'),
      content: TextField(controller: c, keyboardType: TextInputType.url),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save'))],
    ),
  );
  if (ok == true && c.text.trim().startsWith('http')) await Api.instance.setBase(c.text);
}

class _OrDivider extends StatelessWidget {
  const _OrDivider();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(children: [const Expanded(child: Divider()), Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Muted(context.t('or'))), const Expanded(child: Divider())]),
      );
}

class GoogleButton extends StatelessWidget {
  const GoogleButton({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onPressed,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
            child: const Text('G', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: Color(0xFF4285F4), height: 1.1)),
          ),
          const SizedBox(width: 10),
          Text(label),
        ]),
      );
}

mixin _Busy<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? error;
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
}

Widget _spinnerOr(bool busy, String text) => busy
    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
    : Text(text);

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginState();
}

class _LoginState extends ConsumerState<LoginScreen> with _Busy {
  final id = TextEditingController();
  final pw = TextEditingController();
  bool hide = true;

  void submit(Session s) {
    if (id.text.trim().isEmpty || pw.text.isEmpty) {
      setState(() => error = context.t('Enter your email or mobile number and password.'));
      return;
    }
    run(() => s.login(id.text, pw.text));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    return _AuthFrame(
      title: context.t('Welcome back 👋'),
      subtitle: context.t('Log in to see your membership'),
      children: [
        AutofillGroup(
          child: Column(children: [
            LabeledField(
              label: context.t('Email or mobile number'),
              controller: id,
              icon: Icons.mail_outline_rounded,
              keyboard: TextInputType.emailAddress,
              autofill: const [AutofillHints.username],
              action: TextInputAction.next,
            ),
            LabeledField(
              label: context.t('Password'),
              controller: pw,
              icon: Icons.lock_outline_rounded,
              obscure: hide,
              autofill: const [AutofillHints.password],
              suffix: IconButton(icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20), onPressed: () => setState(() => hide = !hide)),
              onSubmitted: (_) => submit(s),
            ),
          ]),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => context.push('/forgot', extra: id.text), child: Text(context.t('Forgot password?'))),
        ),
        ErrorText(error),
        const SizedBox(height: 12),
        FilledButton(onPressed: busy ? null : () => submit(s), child: _spinnerOr(busy, context.t('Log in'))),
        if (s.googleClientId != null) ...[
          const _OrDivider(),
          GoogleButton(label: context.t('Continue with Google'), onPressed: busy ? null : () => run(() => s.google(signup: false))),
          Padding(padding: const EdgeInsets.only(top: 8), child: Center(child: Muted(context.t('Google log-in works after you sign up with Google.'), size: 12, align: TextAlign.center))),
        ],
        const SizedBox(height: 22),
        Center(
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Muted(context.t('New here?'), size: 14),
            TextButton(onPressed: () => context.push('/signup'), child: Text(context.t('Create an account'))),
          ]),
        ),
      ],
    );
  }
}

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});
  @override
  ConsumerState<SignupScreen> createState() => _SignupState();
}

class _SignupState extends ConsumerState<SignupScreen> with _Busy {
  final name = TextEditingController();
  final email = TextEditingController();
  final phone = TextEditingController();
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  bool hide = true;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    return _AuthFrame(
      back: true,
      title: context.t('Create your account'),
      subtitle: context.t('Takes less than a minute'),
      children: [
        LabeledField(label: context.t('Full name'), controller: name, icon: Icons.person_outline_rounded, caps: TextCapitalization.words, action: TextInputAction.next),
        LabeledField(label: context.t('Email'), controller: email, icon: Icons.mail_outline_rounded, keyboard: TextInputType.emailAddress, action: TextInputAction.next),
        LabeledField(label: context.t('Mobile number'), controller: phone, icon: Icons.phone_iphone_rounded, hint: context.t('10-digit number'), keyboard: TextInputType.phone, action: TextInputAction.next),
        LabeledField(
          label: context.t('Password (at least 8 characters)'),
          controller: pw,
          icon: Icons.lock_outline_rounded,
          obscure: hide,
          action: TextInputAction.next,
          suffix: IconButton(icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20), onPressed: () => setState(() => hide = !hide)),
        ),
        LabeledField(label: context.t('Confirm password'), controller: pw2, icon: Icons.lock_outline_rounded, obscure: hide),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: busy
              ? null
              : () {
                  final mismatch = context.t('Passwords do not match');
                  run(() async {
                    if (pw.text != pw2.text) throw ApiException(400, mismatch);
                    await s.signup(name.text, email.text, phone.text, pw.text);
                  });
                },
          child: _spinnerOr(busy, context.t('Sign up')),
        ),
        if (s.googleClientId != null) ...[
          const _OrDivider(),
          GoogleButton(label: context.t('Sign up with Google'), onPressed: busy ? null : () => run(() => s.google(signup: true, phone: phone.text))),
          Padding(padding: const EdgeInsets.only(top: 8), child: Center(child: Muted(context.t('Fill in your mobile number above so your gym can find you.'), size: 12, align: TextAlign.center))),
        ],
        const SizedBox(height: 18),
        Center(
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Muted(context.t('Already have an account?'), size: 14),
            TextButton(onPressed: () => context.canPop() ? context.pop() : context.go('/login'), child: Text(context.t('Log in'))),
          ]),
        ),
      ],
    );
  }
}

class ForgotScreen extends ConsumerStatefulWidget {
  const ForgotScreen({super.key});
  @override
  ConsumerState<ForgotScreen> createState() => _ForgotState();
}

class _ForgotState extends ConsumerState<ForgotScreen> with _Busy {
  final id = TextEditingController();
  String? sentTo;
  int wait = 0;
  Timer? timer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (id.text.isEmpty) {
      final extra = GoRouterState.of(context).extra;
      if (extra is String && extra.contains('@')) id.text = extra.trim();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  void send() {
    final v = id.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v)) {
      setState(() => error = context.t('Enter the email you signed up with.'));
      return;
    }
    run(() async {
      final to = await ref.read(sessionProvider).forgot(id.text);
      setState(() {
        sentTo = to;
        wait = 45;
      });
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => wait = wait > 0 ? wait - 1 : 0);
        if (wait == 0) t.cancel();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    if (sentTo != null) {
      return Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(22, 16, 22, 28), children: [
            Row(children: [_BackButton(onTap: () => context.go('/login'))]),
            const SizedBox(height: 50),
            Center(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0.4, end: 1.0),
                duration: const Duration(milliseconds: 500),
                curve: Curves.elasticOut,
                builder: (_, v, child) => Transform.scale(scale: v, child: child),
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(color: C.ok.withAlpha(36), shape: BoxShape.circle),
                  child: const Icon(Icons.check_rounded, color: C.ok, size: 40),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Center(child: Text(context.t('Email sent!'), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800))),
            const SizedBox(height: 10),
            Muted(context.t('We sent a link to {email}. Open it, set a new password, then log in here.', {'email': sentTo}), size: 14.5, align: TextAlign.center),
            const SizedBox(height: 6),
            Muted(context.t('Not in your inbox? Check the Spam folder.'), size: 12.5, align: TextAlign.center),
            const SizedBox(height: 28),
            FilledButton(onPressed: () => context.go('/login'), child: Text(context.t('Back to login'))),
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: wait > 0 || busy ? null : send,
                child: Text(wait > 0 ? context.t('Resend in 0:{s}', {'s': wait.toString().padLeft(2, '0')}) : context.t('Resend link')),
              ),
            ),
            ErrorText(error),
          ]),
        ),
      );
    }
    return _AuthFrame(
      back: true,
      title: context.t('Forgot password?'),
      subtitle: context.t('Enter the email you signed up with. We will email you a link to set a new password.'),
      children: [
        Align(alignment: Alignment.centerLeft, child: IconTile(Icons.key_rounded, size: 52, color: p.primary)),
        const SizedBox(height: 18),
        LabeledField(
          label: context.t('Email'),
          controller: id,
          icon: Icons.mail_outline_rounded,
          hint: 'name@gmail.com',
          keyboard: TextInputType.emailAddress,
          autofill: const [AutofillHints.email],
          onSubmitted: (_) => send(),
        ),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(onPressed: busy ? null : send, child: _spinnerOr(busy, context.t('Send reset link'))),
      ],
    );
  }
}
