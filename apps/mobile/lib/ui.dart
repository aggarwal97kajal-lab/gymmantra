export 'drip.dart' show DripKind;
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'drip.dart';
import 'i18n.dart';
import 'photo.dart';
import 'theme.dart';

const _monthsEn = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsHi = ['जन', 'फ़र', 'मार्च', 'अप्रै', 'मई', 'जून', 'जुल', 'अग', 'सित', 'अक्टू', 'नव', 'दिस'];

List<String> _months() => AppLang.current == 'hi' ? _monthsHi : _monthsEn;

DateTime _parse(String s) => s.length == 10 ? DateTime.parse('${s}T00:00:00Z') : DateTime.parse(s).toUtc().add(const Duration(hours: 5, minutes: 30));

/// '2026-11-07' or an ISO timestamp -> '7 Nov 2026' (India time for timestamps).
String fmtDate(String? s) {
  if (s == null || s.isEmpty) return '—';
  final d = _parse(s);
  return '${d.day} ${_months()[d.month - 1]} ${d.year}';
}

String fmtDateTime(String s) {
  final d = _parse(s);
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${d.day} ${_months()[d.month - 1]}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
}

/// Days between an ISO timestamp and today in India (0 = today).
int daysAgo(String iso) {
  final now = DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));
  final d = _parse(iso);
  return DateTime.utc(now.year, now.month, now.day).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
}

String rupees(num? n) {
  final v = (n ?? 0).round();
  final s = v.abs().toString();
  String out;
  if (s.length <= 3) {
    out = s;
  } else {
    final last3 = s.substring(s.length - 3);
    var rest = s.substring(0, s.length - 3);
    final parts = <String>[];
    while (rest.length > 2) {
      parts.insert(0, rest.substring(rest.length - 2));
      rest = rest.substring(0, rest.length - 2);
    }
    if (rest.isNotEmpty) parts.insert(0, rest);
    out = '${parts.join(',')},$last3';
  }
  return '₹${v < 0 ? '-' : ''}$out';
}

String plural(num n, String w) => '$n $w${n == 1 ? '' : 's'}';

String initialsOf(String name) => name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(2).map((w) => w.characters.first.toUpperCase()).join();

// ---------------------------------------------------------------- building blocks

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color, this.onTap, this.radius = 18});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    return Material(
      color: color ?? p.surf,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: p.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: SizedBox(width: double.infinity, child: child))),
    );
  }
}

class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.size = 13, this.align, this.maxLines});
  final String text;
  final double size;
  final TextAlign? align;
  final int? maxLines;
  @override
  Widget build(BuildContext context) =>
      Text(text, textAlign: align, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis, style: TextStyle(color: context.c.mut, fontSize: size, height: 1.35));
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
        child: Row(children: [Expanded(child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800))), if (trailing != null) trailing!]),
      );
}

/// Rounded square with an icon, used in lists and quick actions.
class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color, this.size = 40});
  final IconData icon;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) {
    final col = color ?? context.c.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: col.withAlpha(context.c.dark ? 40 : 28), borderRadius: BorderRadius.circular(size * 0.3)),
      child: Icon(icon, color: col, size: size * 0.5),
    );
  }
}

const statusColors = {
  'ACTIVE': C.ok,
  'ENDING_SOON': C.warn,
  'FROZEN': C.blue,
  'EXPIRED': C.red,
  'NO_PLAN': Color(0xFF8B95A5),
  'UPCOMING': C.blue,
};

String statusLabel(BuildContext context, String s) => switch (s) {
      'ACTIVE' => context.t('Active'),
      'ENDING_SOON' => context.t('Ending soon'),
      'FROZEN' => context.t('Frozen'),
      'EXPIRED' => context.t('Expired'),
      'NO_PLAN' => context.t('No plan'),
      'UPCOMING' => context.t('Starts later'),
      _ => s,
    };

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key, this.onColor = false, this.extra});
  final String status;

  /// White chip for use on the orange card.
  final bool onColor;
  final String? extra;
  @override
  Widget build(BuildContext context) {
    final color = statusColors[status] ?? context.c.mut;
    final label = statusLabel(context, status) + (extra == null ? '' : ' · $extra');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: onColor ? Colors.white.withAlpha(46) : color.withAlpha(36), borderRadius: BorderRadius.circular(99)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: onColor ? Colors.white : color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: onColor ? Colors.white : color, fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.error, {super.key});
  final String? error;
  @override
  Widget build(BuildContext context) {
    if (error == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.red.withAlpha(28), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.red.withAlpha(70))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_outline, color: C.red, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(context.t(error!), style: TextStyle(color: context.c.dark ? const Color(0xFFFFB3B3) : const Color(0xFFB91C1C)))),
      ]),
    );
  }
}

/// Segmented control (Light / Dark / Auto, English / हिन्दी).
class Seg<T> extends StatelessWidget {
  const Seg({super.key, required this.value, required this.items, required this.onChanged});
  final T value;
  final List<(T, String, IconData?)> items;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        for (final (v, label, icon) in items)
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onChanged(v),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 9),
                decoration: BoxDecoration(
                  color: v == value ? p.surf : Colors.transparent,
                  borderRadius: BorderRadius.circular(9),
                  boxShadow: v == value && !p.dark ? const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))] : null,
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (icon != null) ...[Icon(icon, size: 16, color: v == value ? p.primary : p.mut), const SizedBox(width: 6)],
                  Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: v == value ? p.fg : p.mut))),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- loading

/// Soft moving shine over grey boxes, shown while a screen loads for the first time.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;
  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300))..repeat();
  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final base = p.dark ? const Color(0xFF1C2129) : const Color(0xFFE8EBF0);
    final hi = p.dark ? const Color(0xFF2A303B) : const Color(0xFFF7F8FA);
    return AnimatedBuilder(
      animation: a,
      builder: (_, child) => ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (r) => LinearGradient(
          colors: [base, hi, base],
          stops: const [0.35, 0.5, 0.65],
          begin: Alignment(-2.2 + a.value * 4.4, -0.3),
          end: Alignment(-1.2 + a.value * 4.4, 0.3),
        ).createShader(r),
        child: child,
      ),
      child: widget.child,
    );
  }
}

class Bone extends StatelessWidget {
  const Bone({super.key, this.width = double.infinity, required this.height, this.radius = 14});
  final double width, height, radius;
  @override
  Widget build(BuildContext context) =>
      Container(width: width, height: height, decoration: BoxDecoration(color: context.c.dark ? const Color(0xFF1C2129) : const Color(0xFFE8EBF0), borderRadius: BorderRadius.circular(radius)));
}

class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key, this.rows = 4, this.first = 150});
  final int rows;
  final double first;
  @override
  Widget build(BuildContext context) => Shimmer(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Bone(height: first, radius: 22),
          const SizedBox(height: 12),
          const Row(children: [Expanded(child: Bone(height: 74)), SizedBox(width: 12), Expanded(child: Bone(height: 74))]),
          for (var i = 0; i < rows - 2; i++) ...[const SizedBox(height: 12), const Bone(height: 64)],
        ]),
      );
}

/// Shows loading / error / data for a provider value. Data saved on the phone
/// shows straight away, so the skeleton appears only on the very first open.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry, this.loading});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  final Widget? loading;
  @override
  Widget build(BuildContext context) {
    if (value.hasValue) return builder(value.value as T);
    if (value.hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.wifi_off_rounded, color: context.c.mut, size: 36),
            const SizedBox(height: 10),
            Text(value.error.toString(), textAlign: TextAlign.center, style: TextStyle(color: context.c.mut)),
            if (onRetry != null) ...[const SizedBox(height: 14), SizedBox(width: 160, child: OutlinedButton(onPressed: onRetry, child: Text(context.t('Try again'))))],
          ]),
        ),
      );
    }
    return loading ?? const Padding(padding: EdgeInsets.all(16), child: ListSkeleton());
  }
}

/// Shows a drip toast (drips out of the front camera). [kind] is guessed from
/// the words when not given; [detail] and [action] turn it into a card.
void toast(BuildContext context, String msg, {DripKind? kind, String? detail, String? action, VoidCallback? onAction}) {
  Drip.show(context, translate(AppLang.current, msg), kind: kind, detail: detail, action: action, onAction: onAction);
}

/// Error from a failed call.
void toastError(BuildContext context, Object e) => toast(context, e.toString(), kind: DripKind.error);

// ---------------------------------------------------------------- brand

/// Logo C: dumbbell with a heartbeat line, drawn in code so it is sharp at any size.
/// [pulse] 0..1 draws the heartbeat line progressively (used by the splash).
class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 64, this.body = C.orange, this.mark, this.pulse = 1});
  final double size;
  final Color body;
  final Color? mark;
  final double pulse;
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: LogoPainter(body: body, mark: mark ?? context.c.fg, pulse: pulse));
}

class LogoPainter extends CustomPainter {
  LogoPainter({required this.body, required this.mark, this.pulse = 1});
  final Color body, mark;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 120;
    canvas.scale(s);
    final fill = Paint()..color = body;
    for (final r in const [Rect.fromLTWH(10, 34, 14, 52), Rect.fromLTWH(26, 24, 14, 72), Rect.fromLTWH(80, 24, 14, 72), Rect.fromLTWH(96, 34, 14, 52)]) {
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(5)), fill);
    }
    if (pulse <= 0) return;
    final path = Path()
      ..moveTo(40, 60)
      ..lineTo(48, 60)
      ..lineTo(54, 46)
      ..lineTo(63, 74)
      ..lineTo(69, 60)
      ..lineTo(80, 60);
    final stroke = Paint()
      ..color = mark
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (pulse >= 1) {
      canvas.drawPath(path, stroke);
    } else {
      final m = path.computeMetrics().first;
      canvas.drawPath(m.extractPath(0, m.length * pulse), stroke);
    }
  }

  @override
  bool shouldRepaint(LogoPainter old) => old.pulse != pulse || old.body != body || old.mark != mark;
}

class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 28, this.color});
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        TextSpan(text: 'Gym', style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: color ?? context.c.fg, letterSpacing: -size * 0.03)),
        TextSpan(text: 'Mantra', style: TextStyle(fontSize: size, fontWeight: FontWeight.w800, color: C.orange, letterSpacing: -size * 0.03)),
      ]));
}

/// Circular "days left" ring on the membership card.
class DaysRing extends StatelessWidget {
  const DaysRing({super.key, required this.days, required this.fraction, required this.label, this.size = 92});
  final int days;
  final double fraction;
  final String label;
  final double size;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: fraction.clamp(0.0, 1.0)),
        duration: const Duration(milliseconds: 900),
        curve: Curves.easeOutCubic,
        builder: (_, v, __) => SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(v),
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('$days', style: TextStyle(fontSize: size * 0.28, fontWeight: FontWeight.w800, color: C.night, height: 1)),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: size * 0.11, color: const Color(0xFF64748B), fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v);
  final double v;
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = Colors.white);
    final rect = Rect.fromCircle(center: c, radius: r - 9);
    final track = Paint()
      ..color = const Color(0xFFFFE1D4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    final arc = Paint()
      ..color = C.orange
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 7;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * v, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.v != v;
}

/// Purple-orange offer banner shown on member / trainer dashboards.
class OfferBanner extends StatelessWidget {
  const OfferBanner({super.key, required this.title, this.details, this.who, this.validTill, this.imageUrl, this.local});
  final String title;
  final String? details;
  final String? who;
  final String? validTill;

  /// Banner picture uploaded by the owner (or a picture just picked, for the live preview).
  final String? imageUrl;
  final Uint8List? local;
  @override
  Widget build(BuildContext context) {
    if (imageUrl != null || local != null) return _ImageOffer(banner: this);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 15),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFFC026D3), C.orange], stops: [0, 0.55, 1], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned(right: -14, bottom: -26, child: Icon(Icons.local_offer_outlined, size: 96, color: Colors.white.withAlpha(46))),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const _OfferTag(),
            const Spacer(),
            if (who != null) Flexible(child: Text(who!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xDDFFFFFF), fontSize: 11))),
          ]),
          const SizedBox(height: 8),
          Text(title, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
          if (details != null && details!.isNotEmpty) ...[const SizedBox(height: 2), Text(details!, style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 12.5))],
          if (validTill != null) ...[const SizedBox(height: 4), Text(context.t('Till {date}', {'date': fmtDate(validTill)}), style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 11.5, fontWeight: FontWeight.w600))],
        ]),
      ]),
    );
  }
}

class _OfferTag extends StatelessWidget {
  const _OfferTag();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(color: Colors.white.withAlpha(56), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.local_offer_rounded, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(context.t('OFFER'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11)),
        ]),
      );
}

/// Offer with the owner's banner picture (2:1), title and date over a dark fade.
class _ImageOffer extends StatefulWidget {
  const _ImageOffer({required this.banner});
  final OfferBanner banner;
  @override
  State<_ImageOffer> createState() => _ImageOfferState();
}

class _ImageOfferState extends State<_ImageOffer> {
  Uint8List? bytes;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_ImageOffer old) {
    super.didUpdateWidget(old);
    if (old.banner.imageUrl != widget.banner.imageUrl) _load();
  }

  void _load() {
    final u = widget.banner.imageUrl;
    if (u == null) return;
    bytes = PhotoCache.get(u);
    if (bytes == null) {
      PhotoCache.load(u).then((b) {
        if (mounted && widget.banner.imageUrl == u) setState(() => bytes = b);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.banner;
    final img = b.local ?? bytes;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: context.c.surf2),
      child: AspectRatio(
        aspectRatio: 2,
        child: Stack(fit: StackFit.expand, children: [
          if (img != null) Image.memory(img, fit: BoxFit.cover, gaplessPlayback: true) else const Shimmer(child: Bone(height: 400, radius: 0)),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: LinearGradient(colors: [Color(0x00000000), Color(0xB3000000)], begin: Alignment.center, end: Alignment.bottomCenter)),
          ),
          Positioned(left: 12, top: 10, child: const _OfferTag()),
          Positioned(
            left: 14,
            right: 14,
            bottom: 10,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
              if (b.validTill != null || b.who != null)
                Text(
                  [if (b.validTill != null) context.t('Till {date}', {'date': fmtDate(b.validTill)}), if (b.who != null) b.who!].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xDDFFFFFF), fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Gym notice ("Gym closed tomorrow") from the owner, shown on dashboards.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({super.key, required this.title, required this.message, this.gym, this.date});
  final String title;
  final String message;
  final String? gym;
  final String? date;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      decoration: BoxDecoration(
        color: C.warn.withAlpha(p.dark ? 34 : 26),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: C.warn.withAlpha(150), width: 1.3),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: C.warn, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.campaign_rounded, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(context.t('NOTICE'), style: const TextStyle(color: Color(0xFFB45309), fontWeight: FontWeight.w800, fontSize: 11, letterSpacing: 0.6)),
              if (date != null) ...[const Spacer(), Text(fmtDate(date), style: TextStyle(color: p.mut, fontSize: 11))],
            ]),
            // Full gym name (wraps to the next line instead of being cut).
            if (gym != null) Text(gym!, style: TextStyle(color: p.mut, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 3),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(message, style: TextStyle(fontSize: 13.5, height: 1.35, color: p.fg.withAlpha(220))),
          ]),
        ),
      ]),
    );
  }
}

/// Small stat tile (number + label).
class StatTile extends StatelessWidget {
  const StatTile({super.key, required this.icon, required this.value, required this.label, this.color});
  final IconData icon;
  final String value;
  final String label;
  final Color? color;
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.fromLTRB(13, 13, 13, 11),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: color ?? context.c.primary),
            const SizedBox(width: 7),
            Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, height: 1.1))),
          ]),
          const SizedBox(height: 4),
          Muted(label, size: 11.5, maxLines: 1),
        ]),
      );
}
