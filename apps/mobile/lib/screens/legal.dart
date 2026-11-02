import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../i18n.dart';
import '../theme.dart';
import '../ui.dart';

// Terms & Conditions and Privacy Policy, shown inside the app (English / Hindi).
// The same text is on the website (/terms and /privacy) for the Play Store listing.

const legalUpdated = '2026-11-02';
const supportEmail = 'support@gymmantra.app';

const _termsEn = <(String, String)>[
  ('Who we are', 'GymMantra is an app that helps gyms manage members, memberships, payments, check-ins, trainers and personal training. Gyms (owners) use it to run their gym; members and trainers use it to see their own details.'),
  ('Your account', 'Give your correct name, mobile number and email. Keep your password secret; you are responsible for what happens in your account. One person, one account. Pick the right role (member, trainer or gym owner) — an account cannot switch roles once it is linked to a gym.'),
  ('You and your gym', 'Your membership, its price, fees, freezes, refunds and the gym rules are agreed between you and your gym. GymMantra keeps the records the gym enters and is not a party to that agreement.'),
  ('Payments', 'Money you pay at the gym (cash, UPI, card or bank) is received by the gym, not by GymMantra. The app shows what the gym recorded. If something looks wrong, ask your gym or raise a ticket.'),
  ('Gym owners', 'Owners must have the right to add the people they add, keep their data correct, and use it only to run their gym. The free trial and GymMantra plans, prices and features are shown in the app; plans can change with notice.'),
  ('Trainers', 'Trainers see only their own clients. Diet charts and workout plans are general fitness guidance by the trainer, not medical advice. Check with a doctor before starting any programme if you have a health condition.'),
  ('Fair use', 'Do not create fake accounts, check in for someone else, share or copy a trainer’s PDF, misuse the check-in QR, or try to break or overload the app. We may suspend accounts that do.'),
  ('Health and safety', 'Exercise carries risk. GymMantra is not responsible for injuries in the gym. Follow your trainer and the gym’s safety rules.'),
  ('Changes and ending', 'We may improve or change the app and these terms; we will show the new date here. You can stop using the app and delete your account any time (Profile). Gym records may be kept by the gym as the law requires.'),
  ('Contact', 'Questions: FAQ & Support → Mail us, or $supportEmail. These terms follow the laws of India; courts in New Delhi have jurisdiction.'),
];

const _privacyEn = <(String, String)>[
  ('What we collect', 'Name, mobile number, email, password (stored securely by Google Firebase, never readable by us), profile photo, and — only if you add them — date of birth, gender and address. Gyms add membership, payment, freeze and check-in records. Trainers add session marks, diet charts and workout plans.'),
  ('Why we use it', 'To run your membership and check-ins, show your plan, PT sessions and dues, send you reminders and notices from your gym, give support, and keep the app safe.'),
  ('Who can see it', 'You. Your gym’s owner and front desk see their own members. Your trainer sees only their PT clients. GymMantra support sees what is needed to help you. We do not sell your data and we do not show it to other gyms.'),
  ('Location', 'Used only at the moment you scan the gym’s check-in QR, to confirm you are inside the gym. We do not track you and we do not keep your location history.'),
  ('Camera and photos', 'The camera is used only to scan the check-in QR and to take a profile photo. Photos are used only as your profile picture.'),
  ('Where it is stored', 'On Google Firebase and Cloudflare servers with encryption in transit. Trainer PDFs open only inside the app with your name on them.'),
  ('How long', 'As long as your account is active. When you delete your account, your login and profile are removed; your gym may keep its membership and payment records as the law requires.'),
  ('Your rights', 'See and correct your details in Profile. Download your data or delete your account in Profile → Privacy. Ask us anything at $supportEmail.'),
  ('Children', 'Members under 18 should use the app with a parent’s or guardian’s consent.'),
  ('Changes', 'If we change this policy we will update the date at the top and tell you in the app.'),
];

const _termsHi = <(String, String)>[
  ('हम कौन हैं', 'GymMantra एक ऐप है जो जिम को मेंबर, मेंबरशिप, पेमेंट, चेक-इन, ट्रेनर और पर्सनल ट्रेनिंग संभालने में मदद करता है। जिम मालिक इससे जिम चलाते हैं; मेंबर और ट्रेनर अपनी जानकारी देखते हैं।'),
  ('आपका अकाउंट', 'सही नाम, मोबाइल नंबर और ईमेल दें। पासवर्ड किसी को न बताएं; अकाउंट में जो होता है उसकी ज़िम्मेदारी आपकी है। एक व्यक्ति, एक अकाउंट। सही रोल चुनें (मेंबर, ट्रेनर या जिम मालिक) — जिम से जुड़ने के बाद रोल नहीं बदलता।'),
  ('आप और आपका जिम', 'मेंबरशिप, उसकी कीमत, फ़ीस, फ़्रीज़, रिफ़ंड और जिम के नियम आपके और जिम के बीच तय होते हैं। GymMantra सिर्फ़ जिम का डाला हुआ रिकॉर्ड रखता है।'),
  ('पेमेंट', 'जिम में दिया गया पैसा (कैश, UPI, कार्ड या बैंक) जिम को मिलता है, GymMantra को नहीं। ऐप वही दिखाता है जो जिम ने दर्ज किया। कुछ गलत लगे तो जिम से पूछें या टिकट बनाएं।'),
  ('जिम मालिक', 'मालिक सिर्फ़ उन्हीं लोगों को जोड़ें जिनकी इजाज़त है, जानकारी सही रखें और सिर्फ़ जिम चलाने के लिए इस्तेमाल करें। फ़्री ट्रायल, प्लान, कीमत और फ़ीचर ऐप में दिखते हैं; बदलाव की सूचना दी जाएगी।'),
  ('ट्रेनर', 'ट्रेनर सिर्फ़ अपने क्लाइंट देखते हैं। डाइट चार्ट और वर्कआउट सामान्य फ़िटनेस सलाह है, डॉक्टर की सलाह नहीं। कोई बीमारी हो तो शुरू करने से पहले डॉक्टर से पूछें।'),
  ('सही इस्तेमाल', 'फ़र्ज़ी अकाउंट न बनाएं, किसी और के लिए चेक-इन न करें, ट्रेनर की PDF शेयर या कॉपी न करें, चेक-इन QR का गलत इस्तेमाल न करें। ऐसा करने पर अकाउंट रोका जा सकता है।'),
  ('सेहत और सुरक्षा', 'एक्सरसाइज़ में जोखिम होता है। जिम में चोट के लिए GymMantra ज़िम्मेदार नहीं है। ट्रेनर और जिम के सुरक्षा नियम मानें।'),
  ('बदलाव और बंद करना', 'हम ऐप और ये शर्तें बेहतर कर सकते हैं; नई तारीख यहाँ दिखेगी। आप कभी भी ऐप छोड़ सकते हैं और प्रोफ़ाइल से अकाउंट हटा सकते हैं। जिम कानून के हिसाब से अपने रिकॉर्ड रख सकता है।'),
  ('संपर्क', 'सवाल: FAQ & Support → Mail us, या $supportEmail। ये शर्तें भारत के कानून के तहत हैं; नई दिल्ली की अदालतें लागू होंगी।'),
];

const _privacyHi = <(String, String)>[
  ('हम क्या लेते हैं', 'नाम, मोबाइल नंबर, ईमेल, पासवर्ड (Google Firebase में सुरक्षित, हम पढ़ नहीं सकते), प्रोफ़ाइल फ़ोटो, और — अगर आप डालें — जन्मतिथि, जेंडर और पता। जिम मेंबरशिप, पेमेंट, फ़्रीज़ और चेक-इन रिकॉर्ड डालता है। ट्रेनर सेशन, डाइट चार्ट और वर्कआउट डालते हैं।'),
  ('क्यों', 'आपकी मेंबरशिप और चेक-इन चलाने, प्लान, PT सेशन और बकाया दिखाने, जिम के रिमाइंडर और सूचना भेजने, मदद करने और ऐप सुरक्षित रखने के लिए।'),
  ('कौन देख सकता है', 'आप। आपके जिम के मालिक और फ्रंट डेस्क अपने मेंबर देखते हैं। ट्रेनर सिर्फ़ अपने PT क्लाइंट देखते हैं। GymMantra सपोर्ट मदद के लिए ज़रूरी जानकारी देखता है। हम आपका डेटा बेचते नहीं और दूसरे जिम को नहीं दिखाते।'),
  ('लोकेशन', 'सिर्फ़ जिम का चेक-इन QR स्कैन करते समय, ये देखने के लिए कि आप जिम के अंदर हैं। हम आपको ट्रैक नहीं करते और लोकेशन का इतिहास नहीं रखते।'),
  ('कैमरा और फ़ोटो', 'कैमरा सिर्फ़ चेक-इन QR स्कैन करने और प्रोफ़ाइल फ़ोटो लेने के लिए। फ़ोटो सिर्फ़ प्रोफ़ाइल पिक्चर के रूप में।'),
  ('कहाँ रखा जाता है', 'Google Firebase और Cloudflare के सर्वर पर, सुरक्षित कनेक्शन से। ट्रेनर की PDF सिर्फ़ ऐप में आपके नाम के साथ खुलती है।'),
  ('कब तक', 'जब तक अकाउंट चालू है। अकाउंट हटाने पर आपका लॉग इन और प्रोफ़ाइल हट जाते हैं; जिम कानून के हिसाब से मेंबरशिप और पेमेंट रिकॉर्ड रख सकता है।'),
  ('आपके अधिकार', 'प्रोफ़ाइल में अपनी जानकारी देखें और सुधारें। प्रोफ़ाइल → Privacy में डेटा डाउनलोड करें या अकाउंट हटाएं। कोई भी सवाल $supportEmail पर।'),
  ('बच्चे', '18 साल से कम उम्र के मेंबर माता-पिता या अभिभावक की सहमति से ऐप इस्तेमाल करें।'),
  ('बदलाव', 'नीति बदलने पर ऊपर की तारीख बदलेगी और ऐप में बताया जाएगा।'),
];

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
    final hi = AppLang.current == 'hi';
    final secs = privacy ? (hi ? _privacyHi : _privacyEn) : (hi ? _termsHi : _termsEn);
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
        for (final (i, (h, t)) in secs.indexed) ...[
          const SizedBox(height: 16),
          Text('${i + 1}. $h', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15.5)),
          const SizedBox(height: 4),
          Text(t, style: TextStyle(color: context.c.mut, height: 1.55, fontSize: 14)),
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
