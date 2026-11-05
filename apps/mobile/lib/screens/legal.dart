import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../i18n.dart';
import '../legal_text.dart';
import '../theme.dart';
import '../ui.dart';

// Terms & Conditions and Privacy Policy, shown inside the app. The text is in lib/legal_text.dart
// (the approved documents, English only); the website shows the same text at /terms and /privacy.

class LegalScreen extends StatefulWidget {
  const LegalScreen({super.key, this.privacy = false});
  final bool privacy;
  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  late bool privacy = widget.privacy;
  @override
  Widget build(BuildContext context) {
    final secs = privacy ? privacySections : termsSections;
    return Scaffold(
      appBar: AppBar(title: Text(context.t(privacy ? 'Privacy Policy' : 'Terms & Conditions'))),
      body: ListView(padding: const EdgeInsets.fromLTRB(18, 4, 18, 32), children: [
        Seg<bool>(
          value: privacy,
          items: [(false, context.t('Terms'), null), (true, context.t('Privacy'), null)],
          onChanged: (v) => setState(() => privacy = v),
        ),
        const SizedBox(height: 12),
        Muted('${context.t('Last updated')}: ${fmtDate(legalUpdated)}', size: 12),
        if (AppLang.current == 'hi')
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Muted('यह कानूनी दस्तावेज़ अंग्रेज़ी में है। कोई सवाल हो तो Help & Support में टिकट बनाएं।', size: 12.5),
          ),
        for (final (i, (h, paras)) in secs.indexed) ...[
          const SizedBox(height: 18),
          Text('${i + 1}. $h', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
          for (final t in paras)
            Padding(
              padding: EdgeInsets.only(top: 6, left: t.startsWith('• ') ? 6 : 0),
              child: Text(t, style: TextStyle(color: context.c.mut, height: 1.55, fontSize: 14)),
            ),
        ],
      ]),
    );
  }
}

/// "I agree to the Terms & Conditions and Privacy Policy" with tappable links.
class AgreeLine extends StatelessWidget {
  const AgreeLine({super.key, this.value, this.onChanged, this.prefix});
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final String? prefix;
  @override
  Widget build(BuildContext context) {
    final p = context.c;
    final link = TextStyle(color: p.primary, fontWeight: FontWeight.w700);
    final text = Text.rich(
      TextSpan(style: TextStyle(color: p.mut, fontSize: 12.5, height: 1.45), children: [
        TextSpan(text: '${context.t(prefix ?? 'I agree to the')} '),
        TextSpan(text: context.t('Terms & Conditions'), style: link, recognizer: TapGestureRecognizer()..onTap = () => context.push('/legal/terms')),
        TextSpan(text: ' ${context.t('and')} '),
        TextSpan(text: context.t('Privacy Policy'), style: link, recognizer: TapGestureRecognizer()..onTap = () => context.push('/legal/privacy')),
      ]),
      textAlign: value == null ? TextAlign.center : TextAlign.start,
    );
    if (value == null) return text;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged?.call(!value!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 24, height: 24, child: Checkbox(value: value, onChanged: (v) => onChanged?.call(v ?? false), activeColor: p.primary)),
          const SizedBox(width: 10),
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 2), child: text)),
        ]),
      ),
    );
  }
}
