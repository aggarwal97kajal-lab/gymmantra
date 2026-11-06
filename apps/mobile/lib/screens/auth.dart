import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'legal.dart' show AgreeLine;
import 'person.dart';

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

/// Indian mobile number box: 🇮🇳 +91 is fixed in front, only 10 digits are typed.
class PhoneField extends StatelessWidget {
  const PhoneField({super.key, required this.label, required this.controller, this.hint, this.action, this.onSubmitted, this.onChanged, this.bottom = 14});
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputAction? action;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final double bottom;

  /// "+91 98765 43210" / "919876543210" → "9876543210" for the box.
  static String local(dynamic v) {
    final d = ((v as String?) ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    return d.length > 10 ? d.substring(d.length - 10) : d;
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.mut))),
          TextField(
            controller: controller,
            keyboardType: TextInputType.phone,
            textInputAction: action,
            onSubmitted: onSubmitted,
            onChanged: onChanged,
            autofillHints: const [AutofillHints.telephoneNumberNational],
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(10)],
            style: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: 0.4),
            decoration: InputDecoration(
              hintText: hint ?? '98765 43210',
              prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 14, right: 10),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const IndiaFlag(),
                  const SizedBox(width: 8),
                  const Text('+91', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  const SizedBox(width: 10),
                  Container(width: 1, height: 22, color: context.c.line),
                ]),
              ),
            ),
          ),
        ]),
      );
}

/// Small Indian flag drawn in code (no image needed).
class IndiaFlag extends StatelessWidget {
  const IndiaFlag({super.key, this.width = 22});
  final double width;
  @override
  Widget build(BuildContext context) {
    final h = width * 2 / 3;
    return Container(
      width: width,
      height: h,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), border: Border.all(color: const Color(0x22000000), width: 0.5)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Expanded(child: Container(color: const Color(0xFFFF9933))),
        Expanded(
          child: Container(
            color: Colors.white,
            alignment: Alignment.center,
            child: Container(width: h / 3, height: h / 3, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0xFF000080), width: 0.8))),
          ),
        ),
        Expanded(child: Container(color: const Color(0xFF138808))),
      ]),
    );
  }
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
  const _AuthFrame({required this.title, required this.subtitle, required this.children, this.back = false, this.busyText, this.wave = false});
  final String title;
  final String subtitle;
  final List<Widget> children;
  final bool back;
  final String? busyText; // shows the dumbbell spinner over the screen
  final bool wave;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        SafeArea(
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
        if (busyText != null) BusyCover(text: busyText!, wave: wave),
      ]),
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
          const SizedBox(width: 22, height: 22, child: CustomPaint(painter: GoogleGPainter())),
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
      busyText: busy ? context.t('Logging in…') : null,
      title: context.t('Welcome back 👋'),
      subtitle: context.t('Log in to see your membership'),
      children: [
        if (s.endedNote != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: C.warn.withAlpha(30), borderRadius: BorderRadius.circular(14), border: Border.all(color: C.warn.withAlpha(90))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.lock_rounded, color: C.warn, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text('${context.t('You were logged out')}\n${context.t(s.endedNote!)}', style: const TextStyle(fontSize: 13, height: 1.35))),
            ]),
          ),
        const RoleBadge(),
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
        const SizedBox(height: 16),
        const AgreeLine(prefix: 'By logging in you agree to our'),
        const SizedBox(height: 10),
        if (Prefs.getString('pendingRole') == 'STAFF')
          Center(child: Muted(context.t('Gym staff accounts are made by the gym owner. Ask your owner to add you (More → Staff → Add staff).'), size: 12.5, align: TextAlign.center))
        else
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
  final person = PersonDetails();
  final email = TextEditingController();
  final phone = TextEditingController();
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  bool hide = true;
  bool agreed = false;
  Map? addedBy; // the gym already made this account

  void submit(Session s) {
    final miss = person.missing(context);
    if (miss != null) {
      setState(() => error = miss);
      return;
    }
    final mismatch = context.t('Passwords do not match');
    run(() async {
      if (pw.text != pw2.text) throw ApiException(400, mismatch);
      try {
        await s.signupFull(person.toJson(), email.text, phone.text, pw.text);
      } on ApiException catch (e) {
        if (e.data?['code'] == 'ADDED_BY_GYM') {
          setState(() => addedBy = e.data);
          return;
        }
        rethrow;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final p = context.c;
    if (addedBy != null) {
      return _AuthFrame(
        back: true,
        busyText: busy ? context.t('Sending link…') : null,
        title: context.t('Create account'),
        subtitle: email.text.trim(),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: C.red.withAlpha(22), borderRadius: BorderRadius.circular(16), border: Border.all(color: C.red.withAlpha(80))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(context.t('An account with this email already exists'), style: const TextStyle(color: C.red, fontWeight: FontWeight.w800, fontSize: 16)),
              const SizedBox(height: 6),
              Text(context.t('{gym} has made you a member. Don\'t make a new account — just set your password and log in.', {'gym': addedBy!['gymName']}), style: TextStyle(color: p.mut, height: 1.4)),
            ]),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy
                ? null
                : () => run(() async {
                      final to = await s.forgot(email.text);
                      if (!mounted) return;
                      toast(context, context.t('Link sent to {email}. Set your password, then log in.', {'email': to}), kind: DripKind.ok);
                      context.go('/login');
                    }),
            child: Text(context.t('Set password & log in')),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => context.go('/login'), child: Text(context.t('Log in'))),
          const SizedBox(height: 10),
          Muted(context.t('The password link goes to this email.'), size: 12),
          ErrorText(error),
        ],
      );
    }
    return _AuthFrame(
      back: true,
      busyText: busy ? context.t('Creating your account…') : null,
      wave: true,
      title: context.t('Create your account'),
      subtitle: context.t('Member · Gym owner · Trainer — everyone fills the same details'),
      children: [
        const RoleBadge(),
        if (s.googleClientId != null) ...[
          GoogleButton(label: context.t('Sign up with Google'), onPressed: busy || !agreed ? null : () => run(() => s.google(signup: true))),
          if (!agreed) Padding(padding: const EdgeInsets.only(top: 6), child: Center(child: Muted(context.t('Tick "I agree" below first.'), size: 12))),
          const _OrDivider(),
        ],
        PersonFields(value: person, between: [
          PhoneField(label: '${context.t('Mobile')} *', controller: phone, action: TextInputAction.next, bottom: 12),
          LabeledField(label: '${context.t('Email')} *', controller: email, keyboard: TextInputType.emailAddress, action: TextInputAction.next),
        ]),
        LabeledField(
          label: context.t('Password (at least 8 characters)'),
          controller: pw,
          icon: Icons.lock_outline_rounded,
          obscure: hide,
          action: TextInputAction.next,
          suffix: IconButton(icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20), onPressed: () => setState(() => hide = !hide)),
        ),
        LabeledField(label: context.t('Confirm password'), controller: pw2, icon: Icons.lock_outline_rounded, obscure: hide),
        AgreeLine(value: agreed, onChanged: (v) => setState(() => agreed = v)),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(onPressed: busy || !agreed ? null : () => submit(s), child: Text(context.t('Sign up'))),
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


/// The four-colour Google "G" for the sign-in button.
class GoogleGPainter extends CustomPainter {
  const GoogleGPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final stroke = s * 0.2;
    final r = (s - stroke) / 2;
    final c = Offset(s / 2, s / 2);
    final rect = Rect.fromCircle(center: c, radius: r);
    double rad(double d) => d * 3.141592653589793 / 180;
    Paint p(Color col) => Paint()
      ..color = col
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    // Angles: 0 = 3 o'clock, clockwise. The opening of the G is at the upper right.
    canvas.drawArc(rect, rad(205), rad(112), false, p(const Color(0xFFEA4335))); // red, top
    canvas.drawArc(rect, rad(145), rad(62), false, p(const Color(0xFFFBBC05))); // yellow, left
    canvas.drawArc(rect, rad(42), rad(105), false, p(const Color(0xFF34A853))); // green, bottom
    canvas.drawArc(rect, rad(-2), rad(46), false, p(const Color(0xFF4285F4))); // blue, right
    canvas.drawRect(Rect.fromLTWH(s / 2 - s * 0.01, s / 2 - stroke / 2, r + stroke / 2 + s * 0.01, stroke), Paint()..color = const Color(0xFF4285F4)); // blue bar
  }

  @override
  bool shouldRepaint(GoogleGPainter oldDelegate) => false;
}


/// Shows the role picked on the first screen, with a way to change it.
class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final role = Prefs.getString('pendingRole') ?? 'MEMBER';
    final (icon, label) = switch (role) {
      'OWNER' => (Icons.storefront_rounded, context.t('Gym owner')),
      'TRAINER' => (Icons.sports_rounded, context.t('Trainer')),
      'STAFF' => (Icons.badge_rounded, context.t('Gym staff')),
      _ => (Icons.person_rounded, context.t('Member')),
    };
    final p = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: p.primary.withAlpha(34), borderRadius: BorderRadius.circular(99)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: p.primary),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: p.primary, fontWeight: FontWeight.w800, fontSize: 13)),
          ]),
        ),
        const SizedBox(width: 6),
        TextButton(onPressed: () => context.go('/start'), child: Text(context.t('Change'))),
      ]),
    );
  }
}

/// Gym-made account, first login (for example with Google): the member chooses a password once.
class SetPasswordScreen extends ConsumerStatefulWidget {
  const SetPasswordScreen({super.key});
  @override
  ConsumerState<SetPasswordScreen> createState() => _SetPasswordState();
}

class _SetPasswordState extends ConsumerState<SetPasswordScreen> with _Busy {
  final pw = TextEditingController();
  final pw2 = TextEditingController();
  bool hide = true;

  void save() {
    final short = context.t('Password (at least 8 characters)');
    final mismatch = context.t('Passwords do not match');
    run(() async {
      if (pw.text.length < 8) throw ApiException(400, short);
      if (pw.text != pw2.text) throw ApiException(400, mismatch);
      final r = await Api.instance.post('/auth/set-password', {'next': pw.text});
      final t = r['token'] as String?;
      if (t != null) await Api.instance.setToken(t); // other phones are logged out; this one stays in
      ref.read(sessionProvider).patchUser(Map<String, dynamic>.from(r['user'] as Map));
      if (mounted) toast(context, context.t('Password saved'), kind: DripKind.ok);
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = ref.watch(sessionProvider).user ?? {};
    return _AuthFrame(
      busyText: busy ? context.t('Saving…') : null,
      title: context.t('Set your password'),
      subtitle: context.t('{gym} made you a member ({email}). Choose your password once — then log in with Google or with email and password.', {'gym': u['addedByGym'] ?? context.t('Your gym'), 'email': u['email'] ?? ''}),
      children: [
        LabeledField(
          label: '${context.t('New password (8+ characters)')} *',
          controller: pw,
          icon: Icons.lock_outline_rounded,
          obscure: hide,
          suffix: IconButton(icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20), onPressed: () => setState(() => hide = !hide)),
        ),
        LabeledField(label: '${context.t('Re-enter password')} *', controller: pw2, icon: Icons.lock_outline_rounded, obscure: hide, onSubmitted: (_) => save()),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save password & continue'))),
        const SizedBox(height: 10),
        Center(child: TextButton(onPressed: () => ref.read(sessionProvider).logout(), child: Text(context.t('Log out')))),
      ],
    );
  }
}

/// Signed up with Google: the same details everyone gives (DOB, state, city, PIN, mobile).
class CompleteDetailsScreen extends ConsumerStatefulWidget {
  const CompleteDetailsScreen({super.key});
  @override
  ConsumerState<CompleteDetailsScreen> createState() => _CompleteDetailsState();
}

class _CompleteDetailsState extends ConsumerState<CompleteDetailsScreen> with _Busy {
  late final PersonDetails person = () {
    final u = ref.read(sessionProvider).user ?? {};
    final d = PersonDetails();
    final parts = ((u['name'] as String?) ?? '').trim().split(RegExp(r'\s+'));
    d.first = (u['firstName'] as String?) ?? (parts.isNotEmpty ? parts.first : '');
    d.last = (u['lastName'] as String?) ?? (parts.length > 1 ? parts.last : '');
    d.dob = u['dob'] as String?;
    d.gender = u['gender'] as String?;
    return d;
  }();
  late final phone = TextEditingController(text: PhoneField.local(ref.read(sessionProvider).user?['phone']));

  void save() {
    final miss = person.missing(context);
    if (miss != null) {
      setState(() => error = miss);
      return;
    }
    final needPhone = ref.read(sessionProvider).user?['phone'] == null;
    final badPhone = context.t('Enter a valid 10-digit mobile number');
    run(() async {
      if (needPhone && phone.text.trim().length != 10) throw ApiException(400, badPhone);
      final s = ref.read(sessionProvider);
      if (needPhone) s.patchUser(Map<String, dynamic>.from(await Api.instance.patch('/me/contact', {'phone': phone.text.trim()}) as Map));
      final r = await Api.instance.patch('/me/profile', person.toJson());
      s.patchUser(Map<String, dynamic>.from(r as Map));
    });
  }

  @override
  Widget build(BuildContext context) {
    final needPhone = ref.watch(sessionProvider).user?['phone'] == null;
    return _AuthFrame(
      busyText: busy ? context.t('Saving…') : null,
      title: context.t('Your details'),
      subtitle: context.t('One last step — everyone gives the same details.'),
      children: [
        PersonFields(value: person, between: [if (needPhone) PhoneField(label: '${context.t('Mobile')} *', controller: phone, bottom: 12)]),
        ErrorText(error),
        const SizedBox(height: 10),
        FilledButton(onPressed: busy ? null : save, child: Text(context.t('Save and continue'))),
        const SizedBox(height: 10),
        Center(child: TextButton(onPressed: () => ref.read(sessionProvider).logout(), child: Text(context.t('Log out')))),
      ],
    );
  }
}
