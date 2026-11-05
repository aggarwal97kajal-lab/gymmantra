import { setup } from '../helpers';
import { P } from '../../src/core';
const N = Number(process.env.SIM_N ?? 20);
it('roster size as members renew monthly for 2 years', async () => {
  const h = setup();
  const owner = await h.ownerWithGym('Renew Gym');
  const plan = (await h.api.post('/plans', { name: 'Monthly', months: 1, price: 1000 }, owner.token)).body;
  const ids: string[] = [];
  for (let i = 0; i < N; i++) ids.push((await h.api.post('/members', { name: `Renew ${i}`, phone: h.nextPhone() }, owner.token)).body.id);
  const out: string[] = [];
  for (let k = 0; k < 24; k++) {
    for (const id of ids) {
      const r = await h.api.post(`/members/${id}/memberships`, { planId: plan.id, paymentMode: 'CASH' }, owner.token);
      if (r.status >= 400) { out.push(`renewal ${k}: ${r.status} ${r.body.message}`); break; }
    }
    const main: any = await h.store.get(P.roster(owner.gym.id));
    const parts = main.parts ?? 1;
    let size = 0;
    let biggest = 0;
    for (let p = 0; p < parts; p++) {
      const n = JSON.stringify(p ? await h.store.get(`tenants/${owner.gym.id}/roster/p${p}`) : main).length;
      size += n;
      biggest = Math.max(biggest, n);
    }
    if ([0, 5, 11, 23].includes(k)) out.push(`after ${k + 1} memberships each: ${size} bytes for ${N} members = ${Math.round(size / N)} per member in ${parts} part(s), biggest part ${biggest} bytes`);
  }
  console.log('RENEW\n' + out.join('\n'));
});
