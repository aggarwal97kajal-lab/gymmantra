import json
d = json.load(open('legal.json'))
def dstr(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$') + "'"
out = ['// GENERATED from the approved Terms & Privacy (Nov 2026). Same text as the website (/terms, /privacy).',
       '// Edit the source documents and regenerate; do not hand-edit.', '',
       f"const legalUpdated = '{d['updated']}';", '']
for k, name in (('terms', 'termsSections'), ('privacy', 'privacySections')):
    out.append(f'const {name} = <(String, List<String>)>[')
    for s in d[k]:
        out.append(f"  ({dstr(s['h'])}, [")
        for p in s['p']:
            out.append(f'    {dstr(p)},')
        out.append('  ]),')
    out.append('];')
    out.append('')
open('/home/claude/gymmantra/apps/mobile/lib/legal_text.dart', 'w').write('\n'.join(out))
ts = ['// GENERATED from the approved Terms & Privacy (Nov 2026). Same text as the app (lib/legal_text.dart).', '',
      f"export const LEGAL_UPDATED = '{d['updated']}';",
      f"export const TERMS: [string, string[]][] = {json.dumps([[s['h'], s['p']] for s in d['terms']], ensure_ascii=False)};",
      f"export const PRIVACY: [string, string[]][] = {json.dumps([[s['h'], s['p']] for s in d['privacy']], ensure_ascii=False)};", '']
open('/home/claude/gymmantra/apps/admin/src/app/legal-text.ts', 'w').write('\n'.join(ts))
