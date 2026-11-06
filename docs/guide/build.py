"""GymMantra user guide (PDF): real app screens + diagrams, simple Hinglish."""
import os

SH = '/home/claude/guide/img'
FONT = '/home/claude/gymmantra/apps/mobile/assets/fonts'
O = '#FF5A1F'


def img(name):
    return f'file://{SH}/{name}.jpg'


def phone(name, cap='', w=58):
    c = f'<div class="pcap">{cap}</div>' if cap else ''
    return f'<div class="ph" style="width:{w}mm"><div class="frame"><img src="{img(name)}"></div>{c}</div>'


def steps(items):
    return '<ol class="steps">' + ''.join(f'<li><span class="n">{i + 1}</span><div>{t}</div></li>' for i, t in enumerate(items)) + '</ol>'


def box(kind, title, body):
    icon = {'eg': '💡', 'tip': '✅', 'warn': '⚠️', 'why': '🎯'}[kind]
    return f'<div class="box {kind}"><div class="bt">{icon} {title}</div><div>{body}</div></div>'


def feature(num, title, sub, body, shots, wide=False, pw=None):
    ph = ''.join(phone(n, c, pw or (50 if wide else 46)) for n, c in shots)
    return f'''<section class="feat{' wide' if wide else ''}">
<div class="fh"><span class="fnum">{num}</span><div><h3>{title}</h3><div class="fsub">{sub}</div></div></div>
<div class="fbody"><div class="ftext">{body}</div><div class="fshots">{ph}</div></div></section>'''


def flow(items, color=O):
    out = []
    for i, (ic, t, s) in enumerate(items):
        out.append(f'<div class="fl"><div class="fli" style="border-color:{color}">{ic}</div><b>{t}</b><span>{s}</span></div>')
        if i < len(items) - 1:
            out.append(f'<div class="arr" style="color:{color}">➜</div>')
    return '<div class="flow">' + ''.join(out) + '</div>'


def chapter(num, title, sub, color, who):
    return f'''<div class="page chap" style="background:linear-gradient(150deg,{color} 0%, #1a0a05 130%)">
<div class="chnum">{num}</div><div class="chtitle">{title}</div><div class="chsub">{sub}</div>
<div class="chwho">{who}</div></div>'''


def page(inner, title=''):
    head = f'<div class="ptitle">{title}</div>' if title else ''
    return f'<div class="page">{head}{inner}<div class="foot">GymMantra · App Guide</div></div>'


CSS = f'''
@font-face {{ font-family: J; src: url(file://{FONT}/PlusJakartaSans-Regular.ttf); font-weight: 400; }}
@font-face {{ font-family: J; src: url(file://{FONT}/PlusJakartaSans-Medium.ttf); font-weight: 500; }}
@font-face {{ font-family: J; src: url(file://{FONT}/PlusJakartaSans-SemiBold.ttf); font-weight: 600; }}
@font-face {{ font-family: J; src: url(file://{FONT}/PlusJakartaSans-Bold.ttf); font-weight: 700; }}
@font-face {{ font-family: J; src: url(file://{FONT}/PlusJakartaSans-ExtraBold.ttf); font-weight: 800; }}
@page {{ size: A4; margin: 0; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; font-family: J, sans-serif; color: #1F2937; font-size: 10.6pt; line-height: 1.5; }}
.page {{ width: 210mm; height: 297mm; padding: 16mm 15mm 14mm; position: relative; page-break-after: always; overflow: hidden; }}
.ptitle {{ font-size: 9pt; font-weight: 700; color: {O}; letter-spacing: .12em; text-transform: uppercase; margin-bottom: 5mm; display:flex; align-items:center; gap:6px }}
.ptitle:before {{ content:''; width: 18px; height: 3px; background: {O}; border-radius: 2px; }}
.foot {{ position: absolute; bottom: 7mm; left: 15mm; right: 15mm; font-size: 8pt; color: #9CA3AF; display: flex; justify-content: space-between; border-top: 1px solid #F1F5F9; padding-top: 2.5mm; }}
.foot:after {{ content: counter(pg); counter-increment: pg; font-weight: 700; color: {O}; }}
body {{ counter-reset: pg; }}
h1 {{ font-size: 25pt; line-height: 1.1; margin: 0 0 4mm; font-weight: 800; letter-spacing: -.02em; }}
h2 {{ font-size: 17pt; margin: 0 0 3mm; font-weight: 800; letter-spacing: -.01em; }}
h3 {{ font-size: 13.5pt; margin: 0; font-weight: 800; }}
p {{ margin: 0 0 2.5mm; }}
.lead {{ font-size: 11.5pt; color: #4B5563; }}
.feat {{ margin-bottom: 7mm; }}
.fh {{ display: flex; gap: 10px; align-items: center; margin-bottom: 3mm; }}
.fnum {{ background: {O}; color: #fff; font-weight: 800; border-radius: 10px; min-width: 30px; height: 30px; display: inline-flex; align-items: center; justify-content: center; font-size: 11pt; padding: 0 6px; }}
.fsub {{ color: #6B7280; font-size: 9.5pt; }}
.fbody {{ display: flex; gap: 6mm; align-items: flex-start; }}
.ftext {{ flex: 1; }}
.fshots {{ display: flex; gap: 4mm; flex: none; }}
.feat.wide .fbody {{ flex-direction: column; }}
.feat.wide .fshots {{ align-self: center; gap: 10mm; }}
.ph {{ text-align: center; }}
.frame {{ border: 2.2mm solid #111827; border-radius: 7mm; overflow: hidden; background: #111827; box-shadow: 0 6px 18px rgba(15,23,42,.18); }}
.frame img {{ width: 100%; display: block; border-radius: 4.6mm; }}
.pcap {{ font-size: 8.3pt; color: #6B7280; margin-top: 2mm; font-weight: 600; }}
.steps {{ list-style: none; padding: 0; margin: 2mm 0 3mm; }}
.steps li {{ display: flex; gap: 8px; margin-bottom: 2mm; align-items: flex-start; }}
.steps .n {{ flex: none; width: 20px; height: 20px; border-radius: 50%; background: #FFF1EB; color: {O}; font-weight: 800; font-size: 9pt; display: inline-flex; align-items: center; justify-content: center; margin-top: 1px; }}
.box {{ border-radius: 10px; padding: 3mm 4mm; margin: 2.5mm 0; font-size: 9.8pt; }}
.box .bt {{ font-weight: 800; margin-bottom: 1mm; }}
.box.eg {{ background: #EFF6FF; border-left: 4px solid #3B82F6; }}
.box.tip {{ background: #ECFDF5; border-left: 4px solid #10B981; }}
.box.warn {{ background: #FFFBEB; border-left: 4px solid #F59E0B; }}
.box.why {{ background: #FFF1EB; border-left: 4px solid {O}; }}
.label {{ display:inline-block; font-size: 8.5pt; font-weight: 800; color: #374151; background: #F3F4F6; border-radius: 6px; padding: 0 6px; }}
.k {{ font-weight: 700; color: #111827; }}
.flow {{ display: flex; align-items: flex-start; justify-content: space-between; gap: 2px; margin: 4mm 0; }}
.fl {{ flex: 1; text-align: center; font-size: 8.8pt; line-height: 1.3; }}
.fl b {{ display: block; font-size: 9.3pt; margin-top: 1.5mm; }}
.fl span {{ color: #6B7280; }}
.fli {{ width: 15mm; height: 15mm; border: 2px solid; border-radius: 50%; margin: 0 auto; display: flex; align-items: center; justify-content: center; font-size: 17pt; background: #fff; }}
.arr {{ font-size: 15pt; margin-top: 4mm; flex: none; }}
.card {{ border: 1px solid #E5E7EB; border-radius: 12px; padding: 4mm; background: #fff; }}
.grid2 {{ display: grid; grid-template-columns: 1fr 1fr; gap: 4mm; }}
.grid3 {{ display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 3.5mm; }}
.grid4 {{ display: grid; grid-template-columns: 1fr 1fr 1fr 1fr; gap: 3mm; }}
.diagram {{ background: #F8FAFC; border: 1px solid #E2E8F0; border-radius: 14px; padding: 5mm; margin: 3mm 0 5mm; }}
.dtitle {{ font-weight: 800; font-size: 10.5pt; margin-bottom: 2mm; }}
.pill {{ display:inline-block; border-radius: 99px; padding: 1px 9px; font-size: 8.6pt; font-weight: 700; }}
.chap {{ color: #fff; display: flex; flex-direction: column; justify-content: center; padding: 25mm; }}
.chnum {{ font-size: 90pt; font-weight: 800; opacity: .25; line-height: 1; }}
.chtitle {{ font-size: 36pt; font-weight: 800; line-height: 1.05; letter-spacing: -.02em; margin-top: 4mm; }}
.chsub {{ font-size: 14pt; opacity: .9; margin-top: 5mm; max-width: 140mm; }}
.chwho {{ margin-top: 14mm; font-size: 11pt; background: rgba(255,255,255,.14); border: 1px solid rgba(255,255,255,.25); border-radius: 14px; padding: 5mm 6mm; max-width: 150mm; line-height: 1.6; }}
table.t {{ width: 100%; border-collapse: collapse; font-size: 9.5pt; }}
table.t th {{ text-align: left; background: #111827; color: #fff; padding: 2mm 3mm; font-weight: 700; }}
table.t td {{ padding: 2mm 3mm; border-bottom: 1px solid #F1F5F9; vertical-align: top; }}
table.t tr:nth-child(even) td {{ background: #FAFAFA; }}
.toc {{ display: grid; grid-template-columns: 1fr 1fr; gap: 3mm 6mm; }}
.toc a {{ display:flex; gap: 8px; align-items: center; color: inherit; text-decoration: none; border: 1px solid #F1F5F9; border-radius: 12px; padding: 3mm 4mm; }}
.toc .ti {{ width: 11mm; height: 11mm; border-radius: 10px; display:flex; align-items:center; justify-content:center; font-size: 15pt; color:#fff; flex:none }}
'''

LOGO = f'''<svg viewBox="0 0 64 64" width="{{s}}" height="{{s}}"><rect width="64" height="64" rx="16" fill="{O}"/>
<g fill="#fff"><rect x="9" y="22" width="6" height="20" rx="2"/><rect x="15" y="26" width="4" height="12" rx="1.5"/><rect x="49" y="22" width="6" height="20" rx="2"/><rect x="45" y="26" width="4" height="12" rx="1.5"/></g>
<polyline points="19,32 26,32 29,24 34,40 38,28 41,32 45,32" fill="none" stroke="#fff" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/></svg>'''


def logo(s):
    return LOGO.replace('{s}', str(s))


pages = []

# ======================= COVER =======================
pages.append(f'''<div class="page" style="padding:0;background:#0B0F19;color:#fff">
<div style="position:absolute;inset:0;background:radial-gradient(circle at 85% 10%, rgba(255,90,31,.55), transparent 45%),radial-gradient(circle at 10% 90%, rgba(255,90,31,.35), transparent 40%)"></div>
<div style="position:relative;padding:22mm 18mm 0">
<div style="display:flex;align-items:center;gap:12px">{logo(46)}<div style="font-size:20pt;font-weight:800">Gym<span style="color:{O}">Mantra</span></div></div>
<div style="margin-top:14mm;font-size:12pt;letter-spacing:.2em;color:{O};font-weight:800">OFFICIAL APP GUIDE</div>
<div style="font-size:38pt;font-weight:800;line-height:1.05;margin-top:4mm;letter-spacing:-.02em">App chalana<br>seekhiye —<br><span style="color:{O}">aasaan bhasha mein</span></div>
<div style="font-size:13pt;margin-top:7mm;max-width:120mm;color:#CBD5E1">Gym owner, front desk staff, trainer aur member — sabke liye step-by-step guide, asli app screens aur examples ke saath.</div>
<div style="display:flex;gap:10px;margin-top:9mm">
{''.join(f'<span class="pill" style="background:rgba(255,255,255,.1);border:1px solid rgba(255,255,255,.25);color:#fff;padding:5px 14px;font-size:10pt">{x}</span>' for x in ['🏋️ Gym owner', '🧾 Staff', '💪 Trainer', '🙋 Member'])}
</div></div>
<div style="position:relative;display:flex;gap:7mm;justify-content:center;align-items:flex-start;margin-top:14mm">
<div style="margin-top:16mm">{phone('50_trainer_home', '', 50)}</div>{phone('10_owner_home', '', 58)}<div style="margin-top:16mm">{phone('60_member_home', '', 50)}</div></div>
</div>''')

# ======================= INTRO / ROLES =======================
roles = [
    ('🏋️', 'Gym owner', '#FF5A1F', 'Poora gym chalata hai: members, paise, plans, trainers, staff, branches, reports.'),
    ('🧾', 'Gym staff (front desk)', '#2563EB', 'Owner ke diye kaam: members add karna, fees lena, check-in, enquiries, lockers.'),
    ('💪', 'Trainer', '#16A34A', 'Apne PT clients, sessions ka calendar, diet chart/workout, apni attendance aur salary.'),
    ('🙋', 'Member', '#9333EA', 'Apni membership, QR se check-in, trainers, PT, offers, notices, rating.'),
]
pages.append(page(f'''
<h1>GymMantra kya hai?</h1>
<p class="lead">GymMantra ek hi app hai jismein gym ka <b>poora kaam</b> phone se hota hai — register, fees, attendance, trainers, staff ki salary, reports. Kaagaz ka register, Excel aur alag-alag WhatsApp groups ki zarurat nahi.</p>
<div class="diagram"><div class="dtitle">Ek app, chaar log — sab ek doosre se jude hue</div>
<div style="display:grid;grid-template-columns:1fr 44mm 1fr;gap:4mm;align-items:center">
<div style="display:flex;flex-direction:column;gap:4mm">{''.join(f'<div class="card" style="border-left:5px solid {c}"><b>{i} {t}</b><div style="font-size:9pt;color:#4B5563">{d}</div></div>' for i, t, c, d in roles[:2])}</div>
<div style="text-align:center">{logo(70)}<div style="font-weight:800;margin-top:2mm">GymMantra</div><div style="font-size:8.5pt;color:#6B7280">Sabka data ek jagah,<br>har koi sirf apna hissa dekhta hai</div></div>
<div style="display:flex;flex-direction:column;gap:4mm">{''.join(f'<div class="card" style="border-left:5px solid {c}"><b>{i} {t}</b><div style="font-size:9pt;color:#4B5563">{d}</div></div>' for i, t, c, d in roles[2:])}</div>
</div></div>
<h2>Is guide ko kaise padhein</h2>
<p>Pehle <b>Chapter 1</b> sab padhein (app shuru karna). Uske baad sirf apna chapter padhein:</p>
<div class="toc">
<a><span class="ti" style="background:#0F172A">1</span><div><b>Shuru kaise karein</b><br><span class="fsub">Download, role chunna, sign-up, login — sabke liye</span></div></a>
<a><span class="ti" style="background:{O}">2</span><div><b>Gym owner</b><br><span class="fsub">Dashboard, members, fees, plans, trainers, staff, reports…</span></div></a>
<a><span class="ti" style="background:#2563EB">3</span><div><b>Gym staff (front desk)</b><br><span class="fsub">Rozana ka desk ka kaam, Present lagana, salary slip</span></div></a>
<a><span class="ti" style="background:#16A34A">4</span><div><b>Trainer</b><br><span class="fsub">Gym join karna, PT clients, sessions calendar</span></div></a>
<a><span class="ti" style="background:#9333EA">5</span><div><b>Member</b><br><span class="fsub">Gym join, check-in, membership, PT, rating</span></div></a>
<a><span class="ti" style="background:#64748B">6</span><div><b>Sabke liye</b><br><span class="fsub">Notifications, profile, security, help, FAQ</span></div></a>
</div>
{box('why', 'Is guide ki photos', 'Saari photos <b>asli GymMantra app</b> ki hain, ek demo gym "Lifetime Fitness" ke saath. Naam aur numbers sirf example hain.')}
''', 'Shuruaat'))

# ======================= CHAPTER 1 =======================
pages.append(chapter('01', 'Shuru kaise karein', 'App download karke 2 minute mein account banaiye. Ye chapter sabke liye hai.', '#0F172A', '👉 Aapko chahiye: ek smartphone, internet, aur aapka mobile number / email.<br>👉 Member aur trainer ko gym ka <b>Gym code</b> bhi chahiye (gym ke poster ya owner se milega).'))

pages.append(page(f'''
<h2>Account banane ka poora raasta</h2>
{flow([('📲', 'App install', 'Link se GymMantra APK'), ('🙋', 'Role chunein', 'Member / Owner / Trainer / Staff'), ('📝', 'Sign up', 'Naam, mobile, email, password'), ('🔑', 'Gym code', 'Member/Trainer daalte hain'), ('✅', 'Owner approve', 'Phir app khul jaati hai')])}
{feature('1.1', 'Aap kaun hain? (Role chunna)', 'App kholte hi sabse pehla screen', f"""
<p>App har role ke liye alag dikhti hai, isliye pehle batana hota hai ki aap kaun hain.</p>
{steps(['Apna role tap karein: <span class=label>Member</span>, <span class=label>Gym owner</span>, <span class=label>Trainer</span> ya <span class=label>Gym staff</span>.', '<span class=label>Continue</span> dabayein.', 'Upar <span class=label>EN</span> se bhasha <b>English / हिंदी</b> badal sakte hain.'])}
{box('warn', 'Dhyan dein', 'Role baad mein badalna mushkil hai. Ek trainer gym owner nahi ban sakta aur owner trainer nahi. Galti ho jaye to naya account banayein.')}
{box('eg', 'Example', 'Rahul gym mein workout karta hai → <b>Member</b>. Rakesh ji ka gym hai → <b>Gym owner</b>. Pooja reception pe baithti hai → <b>Gym staff</b>.')}
""", [('01_role', 'Role chunna')])}
''', 'Chapter 1 · Shuru kaise karein'))

pages.append(page(f'''
{feature('1.2', 'Sign up aur Login', 'Naya account ya pehle se bana account', f"""
<p><b>Naya account (Sign up):</b> naam, mobile number, email aur password daalein, "I agree" pe tick karein aur account ban jayega. Google se bhi sign up kar sakte hain.</p>
<p><b>Login:</b> mobile number <i>ya</i> email + password. Google se bana account Google button se hi khulta hai.</p>
{steps(['Login screen pe mobile/email aur password daalein.', 'Password bhool gaye? <span class=label>Forgot password</span> → email pe reset link aayega.', 'Login hote hi aapka dashboard khul jayega.'])}
{box('warn', 'Galat password', '3 baar galat password daalne pe account 15 minute ke liye lock ho jaata hai — ye chori se bachane ke liye hai. 15 minute baad dobara try karein.')}
{box('tip', 'Gym staff ke liye', 'Staff khud sign up nahi karta. Owner aapko app mein add karega — phir aap apne mobile number se login karke ek baar apna password banayenge.')}
""", [('02_login', 'Login'), ('03_signup', 'Sign up')])}
''', 'Chapter 1 · Shuru kaise karein'))

# ======================= CHAPTER 2 OWNER =======================
pages.append(chapter('02', 'Gym owner', 'Aapka poora gym ek screen pe. Members, fees, trainers, staff, branches aur reports — sab yahan.', O, '🗺️ Owner app ke 5 tab: <b>Home</b> (dashboard) · <b>Members</b> · <b>Requests</b> (join requests) · <b>Offers</b> · <b>More</b> (baaki saare tools).<br>🏢 Upar wali branch button se branch badalte hain — poori app usi branch ka data dikhati hai.'))

pages.append(page(f'''
<h2>Gym register karna (pehli baar)</h2>
{flow([('🏋️', 'Gym owner chunein', 'Role screen pe'), ('📝', 'Sign up', 'Apna account'), ('🏢', 'Gym details', 'Naam, address, state, city, PIN, logo'), ('🎁', 'Free trial', 'Pehle 3 mahine sab free'), ('🔢', 'Gym code milta hai', 'Jaise LIFE983')])}
{feature('2.1', 'Home (Dashboard)', 'Aaj gym mein kya hua — ek nazar mein', f"""
<p>Har subah sabse pehle ye screen dekhein. Isme aaj ka poora haal hota hai:</p>
<table class="t"><tr><th>Box</th><th>Matlab</th></tr>
<tr><td><b>Check-ins today</b></td><td>Aaj kitne members aaye</td></tr>
<tr><td><b>Collected today</b></td><td>Aaj kitni fees aayi (₹)</td></tr>
<tr><td><b>Active members</b></td><td>Jinki membership chal rahi hai</td></tr>
<tr><td><b>Ending in 7 days</b></td><td>Jinki membership 7 din mein khatam — inse renew karwayein</td></tr>
<tr><td><b>Members owe money</b></td><td>Jinke paise baaki hain — <span class=label>Review</span> se list</td></tr></table>
{box('tip', 'Gym code card', 'Orange card mein aapka <b>Gym code</b> hai. <span class=label>Share on WhatsApp</span> dabake members/trainers ko bhejein — wo isi code se app mein aapke gym ko join karte hain.')}
{box('eg', 'Example', 'Dashboard pe "2 Ending in 7 days" dikha → tap karein → Amit aur Deepak ke naam → unhe WhatsApp reminder bhejein.')}
""", [('10_owner_home', 'Owner dashboard')])}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.2', 'Members', 'Aapke saare members, unka status aur paise', f"""
<p>Members tab mein har member ki list hai — upar search (naam/mobile) aur filter: <span class=label>All</span> <span class=label>Active</span> <span class=label>Ending soon</span> <span class=label>Expired</span>.</p>
<div class="diagram" style="padding:3mm 4mm"><div class="dtitle">Status ke rang kya batate hain</div>
<div style="display:flex;gap:6px;flex-wrap:wrap;font-size:9pt">
<span class="pill" style="background:#DCFCE7;color:#166534">● Active — sab theek</span>
<span class="pill" style="background:#FEF3C7;color:#92400E">● Ending soon — 7 din se kam</span>
<span class="pill" style="background:#FEE2E2;color:#991B1B">● Expired — khatam</span>
<span class="pill" style="background:#E0F2FE;color:#075985">● Frozen — rok di gayi</span>
<span class="pill" style="background:#F3F4F6;color:#374151">● No plan — plan nahi</span></div></div>
<p><b>Member pe tap karein</b> to unka page khulta hai: plan, kitne din baaki, paise baaki hain ya nahi, entry allowed hai ya nahi, aur ye buttons:</p>
<table class="t"><tr><th>Button</th><th>Kya karta hai</th></tr>
<tr><td>Call / WhatsApp</td><td>Seedha member ko call ya WhatsApp message (text pehle se likha)</td></tr>
<tr><td>Edit</td><td>Naam, mobile, email, branch badalna</td></tr>
<tr><td>Freeze</td><td>Membership kuch din rokna (bimari, travel) — din baad mein jud jaate hain</td></tr>
<tr><td>Correct</td><td>Galti sudharna (galat plan/rakam) — purana record safe rehta hai</td></tr>
<tr><td>Renew membership</td><td>Naya plan / renewal + payment</td></tr>
<tr><td>Remove</td><td>Member ko gym se hatana (unka login bana rehta hai)</td></tr></table>
""", [('11_owner_members', 'Members list'), ('12_owner_member', 'Ek member')], wide=True)}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.3', 'Naya member add karna', 'Jo member app use nahi karta, use bhi aap add kar sakte hain', f"""
{steps(['Members tab → neeche orange <b>+</b> button (ya Home → Quick actions → Add member).', 'Naam, date of birth, gender, mobile, email, state, city, PIN bharein.', '<span class=label>Add member</span> → phir plan chunein, start date, discount aur payment mode (Cash / UPI / Card / Not paid).', 'Member ko apne aap ek Member ID milta hai (jaise LF-1023).'])}
{box('eg', 'Example', 'Neha ne ₹4,000 ka Quarterly plan liya, ₹2,000 abhi diye. Payment mein ₹2,000 likhein → app ₹2,000 "baaki" dikhayegi aur Dues mein naam aa jayega.')}
{box('tip', 'Member khud app pe aaye to', 'Agar member baad mein app download kare, wo aapka Gym code daal ke join request bhejta hai. Aap approve karenge to uska purana record jud jayega.')}
{box('warn', 'Paise baaki ho to entry?', 'Har membership pe aap tay karte hain ki paise baaki hone pe member andar aa sakta hai ya nahi (<b>Allow entry while due</b>). Gym ka default Settings mein hai.')}
""", [('13_owner_add_member', 'Add member')])}
{feature('2.4', 'Requests (join requests)', 'Koi bhi aapki marzi ke bina gym join nahi kar sakta', f"""
<p>Member ya trainer jab aapka Gym code daal ke join karta hai, request yahan aati hai. Tabs: <span class=label>Join</span> <span class=label>PT</span> <span class=label>Plans</span> <span class=label>Move</span> (branch badalne ki request).</p>
{steps(['Request pe naam, mobile, photo dekhein.', '<span class=label>Approve</span> ya <span class=label>Decline</span> karein.', 'Approve hote hi member ko notification jaata hai aur uski app khul jaati hai.'])}
""", [('14_owner_requests', 'Requests')], pw=36)}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
<h2>Membership ki zindagi — ek diagram mein</h2>
<div class="diagram">
{flow([('🆕', 'Plan diya', 'Start date se shuru'), ('🟢', 'Active', '7+ din baaki'), ('🟡', 'Ending soon', 'Aakhri 7 din · reminder'), ('🔴', 'Expired', 'Entry band'), ('🔁', 'Renew', 'Naya plan, purana record safe')], '#16A34A')}
<div class="grid3" style="margin-top:3mm;font-size:9pt">
<div class="card"><b>❄️ Freeze</b><br>Plan ke "freeze days" tak membership rok sakte hain. Freeze mein check-in band, aur end date utne din aage badh jaati hai. Jaldi khatam kiya to bache din wapas.</div>
<div class="card"><b>💸 Dues (baaki paise)</b><br>Poore paise nahi mile to member "due" mein dikhta hai. Payment add karte hi due kam/khatam.</div>
<div class="card"><b>🛠️ Correct</b><br>Galti hui to purana record badla nahi jaata — ek naya sahi record banta hai aur mile hue paise usmein chale jaate hain.</div>
</div></div>
{feature('2.5', 'Membership plans', 'Aapke gym ke plans aur unki keemat', f"""
<p>More → <b>Membership plans</b>. Har plan mein: naam, mahine, keemat, joining fee, freeze days, aur kya-kya milta hai (Gym floor, Locker, Diet chart…).</p>
{steps(['<span class=label>New plan</span> dabayein.', 'Naam (jaise Quarterly), mahine (3), keemat (₹4,000), joining fee, freeze days bharein.', 'Save karein — ye plan member add/renew karte waqt dikhega aur member bhi app mein dekh sakta hai.'])}
{box('tip', 'Pencil ✏️', 'Plan ki keemat badalne se purane members ki membership nahi badalti — sirf nayi memberships pe naya rate lagta hai.')}
""", [('18_owner_plans', 'Plans')])}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
<h2>Attendance / Check-in kaise hota hai</h2>
<div class="diagram"><div class="dtitle">Member gym aata hai → 5 second mein entry</div>
{flow([('🚶', 'Member gym pahuncha', 'Phone mein GymMantra'), ('📷', 'Gym QR scan', 'Deewar pe laga Check-in QR'), ('📍', 'Location check', 'Gym ke 20 m andar hona zaruri'), ('🧠', 'App jaanchti hai', 'Plan active? paise? freeze?'), ('✅', 'Allowed', 'Ya ❌ reason ke saath')], '#2563EB')}
<div class="grid2" style="font-size:9pt;margin-top:2mm">
<div class="card" style="border-left:4px solid #16A34A"><b>✅ Allowed</b> — plan active hai. Attendance lag gayi, owner ke dashboard pe gin li gayi.</div>
<div class="card" style="border-left:4px solid #DC2626"><b>❌ Blocked</b> — plan khatam, freeze chal raha, ya paise baaki (aur entry allowed nahi). Member ko wajah dikhti hai.</div>
</div></div>
{feature('2.6', 'Attendance page aur Gym QR', 'Kaun aaya, kab aaya — aur Excel', f"""
<p><b>Attendance</b> (More → Attendance): <b>Members</b> — din wise kaun aaya + Excel download. <b>Staff &amp; trainers</b> — mahine ki hazri.</p>
<p><b>Gym QR</b> (More → Gym QR) mein do QR hain:</p>
<table class="t"><tr><th>QR</th><th>Kahan use hota hai</th></tr>
<tr><td><b>Join QR</b></td><td>Poster/Instagram pe lagayein — scan karke log join request bhejte hain</td></tr>
<tr><td><b>Check-in QR</b></td><td>Gym ke andar deewar pe chipkayein — members roz isse check-in karte hain</td></tr></table>
{box('tip', 'Phone nahi hai member ke paas?', 'Desk pe <b>Manual check-in</b> se member ka naam chun ke entry laga sakte hain.')}
""", [('16_owner_attendance', 'Attendance'), ('32_owner_gym_qr', 'Gym QR')], wide=True, pw=34)}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.7', 'Trainers aur PT (Personal Training)', 'Trainer ke packages, aapka hissa, aur PT ka hisaab', f"""
<p>Trainer bhi Gym code se join karta hai; aap Requests mein approve karte hain. Phir More → <b>Trainers</b> mein har trainer ke <b>PT packages</b> (jaise 12 sessions / 30 din = ₹6,000) aur <b>trainer ka share %</b> set karein.</p>
{box('eg', 'Example — paisa kaise batega', 'Suraj ne Rajeev ka ₹6,000 ka PT package liya. Rajeev ka share 50% hai → Rajeev ka hissa ₹3,000, gym ka ₹3,000. Aapne Rajeev ko ₹2,000 de diye → <b>PT accounts</b> mein "To pay ₹1,000" dikhega.')}
{box('tip', 'PT clients', 'More → <b>PT clients</b> mein har trainer ke clients, kitne session hue aur kitne baaki — sab ek jagah. Trainer jo calendar bharta hai wahi aapko dikhta hai.')}
""", [('21_owner_trainers', 'Trainers'), ('23_owner_pt_accounts', 'PT accounts')], wide=True)}
<div class="diagram"><div class="dtitle">PT ka poora raasta</div>
{flow([('🙋', 'Member request', 'Trainer + package chunta hai'), ('🔔', 'Notification', 'Trainer aur owner ko'), ('✅', 'Owner approve', 'Paise lekar'), ('📅', 'Trainer calendar', 'Done / Missed / Planned'), ('💰', 'Trainer ko payment', 'PT accounts se')], '#16A34A')}</div>
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.8', 'Offers aur Notices', 'Members ke dashboard pe aapka message', f"""
<p><b>Offer</b> = discount/scheme (banner photo ke saath), last date tak dikhta hai. <b>Notice</b> = zaruri suchna (gym band, timing change).</p>
{steps(['Offers tab → <span class=label>New offer</span>, ya More → Notices → New notice.', 'Heading + message likhein (Quick start buttons se tayyar text bhi le sakte hain).', 'Kisko bhejna hai: Members (sab / active / expired) aur/ya Trainers, kaunsi branch.', 'Last day chunein → bhejein. Sabke phone pe notification + dashboard pe card.'])}
{box('eg', 'Example', 'Diwali pe "Quarterly aur Annual pe 20% off" ka offer sirf <b>Expired</b> members ko → purane members wapas aayenge.')}
""", [('19_owner_offers', 'Offers'), ('20_owner_notice', 'New notice')], wide=True)}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.9', 'Staff aur unke rights', 'Front desk ko sirf utna hi do jitna zaruri hai', f"""
<p>More → <b>Staff</b> → <span class=label>Add staff</span>: naam, mobile, details. Staff apne mobile se login karke password banata hai.</p>
<p>Har staff ke <b>rights</b> aap chunte hain — jaise Members dekhna, Payment lena, Check-in, Requests, Offers, Reports, Plans, Enquiries, Lockers, Transfers. Tayyar presets bhi hain: <span class=label>Reception</span> <span class=label>Check-in only</span> <span class=label>Manager</span>.</p>
{box('eg', 'Example', 'Pooja ko "Reception" diya → wo member add kar sakti hai, fees le sakti hai, check-in laga sakti hai — par Reports aur staff salary nahi dekh sakti.')}
{box('tip', 'Har staff ek branch mein', 'Staff jis branch mein add hua, sirf wahi branch ka kaam dekhta hai.')}
""", [('24_owner_staff', 'Staff')])}
{feature('2.10', 'Staff salary', 'Hazri ke hisaab se salary, advance, slip', f"""
<p>More → <b>Staff salary</b>. Har person ki salary ek baar set karein: mahine ki fixed ya roz ke hisaab se, kaam ke din, free chhuttiyan, absent pe cut ho ya nahi. Bina app wale (safai, guard) bhi <span class=label>Person without app</span> se.</p>
{steps(['Person pe tap → salary set karein.', 'Mahine mein advance / bonus / cut jodein.', '<span class=label>Pay salary</span> se payment likhein — staff ko apni slip app mein dikhti hai.'])}
{box('tip', 'Branch', 'Jo branch Home pe khuli hai, sirf usi ke staff ki salary dikhti hai.')}
""", [('25_owner_salary', 'Staff salary')])}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.11', 'Staff attendance', 'Staff aur trainer roz "Present" lagate hain', f"""
<p>Staff/trainer gym pahunch ke apni app mein <span class=label>Mark today: Present</span> dabate hain — sirf gym ki location pe hi lagta hai. 11 baje aur 5 baje reminder aata hai agar nahi lagaya.</p>
<p>Aap More → Attendance → Staff &amp; trainers mein har person ka mahina dekhte hain. Kisi din ko tap karke sahi kar sakte hain (wajah likh ke). Excel bhi download hota hai.</p>
""", [('26_owner_staff_attendance', 'Staff attendance')])}
{feature('2.12', 'Lockers', 'Kis member ke paas kaunsa locker, kab tak', f"""
<p>More → <b>Lockers</b>. Rang se samjhein: <span class="pill" style="background:#DCFCE7;color:#166534">Free</span> <span class="pill" style="background:#E0E7FF;color:#3730A3">Given</span> <span class="pill" style="background:#FEF3C7;color:#92400E">Khatam hone wala</span>.</p>
{steps(['Free locker pe tap → member chunein, kab tak, fees, key deposit.', 'Member ko app mein apna locker number dikhta hai; 3 din pehle aur aakhri din reminder.', 'Locker khali karte waqt deposit wapas ya (chaabi khoyi) rakh lein.'])}
""", [('27_owner_lockers', 'Lockers')])}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.13', 'Enquiries (follow-up)', 'Jo log poochne aaye — unhe member banana', f"""
<p>Koi gym dekhne aaya, fees poochi, par join nahi kiya — use More → <b>Enquiries</b> mein likh lein: naam, mobile, kya chahiye (Gym, PT, Zumba), kahan se aaya (Instagram, walk-in), kitna interested (Hot/Warm/Cold), aur <b>kab call karna hai</b>.</p>
{steps(['<span class=label>New enquiry</span> → details bharein.', 'Roz subah 9 baje "Enquiry calls today" ka reminder.', 'Call karke note likhein, agla call date.', 'Join kar le to <span class=label>Joined</span> → seedha Add member form bhara hua khulta hai.'])}
{box('eg', 'Example', 'Rohit Instagram se aaya, evening batch chahiye, "Hot". Aaj 6 baje call reminder → call kiya → agle din join.')}
""", [('28_owner_enquiries', 'Enquiries')])}
{feature('2.14', 'Ratings & reviews', 'Members ki rating — aur best reviews dashboard pe', f"""
<p>Members gym ko aur trainer ko stars + comment dete hain. More → <b>Ratings &amp; reviews</b> mein har branch ka alag card.</p>
<p>Jo review member ne "dikhane ki ijazat" ke saath diya, use aap <span class=label>Show on dashboards</span> kar sakte hain — wo us branch ke members, trainers aur staff ke Home pe "What members say" mein photo ke saath dikhta hai, aur join page pe bhi.</p>
{box('tip', 'Trainer rating', 'Trainer ko sirf apne stars aur tags dikhte hain — kisne kya likha, wo sirf aap dekhte hain.')}
""", [('29_owner_ratings', 'Ratings')])}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.15', 'Reports', 'Kitna kamaya, kitna baaki, kitna kharcha', f"""
<p>More → <b>Reports</b> (7 / 30 / 90 din ya apni dates). Teen hisse:</p>
<table class="t"><tr><th>Tab</th><th>Kya dikhata hai</th></tr>
<tr><td><b>Entries</b></td><td>Har membership/PT entry — Paid, Pending, Overdue filter + Excel</td></tr>
<tr><td><b>Summary</b></td><td>Roz ki collection ka graph, check-ins, kaunsa plan kitna bika</td></tr>
<tr><td><b>Money</b></td><td>Alag cards: Memberships, PT, Lockers, Staff salary — aur neeche <b>kul bacha</b></td></tr></table>
""", [('17_owner_reports', 'Reports')])}
<div class="diagram"><div class="dtitle">Money report ka hisaab</div>
<div style="display:flex;align-items:center;gap:3mm;font-size:9.5pt">
<div class="card" style="flex:1;text-align:center"><b>🎫 Memberships</b><br>+ ₹92,500</div><div style="font-size:16pt">+</div>
<div class="card" style="flex:1;text-align:center"><b>🏋 PT</b><br>+ ₹24,000</div><div style="font-size:16pt">+</div>
<div class="card" style="flex:1;text-align:center"><b>🔐 Lockers</b><br>+ ₹4,800</div><div style="font-size:16pt">−</div>
<div class="card" style="flex:1;text-align:center;border-color:#FCA5A5"><b>💵 Salary + trainer hissa</b><br>− ₹70,400</div><div style="font-size:16pt">=</div>
<div class="card" style="flex:1;text-align:center;background:#0F172A;color:#fff;border:none"><b>Bacha</b><br><span style="color:#4ADE80;font-weight:800">₹50,900</span></div>
</div><div class="fsub" style="margin-top:2mm">Example numbers. Staff salary card sirf owner ko dikhta hai.</div></div>
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
<h2>Branches — ek gym, kai jagah</h2>
<div class="diagram">
<div style="display:grid;grid-template-columns:1fr 1.2fr 1fr;gap:4mm;align-items:center">
<div class="card" style="text-align:center"><b>🏢 Main branch</b><br><span class="fsub">Code: LIFE983</span><br>Apna Check-in QR<br>Apna staff, members</div>
<div style="text-align:center">{logo(54)}<br><b>Lifetime Fitness</b><br><span class="fsub">Ek owner · ek app · alag-alag hisaab</span></div>
<div class="card" style="text-align:center"><b>🏢 Boring Road</b><br><span class="fsub">Code: BORI492</span><br>Apna Check-in QR<br>Apna staff, members</div></div>
<div class="grid3" style="margin-top:4mm;font-size:9pt">
<div class="card">📍 Upar wali <b>branch button</b> se branch badlein — members, dashboard, reports, attendance us branch ke ho jaate hain.</div>
<div class="card">🔢 Har branch ka <b>apna code</b> — member jis code se join kare, usi branch mein jata hai.</div>
<div class="card">🔁 Member ek gym ki ek hi branch mein hota hai. Badalna ho to owner <b>Move</b> kare ya member transfer request bheje.</div></div></div>
{feature('2.16', 'Branches aur Gym settings', 'Naya branch, logo, address, WhatsApp number', f"""
{steps(['More → <b>Branches</b> → <span class=label>Add branch</span>: naam, address, state, city, PIN, logo.', 'Har branch ka QR aur code yahin se share karein.', 'More → <b>Gym settings</b>: gym ka naam, phone, <b>WhatsApp number</b> (reminders/receipts isi se), Member ID prefix (jaise LF).'])}
""", [('31_owner_branches', 'Branches'), ('30_owner_settings', 'Gym settings')])}
''', 'Chapter 2 · Gym owner'))

pages.append(page(f'''
{feature('2.17', 'GymMantra plan (Subscription)', 'Free trial ke baad aapka plan', f"""
<p>Naye gym ko <b>pehle 3 mahine sab kuch free</b> milta hai. Phir More → <b>Subscription</b> mein plan chunein — Starter, Growth ya Pro (mahina ya saal; saal pe 2 mahine free).</p>
{steps(['Plan chunein → <span class=label>Pay</span>.', 'Phone mein jo UPI apps hain (GPay, PhonePe, Paytm…) unme se chunein aur pay karein.', 'Wapas aate hi plan chalu aur receipt (PDF download/share) ban jaati hai.'])}
{box('warn', 'Plan khatam hone se pehle', 'Plan khatam hone se 7 din pehle roz reminder aata hai. Kuch features (Offers, PT, Reports, extra branches) plan ke hisaab se khulte hain.')}
""", [('33_owner_subscription', 'Subscription')])}
{feature('2.18', 'More menu — saare tools ek jagah', 'Jo cheez Home pe nahi, wo yahan', f"""
<p>More tab mein: Subscription, Enquiries, Lockers, Staff, Attendance, Staff salary, Ratings, Import members (Excel/CSV se purane members ek saath), Gym QR, Gate (WiFi gate lock — hardware chahiye), Notices, Trainers, PT clients, PT accounts, Offers, Reports, Branches, Membership plans, Gym settings, Transfer gym.</p>
{box('tip', 'Purane register se shuru', '<b>Import members</b> se Excel sheet daal ke saare purane members ek baar mein jod sakte hain.')}
""", [('15_owner_more', 'More')])}
''', 'Chapter 2 · Gym owner'))

# ======================= CHAPTER 3 STAFF =======================
pages.append(chapter('03', 'Gym staff (front desk)', 'Reception ka rozana kaam — owner ne jo rights diye, wahi dikhega.', '#2563EB', '🔑 Pehli baar: Role screen pe <b>Gym staff</b> chunein → owner ne jo mobile number daala usse login → apna password banayein.<br>📌 Aap sirf apni branch ka kaam dekhte hain.'))

pages.append(page(f'''
{feature('3.1', 'Staff ka Home', 'Owner jaisa dashboard — aapke rights ke hisaab se', f"""
<p>Aapko wahi dikhega jo owner ne allow kiya: members, payments, check-in, requests, enquiries, lockers… Home pe aaj ke check-ins, collection, dues aur members ke reviews ("What members say").</p>
<table class="t"><tr><th>Roz ka kaam</th><th>Kahan</th></tr>
<tr><td>Naya member add / renew</td><td>Members tab → + / member page → Renew</td></tr>
<tr><td>Fees lena</td><td>Member page → payment</td></tr>
<tr><td>Bina phone wale ki entry</td><td>Attendance → Manual check-in</td></tr>
<tr><td>Poochne aaye logon ko likhna</td><td>More → Enquiries</td></tr>
<tr><td>Locker dena</td><td>More → Lockers</td></tr></table>
{box('warn', 'Kuch nahi dikh raha?', 'Agar koi option nahi dikh raha to owner ne wo right nahi diya — owner se maangein.')}
""", [('40_staff_home', 'Staff home'), ('41_staff_more', 'Staff More')], wide=True)}
''', 'Chapter 3 · Gym staff'))

pages.append(page(f'''
{feature('3.2', 'Apni attendance — Present lagana', 'Roz gym pahunch ke ek tap', f"""
{steps(['More → <b>My attendance</b>.', 'Gym ke andar khade hokar <span class=label>Mark today: Present</span> dabayein (location on rakhein).', 'Calendar mein hara din = Present. Owner ko bhi turant dikhta hai.'])}
{box('warn', 'Location', 'Ye sirf gym ki location (lagbhag 20 m) ke andar lagta hai. Ghar se nahi lagega. Fake GPS apps pakdi jaati hain.')}
{box('tip', 'Bhool gaye?', '11 baje aur 5 baje reminder aata hai. Galti ho to owner din ko sahi kar sakta hai.')}
""", [('42_staff_my_attendance', 'My attendance')])}
{feature('3.3', 'My salary', 'Apni salary slip, kabhi bhi', f"""
<p>More → <b>My salary</b>: is mahine kitne din present, salary, advance, kitna mila, kitna baaki. Purane mahine bhi dekh sakte hain.</p>
{box('eg', 'Example', 'Pooja: 4 din present, salary ₹12,000, ₹2,000 advance liya → baaki ₹10,000.')}
{box('tip', 'Privacy', 'Aapki salary sirf aap aur owner dekhte hain.')}
""", [('43_staff_salary', 'My salary')])}
''', 'Chapter 3 · Gym staff'))

# ======================= CHAPTER 4 TRAINER =======================
pages.append(chapter('04', 'Trainer', 'Apne PT clients, unke sessions aur diet/workout — sab phone mein.', '#16A34A', '🔑 Role screen pe <b>Trainer</b> → sign up → gym ka <b>Gym code</b> daalein, kya sikhate hain (Strength, Yoga…) aur experience → owner approve kare.<br>💡 Approve hone tak bhi trainer dashboard khulta hai ("Join your gym" card ke saath).'))

pages.append(page(f'''
{feature('4.1', 'Trainer ka Home', 'Aaj kya karna hai — ek nazar mein', f"""
<table class="t"><tr><th>Box</th><th>Matlab</th></tr>
<tr><td><b>PT clients</b></td><td>Kitne clients abhi chal rahe</td></tr>
<tr><td><b>Sessions today</b></td><td>Aaj kitne session plan hain</td></tr>
<tr><td><b>Ending soon</b></td><td>Jinka package jaldi khatam</td></tr>
<tr><td><b>My rating</b></td><td>Members ki di hui rating (stars + tags)</td></tr>
<tr><td><b>Salary</b></td><td>Apni salary slip</td></tr></table>
<p>Upar gym ke <b>notices</b> aur offers, neeche "What members say" aur <b>My clients</b>. "My attendance" se roz Present lagayein (staff jaisa).</p>
""", [('50_trainer_home', 'Trainer home'), ('51_trainer_clients', 'My PT clients')], wide=True)}
''', 'Chapter 4 · Trainer'))

pages.append(page(f'''
{feature('4.2', 'Session calendar', 'Har client ka hisaab — Done, Missed, Planned', f"""
<p>Client pe tap karein → upar Done / Left / Missed, neeche mahine ka calendar.</p>
<div class="diagram" style="padding:3mm 4mm;font-size:9.3pt">
<span class="pill" style="background:#16A34A;color:#fff">Done</span> session ho gaya &nbsp;
<span class="pill" style="border:1.5px solid {O};color:{O}">Planned</span> aage ka plan (member ko reminder) &nbsp;
<span class="pill" style="background:#DC2626;color:#fff">Missed</span> client nahi aaya</div>
{steps(['Calendar mein din tap karein.', 'Aaj/beete din ke liye <span class=label>Done</span> ya <span class=label>Missed</span>; aane wale din ke liye <span class=label>Planned</span>.', 'Member aur owner ko bilkul wahi calendar dikhta hai.'])}
{box('warn', 'Purane din lock', '2 din se purane session trainer nahi badal sakta — galti ho to owner se kahein.')}
{box('tip', 'Diet chart aur workout', 'Client ke page se uska diet chart aur workout plan (PDF bhi) daal sakte hain — member ko turant dikhta hai.')}
""", [('52_trainer_client', 'Client calendar')])}
{feature('4.3', 'Profile', 'Theme, bhasha, apni jaankari', f"""
<p>Profile mein Light/Dark theme, English/हिंदी, personal details, password, <b>Logged-in devices</b> aur "About me" (jo members trainer list mein dekhte hain).</p>
""", [('54_trainer_profile', 'Trainer profile')])}
''', 'Chapter 4 · Trainer'))

# ======================= CHAPTER 5 MEMBER =======================
pages.append(chapter('05', 'Member', 'Apni membership, check-in, trainer aur PT — sab ek tap pe.', '#9333EA', '🔑 Role screen pe <b>Member</b> → sign up → Home pe <b>Join a gym</b> → gym ka code daalein (jaise LIFE983) → request bhejein → gym approve kare.<br>🏷️ Code daalte hi us branch ki rating aur members ke reviews dikhte hain.'))

pages.append(page(f'''
{feature('5.1', 'Member ka Home', 'Aapki membership ka poora haal', f"""
<p>Home pe: aapka plan, kitne din baaki, paise baaki hain to kitne, is mahine kitni baar aaye, last visit, gym ke offers aur notices, locker, aur "What members say".</p>
<p>Neeche <span class=label>Rate gym</span> aur <span class=label>Rate trainer</span> — apna experience batayein.</p>
{box('eg', 'Example', 'Home pe "Ends in 5 days" dikha → membership card kholein → <b>See gym&#39;s plans</b> se naya plan dekhein, ya desk pe renew karwayein.')}
""", [('60_member_home', 'Member home'), ('64_member_membership', 'Membership')], wide=True, pw=42)}
{feature('5.2', 'Gym join karna', 'Pehli baar ya naya gym', f"""
{steps(['Home → Join a gym (ya Profile se).', 'Gym code daalein → <span class=label>Find gym</span>.', 'Gym ka naam, branch, rating aur reviews dekhein → <span class=label>Send join request</span>.'])}
""", [('67_member_join', 'Join a gym')], pw=36)}
''', 'Chapter 5 · Member'))

pages.append(page(f'''
{feature('5.3', 'Check-in (attendance)', 'Gym pahunch ke QR scan', f"""
{steps(['Gym pahunch ke neeche <b>Check-in</b> tab kholein.', 'Gym ki deewar pe laga <b>Check-in QR</b> scan karein (camera ki permission dein).', 'Location on rakhein — gym ke andar hona zaruri hai.', '✅ dikha = attendance lag gayi.'])}
{box('warn', 'Entry nahi hui?', 'Wajah screen pe likhi aati hai: plan khatam, freeze chal raha, ya paise baaki. Desk pe baat karein.')}
{box('tip', 'Camera kaam nahi kar raha?', 'Home → <span class=label>Show check-in QR</span> → apna QR front desk ko dikhayein. Ye code har 30 second badalta hai, isliye screenshot kaam nahi karta.')}
""", [('61_member_myqr', 'Apna check-in QR')])}
{feature('5.4', 'Trainers aur PT', 'Trainer chunein, package lein', f"""
{steps(['<b>Trainers</b> tab → trainer ka naam, kya sikhate hain, experience, packages.', 'Package chunein → request. Trainer aur owner ko notification.', 'Owner approve kare (payment ke baad) → aapka PT calendar shuru. Har session Done/Missed aapko bhi dikhta hai.'])}
""", [('62_member_trainers', 'Trainers')])}
''', 'Chapter 5 · Member'))

pages.append(page(f'''
{feature('5.5', 'My plan — diet aur workout', 'Trainer ka diya plan', f"""
<p><b>My plan</b> tab mein trainer ka diya <b>Diet</b> (kitni calories, protein, kab kya khana) aur <b>Workout</b> (kaunse din kaunsi exercise, sets, weight). Trainer badle to notification aata hai.</p>
<p><b>3D exercise guides</b> — 40 exercises ki video, sahi tareeka dekh ke karein.</p>
{box('eg', 'Example', 'Breakfast 8 baje: 4 egg whites, 2 brown bread, 1 banana. Monday: Chest + Triceps — Bench press 4 x 10, 40 kg.')}
""", [('63_member_plan', 'My plan')])}
{feature('5.6', 'Rating dena', 'Aapki rai gym ko behtar banati hai', f"""
{steps(['Home → <span class=label>Rate gym</span> ya <span class=label>Rate trainer</span>.', 'Stars + tags (jaise Clean, Good trainers) + comment.', '"Mera review dikha sakte hain" tick karein to owner use dashboard pe dikha sakta hai (aapki photo ke saath).'])}
{box('tip', 'Badal sakte hain', 'Gym rating kabhi bhi badal sakte hain; trainer rating har mahine.')}
""", [('66_member_rate', 'Rate')])}
''', 'Chapter 5 · Member'))

# ======================= CHAPTER 6 COMMON =======================
pages.append(chapter('06', 'Sabke liye', 'Notifications, profile, security aur help — har role ke kaam ki cheezein.', '#475569', '🔔 Notification pe tap karein → seedha wahi page khulta hai.<br>🛡️ Logged-in devices se apna account surakshit rakhein.<br>🆘 Koi dikkat? Help se GymMantra support ko ticket.'))

pages.append(page(f'''
{feature('6.1', 'Notifications', 'Ghanti 🔔 pe laal number = naye messages', f"""
<p>Payment receipt, membership added, PT planned, notices, offers, reminders — sab yahan aur phone pe push. Notification tap karein to wahi page khulta hai jiske baare mein hai.</p>
""", [('69_member_notifications', 'Notifications')])}
{feature('6.2', 'Logged-in devices (security)', 'Aapka account kahan-kahan khula hai', f"""
<p>Profile → <b>Logged-in devices</b>. Har phone/browser ka naam, shehar aur last time.</p>
{steps(['Kisi phone pe <span class=label>Log out</span> → wahan app turant band.', '<span class=label>Log out everywhere else</span> → baaki sab band, ye phone chalu.', 'Anjaan login dikhe → <span class=label>A login was not me</span> → sab band + naya password.'])}
{box('warn', 'Alert', 'Naye phone se login hote hi notification aata hai: "New login on your account". Aap nahi the? Turant "A login was not me" dabayein.')}
""", [('35_owner_devices', 'Logged-in devices')])}
''', 'Chapter 6 · Sabke liye'))

pages.append(page(f'''
{feature('6.3', 'Profile aur settings', 'Apni photo, details, theme, bhasha', f"""
<table class="t"><tr><th>Option</th><th>Kya karta hai</th></tr>
<tr><td>Photo</td><td>Profile photo lagayein — gym aur reviews mein dikhti hai</td></tr>
<tr><td>Theme</td><td>Light / Dark / Auto</td></tr>
<tr><td>Language</td><td>English / हिंदी</td></tr>
<tr><td>Personal details</td><td>Naam, DOB, address, mobile/email</td></tr>
<tr><td>Change password</td><td>Badalne pe baaki phone apne aap logout</td></tr>
<tr><td>Delete my account</td><td>Account hamesha ke liye hatana</td></tr></table>
""", [('65_member_profile', 'Profile')])}
{feature('6.4', 'Help & Support', 'GymMantra team se seedhi baat', f"""
<p>FAQ padhein, ya <span class=label>New ticket</span> banayein. Har ticket ka number milta hai (jaise GM-1001).</p>
<div class="diagram" style="padding:3mm">{flow([('📨', 'Open', 'Aapne bheja'), ('🛠️', 'In progress', 'Team dekh rahi'), ('💬', 'Waiting', 'Jawab aaya, aapki baari'), ('✅', 'Resolved', '7 din tak reply kar sakte'), ('🔒', 'Closed', 'Band')], '#475569')}</div>
""", [('68_member_help', 'Help')])}
''', 'Chapter 6 · Sabke liye'))

faq = [
    ('Password bhool gaya?', 'Login → Forgot password → email pe link. Gym ne account banaya tha to pehli login pe naya password banta hai.'),
    ('Account lock ho gaya?', '3 galat password = 15 minute lock. Ruk ke dobara try karein ya Forgot password.'),
    ('Check-in nahi ho raha?', 'Location on karein, gym ke andar khade hon, sahi branch ka QR scan karein. Plan khatam/freeze/paise baaki ho to entry nahi.'),
    ('Join request ka jawab nahi aaya?', 'Gym owner/desk ko bolein — Requests tab mein approve karna hota hai.'),
    ('Galat branch join ho gayi?', 'Member: transfer request bhejein (agar gym ne on kiya ho). Owner: member page → Edit/Move.'),
    ('Galat payment likh di?', 'Member page → Correct. Purana record safe rehta hai, naya sahi ban jaata hai.'),
    ('Staff ko koi option nahi dikh raha?', 'Owner ne wo right nahi diya — owner Staff → us person → rights badle.'),
    ('Kisi ne mera account khola?', 'Profile → Logged-in devices → "A login was not me" → naya password.'),
    ('Notification nahi aa raha?', 'Phone settings mein GymMantra ke notifications on karein, battery saver se app hatayein.'),
    ('App mein Hindi chahiye?', 'Role screen pe EN button, ya Profile → Language → हिंदी.'),
]
pages.append(page(f'''
<h2>Aksar pooche jaane wale sawaal (FAQ)</h2>
<div class="grid2">{''.join(f'<div class="card"><b>❓ {q}</b><div style="font-size:9.5pt;color:#4B5563;margin-top:1mm">{a}</div></div>' for q, a in faq)}</div>
<div class="diagram" style="margin-top:6mm;text-align:center">
{logo(44)}<div style="font-weight:800;font-size:13pt;margin-top:2mm">Aur madad chahiye?</div>
<div class="fsub">App mein <b>Help &amp; Support</b> → New ticket. GymMantra team jaldi jawab degi.</div></div>
''', 'Chapter 6 · Sabke liye'))

html = f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS}</style></head><body>{"".join(pages)}</body></html>'
open('/home/claude/guide/guide.html', 'w').write(html)
print('pages', len(pages))
