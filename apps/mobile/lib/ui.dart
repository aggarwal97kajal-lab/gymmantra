import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'theme.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// '2026-11-07' or an ISO timestamp -> '7 Nov 2026' (India time for timestamps).
String fmtDate(String? s) {
  if (s == null || s.isEmpty) return '—';
  DateTime d;
  if (s.length == 10) {
    d = DateTime.parse('${s}T00:00:00Z');
  } else {
    d = DateTime.parse(s).toUtc().add(const Duration(hours: 5, minutes: 30));
  }
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

String fmtDateTime(String s) {
  final d = DateTime.parse(s).toUtc().add(const Duration(hours: 5, minutes: 30));
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${d.day} ${_months[d.month - 1]}, $h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
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

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.color, this.onTap});
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(color: color ?? C.card, borderRadius: BorderRadius.circular(18), border: Border.all(color: C.line)),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(borderRadius: BorderRadius.circular(18), onTap: onTap, child: box);
  }
}

const statusInfo = {
  'ACTIVE': ('Active', C.lime),
  'ENDING_SOON': ('Ending soon', C.org),
  'FROZEN': ('Frozen', C.blue),
  'EXPIRED': ('Expired', C.red),
  'NO_PLAN': ('No plan', C.mut),
  'UPCOMING': ('Starts later', C.blue),
};

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = statusInfo[status] ?? (status, C.mut);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color.withAlpha(36), borderRadius: BorderRadius.circular(99)),
      child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.size = 13});
  final String text;
  final double size;
  @override
  Widget build(BuildContext context) => Text(text, style: TextStyle(color: C.mut, fontSize: size));
}

class ErrorText extends StatelessWidget {
  const ErrorText(this.error, {super.key});
  final String? error;
  @override
  Widget build(BuildContext context) {
    if (error == null) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: C.red.withAlpha(36), borderRadius: BorderRadius.circular(12), border: Border.all(color: C.red.withAlpha(64))),
      child: Text(error!, style: const TextStyle(color: Color(0xFFFFB3B3))),
    );
  }
}

/// Shows loading / error / data for a FutureProvider value.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    return value.when(
      data: builder,
      loading: () => const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: C.lime))),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(e.toString(), textAlign: TextAlign.center, style: const TextStyle(color: C.mut)),
            if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Try again'))],
          ]),
        ),
      ),
    );
  }
}

void toast(BuildContext context, String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 64});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset('assets/mark.png', width: size, height: size);
}

class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 28});
  final double size;
  @override
  Widget build(BuildContext context) => Text.rich(TextSpan(children: [
        TextSpan(text: 'Gym', style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: C.fg, letterSpacing: -0.8)),
        TextSpan(text: 'Mantra', style: TextStyle(fontSize: size, fontWeight: FontWeight.w900, color: C.lime, letterSpacing: -0.8)),
      ]));
}
