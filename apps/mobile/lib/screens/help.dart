import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
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
  ('Account', 'I forgot my password.', 'Raise a ticket under "Login problem" from a friend\'s phone or ask your gym to contact GymMantra support.'),
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
  @override
  Widget build(BuildContext context) {
    final tickets = ref.watch(ticketsProvider);
    final shown = faqs.where((f) => q.isEmpty || '${f.$2} ${f.$3}'.toLowerCase().contains(q.toLowerCase())).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Help & Support')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.lime,
        foregroundColor: C.ink,
        onPressed: () async {
          await context.push('/help/new');
          ref.invalidate(ticketsProvider);
        },
        icon: const Icon(Icons.add_comment),
        label: const Text('Ask for help'),
      ),
      body: RefreshIndicator(
        color: C.lime,
        onRefresh: () async => ref.invalidate(ticketsProvider),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 90), children: [
          TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search help'), onChanged: (t) => setState(() => q = t)),
          const SizedBox(height: 16),
          const Text('My tickets', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          AsyncBody(
            value: tickets,
            builder: (d) {
              final list = (d as List).cast<Map>();
              if (list.isEmpty) return const Muted('No tickets yet.');
              return Column(children: [
                for (final t in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      padding: const EdgeInsets.all(14),
                      onTap: () => context.push('/help/ticket/${t['id']}'),
                      child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(t['subject'], style: const TextStyle(fontWeight: FontWeight.w700)), Muted('${topics[t['topic']] ?? t['topic']} · ${fmtDateTime(t['updatedAt'])}', size: 12)])),
                        Text(t['status'] == 'OPEN' ? 'Open' : 'Resolved', style: TextStyle(color: t['status'] == 'OPEN' ? C.org : C.lime, fontWeight: FontWeight.w700, fontSize: 12)),
                      ]),
                    ),
                  ),
              ]);
            },
          ),
          const SizedBox(height: 16),
          const Text('FAQ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          for (final f in shown)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(f.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(f.$1, style: const TextStyle(color: C.mut, fontSize: 12)),
                childrenPadding: const EdgeInsets.only(bottom: 12),
                expandedAlignment: Alignment.centerLeft,
                children: [Text(f.$3, style: const TextStyle(color: C.mut, height: 1.4))],
              ),
            ),
        ]),
      ),
    );
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
      appBar: AppBar(title: const Text('Ask for help')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        DropdownButtonFormField<String>(
          value: topic,
          decoration: const InputDecoration(labelText: 'Topic'),
          items: [for (final e in topics.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => topic = v!),
        ),
        const SizedBox(height: 6),
        Muted(isGym ? 'This goes to your gym.' : 'This goes to the GymMantra team.', size: 12),
        if (isGym) ...[
          const SizedBox(height: 12),
          gyms.maybeWhen(
            data: (d) {
              final list = (d['memberships'] as List).cast<Map>();
              if (list.isEmpty) return const Muted('Join a gym first to ask your gym.');
              memberId ??= list.first['memberId'] as String;
              return DropdownButtonFormField<String>(
                value: memberId,
                decoration: const InputDecoration(labelText: 'Gym'),
                items: [for (final m in list) DropdownMenuItem(value: m['memberId'] as String, child: Text(m['gym']['name']))],
                onChanged: (v) => setState(() => memberId = v),
              );
            },
            orElse: () => const LinearProgressIndicator(color: C.lime),
          ),
        ],
        const SizedBox(height: 12),
        TextField(controller: subject, decoration: const InputDecoration(labelText: 'Subject')),
        const SizedBox(height: 12),
        TextField(controller: body, maxLines: 5, decoration: const InputDecoration(labelText: 'Tell us what happened', alignLabelWithHint: true)),
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
                  try {
                    await Api.instance.post('/me/tickets', {'topic': topic, 'subject': subject.text.trim(), 'body': body.text.trim(), if (isGym && memberId != null) 'memberId': memberId});
                    if (mounted) {
                      toast(context, 'Sent. We will reply here.');
                      context.pop();
                    }
                  } catch (e) {
                    setState(() => error = e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(busy ? 'Sending…' : 'Send'),
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
      appBar: AppBar(title: const Text('Ticket')),
      body: AsyncBody(
        value: t,
        builder: (d) {
          final messages = (d['messages'] as List).cast<Map>();
          return Column(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d['subject'], style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Muted('${topics[d['topic']] ?? d['topic']} · ${d['status'] == 'OPEN' ? 'Open' : 'Resolved'}'),
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
                      decoration: BoxDecoration(color: m['authorId'] == me ? const Color(0x26C8FF3E) : C.card2, borderRadius: BorderRadius.circular(14)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m['fromStaff'] == true ? 'Support' : 'You', style: const TextStyle(fontSize: 11, color: C.mut)),
                        const SizedBox(height: 2),
                        Text(m['body']),
                        const SizedBox(height: 4),
                        Text(fmtDateTime(m['createdAt']), style: const TextStyle(fontSize: 10, color: C.mut)),
                      ]),
                    ),
                  ),
              ]),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(child: TextField(controller: msg, decoration: const InputDecoration(hintText: 'Write a message'))),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: C.lime, foregroundColor: C.ink),
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
