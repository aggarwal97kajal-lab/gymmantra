import { setup } from '../helpers';
import { P } from '../../src/core';
it('roster size as members renew monthly for 2 years', async () => {
  const h = setup();
  const owner = await h.ownerWithGym('Renew Gym');
  const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1000 }, owner.token)).body;
  const ids: string[] = [];
  for (let i = 0; i < 20; i++) ids.push((await h.api.post('/members', { name: `Renew ${i}`, phone: h.nextPhone() }, owner.token)).body.id);
  const out: string[] = [];
  for (let k = 0; k < 24; k++) {
    for (const id of ids) {
      const r = await h.api.post(`/members/${id}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, owner.token);
      if (r.status >= 400) { out.push(`renewal ${k}: ${r.status} ${r.body.message}`); break; }
    }
    const size = JSON.stringify(await h.store.get(P.roster(owner.gym.id))).length;
    if ([0, 5, 11, 23].includes(k)) out.push(`after ${k + 1} memberships each: ${size} bytes for 20 members = ${Math.round(size / 20)} per member → 1 MB fits ${Math.floor(1_000_000 / (size / 20))} members`);
  }
  console.log('RENEW\n' + out.join('\n'));
});
