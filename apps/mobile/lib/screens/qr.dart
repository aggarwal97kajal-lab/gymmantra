import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

/// Rotating check-in QR. Refreshes a little before each 30-second window ends.
class QrScreen extends ConsumerStatefulWidget {
  const QrScreen({super.key});
  @override
  ConsumerState<QrScreen> createState() => _QrState();
}

class _QrState extends ConsumerState<QrScreen> {
  String? memberId;
  Map? qr;
  String? error;
  Timer? timer;
  int secondsLeft = 0;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> fetch() async {
    if (memberId == null) return;
    try {
      final r = await Api.instance.get('/me/qr/$memberId');
      if (!mounted) return;
      setState(() {
        qr = r as Map;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void tick() {
    final exp = qr == null ? null : DateTime.parse(qr!['expiresAt']);
    final left = exp == null ? 0 : exp.difference(DateTime.now()).inSeconds;
    setState(() => secondsLeft = left.clamp(0, 30));
    if (left <= 2) fetch();
  }

  void select(String id) {
    if (memberId == id) return;
    memberId = id;
    qr = null;
    fetch();
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  @override
  Widget build(BuildContext context) {
    final gyms = ref.watch(gymsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('QR check-in')),
      body: AsyncBody(
        value: gyms,
        onRetry: () => ref.invalidate(gymsProvider),
        builder: (d) {
          final list = (d['memberships'] as List).cast<Map>();
          if (list.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Muted('Join a gym first to get your check-in QR.')));
          final selected = list.firstWhere((m) => m['memberId'] == memberId, orElse: () => list.first);
          WidgetsBinding.instance.addPostFrameCallback((_) => select(selected['memberId'] as String));
          return ListView(padding: const EdgeInsets.all(20), children: [
            if (list.length > 1)
              Wrap(spacing: 8, children: [
                for (final m in list)
                  ChoiceChip(label: Text(m['gym']['name']), selected: m['memberId'] == selected['memberId'], onSelected: (_) => setState(() => select(m['memberId'] as String))),
              ]),
            const SizedBox(height: 12),
            Center(child: Text(selected['gym']['name'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            const SizedBox(height: 4),
            Center(child: StatusChip(selected['status'] as String)),
            const SizedBox(height: 18),
            Center(
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                child: qr == null
                    ? const SizedBox(width: 240, height: 240, child: Center(child: CircularProgressIndicator(color: C.ink)))
                    : QrImageView(data: qr!['token'] as String, size: 240, backgroundColor: Colors.white),
              ),
            ),
            const SizedBox(height: 14),
            Center(child: Muted(qr == null ? 'Loading…' : 'New code in $secondsLeft s · show this at the front desk')),
            ErrorText(error),
            const SizedBox(height: 18),
            if (qr != null)
              Panel(
                child: Row(children: [
                  const Icon(Icons.calendar_month, color: C.lime),
                  const SizedBox(width: 12),
                  Expanded(child: Text('${qr!['visitsThisMonth']} visits this month', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Muted('${qr!['memberCode']}'),
                ]),
              ),
            const SizedBox(height: 12),
            const Muted('The code changes every 30 seconds, so a screenshot will not work.', size: 12),
          ]);
        },
      ),
    );
  }
}
