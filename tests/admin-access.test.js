/* Admin access-control + stored-XSS browser tests. MOCKED backend only (page.route): this proves the
   admin UI's own behaviour, not Supabase's RLS (that is covered by the SQL suite on a scratch Postgres). */
const { chromium } = require('playwright');
const SITE = process.env.SITE_ROOT || 'http://localhost:8765';
const BASE = 'https://mock-project.supabase.co';
let passed = 0, failed = 0;
const ok = (c, m) => { c ? passed++ : failed++; console.log((c ? 'PASS: ' : 'FAIL: ') + m); };
const cors = { 'access-control-allow-origin': '*', 'access-control-allow-headers': '*' };
const json = (r, b, s = 200) => r.fulfill({ status: s, contentType: 'application/json', headers: cors, body: JSON.stringify(b) });

async function open(browser, { configured, adminRows, bookings }) {
  const ctx = await browser.newContext(); const page = await ctx.newPage(); const log = { reqs: [], errors: [] };
  page.on('pageerror', e => log.errors.push(String(e)));
  if (configured) {
    await page.route('**/config.js', r => r.fulfill({ contentType: 'text/javascript', body: `window.DERYA_CONFIG={supabaseUrl:'${BASE}',supabaseAnonKey:'sb_publishable_${'x'.repeat(30)}'}` }));
    await page.route(BASE + '/**', r => {
      const u = r.request().url(); log.reqs.push(r.request().method() + ' ' + u.replace(BASE, ''));
      if (r.request().method() === 'OPTIONS') return r.fulfill({ status: 204, headers: cors });
      if (u.includes('/auth/v1/token')) return json(r, { access_token: 'tok-abc', refresh_token: 'r', expires_in: 3600, user: { id: '11111111-1111-1111-1111-111111111111', email: 'o@example.test' } });
      if (u.includes('/rest/v1/admin_users')) return json(r, adminRows);
      if (u.includes('/rpc/admin_overview')) return json(r, { bookings: { unread: 1 }, feedback: {}, notifications: {}, projects: {}, draft_changes: 0, recent_activity: [] });
      if (u.includes('/rest/v1/bookings')) return json(r, bookings || []);
      return json(r, []);
    });
  }
  await page.goto(SITE + '/admin/index.html', { waitUntil: 'load' }); await page.waitForTimeout(500);
  return { page, log, ctx };
}
const signIn = async (page) => { await page.fill('#login-form [name=email]', 'o@example.test'); await page.fill('#login-form [name=password]', 'correct horse battery'); await page.click('#login-form button'); await page.waitForTimeout(900); };

(async () => {
  const browser = await chromium.launch();
  { const { page, log, ctx } = await open(browser, {});
    ok(await page.isHidden('#app') && await page.isVisible('#login'), 'unauthenticated visitor sees only the sign-in form (dashboard hidden)');
    ok(await page.isDisabled('#login-form button'), 'unconfigured backend: the sign-in button is disabled (no fake login)');
    ok(await page.isHidden('#app'), 'unconfigured backend: the dashboard stays hidden');
    ok(log.errors.length === 0, 'no uncaught errors ' + JSON.stringify(log.errors)); await ctx.close(); }
  { const { page, log, ctx } = await open(browser, { configured: true, adminRows: [] });
    await signIn(page);
    ok(await page.isHidden('#app'), 'a valid login that is NOT in admin_users never reaches the dashboard');
    ok(/not an active portfolio owner|denied/i.test(await page.textContent('#login-status')), 'non-admin gets an access-denied message');
    ok(!log.reqs.some(r => /rest\/v1\/(bookings|feedback|notification_deliveries)|rpc\/admin_/.test(r)), 'no private data was requested for a non-admin');
    await ctx.close(); }
  { const { page, log, ctx } = await open(browser, { configured: true, adminRows: [{ user_id: '1', email: 'o@example.test', role: 'editor', active: true }] });
    await signIn(page); ok(await page.isHidden('#app'), 'a non-owner admin role is refused by the owner-only dashboard'); await ctx.close(); }
  { const evil = { id: '22222222-2222-2222-2222-222222222222', reference: 'DB-XSS00001', name: '<img src=x onerror="window.__xss=1">', business: '<script>window.__xss=2</script>', email: 'a@b.co', whatsapp: null, delivery_channel: 'telegram', service: 'website', budget: null, description: '"><svg onload=window.__xss=3>', status: 'unread', created_at: new Date().toISOString() };
    const { page, log, ctx } = await open(browser, { configured: true, adminRows: [{ user_id: '1', email: 'o@example.test', role: 'owner', active: true }], bookings: [evil] });
    await signIn(page);
    ok(await page.isVisible('#app'), 'owner reaches the dashboard');
    ok(!(await page.evaluate(() => JSON.stringify(Object.entries(sessionStorage).concat(Object.entries(localStorage))).includes('tok-abc'))), 'access token is not written to browser storage');
    await page.click('[data-tab=bookings]'); await page.waitForTimeout(800);
    ok(await page.evaluate(() => window.__xss === undefined), 'visitor-submitted HTML/JS in a booking never executes in the admin');
    ok(await page.$$eval('#booking-list img, #booking-list script, #booking-list svg', n => n.length) === 0, 'visitor-submitted markup is rendered as text, not elements');
    ok((await page.textContent('#booking-list')).includes('<img src=x'), 'the payload is shown literally so the owner can see it');
    ok(log.errors.length === 0, 'no uncaught errors ' + JSON.stringify(log.errors)); await ctx.close(); }
  await browser.close(); console.log(`\n${passed} passed, ${failed} failed`); process.exit(failed ? 1 : 0);
})();
