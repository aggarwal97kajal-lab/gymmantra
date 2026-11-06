const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage();
  await p.goto('file:///home/claude/guide/guide.html', { waitUntil: 'networkidle' });
  await p.waitForTimeout(800);
  await p.pdf({ path: '/home/claude/guide/GymMantra_App_Guide.pdf', format: 'A4', printBackground: true, preferCSSPageSize: true });
  await b.close();
})();
