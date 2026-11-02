import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../api.dart';
import '../i18n.dart';
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
  bool fetching = false;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> fetch() async {
    final id = memberId;
    if (id == null || fetching) return;
    fetching = true;
    try {
      final r = await Api.instance.get('/me/qr/$id');
      if (!mounted || id != memberId) return;
      setState(() {
        qr = r as Map;
        error = null;
      });
      tick();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      fetching = false;
    }
  }

  void tick() {
    final exp = qr == null ? null : DateTime.tryParse(qr!['expiresAt'] as String? ?? '');
    final left = exp == null ? 0 : exp.difference(DateTime.now()).inSeconds;
    if (mounted) setState(() => secondsLeft = left.clamp(0, 30));
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
    final p = context.c;
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Check-in'))),
      body: AsyncBody(
        value: gyms,
        onRetry: () => ref.invalidate(gymsProvider),
        loading: const Padding(padding: EdgeInsets.all(18), child: Shimmer(child: Bone(height: 420, radius: 24))),
        builder: (d) {
          final list = (d['memberships'] as List).cast<Map>();
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.qr_code_2_rounded, size: 64, color: p.mut),
                  const SizedBox(height: 10),
                  Muted(context.t('Join a gym first to get your check-in QR.'), align: TextAlign.center, size: 14),
                  const SizedBox(height: 16),
                  SizedBox(width: 200, child: FilledButton(onPressed: () => context.push('/join'), child: Text(context.t('Enter gym code')))),
                ]),
              ),
            );
          }
          final selected = list.firstWhere((m) => m['memberId'] == memberId, orElse: () => list.first);
          if (memberId != selected['memberId']) WidgetsBinding.instance.addPostFrameCallback((_) => select(selected['memberId'] as String));
          final daysLeft = selected['daysLeft'] as int?;
          return ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 24), children: [
            if (list.length > 1) ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in list)
                  ChoiceChip(
                    label: Text(m['gym']['name']),
                    selected: m['memberId'] == selected['memberId'],
                    onSelected: (_) => setState(() => select(m['memberId'] as String)),
                  ),
              ]),
              const SizedBox(height: 12),
            ],
            Panel(
              radius: 24,
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
              child: Column(children: [
                Text(selected['gym']['name'], textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                StatusChip(selected['status'] as String, extra: daysLeft != null && daysLeft >= 0 ? context.t('{n} days left', {'n': daysLeft}) : null),
                const SizedBox(height: 18),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    key: ValueKey(qr?['token']),
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
                    child: qr == null
                        ? const SizedBox(width: 236, height: 236, child: Center(child: CircularProgressIndicator(color: C.orange)))
                        : Stack(alignment: Alignment.center, children: [
                            QrImageView(
                              data: qr!['token'] as String,
                              size: 236,
                              padding: EdgeInsets.zero,
                              backgroundColor: Colors.white,
                              errorCorrectionLevel: QrErrorCorrectLevel.H,
                              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: C.night),
                              dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: C.night),
                            ),
                            Container(
                              padding: const EdgeInsets.all(5),
                              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                              child: const Logo(size: 38, mark: C.night),
                            ),
                          ]),
                  ),
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    width: 180,
                    height: 5,
                    child: LinearProgressIndicator(value: qr == null ? null : secondsLeft / 30, backgroundColor: p.surf2, color: C.orange),
                  ),
                ),
                const SizedBox(height: 10),
                Muted(qr == null ? context.t('Loading…') : context.t('New code in {s} s · show this at the front desk', {'s': secondsLeft}), align: TextAlign.center),
              ]),
            ),
            ErrorText(error),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _Box(value: '${qr?['visitsThisMonth'] ?? selected['visitsThisMonth'] ?? 0}', label: context.t('Visits this month'))),
              const SizedBox(width: 12),
              Expanded(child: _Box(value: '${selected['memberCode']}', label: context.t('Member ID'))),
            ]),
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.lock_clock_outlined, size: 15, color: p.mut),
              const SizedBox(width: 6),
              Flexible(child: Muted(context.t('The code changes every 30 seconds, so a screenshot will not work.'), size: 12, align: TextAlign.center)),
            ]),
          ]);
        },
      ),
    );
  }
}

class _Box extends StatelessWidget {
  const _Box({required this.value, required this.label});
  final String value;
  final String label;
  @override
  Widget build(BuildContext context) => Panel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Muted(label, size: 12),
        ]),
      );
}
