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
    return f'<div class="page">{head}{inner}<div class="foot">GymMantra · App Manual</div></div>'


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


