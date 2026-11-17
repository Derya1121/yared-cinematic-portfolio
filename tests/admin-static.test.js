const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const html = fs.readFileSync('admin/index.html','utf8');
const js = fs.readFileSync('admin/admin.js','utf8');
test('admin route is excluded from search indexing',()=>assert.match(html,/<meta name="robots" content="noindex,nofollow">/));
test('admin authenticates through Supabase Auth and checks owner authorization',()=>{
  assert.match(js,/auth\/v1\/token\?grant_type=password/);
  assert.match(js,/admin_users/);
  assert.match(js,/admin\.role!=='owner'/);
});
test('dashboard uses owner-only RPCs for overview, publishing and analytics',()=>{
  for(const name of ['admin_overview','admin_publish_content','admin_analytics_summary','admin_retry_notification']) assert.ok(js.includes(name),name);
});
test('dashboard includes private booking and feedback workflows',()=>{
  for(const name of ['bookings','booking_notes','feedback','notification_deliveries']) assert.ok(js.includes(name),name);
});
test('browser code contains no privileged provider or Supabase secrets',()=>{
  for(const secret of ['SUPABASE_SERVICE_ROLE_KEY','TELEGRAM_BOT_TOKEN','WHATSAPP_ACCESS_TOKEN']) assert.ok(!js.includes(secret),secret);
  assert.ok(!html.includes('service_role'));
});
test('dashboard does not persist access tokens in browser storage',()=>{
  assert.ok(!/localStorage|sessionStorage/.test(js));
});

test('public booking requires exactly one supported inbox channel',()=>{
  const page = fs.readFileSync('index.html','utf8');
  const publicJs = fs.readFileSync('cms-public.js','utf8');
  const handler = fs.readFileSync('supabase/functions/_shared/handlers.ts','utf8');
  const migration = fs.readFileSync('supabase/migrations/20261117000000_stage8_cms_admin.sql','utf8');
  assert.match(page,/<select name="delivery_channel" required>/);
  assert.match(publicJs,/d\.delivery_channel !== 'telegram' && d\.delivery_channel !== 'whatsapp'/);
  assert.match(handler,/delivery_channel: deliveryChannel/);
  assert.match(migration,/values \(v_id, v_channel\)/);
});

test('booking and admin forms contain real line breaks, not visible escaped sequences',()=>{
  const page = fs.readFileSync('index.html','utf8');
  assert.ok(!page.includes('\\\\n'));
  assert.ok(!html.includes('\\\\n'));
});
test('project upload errors are caught and save button is restored',()=>{
  assert.match(js,/try\{const f=new FormData\(form\)/);
  assert.match(js,/finally\{btn\.disabled=false\}/);
});
