"""Nightly backup and restore of the GymMantra database (see .github/workflows/backup.yml, restore.yml).

The server hands out the database page by page, already encrypted; this script only stores the
pages (backup) or sends them back (restore). It logs in with GitHub's own signed token (OIDC).
"""
import json, os, sys, time, urllib.request

API = 'https://gymmantra.aggarwal97kajal.workers.dev/api/v1'
_tok = {'v': None, 'at': 0.0}


def github_token():
    if not _tok['v'] or time.time() - _tok['at'] > 180:
        req = urllib.request.Request(os.environ['ACTIONS_ID_TOKEN_REQUEST_URL'] + '&audience=gymmantra-backup',
                                     headers={'Authorization': 'bearer ' + os.environ['ACTIONS_ID_TOKEN_REQUEST_TOKEN']})
        _tok['v'] = json.load(urllib.request.urlopen(req, timeout=30))['value']
        _tok['at'] = time.time()
    return _tok['v']


def post(path, body):
    for attempt in range(6):
        try:
            req = urllib.request.Request(API + path, data=json.dumps(body).encode(), method='POST',
                                         headers={'content-type': 'application/json', 'user-agent': 'gymmantra-backup/1',
                                                  'authorization': 'Bearer ' + github_token()})
            return json.load(urllib.request.urlopen(req, timeout=60))
        except Exception as e:  # noqa: BLE001 - retry anything, then give up
            if attempt == 5:
                raise
            body = e.read().decode(errors='replace')[:300] if hasattr(e, 'read') else ''
            print(f'retry {attempt + 1}: {e} {body}', flush=True)
            time.sleep(2 ** attempt)


def backup(folder):
    os.makedirs(folder, exist_ok=True)
    after, pages, docs = None, 0, 0
    while True:
        r = post('/backup/page', {'after': after})
        pages += 1
        docs += r['n']
        with open(os.path.join(folder, f'page-{pages:05d}.json'), 'w') as f:
            json.dump({'data': r['data']}, f)
        after = r['next']
        if not after:
            break
    with open(os.path.join(folder, 'summary.json'), 'w') as f:
        json.dump({'at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'pages': pages, 'documents': docs}, f)
    print(f'Backup done: {docs} documents in {pages} pages')


def restore(folder):
    files = sorted(n for n in os.listdir(folder) if n.startswith('page-'))
    if not files:
        sys.exit('No backup pages found')
    docs = 0
    for n in files:
        with open(os.path.join(folder, n)) as f:
            docs += post('/backup/restore', json.load(f))['n']
    print(f'Restore done: {docs} documents written back')


if __name__ == '__main__':
    {'backup': backup, 'restore': restore}[sys.argv[1]](sys.argv[2])
