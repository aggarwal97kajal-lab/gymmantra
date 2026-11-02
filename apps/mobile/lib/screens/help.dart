import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

const faqs = [
  ('Membership', 'How do I renew my membership?', 'Visit or call your gym front desk. When they record your renewal, it shows in the app straight away.'),
  ('Membership', 'Why is my membership not showing?', 'Your gym must approve your join request first. If you joined long ago, ask the front desk to link your mobile number.'),
  ('Membership', 'Can I pause (freeze) my membership?', 'Yes, if your plan has freeze days. Ask your gym. The frozen days are added to your end date.'),
  ('Check-in', 'How do I check in?', 'Open the Check-in tab and show the QR code at the front desk. It changes every 30 seconds.'),
  ('Check-in', 'The front desk says my QR is blocked.', 'Your membership may have ended, be frozen or have a payment due. Check My membership, or raise a ticket.'),
  ('Payments', 'Can I pay in the app?', 'Not yet. Pay at your gym. They record it and it shows in the app.'),
  ('Account', 'I forgot my password.', 'Log out, then tap "Forgot password?" on the login screen. We will email you a link to set a new password.'),
  ('Account', 'How do I change my photo?', 'Go to Profile and tap your photo.'),
];

const topics = {
  'membership': 'Membership',
  'payment': 'Payment',
  'checkin': 'Check-in',
  'facility': 'Gym facility',
  'trainer': 'Trainer',
  'other_gym': 'Other gym question',
  'app_login': 'Login problem',
  'app_bug': 'App not working',
  'app_other': 'Other app question',
};

class HelpScreen extends ConsumerStatefulWidget {
  const HelpScreen({super.key});
  @override
  ConsumerState<HelpScreen> createState() => _HelpState();
}

class _HelpState extends ConsumerState<HelpScreen> {
  String q = '';
  String? openQ;
  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(ticketsProvider);
    final shown = faqs.where((f) => q.isEmpty || '${f.$2} ${f.$3} ${context.t(f.$2)} ${context.t(f.$3)}'.toLowerCase().contains(q.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Help & Support'))),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: context.c.primary,
        foregroundColor: Colors.white,
        onPressed: () async {
          await context.push('/help/new');
          ref.invalidate(ticketsProvider);
        },
        icon: const Icon(Icons.add_comment),
        label: Text(context.t('Ask for help')),
      ),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(ticketsProvider),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 90), children: [
          TextField(decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Search help')), onChanged: (t) => setState(() => q = t)),
          const SizedBox(height: 16),
          SectionTitle(context.t('My tickets')),
          AsyncBody(
            value: tickets,
            loading: const Shimmer(child: Column(children: [Bone(height: 64), SizedBox(height: 8), Bone(height: 64)])),
            builder: (d) {
              final list = (d as List).cast<Map>();
              if (list.isEmpty) return Muted(context.t('No tickets yet.'));
              return Column(children: [
                for (final t in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.all(14),
                      onTap: () => context.push('/help/ticket/${t['id']}'),
                      child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t['subject'], style: const TextStyle(fontWeight: FontWeight.w700)), Muted('${context.t(topics[t['topic']] ?? '${t['topic']}')} · ${fmtDateTime(t['updatedAt'])}', size: 12)])),
                        Text(t['status'] == 'OPEN' ? context.t('Open') : context.t('Resolved'), style: TextStyle(color: t['status'] == 'OPEN' ? C.warn : C.ok, fontWeight: FontWeight.w700, fontSize: 12)),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 16),
          SectionTitle(context.t('Common questions')),
          // Only one answer open at a time: opening a question closes the previous one.
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (final (i, f) in shown.indexed)
                _FaqTile(
                  question: context.t(f.$2),
                  topic: context.t(f.$1),
                  answer: context.t(f.$3),
                  open: openQ == f.$2,
                  last: i == shown.length - 1,
                  onTap: () => setState(() => openQ = openQ == f.$2 ? null : f.$2),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _FaqTile extends StatelessWidget {
  const _FaqTile({required this.question, required this.topic, required this.answer, required this.open, required this.last, required this.onTap});
  final String question, topic, answer;
  final bool open, last;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    return Column(children: [
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(question, style: TextStyle(fontWeight: FontWeight.w700, color: open ? p.primary : p.fg)),
                const SizedBox(height: 2),
                Text(topic, style: TextStyle(color: p.mut, fontSize: 12)),
              ]),
            ),
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 220),
              child: Icon(Icons.keyboard_arrow_down_rounded, color: open ? p.primary : p.mut),
            ),
          ]),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: open
            ? Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Text(answer, style: TextStyle(color: p.mut, height: 1.5)),
              )
            : const SizedBox(width: double.infinity),
      ),
      if (!last) Divider(height: 1, indent: 16, endIndent: 16, color: p.line),
    ]);
  }
}

class NewTicketScreen extends ConsumerStatefulWidget {
  const NewTicketScreen({super.key});
  @override
  ConsumerState<NewTicketScreen> createState() => _NewTicketState();
}

class _NewTicketState extends ConsumerState<NewTicketScreen> {
  String topic = 'membership';
  String? memberId;
  final subject = TextEditingController();
  final body = TextEditingController();
  bool busy = false;
  String? error;

  @override
  Widget build(BuildContext context) {
    final gyms = ref.watch(gymsProvider);
    final isGym = !topic.startsWith('app_');
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Ask for help'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          value: topic,
          decoration: InputDecoration(labelText: context.t('Topic')),
          items: [for (final e in topics.entries) DropdownMenuItem(value: e.key, child: Text(context.t(e.value)))],
          onChanged: (v) => setState(() => topic = v!),
        ),
        const SizedBox(height: 6),
        Muted(isGym ? context.t('This goes to your gym.') : context.t('This goes to the GymMantra team.'), size: 12),
        if (isGym) ...[
          const SizedBox(height: 12),
          gyms.maybeWhen(
            data: (d) {
              final list = (d['memberships'] as List).cast<Map>();
              if (list.isEmpty) return Muted(context.t('Join a gym first to ask your gym.'));
              memberId ??= list.first['memberId'] as String;
              return DropdownButtonFormField<String>(
                value: memberId,
                decoration: InputDecoration(labelText: context.t('Gym')),
                items: [for (final m in list) DropdownMenuItem(value: m['memberId'] as String, child: Text(m['gym']['name']))],
                onChanged: (v) => setState(() => memberId = v),
              );
            },
            orElse: () => const LinearProgressIndicator(color: C.orange),
          ),
        ],
        const SizedBox(height: 12),
        TextField(controller: subject, decoration: InputDecoration(labelText: context.t('Subject'))),
        const SizedBox(height: 12),
        TextField(controller: body, maxLines: 5, decoration: InputDecoration(labelText: context.t('Tell us what happened'), alignLabelWithHint: true)),
        ErrorText(error),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  final sentMsg = context.t('Sent. We will reply here.');
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await Api.instance.post('/me/tickets', {'topic': topic, 'subject': subject.text.trim(), 'body': body.text.trim(), if (isGym && memberId != null) 'memberId': memberId});
                    if (mounted) {
                      toast(context, sentMsg);
                      context.pop();
                    }
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(busy ? context.t('Sending…') : context.t('Send')),
        ),
      ]),
    );
  }
}

class TicketScreen extends ConsumerStatefulWidget {
  const TicketScreen({super.key, required this.id});
  final String id;
  @override
  ConsumerState<TicketScreen> createState() => _TicketState();
}

class _TicketState extends ConsumerState<TicketScreen> {
  final msg = TextEditingController();
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(ticketProvider(widget.id));
    final me = ref.watch(sessionProvider).user?['id'];
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Ticket'))),
      body: AsyncBody(
        value: t,
        builder: (d) {
          final messages = (d['messages'] as List).cast<Map>();
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d['subject'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Muted('${context.t(topics[d['topic']] ?? '${d['topic']}')} · ${d['status'] == 'OPEN' ? context.t('Open') : context.t('Resolved')}'),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                for (final m in messages)
                  Align(
                    alignment: m['authorId'] == me ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: m['authorId'] == me ? context.c.primary.withAlpha(36) : context.c.surf2, borderRadius: BorderRadius.circular(14)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m['fromStaff'] == true ? context.t('Support') : context.t('You'), style: TextStyle(fontSize: 11, color: context.c.mut)),
                        const SizedBox(height: 2),
                        Text(m['body']),
                        const SizedBox(height: 4),
                        Text(fmtDateTime(m['createdAt']), style: TextStyle(fontSize: 10, color: context.c.mut)),
                      ]),
                    ),
                  ),
              ]),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(child: TextField(controller: msg, decoration: InputDecoration(hintText: context.t('Write a message')))),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: context.c.primary, foregroundColor: Colors.white),
                    onPressed: busy
                        ? null
                        : () async {
                            if (msg.text.trim().isEmpty) return;
                            setState(() => busy = true);
                            try {
                              await Api.instance.post('/me/tickets/${widget.id}/messages', {'body': msg.text.trim()});
                              msg.clear();
                              ref.invalidate(ticketProvider(widget.id));
                            } catch (e) {
                              if (mounted) toast(context, e.toString());
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                    icon: const Icon(Icons.send),
                  ),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
