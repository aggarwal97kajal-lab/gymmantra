import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../photo.dart';
import '../prefs.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';
import 'home.dart' show openUrl, waLink;

final subscriptionProvider = StreamProvider.autoDispose<dynamic>((ref) => Api.instance.cachedGet('/subscription'));

// ============================================================ plan ring

const ringColors = {
  'trial': [Color(0xFF22C55E), Color(0xFF86EFAC)],
  'starter': [Color(0xFF60A5FA), Color(0xFFC7D2FE)],
  'growth': [C.orange, Color(0xFFFDBA74)],
  'pro': [Color(0xFFF59E0B), Color(0xFFFDE68A)],
};

/// Glowing, slowly turning ring around the owner's photo in their plan's colour.
class GlowRing extends StatefulWidget {
  const GlowRing({super.key, required this.ring, required this.child, required this.size, this.label = true});
  final String? ring;
  final Widget child;
  final double size;
  final bool label;
  @override
  State<GlowRing> createState() => _GlowRingState();
}

class _GlowRingState extends State<GlowRing> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();
  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cols = ringColors[widget.ring];
    if (cols == null) return widget.child;
    final s = widget.size + 10;
    final name = {'trial': 'TRIAL', 'starter': 'STARTER', 'growth': 'GROWTH', 'pro': 'PRO'}[widget.ring]!;
    return RepaintBoundary(child: SizedBox(
      width: s,
      height: s + (widget.label ? 6 : 0),
      child: Stack(clipBehavior: Clip.none, alignment: Alignment.topCenter, children: [
        AnimatedBuilder(
          animation: a,
          builder: (_, __) => Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: SweepGradient(colors: [cols[0], cols[1], cols[0], cols[1], cols[0]], transform: GradientRotation(a.value * 2 * math.pi)),
              boxShadow: [BoxShadow(color: cols[0].withAlpha((110 + 60 * math.sin(a.value * 2 * math.pi)).round().clamp(0, 255)), blurRadius: s * 0.22, spreadRadius: 1)],
            ),
          ),
        ),
        Positioned(top: 3, child: Container(width: s - 6, height: s - 6, decoration: BoxDecoration(shape: BoxShape.circle, color: context.c.bg))),
        Positioned(top: 5, child: widget.child),
        if (widget.label)
          Positioned(
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(gradient: LinearGradient(colors: cols), borderRadius: BorderRadius.circular(99)),
              child: Text(name, style: TextStyle(fontSize: math.max(8.5, widget.size * 0.13), fontWeight: FontWeight.w800, color: const Color(0xFF111827))),
            ),
          ),
      ]),
    ));
  }
}

/// Owner photo with their plan ring.
class OwnerAvatar extends ConsumerWidget {
  const OwnerAvatar({super.key, this.size = 46, this.label = true});
  final double size;
  final bool label;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final u = ref.watch(sessionProvider).user ?? {};
    final ring = ref.watch(subscriptionProvider).valueOrNull?['ring'] as String?;
    return GlowRing(ring: ring, size: size, label: label, child: Avatar(name: (u['name'] as String?) ?? '', url: u['photoUrl'] as String?, size: size));
  }
}

// ============================================================ locks

const featureNames = {'offers': 'Offers', 'pt': 'Trainers and PT', 'reports': 'Reports', 'branches': 'More branches'};
const featurePlan = {'offers': 'Growth', 'pt': 'Growth', 'reports': 'Pro', 'branches': 'Pro'};

bool isUnlocked(WidgetRef ref, String key) {
  final sub = ref.watch(subscriptionProvider).valueOrNull;
  if (sub == null) return true; // unknown yet: let the server decide
  return ((sub['unlocks'] as List?) ?? const []).contains(key);
}

/// Shows the upgrade sheet when a feature is locked. Returns true if it is open.
Future<bool> checkUnlocked(BuildContext context, WidgetRef ref, String key) async {
  if (isUnlocked(ref, key)) return true;
  await showModalBottomSheet(context: context, isScrollControlled: true, builder: (_) => LockSheet(feature: key));
  return false;
}

class LockChip extends StatelessWidget {
  const LockChip(this.plan, {super.key});
  final String plan;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: context.c.surf2, borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_rounded, size: 13, color: context.c.mut),
          const SizedBox(width: 4),
          Text(plan, style: TextStyle(color: context.c.mut, fontWeight: FontWeight.w700, fontSize: 12)),
        ]),
      );
}

class LockSheet extends ConsumerWidget {
  const LockSheet({super.key, required this.feature});
  final String feature;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sub = ref.watch(subscriptionProvider).valueOrNull;
    final planName = featurePlan[feature] ?? 'Growth';
    final plan = ((sub?['plans'] as List?) ?? const []).cast<Map>().where((p) => p['name'] == planName).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(colors: [C.orangeSoft, C.orangeDeep]),
            boxShadow: [BoxShadow(color: C.orange.withAlpha(110), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: const Icon(Icons.lock_rounded, color: Colors.white, size: 34),
        ),
        const SizedBox(height: 14),
        Text(context.t('{feature} is in the {plan} plan', {'feature': context.t(featureNames[feature] ?? feature), 'plan': planName}), textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Muted(context.t('Upgrade to unlock it for your gym.'), align: TextAlign.center),
        if (plan != null) ...[
          const SizedBox(height: 14),
          Panel(
            color: context.c.surf2,
            child: Column(children: [
              Row(children: [Expanded(child: Muted(planName)), Text('${rupees(plan['monthlyPrice'] as num?)} / ${context.t('month')}', style: TextStyle(fontWeight: FontWeight.w800, color: context.c.primary))]),
              const SizedBox(height: 4),
              Row(children: [Expanded(child: Muted(context.t('or yearly'))), Text(rupees(plan['annualPrice'] as num?), style: const TextStyle(fontWeight: FontWeight.w700))]),
            ]),
          ),
          const SizedBox(height: 10),
          for (final f in (plan['features'] as List).cast<String>())
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [const Icon(Icons.check_rounded, color: C.ok, size: 17), const SizedBox(width: 8), Expanded(child: Text(f, style: const TextStyle(fontSize: 13.5)))]),
            ),
        ],
        const SizedBox(height: 14),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            context.push('/o/subscription');
          },
          child: Text(context.t('Upgrade to {plan}', {'plan': planName})),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t('Not now'))),
      ]),
    );
  }
}

// ============================================================ subscription

class SubscriptionScreen extends ConsumerStatefulWidget {
  const SubscriptionScreen({super.key});
  @override
  ConsumerState<SubscriptionScreen> createState() => _SubscriptionState();
}

class _SubscriptionState extends ConsumerState<SubscriptionScreen> {
  bool yearly = true;

  void buy(Map plan, Map sub) {
    final gym = ref.read(sessionProvider).myGym ?? {};
    final wa = sub['supportWhatsapp'] as String?;
    final price = yearly ? plan['annualPrice'] : plan['monthlyPrice'];
    final text = 'Hi GymMantra, ${gym['name']} (${gym['gymCode']}) wants the ${plan['name']} plan (${yearly ? 'yearly' : 'monthly'}, ₹$price).';
    if (wa == null) {
      toast(context, context.t('Online payment is coming soon. Contact GymMantra support from Help.'));
      return;
    }
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${plan['name']} · ${rupees(price as num?)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Muted(context.t('Pay by UPI to GymMantra. Send us a message on WhatsApp — we turn on your plan and your receipt appears here.')),
          const SizedBox(height: 16),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: C.wa),
            onPressed: () {
              Navigator.pop(ctx);
              openUrl(waLink(wa, text));
            },
            icon: const Icon(Icons.chat_rounded),
            label: Text(context.t('Message GymMantra on WhatsApp')),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(subscriptionProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Subscription'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(subscriptionProvider),
        child: AsyncBody(
          value: v,
          onRetry: () => ref.invalidate(subscriptionProvider),
          builder: (d) {
            final plans = (d['plans'] as List).cast<Map>();
            final bills = (d['bills'] as List).cast<Map>();
            final cur = d['plan'] as Map?;
            final usage = d['usage'] as Map;
            return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
              Center(child: const OwnerAvatar(size: 70)),
              const SizedBox(height: 14),
              if (d['inTrial'] == true) _TrialCard(daysLeft: d['trialDaysLeft'] as int, total: d['trialTotalDays'] as int, endsAt: d['trialEndsAt'] as String?)
              else if (cur != null)
                Panel(
                  child: Row(children: [
                    const IconTile(Icons.workspace_premium_rounded, size: 46),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(context.t('{plan} plan', {'plan': cur['name']}), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
                        Muted(context.t('Active till {date}', {'date': fmtDate(d['planEndsAt'] as String?)}), size: 12.5),
                      ]),
                    ),
                    StatusChip('ACTIVE'),
                  ]),
                )
              else
                Panel(
                  color: C.red.withAlpha(24),
                  child: Row(children: [
                    const IconTile(Icons.lock_clock_rounded, color: C.red, size: 46),
                    const SizedBox(width: 12),
                    Expanded(child: Text(context.t('Your free trial has ended. Choose a plan to unlock features again.'), style: const TextStyle(fontWeight: FontWeight.w700))),
                  ]),
                ),
              const SizedBox(height: 16),
              Seg<bool>(value: yearly, items: [(false, context.t('Monthly'), null), (true, context.t('Yearly · 2 months free'), null)], onChanged: (v) => setState(() => yearly = v)),
              const SizedBox(height: 12),
              for (final p in plans)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _PlanCard(plan: p, yearly: yearly, current: cur?['id'] == p['id'], onBuy: () => buy(p, d)),
                ),
              const SizedBox(height: 4),
              SectionTitle(context.t('Usage')),
              Panel(
                child: Column(children: [
                  _UsageRow(context.t('Members'), usage['members'] as int? ?? 0, null),
                  const SizedBox(height: 10),
                  _UsageRow(context.t('Trainers'), usage['trainers'] as int? ?? 0, null),
                  const SizedBox(height: 10),
                  _UsageRow(context.t('Branches'), usage['branches'] as int? ?? 1, null),
                ]),
              ),
              const SizedBox(height: 16),
              SectionTitle(context.t('Plan history')),
              if (bills.isEmpty) Muted(context.t('No bills yet.')),
              for (final b in bills)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Panel(
                    onTap: () => context.push('/o/bill/${b['id']}'),
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      const IconTile(Icons.receipt_long_rounded, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${b['planName']} · ${context.t(b['cycle'] == 'ANNUAL' ? '1 year' : '1 month')}', style: const TextStyle(fontWeight: FontWeight.w800)),
                          Muted('${fmtDate(b['periodStart'] as String?)} – ${fmtDate(b['periodEnd'] as String?)} · ${b['number']}', size: 11.5),
                        ]),
                      ),
                      Text(rupees(b['total'] as num?), style: const TextStyle(fontWeight: FontWeight.w800)),
                    ]),
                  ),
                ),
              if (d['inTrial'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Muted(context.t('Free trial · {date}', {'date': fmtDate(d['trialEndsAt'] as String?)}), size: 12),
                ),
            ]);
          },
        ),
      ),
    );
  }
}

class _TrialCard extends StatelessWidget {
  const _TrialCard({required this.daysLeft, required this.total, required this.endsAt});
  final int daysLeft;
  final int total;
  final String? endsAt;
  @override
  Widget build(BuildContext context) {
    final frac = total == 0 ? 0.0 : (daysLeft / total).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), gradient: const LinearGradient(colors: [Color(0xFF15803D), Color(0xFF22C55E)])),
      child: Row(children: [
        SizedBox(
          width: 78,
          height: 78,
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0.0, end: frac),
            duration: const Duration(milliseconds: 900),
            builder: (_, v, __) => Stack(alignment: Alignment.center, children: [
              SizedBox(width: 78, height: 78, child: CircularProgressIndicator(value: v, strokeWidth: 8, color: Colors.white, backgroundColor: Colors.white.withAlpha(64))),
              Text('$daysLeft', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 22)),
            ]),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.t('Free trial · all unlocked 🔓'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(context.t('{n} days left', {'n': daysLeft}), style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
            Text(context.t('Ends {date}. After that, your plan decides the features.', {'date': fmtDate(endsAt)}), style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 12)),
          ]),
        ),
      ]),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.plan, required this.yearly, required this.current, required this.onBuy});
  final Map plan;
  final bool yearly;
  final bool current;
  final VoidCallback onBuy;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final key = (plan['name'] as String).toLowerCase();
    final cols = ringColors[key.contains('starter') ? 'starter' : key.contains('pro') ? 'pro' : 'growth']!;
    final unlocks = (plan['unlocks'] as List).cast<String>();
    return Material(
      color: p.surf,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: current ? p.primary : p.line, width: current ? 2 : 1)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: cols))),
            const SizedBox(width: 8),
            Expanded(child: Text(plan['name'] as String, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17))),
            if (current)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: p.primary, borderRadius: BorderRadius.circular(99)),
                child: Text(context.t('Your plan'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
              ),
          ]),
          const SizedBox(height: 6),
          Text.rich(TextSpan(children: [
            TextSpan(text: rupees((yearly ? plan['annualPrice'] : plan['monthlyPrice']) as num?), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            TextSpan(text: ' / ${context.t(yearly ? 'year' : 'month')}', style: TextStyle(color: p.mut)),
          ])),
          const SizedBox(height: 8),
          for (final k in ['offers', 'pt', 'reports', 'branches'])
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(children: [
                Icon(unlocks.contains(k) ? Icons.check_rounded : Icons.lock_rounded, size: 16, color: unlocks.contains(k) ? C.ok : p.mut),
                const SizedBox(width: 8),
                Text(context.t(featureNames[k]!), style: TextStyle(fontSize: 13, color: unlocks.contains(k) ? p.fg : p.mut)),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(children: [
              const Icon(Icons.check_rounded, size: 16, color: C.ok),
              const SizedBox(width: 8),
              Text(plan['memberLimit'] == null ? context.t('Unlimited members') : context.t('Up to {n} members', {'n': plan['memberLimit']}), style: const TextStyle(fontSize: 13)),
            ]),
          ),
          const SizedBox(height: 10),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44), backgroundColor: current ? p.surf2 : p.primary, foregroundColor: current ? p.fg : Colors.white),
            onPressed: onBuy,
            child: Text(current ? context.t('Renew') : context.t('Choose {plan}', {'plan': plan['name']})),
          ),
        ]),
      ),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow(this.label, this.value, this.limit);
  final String label;
  final int value;
  final int? limit;
  @override
  Widget build(BuildContext context) => Row(children: [Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))), Text(limit == null ? '$value' : '$value / $limit', style: const TextStyle(fontWeight: FontWeight.w800))]);
}

// ============================================================ receipt

String _amountInWords(num n) {
  const ones = ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen'];
  const tens = ['', '', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety'];
  String two(int x) => x < 20 ? ones[x] : '${tens[x ~/ 10]}${x % 10 > 0 ? '-${ones[x % 10]}' : ''}';
  String three(int x) => x >= 100 ? '${ones[x ~/ 100]} hundred${x % 100 > 0 ? ' ${two(x % 100)}' : ''}' : two(x);
  String words(int x) {
    if (x == 0) return 'zero';
    final parts = <String>[];
    if (x >= 10000000) {
      parts.add('${words(x ~/ 10000000)} crore');
      x %= 10000000;
    }
    if (x >= 100000) {
      parts.add('${two(x ~/ 100000)} lakh');
      x %= 100000;
    }
    if (x >= 1000) {
      parts.add('${two(x ~/ 1000)} thousand');
      x %= 1000;
    }
    if (x > 0) parts.add(three(x));
    return parts.join(' ');
  }

  final rupeesPart = n.floor();
  final paise = ((n - rupeesPart) * 100).round();
  final s = '${words(rupeesPart)} rupees${paise > 0 ? ' and ${two(paise)} paise' : ''} only';
  return s[0].toUpperCase() + s.substring(1);
}

final _billProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, id) => Api.instance.cachedGet('/subscription/bills/$id'));

class BillScreen extends ConsumerWidget {
  const BillScreen({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = ref.watch(_billProvider(id));
    return Scaffold(
      backgroundColor: const Color(0xFFE9ECF1),
      appBar: AppBar(
        backgroundColor: const Color(0xFFE9ECF1),
        foregroundColor: const Color(0xFF0F172A),
        title: Text(context.t('Receipt')),
        actions: [
          IconButton(
            tooltip: context.t('Copy details'),
            onPressed: () {
              final b = v.valueOrNull;
              if (b == null) return;
              Clipboard.setData(ClipboardData(text: 'GymMantra ${b['number']} · ${b['planName']} · ₹${b['total']} · ${fmtDate(b['paidAt'] as String?)}'));
              toast(context, context.t('Copied'));
            },
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(_billProvider(id)),
        builder: (b) => ListView(padding: const EdgeInsets.fromLTRB(12, 4, 12, 24), children: [ReceiptPaper(bill: b as Map)]),
      ),
    );
  }
}

/// The receipt / tax invoice, always on white paper (also in dark mode).
class ReceiptPaper extends StatelessWidget {
  const ReceiptPaper({super.key, required this.bill});
  final Map bill;
  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF0F172A);
    const mut = Color(0xFF64748B);
    final gst = bill['gst'] as Map?;
    final gym = bill['gym'] as Map;
    final seller = bill['seller'] as Map;
    final invoice = bill['kind'] == 'TAX_INVOICE';
    TextStyle t(double s, {FontWeight w = FontWeight.w500, Color c = ink}) => TextStyle(fontSize: s, fontWeight: w, color: c, height: 1.4);
    Widget kv(String k, String v) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(k, style: t(10.5, c: mut)), Text(v, style: t(12, w: FontWeight.w700))]));
    Widget money(String k, num v, {bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [Expanded(child: Text(k, style: t(12, w: bold ? FontWeight.w800 : FontWeight.w500))), Text(v.toStringAsFixed(2), style: t(12, w: bold ? FontWeight.w800 : FontWeight.w600))]),
        );
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 16, offset: Offset(0, 6))]),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(height: 6, decoration: const BoxDecoration(gradient: LinearGradient(colors: [C.orangeSoft, C.orangeDeep]))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Logo(size: 34, mark: ink),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Wordmark(size: 16, color: ink),
                  Text(seller['name'] as String? ?? 'GymMantra', style: t(10, c: mut)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(invoice ? 'TAX INVOICE' : 'PAYMENT RECEIPT', style: t(12.5, w: FontWeight.w800)),
                Stack(children: [
                  Transform.rotate(
                    angle: -0.2,
                    child: Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF16A34A), width: 2), borderRadius: BorderRadius.circular(5)),
                      child: Text('PAID', style: t(13, w: FontWeight.w900, c: const Color(0xFF16A34A))),
                    ),
                  ),
                ]),
              ]),
            ]),
            if (seller['address'] != null || seller['gstin'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text([seller['address'], if (seller['gstin'] != null) 'GSTIN ${seller['gstin']}'].whereType<String>().join(' · '), style: t(10.5, c: mut)),
              ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(6)),
              child: Column(children: [
                Row(children: [kv(invoice ? 'Invoice no.' : 'Receipt no.', bill['number'] as String), kv('Date', fmtDate(bill['paidAt'] as String?))]),
                const SizedBox(height: 8),
                Row(children: [
                  kv('Payment', [bill['mode'] == 'BANK_TRANSFER' ? 'Bank' : bill['mode'], bill['ref']].whereType<String>().join(' · ')),
                  kv(gst != null ? 'Place of supply' : 'Status', gst != null ? '${gym['state'] ?? ''} (${gst['placeOfSupply']})' : 'Paid'),
                ]),
              ]),
            ),
            const SizedBox(height: 12),
            Text(invoice ? 'BILL TO' : 'RECEIVED FROM', style: t(9.5, w: FontWeight.w800, c: mut)),
            Text(gym['name'] as String, style: t(13, w: FontWeight.w800)),
            if (gym['address'] != null) Text('${gym['address']}${gym['state'] != null ? ', ${gym['state']}' : ''}', style: t(11, c: const Color(0xFF475569))),
            if (gym['gstin'] != null) Text('GSTIN: ${gym['gstin']}', style: t(11, c: const Color(0xFF475569))),
            if (gym['ownerName'] != null) Text('Owner: ${gym['ownerName']}${gym['ownerPhone'] != null ? ' · ${gym['ownerPhone']}' : ''}', style: t(11, c: const Color(0xFF475569))),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: ink,
              child: Row(children: [
                Expanded(child: Text('Description', style: t(11, w: FontWeight.w700, c: Colors.white))),
                if (invoice) SizedBox(width: 56, child: Text('SAC', textAlign: TextAlign.center, style: t(11, w: FontWeight.w700, c: Colors.white))),
                Text('Amount ₹', style: t(11, w: FontWeight.w700, c: Colors.white)),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('GymMantra ${bill['planName']} plan', style: t(12, w: FontWeight.w700)),
                    Text('${bill['cycle'] == 'ANNUAL' ? '12 months' : '1 month'} · ${fmtDate(bill['periodStart'] as String?)} – ${fmtDate(bill['periodEnd'] as String?)}', style: t(10.5, c: mut)),
                  ]),
                ),
                if (invoice) SizedBox(width: 56, child: Text('998314', textAlign: TextAlign.center, style: t(11))),
                Text((bill['taxable'] as num).toStringAsFixed(2), style: t(12, w: FontWeight.w600)),
              ]),
            ),
            const Divider(color: Color(0xFFE2E8F0), height: 1),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 110),
              child: Column(children: [
                money(invoice ? 'Taxable value' : 'Subtotal', bill['taxable'] as num),
                if (gst != null && gst['type'] == 'CGST_SGST') ...[
                  money('CGST @ ${(gst['rate'] as num) / 2}%', gst['cgst'] as num),
                  money('SGST @ ${(gst['rate'] as num) / 2}%', gst['sgst'] as num),
                ],
                if (gst != null && gst['type'] == 'IGST') money('IGST @ ${gst['rate']}%', gst['igst'] as num),
                const Divider(color: ink, thickness: 1.4, height: 10),
                Row(children: [
                  Expanded(child: Text(invoice ? 'Total' : 'Total paid', style: t(13.5, w: FontWeight.w800))),
                  Text('₹${(bill['total'] as num).toStringAsFixed(2)}', style: t(13.5, w: FontWeight.w800, c: C.orangeDeep)),
                ]),
              ]),
            ),
            const SizedBox(height: 10),
            Text.rich(TextSpan(children: [TextSpan(text: 'Amount in words: ', style: t(11, c: mut)), TextSpan(text: _amountInWords(bill['total'] as num), style: t(11, w: FontWeight.w700))])),
            const SizedBox(height: 22),
            Align(
              alignment: Alignment.centerRight,
              child: Column(children: [
                Text('GymMantra', style: t(14, w: FontWeight.w600, c: const Color(0xFF334155)).copyWith(fontStyle: FontStyle.italic)),
                Container(width: 110, height: 1, color: const Color(0xFF94A3B8)),
                Text('Authorised signatory', style: t(9.5, c: mut)),
              ]),
            ),
            const SizedBox(height: 14),
            Container(height: 1, color: const Color(0xFFCBD5E1)),
            const SizedBox(height: 6),
            Text('Computer generated ${invoice ? 'invoice' : 'receipt'} · Thank you for choosing GymMantra', style: t(9.5, c: const Color(0xFF94A3B8))),
          ]),
        ),
      ]),
    );
  }
}

// ============================================================ address (State → City → PIN)

class IndiaState {
  IndiaState(this.name, this.code, this.pins, this.cities);
  final String name;
  final String code;
  final List<String> pins;
  final List<String> cities;
}

List<IndiaState>? _india;
Future<List<IndiaState>> loadIndia() async {
  if (_india != null) return _india!;
  final raw = jsonDecode(await rootBundle.loadString('assets/india.json')) as Map;
  _india = [
    for (final s in (raw['states'] as List).cast<Map>()) IndiaState(s['name'] as String, s['code'] as String, (s['pins'] as List).cast<String>(), (s['cities'] as List).cast<String>()),
  ];
  return _india!;
}

class Address {
  String line = '';
  String? state;
  String? city;
  String pin = '';
  String gstin = '';
  Map<String, dynamic> toJson() => {'addressLine': line.trim(), 'state': state, 'city': city, 'pincode': pin.trim(), if (gstin.trim().isNotEmpty) 'gstin': gstin.trim().toUpperCase()};
}

/// Address fields with searchable State and City pickers and a PIN check.
class AddressFields extends StatefulWidget {
  const AddressFields({super.key, required this.value});
  final Address value;
  @override
  State<AddressFields> createState() => _AddressFieldsState();
}

class _AddressFieldsState extends State<AddressFields> {
  List<IndiaState> states = const [];
  late final line = TextEditingController(text: widget.value.line);
  late final pin = TextEditingController(text: widget.value.pin);
  late final gstin = TextEditingController(text: widget.value.gstin);

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
        builder: (_) => _SearchList(title: title, items: items, allowOther: other),
      );

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    Widget selectBox(String label, String? value, String hint, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: InputDecorator(
              decoration: InputDecoration(labelText: '$label *', suffixIcon: Icon(value == null ? Icons.expand_more_rounded : Icons.check_rounded, color: value == null ? null : C.ok), enabled: onTap != null),
              child: Text(value ?? hint, style: TextStyle(color: value == null ? context.c.mut : context.c.fg, fontWeight: FontWeight.w600)),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: line,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(labelText: '${context.t('Address (building / plot, area)')} *', prefixIcon: const Icon(Icons.place_outlined)),
        onChanged: (t) => v.line = t,
      ),
      const SizedBox(height: 12),
      selectBox(context.t('State'), v.state, context.t('Choose state'), () async {
        final s = await pick(context.t('Choose state'), states.map((e) => e.name).toList());
        if (s != null) setState(() {
          v.state = s;
          v.city = null;
        });
      }),
      selectBox(context.t('City'), v.city, st == null ? context.t('Choose state first') : context.t('Choose city'), st == null
          ? null
          : () async {
              final c = await pick(context.t('{state} cities', {'state': st!.name}), st!.cities, other: true);
              if (c != null) setState(() => v.city = c);
            }),
      TextField(
        controller: pin,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: InputDecoration(labelText: '${context.t('PIN code')} *', counterText: '', errorText: pinError, errorMaxLines: 2),
        onChanged: (t) => setState(() => v.pin = t),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: gstin,
        textCapitalization: TextCapitalization.characters,
        maxLength: 15,
        decoration: InputDecoration(labelText: context.t('GSTIN (if you have one)'), counterText: ''),
        onChanged: (t) => v.gstin = t,
      ),
    ]);
  }
}

class _SearchList extends StatefulWidget {
  const _SearchList({required this.title, required this.items, this.allowOther = false});
  final String title;
  final List<String> items;
  final bool allowOther;
  @override
  State<_SearchList> createState() => _SearchListState();
}

class _SearchListState extends State<_SearchList> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final list = widget.items.where((x) => x.toLowerCase().contains(q.toLowerCase())).toList();
    final h = MediaQuery.of(context).size.height * 0.78;
    return SizedBox(
      height: h,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.of(context).viewInsets.bottom),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          TextField(autofocus: false, decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Search…')), onChanged: (t) => setState(() => q = t)),
          const SizedBox(height: 6),
          Expanded(
            child: ListView(children: [
              for (final x in list) ListTile(title: Text(x, style: const TextStyle(fontWeight: FontWeight.w600)), onTap: () => Navigator.pop(context, x)),
              if (widget.allowOther && q.trim().length >= 2 && !list.any((x) => x.toLowerCase() == q.trim().toLowerCase()))
                ListTile(
                  leading: const Icon(Icons.add_rounded),
                  title: Text(context.t('Use "{name}"', {'name': q.trim()})),
                  onTap: () => Navigator.pop(context, q.trim()),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Owner: complete or change the gym address.
class GymAddressScreen extends ConsumerStatefulWidget {
  const GymAddressScreen({super.key});
  @override
  ConsumerState<GymAddressScreen> createState() => _GymAddressState();
}

class _GymAddressState extends ConsumerState<GymAddressScreen> {
  Address? a;
  bool busy = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(gymProvider).valueOrNull;
    if (a == null && g != null) {
      a = Address()
        ..line = (g['addressLine'] as String?) ?? ''
        ..state = g['state'] as String?
        ..city = g['city'] as String?
        ..pin = (g['pincode'] as String?) ?? ''
        ..gstin = (g['gstin'] as String?) ?? '';
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Gym address'))),
      body: a == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              AddressFields(value: a!),
              ErrorText(error),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        setState(() {
                          busy = true;
                          error = null;
                        });
                        final saved = context.t('Saved');
                        try {
                          await Api.instance.patch('/gym', a!.toJson());
                          ref.invalidate(gymProvider);
                          ref.invalidate(subscriptionProvider);
                          if (context.mounted) {
                            toast(context, saved);
                            context.pop();
                          }
                        } catch (e) {
                          setState(() => error = e.toString());
                        } finally {
                          if (mounted) setState(() => busy = false);
                        }
                      },
                child: Text(context.t('Save')),
              ),
            ]),
    );
  }
}

// ============================================================ ads

final adsProvider = StreamProvider.autoDispose.family<dynamic, String>((ref, role) => Api.instance.cachedGet('/ads?role=$role'));

/// "Sponsored" banners chosen by GymMantra. Hidden for the day when closed.
class AdsStrip extends ConsumerStatefulWidget {
  const AdsStrip({super.key, required this.role});
  final String role;
  @override
  ConsumerState<AdsStrip> createState() => _AdsStripState();
}

class _AdsStripState extends ConsumerState<AdsStrip> {
  final reported = <String>{};

  String get today => DateTime.now().toIso8601String().substring(0, 10);
  bool hidden(String id) => Prefs.getString('adHide:$id') == today;

  void seen(String id) {
    if (reported.contains(id) || Prefs.getString('adSeen:$id') == today) return;
    reported.add(id);
    Prefs.setString('adSeen:$id', today);
    Api.instance.post('/ads/$id/event', {'type': 'view', 'role': widget.role}).catchError((_) => null);
  }

  void tap(Map a) {
    Api.instance.post('/ads/${a['id']}/event', {'type': 'click', 'role': widget.role}).catchError((_) => null);
    final v = a['linkValue'] as String?;
    if (v == null) return;
    switch (a['linkKind']) {
      case 'URL':
        openUrl(v);
      case 'WHATSAPP':
        openUrl(waLink(v, 'Hi, I saw your offer on GymMantra.'));
      case 'CALL':
        openUrl('tel:$v');
    }
  }

  Color parse(String? hex) {
    final h = (hex ?? '#2563EB').replaceFirst('#', '');
    return Color(int.tryParse('FF$h', radix: 16) ?? 0xFF2563EB);
  }

  @override
  Widget build(BuildContext context) {
    final list = ((ref.watch(adsProvider(widget.role)).valueOrNull as List?) ?? const []).cast<Map>().where((a) => !hidden(a['id'] as String)).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final a in list.take(2))
        Builder(builder: (_) {
          seen(a['id'] as String);
          final col = parse(a['color'] as String?);
          final img = a['imageUrl'] as String?;
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              color: col,
              child: InkWell(
                onTap: () => tap(a),
                child: Stack(children: [
                  if (img != null)
                    Positioned.fill(child: Image.network(Api.instance.url(img), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox())),
                  if (img != null) Positioned.fill(child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.black.withAlpha(150), Colors.transparent], begin: Alignment.bottomLeft, end: Alignment.topRight)))),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: Colors.black.withAlpha(60), borderRadius: BorderRadius.circular(99)),
                        child: Text(context.t('Sponsored'), style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w700)),
                      ),
                      SizedBox(height: img != null ? 46 : 8),
                      Text(a['title'] as String, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
                      if (a['body'] != null) Text(a['body'] as String, style: const TextStyle(color: Color(0xEEFFFFFF), fontSize: 12.5)),
                    ]),
                  ),
                  Positioned(
                    right: 6,
                    top: 6,
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(backgroundColor: Colors.black.withAlpha(60)),
                      onPressed: () {
                        Prefs.setString('adHide:${a['id']}', today);
                        setState(() {});
                      },
                      icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
    ]);
  }
}
