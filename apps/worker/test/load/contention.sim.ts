/** Many check-ins at the same moment on one gym: how the database's same-document limit behaves (Firestore emulator). */
import { FirestoreStore } from '../../src/store/firestore';
it('rush hour: N people check in at the same second', async () => {
  const out: string[] = [];
  for (const n of [5, 10, 20, 40]) {
    const s = new FirestoreStore('demo-load', async () => 'owner', 'http://127.0.0.1:8080');
    await s.set('t/daily', { checkins: 0 });
    let fail = 0;
    const t0 = Date.now();
    await Promise.all(
      Array.from({ length: n }, (_, i) =>
        s
          .tx(async (t) => {
            const d = (await t.get<{ checkins: number }>('t/daily'))!;
            t.set(`t/scan${i}`, { at: Date.now() });
            t.set('t/daily', { checkins: d.checkins + 1 });
          })
          .catch(() => fail++),
      ),
    );
    const d = await new FirestoreStore('demo-load', async () => 'owner', 'http://127.0.0.1:8080').get<{ checkins: number }>('t/daily');
    out.push(`${n} at once: ${n - fail} ok, ${fail} failed ("database was busy"), counter ${d?.checkins}, ${Date.now() - t0} ms, db calls ${s.calls}`);
  }
  // New check-in: the check-in writes only the person's own documents; the day's counter is a second, separate step.
  for (const n of [10, 20, 40]) {
    const s = new FirestoreStore('demo-load', async () => 'owner', 'http://127.0.0.1:8080');
    await s.set('t2/daily', { checkins: 0 });
    let fail = 0;
    let counterFail = 0;
    const t0 = Date.now();
    await Promise.all(
      Array.from({ length: n }, (_, i) =>
        s
          .tx(async (t) => {
            await t.get(`t2/scan${i}`);
            t.set(`t2/scan${i}`, { at: Date.now() });
          })
          .then(() => s.tx(async (t) => {
            const d = (await t.get<{ checkins: number }>('t2/daily'))!;
            t.set('t2/daily', { checkins: d.checkins + 1 });
          }).catch(() => counterFail++))
          .catch(() => fail++),
      ),
    );
    const d = await new FirestoreStore('demo-load', async () => 'owner', 'http://127.0.0.1:8080').get<{ checkins: number }>('t2/daily');
    out.push(`NEW ${n} at once: ${n - fail} check-ins ok, ${fail} failed; counter ${d?.checkins} (${counterFail} counter misses), ${Date.now() - t0} ms`);
  }
  console.log('RUSH\n' + out.join('\n'));
});
