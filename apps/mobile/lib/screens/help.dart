import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../api.dart';
import '../i18n.dart';
import '../session.dart';
import '../theme.dart';
import '../ui.dart';

// FAQ for each role, "Mail us" tickets to GymMantra support (super admin only),
// and the ticket thread. One ticket = one unique number (GM-1001…). The person
// can write again on a ticket only after support has answered.

typedef Faq = (String topic, String q, String a);

const memberFaqs = <Faq>[
  ('Check-in', 'How do I check in?', 'Open the Check-in tab and scan the green check-in QR inside your gym. You are checked in at once. It counts once a day.'),
  ('Check-in', 'Check-in says I am too far from the gym.', 'Check-in works only inside the gym. Turn on location (GPS), step inside and scan again.'),
  ('Payments', 'How much do I owe?', 'Your home screen shows "Due" with how much you paid of the total. Pay at the front desk; it disappears once the gym records it.'),
  ('Membership', 'How do I renew or change my plan?', 'Go to Gym plans and tap "Interested" on a plan. The gym will contact you and start it.'),
  ('Membership', 'Can I pause (freeze) my membership?', 'Yes, if your plan has freeze days. Ask the front desk. Frozen days are added to your end date.'),
  ('Trainer', 'How do I take personal training (PT)?', 'Open Trainers, choose a trainer and a package, and send the request. The owner approves it.'),
  ('Trainer', 'Where is my diet chart or workout?', 'Open My plan. Your trainer’s plan or PDF shows there. PDFs open only inside the app.'),
  ('Account', 'I forgot my password.', 'On the login screen tap "Forgot password?". We email you a link to set a new one.'),
];

const trainerFaqs = <Faq>[
  ('Joining', 'How do I join a gym?', 'Enter the gym code and choose what you teach. The owner approves you and your trainer dashboard opens.'),
  ('Check-in', 'How do I mark my attendance?', 'Tap "Check in at the gym" on your home screen and scan the green check-in QR inside the gym.'),
  ('Sessions', 'How do I mark a PT session?', 'Open the client, tap the date on the calendar and choose Done, Missed or Planned.'),
  ('Sessions', 'Why can’t I change an old session?', 'Done and Missed can be changed only for today and the 2 days before. Coming days can only be Planned. Ask the owner to fix older days.'),
  ('Plans', 'How do I send a diet chart or workout?', 'Open the client → Diet chart or Workout plan. Upload a PDF (up to 2 MB) or write the plan, then save.'),
  ('Money', 'When do I get my PT money?', 'The owner pays your share. You can see what you earned and what was paid on your home screen.'),
  ('Account', 'Can I work at two gyms?', 'Yes. Join the second gym with its code; the owner approves it.'),
];

const ownerFaqs = <Faq>[
  ('Money', 'How do I remind members who owe money?', 'On the dashboard tap the "members owe money" card → Review → "Send reminder". Everyone gets a notification and sees it when they open the app.'),
  ('Money', 'How do I record a payment?', 'Open the member → "Take payment" on the membership that has money due. Choose Cash, UPI, Card or Bank.'),
  ('Check-in', 'Where is the check-in QR?', 'More → Gym QR → Check-in QR. Download or print it and put it up in the gym. Set the gym location there, standing inside the gym.'),
  ('Members', 'How do new members join?', 'Share the Join QR or gym code (More → Gym QR → Share). Approve their request in Requests.'),
  ('Trainers', 'How do I add a trainer?', 'The trainer joins with your gym code and you approve them in Requests. Then set their PT packages in Trainers.'),
  ('Plans', 'How do I change plan prices?', 'More → Membership plans. New prices apply to new and renewed memberships only.'),
  ('Account', 'How do I renew my GymMantra subscription?', 'More → Subscription. Choose a plan and message us; we record the payment and send a receipt.'),
];

List<Faq> faqsFor(String mode) => switch (mode) {
      'owner' => ownerFaqs,
      'trainer' || 'waiting' || 'trainerJoin' => trainerFaqs,
      _ => memberFaqs,
    };

const ticketTopics = {
  'app_problem': 'App problem',
  'payment': 'Payment / due',
  'checkin': 'Check-in',
  'account': 'Account',
  'other': 'Other',
};

/// Older tickets used other topic names.
const _oldTopics = {
  'membership': 'Membership',
  'facility': 'Gym facility',
  'trainer': 'Trainer',
  'other_gym': 'Other',
  'app_login': 'Login problem',
  'app_bug': 'App problem',
  'app_other': 'Other',
};
String topicLabel(BuildContext context, String? t) => context.t(ticketTopics[t] ?? _oldTopics[t] ?? 'Other');

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
    final mode = ref.watch(sessionProvider).mode;
    final faqs = faqsFor(mode);
    final roleLabel = switch (mode) { 'owner' => 'For gym owners', 'trainer' || 'waiting' || 'trainerJoin' => 'For trainers', _ => 'For members' };
    final tickets = ref.watch(ticketsProvider);
    final needle = q.toLowerCase();
    final shown = faqs.where((f) => q.isEmpty || '${f.$2} ${f.$3} ${context.t(f.$2)} ${context.t(f.$3)}'.toLowerCase().contains(needle)).toList();
    return Scaffold(
      appBar: AppBar(title: Text(context.t('FAQ & Support'))),
      body: RefreshIndicator(
        color: context.c.primary,
        onRefresh: () async => ref.invalidate(ticketsProvider),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(color: context.c.primary.withAlpha(34), borderRadius: BorderRadius.circular(99)),
              child: Text(context.t(roleLabel), style: TextStyle(color: context.c.primary, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 10),
          TextField(decoration: InputDecoration(prefixIcon: const Icon(Icons.search_rounded), hintText: context.t('Search help'), isDense: true), onChanged: (t) => setState(() => q = t)),
          const SizedBox(height: 12),
          // Only one answer open at a time: opening a question closes the previous one.
          Panel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              if (shown.isEmpty) Padding(padding: const EdgeInsets.all(18), child: Muted(context.t('No answer found. Mail us below.'))),
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
          const SizedBox(height: 14),
          Material(
            color: context.c.surf,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: context.c.primary, width: 1.5)),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async {
                await context.push('/help/new');
                ref.invalidate(ticketsProvider);
              },
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(color: context.c.primary.withAlpha(34), borderRadius: BorderRadius.circular(14)),
                    child: Icon(Icons.mail_outline_rounded, color: context.c.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(context.t('Still need help? Mail us'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      Muted(context.t('We typically respond within 1 day'), size: 12.5),
                    ]),
                  ),
                  Icon(Icons.chevron_right_rounded, color: context.c.mut),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 18),
          SectionTitle(context.t('My tickets')),
          AsyncBody(
            value: tickets,
            loading: const Shimmer(child: Column(children: [Bone(height: 64), SizedBox(height: 8), Bone(height: 64)])),
            builder: (d) {
              final list = (d as List).cast<Map>();
              if (list.isEmpty) return Muted(context.t('No tickets yet.'));
              return Column(children: [for (final t in list) TicketTile(t: t, onTap: () => context.push('/help/ticket/${t['id']}'))]);
            },
          ),
        ]),
      ),
    );
  }
}

(String, Color) ticketState(BuildContext context, Map t) {
  if (t['status'] == 'RESOLVED') return (context.t('Closed'), context.c.mut);
  if (t['waiting'] == false) return (context.t('Answered'), C.ok);
  return (context.t('Open'), C.warn);
}

class TicketTile extends StatelessWidget {
  const TicketTile({super.key, required this.t, required this.onTap, this.admin = false});
  final Map t;
  final VoidCallback onTap;
  final bool admin;
  @override
  Widget build(BuildContext context) {
    final (label, color) = ticketState(context, t);
    final last = ((t['messages'] as List?) ?? const []).cast<Map>();
    final reply = last.isNotEmpty && last.last['fromStaff'] == true ? last.last['body'] as String? : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        padding: const EdgeInsets.all(14),
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(t['subject'] as String, style: const TextStyle(fontWeight: FontWeight.w700))),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: color.withAlpha(36), borderRadius: BorderRadius.circular(99)),
              child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11.5)),
            ),
          ]),
          const SizedBox(height: 3),
          Muted(
            [
              if (t['number'] != null) '#${t['number']}',
              topicLabel(context, t['topic'] as String?),
              if (admin && t['gymName'] != null) t['gymName'],
              if (admin && t['role'] != null) context.t(switch (t['role']) { 'OWNER' => 'Gym owner', 'TRAINER' => 'Trainer', _ => 'Member' }),
              fmtDateTime(t['updatedAt'] as String),
            ].join(' · '),
            size: 12,
          ),
          if (reply != null && !admin) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: context.c.surf2, borderRadius: BorderRadius.circular(12)),
              child: Text.rich(
                TextSpan(children: [TextSpan(text: '${context.t('GymMantra Support')}: ', style: const TextStyle(fontWeight: FontWeight.w800)), TextSpan(text: reply)]),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
          ],
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

// ============================================================ Mail us (raise a ticket)

class NewTicketScreen extends ConsumerStatefulWidget {
  const NewTicketScreen({super.key});
  @override
  ConsumerState<NewTicketScreen> createState() => _NewTicketState();
}

class _NewTicketState extends ConsumerState<NewTicketScreen> {
  String topic = 'app_problem';
  final subject = TextEditingController();
  final body = TextEditingController();
  bool busy = false;
  String? error;
  Map? done;

  Future<void> send() async {
    FocusScope.of(context).unfocus();
    if (subject.text.trim().length < 3) return setState(() => error = context.t('Write a short subject'));
    if (body.text.trim().length < 5) return setState(() => error = context.t('Tell us a little more in the message'));
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final r = await Api.instance.post('/me/tickets', {'topic': topic, 'subject': subject.text.trim(), 'body': body.text.trim()});
      ref.invalidate(ticketsProvider);
      if (mounted) setState(() => done = r as Map);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final d = done;
    if (d != null) {
      return Scaffold(
        appBar: AppBar(title: Text(context.t('Mail us'))),
        body: ListView(padding: const EdgeInsets.fromLTRB(22, 40, 22, 24), children: [
          Center(
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(color: C.ok.withAlpha(36), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Container(width: 76, height: 76, decoration: const BoxDecoration(color: C.ok, shape: BoxShape.circle), child: const Icon(Icons.check_rounded, color: Colors.white, size: 40)),
            ),
          ),
          const SizedBox(height: 16),
          Text(context.t('Ticket raised'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          Muted('${context.t('Ticket')} #${d['number']}', align: TextAlign.center),
          const SizedBox(height: 20),
          Panel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d['subject'] as String, style: const TextStyle(fontWeight: FontWeight.w800)),
              Muted(topicLabel(context, d['topic'] as String?), size: 12.5),
              const SizedBox(height: 10),
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: C.warn.withAlpha(36), borderRadius: BorderRadius.circular(99)),
                  child: Text(context.t('Open'), style: const TextStyle(color: C.warn, fontWeight: FontWeight.w800, fontSize: 11.5)),
                ),
                const SizedBox(width: 8),
                Muted(context.t('Reply within 1 day'), size: 12),
              ]),
            ]),
          ),
          const SizedBox(height: 14),
          Muted(context.t('You will get a notification when we reply. See it anytime in FAQ & Support → My tickets.'), align: TextAlign.center, size: 12.5),
          const SizedBox(height: 18),
          OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(50)), onPressed: () => context.pop(), child: Text(context.t('Done'))),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(context.t('Mail us'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: p.primary.withAlpha(30), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(Icons.schedule_rounded, size: 18, color: p.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(context.t('We typically respond within 1 day'), style: TextStyle(color: p.primary, fontWeight: FontWeight.w700, fontSize: 13))),
          ]),
        ),
        const SizedBox(height: 14),
        Muted(context.t('What is it about?'), size: 13),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final e in ticketTopics.entries)
            ChoiceChip(
              label: Text(context.t(e.value)),
              selected: topic == e.key,
              showCheckmark: false,
              selectedColor: p.primary,
              labelStyle: TextStyle(color: topic == e.key ? Colors.white : p.fg, fontWeight: FontWeight.w700),
              onSelected: (_) => setState(() => topic = e.key),
            ),
        ]),
        const SizedBox(height: 16),
        Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(context.t('Subject'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.mut))),
        TextField(controller: subject, maxLength: 120, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(hintText: context.t('e.g. Payment done but still showing due'), counterText: '')),
        const SizedBox(height: 14),
        Padding(padding: const EdgeInsets.only(left: 2, bottom: 6), child: Text(context.t('Message'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.mut))),
        TextField(
          controller: body,
          minLines: 6,
          maxLines: 10,
          maxLength: 1000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(hintText: context.t('Tell us what happened'), alignLabelWithHint: true),
        ),
        ErrorText(error),
        const SizedBox(height: 14),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: busy ? null : send,
          icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.send_rounded, size: 18),
          label: Text(context.t('Raise ticket')),
        ),
      ]),
    );
  }
}

// ============================================================ ticket thread

class TicketScreen extends ConsumerStatefulWidget {
  const TicketScreen({super.key, required this.id, this.admin = false});
  final String id;
  final bool admin;
  @override
  ConsumerState<TicketScreen> createState() => _TicketState();
}

class _TicketState extends ConsumerState<TicketScreen> {
  final msg = TextEditingController();
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final prov = widget.admin ? superTicketProvider(widget.id) : ticketProvider(widget.id);
    final t = ref.watch(prov);
    final me = ref.watch(sessionProvider).user?['id'];
    return Scaffold(
      appBar: AppBar(title: Text(t.valueOrNull?['number'] != null ? '#${t.valueOrNull['number']}' : context.t('Ticket'))),
      body: AsyncBody(
        value: t,
        builder: (d) {
          final messages = (d['messages'] as List).cast<Map>();
          final (label, color) = ticketState(context, d as Map);
          // People wait for support's answer before writing again; support can always reply.
          final locked = !widget.admin && d['waiting'] == true;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d['subject'] as String, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(color: color.withAlpha(36), borderRadius: BorderRadius.circular(99)),
                    child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11.5)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Muted(
                      [
                        topicLabel(context, d['topic'] as String?),
                        if (widget.admin && d['gymName'] != null) d['gymName'],
                        if (widget.admin && d['authors'] != null) ((d['authors'] as List).cast<Map>().where((a) => a['id'] == d['userId']).firstOrNull?['name'] ?? ''),
                      ].join(' · '),
                      size: 12,
                    ),
                  ),
                ]),
              ]),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                for (final m in messages)
                  Align(
                    alignment: (widget.admin ? m['fromStaff'] == true : m['authorId'] == me) ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: (widget.admin ? m['fromStaff'] == true : m['authorId'] == me) ? context.c.primary.withAlpha(36) : context.c.surf2,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m['fromStaff'] == true ? context.t('GymMantra Support') : (widget.admin ? context.t('User') : context.t('You')), style: TextStyle(fontSize: 11, color: context.c.mut, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(m['body'] as String, style: const TextStyle(height: 1.4)),
                        const SizedBox(height: 4),
                        Text(fmtDateTime(m['createdAt'] as String), style: TextStyle(fontSize: 10, color: context.c.mut)),
                      ]),
                    ),
                  ),
              ]),
            ),
            SafeArea(
              child: locked
                  ? Container(
                      width: double.infinity,
                      margin: const EdgeInsets.all(12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: C.warn.withAlpha(30), borderRadius: BorderRadius.circular(14)),
                      child: Row(children: [
                        const Icon(Icons.hourglass_top_rounded, color: C.warn, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            context.t('Waiting for GymMantra support. You can write again after we reply (usually within 1 day).'),
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
                          ),
                        ),
                      ]),
                    )
                  : Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        Expanded(child: TextField(controller: msg, minLines: 1, maxLines: 4, decoration: InputDecoration(hintText: context.t('Write a message')))),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          style: IconButton.styleFrom(backgroundColor: context.c.primary, foregroundColor: Colors.white),
                          onPressed: busy
                              ? null
                              : () async {
                                  if (msg.text.trim().isEmpty) return;
                                  setState(() => busy = true);
                                  try {
                                    await Api.instance.post('${widget.admin ? '/super' : '/me'}/tickets/${widget.id}/messages', {'body': msg.text.trim()});
                                    msg.clear();
                                    ref.invalidate(prov);
                                    ref.invalidate(ticketsProvider);
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
