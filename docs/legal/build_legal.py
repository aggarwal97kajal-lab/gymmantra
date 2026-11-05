import json, re

def parse(path):
    lines = open(path).read().split('\n')
    secs = []; cur = None
    for ln in lines:
        s = ln.strip()
        m = re.match(r'^(\d+)\. (.+)$', s)
        if m and int(m.group(1)) == len(secs) + 1:
            cur = {'h': m.group(2), 'p': []}; secs.append(cur); continue
        if s.startswith('Operator Details Schedule'):
            break
        if cur is None or not s:
            continue
        if s.startswith('-   '):
            cur['p'].append('• ' + s[4:])
        else:
            cur['p'].append(s)
    return secs

def edit(secs, n, old, new):
    sec = secs[n - 1]
    for i, p in enumerate(sec['p']):
        if old in p:
            sec['p'][i] = p.replace(old, new) if new is not None else None
            sec['p'] = [x for x in sec['p'] if x is not None]
            return
    raise SystemExit(f'not found in {n}: {old[:50]}')

OPERATOR = 'GymMantra is a brand and product operated by Suraj Kumar Thakur, its founder and individual operator (the “operator”). GymMantra is not currently incorporated as a company; “GymMantra” is the product/brand name and does not by itself identify a separate legal person.'
CONTACT = ['Operator: Suraj Kumar Thakur, founder and individual operator of GymMantra (not incorporated as a company).',
           'Contact channel: GymMantra app → Help & Support → Raise a ticket.',
           'Territory: India.']

# ---------------- Terms
t = parse('/tmp/legal/terms.txt')
assert len(t) == 19, len(t)
edit(t, 1, 'GymMantra is currently a brand and product operated by its founder/operator', None)
t[0]['p'].insert(1, OPERATOR)
edit(t, 10, '(c) generate or reuse QR codes or tokens to bypass check-in controls;', '(c) generate or reuse QR codes or tokens, use another branch’s or another person’s check-in, or use fake-location tools to bypass check-in or attendance controls;')
edit(t, 18, ' No exclusive city or court is designated in this draft because the operator’s principal place of business has not yet been supplied.', '')
edit(t, 19, 'The in-app ticket channel is the contact method currently designated by GymMantra for this draft.', None)
edit(t, 19, 'The ticket interface should provide a reference number and allow you to track replies.', 'Each ticket gets a reference number (for example GM-1001) and you can follow replies in the app.')
t[18]['p'] += CONTACT

# ---------------- Privacy
p = parse('/tmp/legal/privacy.txt')
assert len(p) == 17, len(p)
edit(p, 1, 'GymMantra is currently a brand/product operated by its founder/operator', None)
p[0]['p'].insert(1, OPERATOR + ' This Policy applies to gym owners, administrators, front-desk staff, trainers, members, prospective users and parents or guardians acting for minors.')
edit(p, 3, 'Attendance and access records: QR check-in tokens or scan events, timestamps, branch, result of the scan, staff member who recorded the event, visit counts and related anti-fraud/security information.',
     'Attendance and access records: check-in events (time, branch, result such as allowed or stopped, and whether it was a self check-in or a manual entry by gym staff), visit counts, and for front-desk staff and trainers the days they marked themselves present, with the distance from the gym at that moment.')
edit(p, 3, 'Gym and membership records: gym and branch name/address,', 'Gym and membership records: gym and branch name, address, logo and GSTIN (if entered by the owner),')
edit(p, 3, 'payment status, UPI transaction reference and related reconciliation information.', 'payment status, the GymMantra payment ID and related reconciliation information.')
sec4 = [
    'The mobile app may request camera access to scan the gym’s check-in QR code and, where you use the feature, to take a profile photograph. If you select a photograph or logo from your device gallery, the app accesses only the image you choose. A profile photograph is used as your account image and is visible to authorised users according to role and gym permissions. Gym and branch logos uploaded by an owner are shown to people linked to that gym.',
    'Location is used only at two moments: (a) when a member scans the gym’s check-in QR, and (b) when a front-desk staff member or trainer marks themselves present for the day. At that moment the app reads the phone’s current location and the server compares it with the location the gym owner set for that branch (about 20 metres, allowing for normal GPS accuracy). The gym owner sets that location from their own phone while standing in the gym.',
    'GymMantra does not track your location in the background and does not keep a location history. For a member check-in, the location is used only to allow or refuse that check-in. For staff and trainer attendance, the distance from the gym (in metres) may be saved with that day’s attendance record. If the phone reports a fake-location (mock) app, attendance may be refused.',
    'You can deny camera, photo or location permissions in your device settings, but QR check-in, attendance or photo features may not work until the relevant permission is granted. You may remove or replace your profile photograph in the app.',
]
p[3]['p'] = sec4
edit(p, 9, 'The identity of the advertising provider, SDK, data categories, purposes, retention and available opt-out or consent controls must be disclosed in an updated notice before the integration is launched. This draft does not represent that a particular advertising network is already integrated or that personalised advertising is currently active.',
     'At the time this Policy was last updated, no third-party advertising network is integrated in the GymMantra apps; promotions shown in the app are placed by GymMantra itself or by your gym. Before any third-party advertising network is enabled, we will update this Policy with the provider, the data it receives, its purposes, retention and the available consent or opt-out controls.')
edit(p, 8, 'the gym owner and authorised gym staff who need the information to administer that gym;', 'the gym owner and authorised gym staff who need the information to administer that gym (including reports and attendance they may download as spreadsheets, which are then under the gym’s control);')
edit(p, 14, 'The current product may provide profile editing and account deletion controls in certain screens or versions. Do not rely on a feature being available unless it is visible in your current app version. If a self-service option is unavailable, use an in-app support ticket.',
     'You can edit your profile, download a copy of your data and delete your account from the app (Profile → Privacy). Deleting your account removes your GymMantra login and profile; the gym may keep its own membership and payment records as described in Section 13. If a self-service option is not available to you, raise an in-app support ticket.')
edit(p, 15, 'Tickets concerning gym membership or facilities may be routed to the relevant gym; app, login or technical issues may be routed to GymMantra support.',
     'All tickets are handled by GymMantra support. Where a ticket concerns a gym’s membership, payments or facilities, we may ask you to contact the gym directly.')
edit(p, 17, 'The in-app ticket channel is the contact method currently designated by GymMantra for this draft.', None)
edit(p, 17, 'The ticket interface should provide a reference number and a way to follow the request.', 'Each ticket gets a reference number and you can follow replies in the app.')
p[16]['p'] += CONTACT

doc = {'updated': '2026-11-06', 'terms': t, 'privacy': p}
for k in ('terms', 'privacy'):
    txt = json.dumps(doc[k])
    for bad in ['draft', 'INSERT', 'before publication', 'Before publication', 'must be inserted']:
        assert bad not in txt, (k, bad)
json.dump(doc, open('legal.json', 'w'), ensure_ascii=False, indent=1)
print(sum(len(' '.join(s['p']).split()) for s in t), sum(len(' '.join(s['p']).split()) for s in p))
