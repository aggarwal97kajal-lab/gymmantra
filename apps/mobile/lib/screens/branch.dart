import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

// ---------- Branches: switcher for the owner, transfers for owner and member ----------

List<Map> branchesOf(Map? g) => ((g?['branches'] as List?) ?? const []).whereType<Map>().toList();

/// Owner home: "📍 Dwarka ▾" — the whole owner app shows this branch.
class BranchChip extends ConsumerWidget {
  const BranchChip({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(gymProvider).valueOrNull as Map?;
    final list = branchesOf(g);
    if (list.length < 2) return const SizedBox.shrink();
    final cur = list.firstWhere((b) => b['id'] == g?['currentBranchId'], orElse: () => list.first);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: context.c.surf,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: context.c.primary.withAlpha(90))),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => pickBranch(context, ref),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(Icons.place_rounded, color: context.c.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(cur['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  Muted('${context.t('Code')}: ${cur['code'] ?? '—'} · ${context.t('Tap to switch branch')}', size: 11.5),
                ]),
              ),
              Icon(Icons.expand_more_rounded, color: context.c.mut),
            ]),
          ),
        ),
      ),
    );
  }
}

Future<void> pickBranch(BuildContext context, WidgetRef ref) async {
  final g = ref.read(gymProvider).valueOrNull as Map?;
  final list = branchesOf(g);
  final curId = g?['currentBranchId'] ?? (list.isEmpty ? null : list.first['id']);
  final picked = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ctx.t('Choose branch'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Muted(ctx.t('Members, check-ins, money, offers and notifications will show for this branch.'), size: 12.5),
          ]),
        ),
        for (final b in list)
          ListTile(
            leading: Icon(b['id'] == curId ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded, color: b['id'] == curId ? ctx.c.primary : ctx.c.mut),
            title: Text(b['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${ctx.t('Code')}: ${b['code'] ?? '—'}${b['address'] == null ? '' : ' · ${b['address']}'}', maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => Navigator.pop(ctx, b['id'] as String),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (picked == null || picked == curId) return;
  ref.read(sessionProvider).setBranch(picked);
  if (context.mounted) toast(context, context.t('Showing {b}', {'b': list.firstWhere((b) => b['id'] == picked)['name']}));
}

/// Gym settings → tap a branch: show that branch's Join and Check-in QR.
Future<void> showBranchQr(BuildContext context, WidgetRef ref, Map b) async {
  final g = ref.read(gymProvider).valueOrNull as Map?;
  if (g?['currentBranchId'] != b['id']) ref.read(sessionProvider).setBranch(b['id'] as String);
  if (context.mounted) context.push('/o/gym-qr');
}

/// Offer / notice form: who sees it — this branch only, or every branch.
class BranchTarget extends ConsumerWidget {
  const BranchTarget({super.key, required this.all, required this.onChanged});
  final bool all;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = ref.watch(gymProvider).valueOrNull as Map?;
    final list = branchesOf(g);
    if (list.length < 2) return const SizedBox.shrink();
    final cur = list.firstWhere((b) => b['id'] == g?['currentBranchId'], orElse: () => list.first);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.t('Branch'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 6, children: [
          ChoiceChip(label: Text(context.t('Only {b}', {'b': cur['name']})), selected: !all, onSelected: (_) => onChanged(false)),
          ChoiceChip(label: Text(context.t('All branches')), selected: all, onSelected: (_) => onChanged(true)),
        ]),
      ]),
    );
  }
}

// ---------- Owner: Requests → Transfer ----------

class TransferRequests extends ConsumerStatefulWidget {
  const TransferRequests({super.key});
  @override
  ConsumerState<TransferRequests> createState() => _TransferRequestsState();
}

class _TransferRequestsState extends ConsumerState<TransferRequests> {
  final busy = <String>{};
  bool? allowOverride;

  Future<void> act(String id, bool ok) async {
    setState(() => busy.add(id));
    final done = context.t(ok ? 'Moved' : 'Declined');
    try {
      await Api.instance.post('/transfers/$id/${ok ? 'approve' : 'decline'}', {});
      ref.invalidate(transfersProvider);
      ref.invalidate(ownerMembersProvider);
      ref.invalidate(dashboardProvider);
      if (mounted) toast(context, done);
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  Future<void> setAllow(bool v) async {
    setState(() => allowOverride = v);
    try {
      await Api.instance.patch('/gym', {'allowTransfer': v});
      ref.invalidate(gymProvider);
      ref.invalidate(transfersProvider);
    } catch (e) {
      if (mounted) {
        setState(() => allowOverride = !v);
        toast(context, e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(transfersProvider);
    final owner = ref.watch(sessionProvider).myGym?['role'] == 'OWNER';
    return AsyncBody(
      value: v,
      onRetry: () => ref.invalidate(transfersProvider),
      builder: (d) {
        final allow = allowOverride ?? (d['allowTransfer'] == true);
        final items = ((d['items'] as List?) ?? const []).cast<Map>();
        return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
          Panel(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: allow,
              onChanged: owner ? setAllow : null,
              title: Text(context.t('Members can ask to move to another branch'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              subtitle: Text(
                context.t(allow ? 'ON: members see “Request transfer”. You approve here.' : 'OFF: members are told to ask at the front desk. You can still move anyone from their profile.'),
                style: TextStyle(color: context.c.mut, fontSize: 12),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty) ...[
            const SizedBox(height: 50),
            Icon(Icons.swap_horiz_rounded, size: 56, color: context.c.mut),
            const SizedBox(height: 10),
            Muted(context.t('No transfer requests.'), align: TextAlign.center, size: 14),
          ],
          for (final r in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Panel(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const IconTile(Icons.swap_horiz_rounded, size: 40),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        Muted('${r['memberCode']} · ${fmtDate(r['createdAt'] as String?)}', size: 12),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Flexible(child: _BranchPill('${r['fromBranch']}', muted: true)),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward_rounded, size: 18, color: context.c.mut)),
                    Flexible(child: _BranchPill('${r['toBranch']}')),
                  ]),
                  if (owner) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton(onPressed: busy.contains(r['id']) ? null : () => act(r['id'] as String, false), child: Text(context.t('Decline'))),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(onPressed: busy.contains(r['id']) ? null : () => act(r['id'] as String, true), child: Text(context.t('Approve & move'))),
                      ),
                    ]),
                  ] else
                    Padding(padding: const EdgeInsets.only(top: 8), child: Muted(context.t('Only the gym owner can approve.'), size: 12)),
                ]),
              ),
            ),
        ]);
      },
    );
  }
}

class _BranchPill extends StatelessWidget {
  const _BranchPill(this.text, {this.muted = false});
  final String text;
  final bool muted;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: muted ? context.c.surf2 : context.c.primary.withAlpha(30),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: muted ? context.c.mut : context.c.primary)),
      );
}

/// Owner: move a member to another branch from their profile.
Future<bool> moveMemberSheet(BuildContext context, WidgetRef ref, String memberId, String? currentBranchId) async {
  final g = ref.read(gymProvider).valueOrNull as Map?;
  final list = branchesOf(g);
  if (list.length < 2) return false;
  final cur = currentBranchId ?? list.first['id'];
  final to = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ctx.t('Move to branch'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Muted(ctx.t('The membership, payments and history move with the member.'), size: 12.5),
          ]),
        ),
        for (final b in list)
          ListTile(
            enabled: b['id'] != cur,
            leading: Icon(b['id'] == cur ? Icons.check_circle_rounded : Icons.place_outlined, color: b['id'] == cur ? C.ok : ctx.c.primary),
            title: Text(b['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: b['id'] == cur ? Text(ctx.t('Now here')) : null,
            onTap: () => Navigator.pop(ctx, b['id'] as String),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (to == null || to == cur) return false;
  try {
    await Api.instance.patch('/members/$memberId', {'branchId': to});
    ref.invalidate(ownerMembersProvider);
    ref.invalidate(ownerMemberProvider(memberId));
    ref.invalidate(dashboardProvider);
    if (context.mounted) toast(context, context.t('Moved to {b}', {'b': list.firstWhere((b) => b['id'] == to)['name']}));
    return true;
  } catch (e) {
    if (context.mounted) toast(context, e.toString());
    return false;
  }
}

// ---------- Member: request a transfer ----------

class MemberTransferScreen extends ConsumerStatefulWidget {
  const MemberTransferScreen({super.key, required this.tenantId, this.toBranchId});
  final String tenantId;
  final String? toBranchId;
  @override
  ConsumerState<MemberTransferScreen> createState() => _MemberTransferScreenState();
}

class _MemberTransferScreenState extends ConsumerState<MemberTransferScreen> {
  String? pick;
  bool busy = false;

  Future<void> send() async {
    final to = pick;
    if (to == null) return;
    setState(() => busy = true);
    try {
      final r = await Api.instance.post('/me/gyms/${widget.tenantId}/transfer', {'branchId': to});
      ref.invalidate(myTransferProvider(widget.tenantId));
      if (mounted) toast(context, context.t('Request sent for {b}. The gym owner will approve it.', {'b': r['toBranch']}));
    } catch (e) {
      if (mounted) toast(context, e.toString());
      ref.invalidate(myTransferProvider(widget.tenantId));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> cancel() async {
    setState(() => busy = true);
    try {
      await Api.instance.delete('/me/gyms/${widget.tenantId}/transfer');
      ref.invalidate(myTransferProvider(widget.tenantId));
    } catch (e) {
      if (mounted) toast(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = ref.watch(myTransferProvider(widget.tenantId));
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Change branch'))),
      body: AsyncBody(
        value: v,
        onRetry: () => ref.invalidate(myTransferProvider(widget.tenantId)),
        builder: (d) {
          final list = ((d['branches'] as List?) ?? const []).cast<Map>();
          final pending = d['pending'] as Map?;
          final allow = d['allowTransfer'] == true;
          pick ??= widget.toBranchId != null && list.any((b) => b['id'] == widget.toBranchId && b['current'] != true) ? widget.toBranchId : null;
          return ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 28), children: [
            if (!allow)
              Panel(
                color: C.warn.withAlpha(30),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Icon(Icons.lock_outline_rounded, color: C.warn),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      context.t('Your gym owner has not enabled transfer of your membership. Ask at the front desk or the gym owner.'),
                      style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35),
                    ),
                  ),
                ]),
              )
            else if (pending != null)
              Panel(
                color: context.c.primary.withAlpha(24),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.hourglass_top_rounded, color: context.c.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text(context.t('Waiting for approval: move to {b}', {'b': pending['toBranch']}), style: const TextStyle(fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 10),
                  OutlinedButton(onPressed: busy ? null : cancel, child: Text(context.t('Cancel request'))),
                ]),
              )
            else
              Muted(context.t('A member can be in one branch of a gym at a time. Pick the branch you want to move to — the gym owner approves it.'), size: 13),
            const SizedBox(height: 14),
            SectionTitle(context.t('Branches')),
            Panel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(children: [
                for (final b in list)
                  ListTile(
                    enabled: allow && pending == null && b['current'] != true,
                    onTap: () => setState(() => pick = b['id'] as String),
                    leading: Icon(
                      b['current'] == true
                          ? Icons.check_circle_rounded
                          : pick == b['id']
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_off_rounded,
                      color: b['current'] == true ? C.ok : (pick == b['id'] ? context.c.primary : context.c.mut),
                    ),
                    title: Text(b['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(b['current'] == true ? context.t('Your branch now') : ((b['address'] as String?) ?? '')),
                  ),
              ]),
            ),
            if (allow && pending == null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy || pick == null ? null : send,
                icon: const Icon(Icons.swap_horiz_rounded),
                label: Text(context.t('Request transfer')),
              ),
            ],
          ]);
        },
      ),
    );
  }
}

/// Join flow: the code belongs to another branch of a gym this member is already in.
Future<void> showAlreadyMember(BuildContext context, ApiException e) async {
  final d = e.data ?? const {};
  final tid = d['tenantId'] as String?;
  final allow = d['allowTransfer'] == true;
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Icon(allow ? Icons.swap_horiz_rounded : Icons.lock_outline_rounded, size: 44, color: allow ? ctx.c.primary : C.warn),
          const SizedBox(height: 10),
          Text(ctx.t('One branch at a time'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(e.message, textAlign: TextAlign.center, style: TextStyle(color: ctx.c.mut, height: 1.4)),
          const SizedBox(height: 16),
          if (allow && tid != null)
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                context.push('/transfer/$tid?to=${d['toBranchId'] ?? ''}');
              },
              icon: const Icon(Icons.swap_horiz_rounded),
              label: Text(ctx.t('Request transfer to {b}', {'b': d['toBranch'] ?? ''})),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(ctx.t('OK'))),
        ]),
      ),
    ),
  );
}
