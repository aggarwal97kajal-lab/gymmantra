"""Short GymMantra manual: 6 pages, real screens, simple Hinglish."""
from lib6 import *  # noqa: F403  (CSS, phone, steps, box, flow, logo, page, O)

EXTRA = '''
.page { padding: 12mm 12mm 12mm; }
body { font-size: 9.3pt; line-height: 1.42; }
h2 { font-size: 15pt; margin-bottom: 2mm; }
.mini { display: flex; gap: 3.5mm; align-items: flex-start; }
.mini .txt { flex: 1; }
.mini h4 { margin: 0 0 1mm; font-size: 10.5pt; font-weight: 800; display: flex; gap: 6px; align-items: center; }
.mini h4 .ic { width: 22px; height: 22px; border-radius: 7px; background: #FFF1EB; display: inline-flex; align-items: center; justify-content: center; font-size: 11pt; }
.mini p { margin: 0 0 1mm; font-size: 9pt; color: #374151; }
.cell { border: 1px solid #EEF0F3; border-radius: 12px; padding: 3mm; background: #fff; }
.frame { border-width: 1.6mm; border-radius: 5mm; }
.frame img { border-radius: 3.4mm; }
.pcap { font-size: 7.5pt; margin-top: 1mm; }
.steps li { margin-bottom: 1mm; font-size: 9pt; }
.steps .n { width: 17px; height: 17px; font-size: 8pt; }
.box { padding: 2mm 3mm; margin: 1.5mm 0; font-size: 8.8pt; }
.band { border-radius: 14px; color: #fff; padding: 4mm 5mm; display: flex; align-items: center; gap: 4mm; margin-bottom: 4mm; }
.band .big { font-size: 20pt; font-weight: 800; line-height: 1; }
.band .t { font-size: 15pt; font-weight: 800; }
.band .s { font-size: 9pt; opacity: .9; }
.fl { font-size: 8pt; } .fl b { font-size: 8.6pt; } .fli { width: 12mm; height: 12mm; font-size: 14pt; } .arr { font-size: 12pt; margin-top: 3mm; }
.diagram { padding: 3.5mm; margin: 2mm 0 3mm; }
'''


def mini(icon, title, body, shot=None, w=30, cap=''):
    ph = phone(shot, cap, w) if shot else ''
    return f'<div class="cell mini"><div class="txt"><h4><span class="ic">{icon}</span>{title}</h4>{body}</div>{ph}</div>'


def band(color, num, title, sub):
    return f'<div class="band" style="background:linear-gradient(120deg,{color},#1a0a05 160%)"><div class="big">{num}</div><div><div class="t">{title}</div><div class="s">{sub}</div></div></div>'


P = []

# ---------------- 1: cover + start ----------------
P.append(f'''<div class="page" style="padding:0">
<div style="background:#0B0F19;color:#fff;padding:12mm 12mm 8mm;position:relative;overflow:hidden">
<div style="position:absolute;inset:0;background:radial-gradient(circle at 90% 0%, rgba(255,90,31,.6), transparent 50%)"></div>
<div style="position:relative;display:flex;gap:8mm;align-items:center">
<div style="flex:1">
<div style="display:flex;align-items:center;gap:10px">{logo(34)}<div style="font-size:15pt;font-weight:800">Gym<span style="color:{O}">Mantra</span></div></div>
<div style="font-size:24pt;font-weight:800;line-height:1.1;margin-top:6mm">App manual —<br><span style="color:{O}">5 minute mein seekhiye</span></div>
<div style="font-size:10pt;color:#CBD5E1;margin-top:3mm">Gym ka poora kaam ek app mein: members, fees, check-in, trainers, staff, salary aur reports. Kaagaz ka register aur Excel ki zarurat nahi.</div>
</div>
<div style="display:flex;gap:3mm;align-items:flex-end">{phone('10_owner_home', '', 34)}{phone('60_member_home', '', 34)}</div>
</div></div>
<div style="padding:7mm 12mm 0">
<h2>Ek app, chaar log</h2>
<div class="grid4">
{''.join(f'<div class="cell" style="border-top:4px solid {c}"><b>{i} {t}</b><div style="font-size:8.6pt;color:#4B5563;margin-top:1mm">{d}</div></div>' for i, t, c, d in [
    ('🏋️', 'Gym owner', O, 'Poora gym chalata hai: members, paise, plans, trainers, staff, reports.'),
    ('🧾', 'Gym staff', '#2563EB', 'Front desk: member add, fees, check-in, enquiries, lockers. Owner jo rights de.'),
    ('💪', 'Trainer', '#16A34A', 'PT clients, sessions calendar, diet/workout, apni attendance aur salary.'),
    ('🙋', 'Member', '#9333EA', 'Membership, QR check-in, trainers, PT, offers, notices, rating.')])}
</div>
<h2 style="margin-top:6mm">Shuru kaise karein</h2>
{flow([('📲', 'App install karein', 'GymMantra'), ('🙋', 'Role chunein', 'Member / Owner / Trainer / Staff'), ('📝', 'Sign up', 'Naam, mobile, email, password'), ('🔑', 'Gym code daalein', 'Member aur trainer'), ('✅', 'Owner approve kare', 'App khul jaati hai')])}
<div class="grid3" style="margin-top:2mm">
{mini('🙋', 'Role chunna', '<p>App kholte hi apna role tap karein → <b>Continue</b>. Upar <b>EN</b> se English/हिंदी.</p>', '01_role', 27)}
{mini('🔑', 'Login', '<p>Mobile ya email + password. Bhool gaye? <b>Forgot password</b> → email pe link.</p><p>3 galat password = 15 minute lock.</p>', '02_login', 27)}
{mini('🧾', 'Staff ka login', '<p>Staff khud sign up nahi karta. Owner add karta hai → staff apne mobile se login karke password banata hai.</p>')}
</div>
{box('tip', 'Gym code kahan milega?', 'Owner ke Home pe orange card mein (jaise <b>LIFE872</b>). Har branch ka apna code. Owner ise WhatsApp ya poster se share kare.')}
</div><div class="foot">GymMantra · App Manual</div></div>''')

# ---------------- 2: owner (1) ----------------
P.append(page(f'''
{band(O, '🏋️', 'Gym owner — rozana ka kaam', 'Neeche 5 tab: Home · Members · Requests · Offers · More. Upar branch button se branch badlein.')}
<div class="grid2">
{mini('📊', 'Home (dashboard)', '<p>Aaj ke check-ins, aaj ki collection, active members, <b>7 din mein khatam</b> hone wale, aur jinke <b>paise baaki</b> hain.</p><p>Har subah ek baar dekhein, phir renew ke reminders bhejein.</p>', '10_owner_home', 33)}
{mini('👥', 'Members', '<p>Search, aur filter: Active / Ending soon / Expired. Member pe tap karke:</p><p><b>Call/WhatsApp</b> · <b>Renew</b> · <b>Freeze</b> (kuch din rokna) · <b>Correct</b> (galti sudharna) · <b>Remove</b></p>', '12_owner_member', 33)}
{mini('➕', 'Naya member', steps(['Members → <b>+</b>', 'Details bharein → plan, start date, discount', 'Payment: Cash / UPI / Card / Not paid']) + '<p>Member ID apne aap banta hai (LF-1023).</p>', '13_owner_add_member', 33)}
{mini('📥', 'Requests', '<p>Member/trainer Gym code se join karte hain → yahan request. <b>Approve</b> ya <b>Decline</b>. PT, plan aur branch-move ki requests bhi yahin.</p>', '14_owner_requests', 33)}
</div>
<div class="diagram"><div class="dtitle">Membership ka safar</div>
{flow([('🆕', 'Plan diya', 'Paise liye'), ('🟢', 'Active', 'Entry allowed'), ('🟡', 'Ending soon', 'Aakhri 7 din'), ('🔴', 'Expired', 'Entry band'), ('🔁', 'Renew', 'Phir Active')], '#16A34A')}
<div style="font-size:8.6pt;color:#4B5563">💸 Paise baaki → "Dues" mein naam. Entry allow karni hai ya nahi, ye aap har membership pe tay karte hain. ❄️ Freeze ke din end date mein jud jaate hain.</div></div>
''', 'Gym owner · 1/2'))

# ---------------- 3: owner (2) ----------------
P.append(page(f'''
<div class="diagram" style="margin-top:0"><div class="dtitle">Check-in: member 5 second mein andar</div>
{flow([('🚶', 'Gym pahuncha', 'Phone mein app'), ('📷', 'Check-in QR scan', 'Deewar pe laga'), ('📍', 'Location check', 'Gym ke 20 m andar'), ('🧠', 'App jaanchti hai', 'Plan, paise, freeze'), ('✅', 'Entry', 'Ya ❌ wajah ke saath')], '#2563EB')}
<div style="font-size:8.6pt;color:#4B5563">More → <b>Gym QR</b>: <b>Join QR</b> poster/Instagram ke liye, <b>Check-in QR</b> gym ki deewar ke liye. Phone nahi hai → desk pe <b>Manual check-in</b>.</div></div>
<div class="grid2">
{mini('💪', 'Trainers aur PT', '<p>Trainer ke packages aur share % set karein. Member PT maange → aap approve karein (paise lekar). Trainer calendar bharta hai.</p>' + box('eg', 'Example', '₹6,000 PT, trainer ka share 50% → trainer ₹3,000, gym ₹3,000. <b>PT accounts</b> mein dikhta hai kitna dena baaki hai.'), '23_owner_pt_accounts', 31)}
{mini('📣', 'Offers aur Notices', '<p>Offer (discount) ya Notice (gym band, timing) → kisko bhejna: sab / active / expired members, trainers. Sabke phone pe notification aur Home pe card.</p>', '19_owner_offers', 31)}
{mini('🧾', 'Staff, salary, attendance', '<p><b>Staff</b>: add karein, rights chunein (Reception / Check-in only / Manager). <b>Staff salary</b>: salary set karein, advance, pay, slip. <b>Attendance</b>: staff roz gym se "Present" lagata hai.</p><p>Jo branch Home pe khuli hai, usi ka staff dikhta hai.</p>', '25_owner_salary', 31)}
{mini('📈', 'Reports', '<p>7 / 30 / 90 din. <b>Money</b> tab: Memberships + PT + Lockers − Staff salary − trainer ka hissa = <b>bacha paisa</b>. Excel bhi.</p>', '17_owner_reports', 31)}
</div>
<div class="grid4" style="margin-top:3mm;font-size:8.6pt">
<div class="cell"><b>🔐 Lockers</b><br>Kis member ko kaunsa locker, kab tak, fees, deposit. Khatam hone se pehle reminder.</div>
<div class="cell"><b>📞 Enquiries</b><br>Poochne aaye logon ka record, roz 9 baje "aaj kise call karna hai".</div>
<div class="cell"><b>⭐ Ratings</b><br>Members ki rating. Achhe reviews ko "Show on dashboards" karke photo ke saath dikhayein.</div>
<div class="cell"><b>👆 Fingerprint machine</b><br>eSSL, ZKTeco, Hikvision ya pen drive. User ID = Member ID ka number (1023).</div>
</div>
{box('tip', 'Plan aur trial', 'Naye gym ko pehle 3 mahine sab free. Phir More → <b>Subscription</b> → plan chun ke UPI se pay. Purane members Excel se ek saath: More → <b>Import members</b>.')}
''', 'Gym owner · 2/2'))

# ---------------- 4: staff + trainer ----------------
P.append(page(f'''
{band('#2563EB', '🧾', 'Gym staff (front desk)', 'Owner ne jo rights diye, wahi dikhta hai. Aap sirf apni branch ka kaam dekhte hain.')}
<div class="grid2">
{mini('🗂️', 'Desk ka rozana kaam', '<p>➕ Member add / renew → Members tab<br>💰 Fees lena → member page<br>✋ Bina phone wale ki entry → Manual check-in<br>📞 Enquiry likhna, 🔐 locker dena → More</p><p>Koi option nahi dikh raha = owner ne right nahi diya.</p>', '40_staff_home', 31)}
{mini('📅', 'Present lagana aur salary', steps(['More → <b>My attendance</b>', 'Gym ke andar <b>Mark today: Present</b> dabayein (location on)', 'More → <b>My salary</b>: din, salary, advance, baaki']) + '<p>11 aur 5 baje reminder aata hai. Fingerprint wale gym mein button nahi, machine pe ungli lagayein.</p>', '42_staff_my_attendance', 31)}
</div>
{band('#16A34A', '💪', 'Trainer', 'Role "Trainer" → sign up → gym ka code + kya sikhate hain → owner approve.')}
<div class="grid2">
{mini('🏠', 'Trainer ka Home', '<p>PT clients, aaj ke sessions, jaldi khatam hone wale packages, aapki rating aur salary. Gym ke notices aur "My attendance" (roz Present).</p>', '50_trainer_home', 31)}
{mini('📆', 'Session calendar', '<p>Client pe tap karein → din chunein:</p><p><span class="pill" style="background:#16A34A;color:#fff">Done</span> <span class="pill" style="border:1.5px solid #FF5A1F;color:#FF5A1F">Planned</span> <span class="pill" style="background:#DC2626;color:#fff">Missed</span></p><p>Member aur owner ko wahi calendar dikhta hai. Diet chart aur workout bhi yahin se daalein. 2 din se purana session sirf owner badal sakta hai.</p>', '52_trainer_client', 31)}
</div>
''', 'Staff aur Trainer'))

# ---------------- 5: member ----------------
P.append(page(f'''
{band('#9333EA', '🙋', 'Member', 'Role "Member" → sign up → Home pe "Join a gym" → gym code → request → gym approve kare.')}
<div class="grid2">
{mini('🏠', 'Home', '<p>Aapka plan, kitne din baaki, paise baaki, is mahine kitni baar aaye, offers aur notices, locker, aur doosre members ke reviews.</p>', '60_member_home', 33)}
{mini('📷', 'Check-in', steps(['Gym pahunch ke <b>Check-in</b> tab', 'Deewar ka <b>Check-in QR</b> scan karein (location on)', '✅ = attendance lag gayi']) + '<p>Camera nahi chal raha? Home → <b>Show check-in QR</b> → desk ko dikhayein. Fingerprint wale gym mein gate ki machine pe ungli lagayein.</p>', '61_member_myqr', 33)}
{mini('💪', 'Trainers aur PT', '<p><b>Trainers</b> tab → trainer chunein → package request. Owner approve kare → aapka PT calendar shuru, har session aapko dikhega.</p>', '62_member_trainers', 33)}
{mini('🥗', 'My plan', '<p>Trainer ka diya <b>Diet</b> (calories, protein, kab kya khana) aur <b>Workout</b> (din, exercise, sets). 3D exercise videos bhi.</p>', '63_member_plan', 33)}
</div>
{box('tip', 'Rating dein', 'Home → <b>Rate gym</b> / <b>Rate trainer</b>: stars + comment. Review dikhane ki ijazat di to gym use apne app pe aapki photo ke saath dikha sakta hai.')}
''', 'Member'))

# ---------------- 6: everyone + FAQ ----------------
faq = [
    ('Check-in nahi ho raha?', 'Location on karein, gym ke andar hon, apni branch ka QR scan karein. Plan khatam, freeze ya paise baaki ho to entry nahi milti.'),
    ('Join request ka jawab nahi aaya?', 'Owner/desk ko bolein, Requests tab mein approve karna hota hai.'),
    ('Galat payment likh di?', 'Member page → Correct. Purana record safe rehta hai.'),
    ('Account lock ho gaya?', '3 galat password = 15 minute lock. Ya Forgot password.'),
    ('Notification nahi aa raha?', 'Phone settings mein GymMantra ke notifications on karein, battery saver se app hatayein.'),
    ('Hindi chahiye?', 'Profile → Language → हिंदी.'),
]
P.append(page(f'''
{band('#475569', '🛡️', 'Sabke liye', 'Notifications, security aur help: har role ke kaam ki cheezein.')}
<div class="grid2">
{mini('🔔', 'Notifications', '<p>Receipt, membership, PT, notices, offers, reminders: sab ghanti 🔔 mein aur phone pe. Tap karein → wahi page khulta hai. Ghanti khol ke wapas aate hi number hat jaata hai.</p>', '69_member_notifications', 30)}
{mini('📱', 'Logged-in devices', '<p>Profile → <b>Logged-in devices</b>: aapka account kahan-kahan khula hai.</p><p>Kisi phone ko <b>Log out</b>, ya <b>Log out everywhere else</b>. Anjaan login dikhe → <b>It was not me</b> → sab band + naya password.</p><p>Naye phone se login pe alert. Password badalte hi doosre phone pe app <b>usi second</b> logout.</p>', '35_owner_devices', 30)}
</div>
<div class="cell" style="margin-top:3mm"><b>🆘 Help &amp; Support</b> — Profile → Help → <b>New ticket</b> (number milta hai, jaise GM-1001).
{flow([('📨', 'Open', 'Aapne bheja'), ('🛠️', 'In progress', 'Team dekh rahi'), ('💬', 'Waiting', 'Jawab aaya'), ('✅', 'Resolved', '7 din tak reply'), ('🔒', 'Closed', 'Band')], '#475569')}</div>
<h2 style="margin-top:4mm">Aksar pooche jaane wale sawaal</h2>
<div class="grid3">{''.join(f'<div class="cell"><b>❓ {q}</b><div style="font-size:8.6pt;color:#4B5563;margin-top:1mm">{a}</div></div>' for q, a in faq)}</div>
<div style="display:flex;align-items:center;gap:4mm;margin-top:5mm;background:#0F172A;color:#fff;border-radius:14px;padding:4mm 5mm">{logo(32)}<div><b>GymMantra</b> — Gym ka poora kaam, ek app mein.<div style="font-size:8.6pt;color:#CBD5E1">Aur madad chahiye? App mein Help &amp; Support → New ticket.</div></div></div>
''', 'Sabke liye'))

html = f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}{EXTRA}</style></head><body>{"".join(P)}</body></html>'
open('/home/claude/guide/manual.html', 'w').write(html)
print('pages', len(P))
