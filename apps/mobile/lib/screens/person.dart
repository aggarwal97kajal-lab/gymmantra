import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';
import 'billing.dart' show IndiaState, loadIndia, SearchList;

/// The same details everywhere: sign-up (member, trainer, owner) and the owner's "Add member".
class PersonDetails {
  String first = '';
  String middle = '';
  String last = '';
  String? dob; // YYYY-MM-DD
  String? gender;
  String? state;
  String? city;
  String country = 'India';
  String pin = '';

  String get fullName => [first.trim(), middle.trim(), last.trim()].where((x) => x.isNotEmpty).join(' ');

  Map<String, dynamic> toJson() => {
        'firstName': first.trim(),
        if (middle.trim().isNotEmpty) 'middleName': middle.trim(),
        'lastName': last.trim(),
        'dob': dob,
        if (gender != null) 'gender': gender,
        'state': state,
        'city': city,
        'country': country,
        'pincode': pin.trim(),
      };

  /// First problem to show, or null when everything is filled in.
  String? missing(BuildContext context) {
    if (first.trim().isEmpty) return context.t('Enter the first name');
    if (last.trim().isEmpty) return context.t('Enter the last name');
    if (dob == null) return context.t('Choose the date of birth');
    if (state == null) return context.t('Choose the state');
    if (city == null || city!.trim().isEmpty) return context.t('Choose the city');
    if (!RegExp(r'^[1-9]\d{5}$').hasMatch(pin.trim())) return context.t('Enter a valid 6-digit PIN code');
    return null;
  }
}

String ymd(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Labelled box like the designs: small grey label on top, white box below.
class _Box extends StatelessWidget {
  const _Box({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.c.mut))),
          child,
        ]),
      );
}

/// First / middle / last name, date of birth, gender, state, city, country, PIN.
/// [between] goes after gender (sign-up puts mobile and email there).
class PersonFields extends StatefulWidget {
  const PersonFields({super.key, required this.value, this.between = const []});
  final PersonDetails value;
  final List<Widget> between;
  @override
  State<PersonFields> createState() => _PersonFieldsState();
}

class _PersonFieldsState extends State<PersonFields> {
  List<IndiaState> states = const [];
  late final first = TextEditingController(text: widget.value.first);
  late final middle = TextEditingController(text: widget.value.middle);
  late final last = TextEditingController(text: widget.value.last);
  late final pin = TextEditingController(text: widget.value.pin);

  @override
  void initState() {
    super.initState();
    loadIndia().then((s) {
      if (mounted) setState(() => states = s);
    });
  }

  IndiaState? get st => states.where((s) => s.name == widget.value.state).firstOrNull;

  String? get pinError {
    final s = st;
    final p = pin.text.trim();
    if (s == null || p.length != 6) return null;
    if (!RegExp(r'^[1-9]\d{5}$').hasMatch(p)) return context.t('Enter a valid 6-digit PIN code');
    if (!s.pins.contains(p.substring(0, 2))) return context.t('This PIN is not from {state}. {state} PIN codes start with {start}.', {'state': s.name, 'start': s.pins.join('/')});
    return null;
  }

  Future<String?> pick(String title, List<String> items, {bool other = false}) => showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (_) => SearchList(title: title, items: items, allowOther: other),
      );

  /// Every box in this form is the same kind of text box, so all of them are exactly the same
  /// height (the old tap-to-choose boxes and "India" were drawn differently and came out shorter
  /// than the PIN and name boxes).
  Widget _select(String? value, String hint, VoidCallback? onTap) => TextField(
        controller: TextEditingController(text: value ?? ''),
        readOnly: true,
        showCursor: false,
        enableInteractiveSelection: false,
        enabled: onTap != null,
        onTap: onTap,
        maxLines: 1,
        style: const TextStyle(fontWeight: FontWeight.w600),
        decoration: InputDecoration(hintText: hint, suffixIcon: Icon(Icons.expand_more_rounded, color: context.c.mut)),
      );

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    Widget two(Widget a, Widget b) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]);
    TextField text(TextEditingController c, ValueChanged<String> on) => TextField(controller: c, textCapitalization: TextCapitalization.words, style: const TextStyle(fontWeight: FontWeight.w600), onChanged: on);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      two(
        _Box(label: '${context.t('First name')} *', child: text(first, (t) => v.first = t)),
        _Box(label: context.t('Middle name'), child: text(middle, (t) => v.middle = t)),
      ),
      _Box(label: '${context.t('Last name')} *', child: text(last, (t) => v.last = t)),
      two(
        _Box(
          label: '${context.t('Date of birth')} *',
          child: _select(v.dob == null ? null : fmtDate(v.dob), context.t('Choose date'), () async {
            final init = DateTime.tryParse(v.dob ?? '') ?? DateTime(1998, 1, 1);
            final d = await showDatePicker(context: context, initialDate: init, firstDate: DateTime(1930), lastDate: DateTime.now(), initialEntryMode: DatePickerEntryMode.calendarOnly);
            if (d != null) setState(() => v.dob = ymd(d));
          }),
        ),
        _Box(
          label: context.t('Gender'),
          child: _select(v.gender == null ? null : context.t(v.gender == 'male' ? 'Male' : v.gender == 'female' ? 'Female' : 'Other'), context.t('Choose'), () async {
            final g = await showModalBottomSheet<String>(
              context: context,
              builder: (ctx) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final (k, l) in [('male', 'Male'), ('female', 'Female'), ('other', 'Other')]) ListTile(title: Text(ctx.t(l), style: const TextStyle(fontWeight: FontWeight.w700)), onTap: () => Navigator.pop(ctx, k)),
                ]),
              ),
            );
            if (g != null) setState(() => v.gender = g);
          }),
        ),
      ),
      ...widget.between,
      two(
        _Box(
          label: '${context.t('State')} *',
          child: _select(v.state, context.t('Choose'), () async {
            final s = await pick(context.t('Choose state'), states.map((e) => e.name).toList());
            if (s != null) {
              setState(() {
                v.state = s;
                v.city = null;
              });
            }
          }),
        ),
        _Box(
          label: '${context.t('City')} *',
          child: _select(v.city, st == null ? context.t('State first') : context.t('Choose'), st == null
              ? null
              : () async {
                  final c = await pick(context.t('{state} cities', {'state': st!.name}), st!.cities, other: true);
                  if (c != null) setState(() => v.city = c);
                }),
        ),
      ),
      two(
        _Box(
          label: context.t('Country'),
          child: TextField(
            controller: TextEditingController(text: context.t('India')),
            readOnly: true,
            showCursor: false,
            enableInteractiveSelection: false,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        _Box(
          label: '${context.t('PIN code')} *',
          // No maxLength (its hidden counter made this box taller than the others).
          child: TextField(
            controller: pin,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
            style: const TextStyle(fontWeight: FontWeight.w600),
            onChanged: (t) => setState(() => v.pin = t),
          ),
        ),
      ),
      if (pinError != null) Padding(padding: const EdgeInsets.only(left: 4, top: 0, bottom: 8), child: Text(pinError!, style: const TextStyle(color: C.red, fontSize: 12))),
    ]);
  }
}

// ============================================================ dumbbell spinner

/// Gym-style loader: a dumbbell lifting up and down (or a wave of dumbbells).
class DumbbellSpinner extends StatefulWidget {
  const DumbbellSpinner({super.key, this.size = 46, this.wave = false, this.color});
  final double size;
  final bool wave;
  final Color? color;
  @override
  State<DumbbellSpinner> createState() => _DumbbellSpinnerState();
}

class _DumbbellSpinnerState extends State<DumbbellSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final col = widget.color ?? C.orange;
    return AnimatedBuilder(
      animation: a,
      builder: (_, __) {
        if (!widget.wave) {
          final t = math.sin(a.value * 2 * math.pi);
          return Transform.translate(
            offset: Offset(0, -t * widget.size * 0.14),
            child: Transform.rotate(angle: -0.35 + t * 0.12, child: CustomPaint(size: Size(widget.size, widget.size * 0.6), painter: _DumbbellPainter(col))),
          );
        }
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < 5; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Transform.translate(
                offset: Offset(0, -math.max(0, math.sin((a.value - i * 0.12) * 2 * math.pi)) * widget.size * 0.4),
                child: CustomPaint(size: Size(widget.size * 0.62, widget.size * 0.38), painter: _DumbbellPainter(col)),
              ),
            ),
        ]);
      },
    );
  }
}

class _DumbbellPainter extends CustomPainter {
  _DumbbellPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()..color = color;
    final h = s.height;
    final w = s.width;
    final r = Radius.circular(h * 0.12);
    // bar
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.2, h * 0.42, w * 0.6, h * 0.16), r), p);
    // plates
    for (final x in [0.0, w * 0.82]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, h * 0.1, w * 0.1, h * 0.8), r), p);
    }
    for (final x in [w * 0.1, w * 0.72]) {
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(x, h * 0.2, w * 0.1, h * 0.6), r), p);
    }
  }

  @override
  bool shouldRepaint(_DumbbellPainter o) => o.color != color;
}

/// Dark screen cover with the spinner and a line of text ("Logging in…").
class BusyCover extends StatelessWidget {
  const BusyCover({super.key, required this.text, this.wave = false});
  final String text;
  final bool wave;
  @override
  Widget build(BuildContext context) => Positioned.fill(
        child: AbsorbPointer(
          child: Container(
            color: Colors.black.withAlpha(150),
            alignment: Alignment.center,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (wave)
                const DumbbellSpinner(size: 44, wave: true)
              else
                Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(color: const Color(0xFF15171C), borderRadius: BorderRadius.circular(26), boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 10))]),
                  alignment: Alignment.center,
                  child: const DumbbellSpinner(size: 58),
                ),
              const SizedBox(height: 16),
              Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
            ]),
          ),
        ),
      );
}
