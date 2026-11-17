-- Stage 8 database assertions. Run by run_tests.sh against a THROW-AWAY local database only.
-- Every check prints "PASS: ..."; any failure raises an exception and stops the run.
\set ON_ERROR_STOP 1
\set QUIET 1
set client_min_messages = notice;

create schema t;
grant usage on schema t to public;

-- ---- tiny assertion helpers (run as whatever role is active) ----------------
create function t.as_user(uid text, aal text default 'aal1') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated', 'aal', aal)::text, true);
  set local role authenticated;
end $$;
create function t.as_anon() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', true); set local role anon; end $$;
create function t.as_service() returns void language plpgsql as $$
begin perform set_config('request.jwt.claims', '', true); set local role service_role; end $$;

create function t.pass(label text) returns void language plpgsql as $$ begin raise notice 'PASS: %', label; end $$;

create function t.ok(q text, label text) returns void language plpgsql as $$
begin execute q; perform t.pass(label); end $$;

create function t.denied(q text, label text) returns void language plpgsql as $$
declare hit boolean := false;
begin
  begin execute q; exception when insufficient_privilege then hit := true; end;
  if not hit then raise exception 'FAIL: expected permission denied: %', label; end if;
  perform t.pass(label);
end $$;

create function t.errs(q text, state text, label text) returns void language plpgsql as $$
declare got text := 'none';
begin
  begin execute q; exception when others then got := sqlstate; end;
  if got <> state then raise exception 'FAIL: % (expected %, got %)', label, state, got; end if;
  perform t.pass(label);
end $$;

create function t.rows(q text, want int, label text) returns void language plpgsql as $$
declare c int;
begin
  execute 'select count(*) from (' || q || ') s' into c;
  if c <> want then raise exception 'FAIL: % (expected % rows, got %)', label, want, c; end if;
  perform t.pass(label);
end $$;

create function t.dml(q text, want int, label text) returns void language plpgsql as $$
declare n int;
begin
  execute q; get diagnostics n = row_count;
  if n <> want then raise exception 'FAIL: % (expected % rows changed, got %)', label, want, n; end if;
  perform t.pass(label);
end $$;

create function t.eq(q text, want text, label text) returns void language plpgsql as $$
declare got text;
begin
  execute q into got;
  if got is distinct from want then raise exception 'FAIL: % (expected %, got %)', label, want, got; end if;
  perform t.pass(label);
end $$;

-- ---- fixtures ----------------------------------------------------------------
insert into auth.users (id, email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@example.test'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'editor@example.test'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'stranger@example.test');
insert into public.admin_users (user_id, email, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'owner@example.test', 'owner'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'editor@example.test', 'editor');

-- =============================================================================
-- A. Structure
-- =============================================================================
select t.rows($q$select relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity$q$, 0, 'A1 every public table has RLS enabled');
select t.rows($q$select 1 from information_schema.role_table_grants
  where table_schema = 'public' and grantee = 'anon'$q$, 0, 'A2 anon holds no table privilege at all');
select t.rows($q$select 1 from information_schema.role_table_grants
  where table_schema = 'public' and grantee = 'authenticated' and privilege_type = 'DELETE'
    and table_name not in ('projects','project_media','testimonials')$q$, 0, 'A3 authenticated can delete only projects/media/testimonials (never bookings, feedback, logs)');
select t.rows($q$select 1 from information_schema.routine_privileges
  where routine_schema = 'public' and grantee = 'PUBLIC'$q$, 0, 'A4 no public function is executable by PUBLIC');
select t.eq($q$select count(*)::text from public.content_fields where key ~* 'facebook'$q$, '0', 'A5 no Facebook content field exists');
select t.eq($q$select count(*)::text from public.projects where status = 'published'$q$, '4', 'A6 the four existing projects are seeded as published');
select t.eq($q$select count(*)::text from public.projects where demo_url is not null or thumbnail_path is not null$q$, '0', 'A7 no invented demo URLs or screenshots were seeded');

-- =============================================================================
-- B. Anonymous visitor
-- =============================================================================
begin; select t.as_anon();
select t.denied('select * from public.bookings', 'B1 anon cannot read bookings');
select t.denied('select * from public.feedback', 'B2 anon cannot read feedback');
select t.denied('select * from public.site_content', 'B3 anon cannot read site_content directly');
select t.denied('select * from public.projects', 'B4 anon cannot read projects directly');
select t.denied('select * from public.notification_deliveries', 'B5 anon cannot read notification records');
select t.denied('select * from public.admin_audit_log', 'B6 anon cannot read the audit log');
select t.denied('select * from public.analytics_events', 'B7 anon cannot read analytics rows');
select t.denied($q$insert into public.bookings (reference,name,service,description,dedupe_hash,email) values ('X','x','other','0123456789','h','a@b.co')$q$, 'B8 anon cannot insert bookings directly');
select t.denied($q$insert into public.feedback (reference,category,message) values ('X','other','hello there')$q$, 'B9 anon cannot insert feedback directly');
select t.denied($q$insert into public.analytics_events (event) values ('page_view')$q$, 'B10 anon cannot insert analytics directly');
select t.denied('select public.admin_overview()', 'B11 anon cannot call admin_overview');
select t.denied('select public.admin_analytics_summary(current_date - 1, current_date)', 'B12 anon cannot read analytics summary');
select t.denied($q$select public.create_booking_v1('{}'::jsonb)$q$, 'B13 anon cannot call the service-only booking RPC');
select t.denied('select public.claim_notifications_v1(5)', 'B14 anon cannot claim notifications');
select t.denied($q$select public.record_event_v1('page_view')$q$, 'B15 anon cannot call the service-only analytics RPC');
select t.denied($q$select public.check_rate_limit_v1('x', 1, 60)$q$, 'B16 anon cannot call the rate-limit RPC');
select t.denied('select public.admin_publish_content()', 'B17 anon cannot publish');
select t.denied($q$select * from private.app_config$q$, 'B18 anon cannot read private config');
select t.ok('select public.get_public_site()', 'B19 anon can call get_public_site');
select t.eq($q$select jsonb_array_length(public.get_public_site()->'projects')::text$q$, '4', 'B20 public site exposes the 4 published projects');
select t.eq($q$select (public.get_public_site()->'content')::text$q$, '{}', 'B21 nothing is public until the owner publishes content');
select t.denied($q$insert into storage.objects (bucket_id, name) values ('portfolio-media','projects/x.png')$q$, 'B22 anon cannot upload to storage');
commit;

-- =============================================================================
-- C. Signed-in non-admin
-- =============================================================================
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000003');
select t.rows('select 1 from public.site_content', 0, 'C1 non-admin sees no site_content');
select t.rows('select 1 from public.bookings', 0, 'C2 non-admin sees no bookings');
select t.rows('select 1 from public.feedback', 0, 'C3 non-admin sees no feedback');
select t.rows('select 1 from public.admin_audit_log', 0, 'C4 non-admin sees no audit log');
select t.rows('select 1 from public.admin_users', 0, 'C5 non-admin sees no admin list');
select t.errs($q$insert into public.projects (slug,title) values ('hack-me','x')$q$, '42501', 'C6 non-admin cannot create projects (RLS)');
select t.dml($q$update public.site_content set draft = 'pwned'$q$, 0, 'C7 non-admin cannot edit content');
select t.errs('select public.admin_overview()', '42501', 'C8 non-admin cannot call admin_overview');
select t.errs('select public.admin_publish_content()', '42501', 'C9 non-admin cannot publish');
select t.errs($q$insert into storage.objects (bucket_id, name) values ('portfolio-media','projects/x.png')$q$, '42501', 'C10 non-admin cannot upload');
select t.denied($q$insert into public.admin_users (user_id, role) values ('aaaaaaaa-0000-0000-0000-000000000003','owner')$q$, 'C11 a user cannot make themselves admin');
commit;

-- =============================================================================
-- D. Service role: bookings, feedback, analytics, rate limits
-- =============================================================================
begin; select t.as_service();
select t.eq($q$select (public.create_booking_v1('{"name":"Abel Tester","business":"Test Co","email":"Abel@Example.com","whatsapp":"+251 91 234 5678","service":"website","budget":"500-1500","description":"I need a new website for my shop."}'::jsonb, 'iphash1', 'clientkey0001'))->>'ok'$q$, 'true', 'D1 valid booking is stored');
select t.eq($q$select reference ~ '^DB-[0-9A-F]{8}$' from public.bookings$q$, 'true', 'D2 booking gets a DB-XXXXXXXX reference');
select t.eq($q$select email || '|' || whatsapp from public.bookings$q$, 'abel@example.com|+251912345678', 'D3 email lower-cased, whatsapp normalised');
select t.rows('select 1 from public.notification_deliveries where status = $$pending$$', 1, 'D4 only the selected Telegram delivery row is created, pending');
select t.eq($q$select (public.create_booking_v1('{"name":"Abel Tester","email":"abel@example.com","whatsapp":"+251912345678","service":"website","description":"I  need a NEW website   for my shop."}'::jsonb))->>'duplicate'$q$, 'true', 'D5 same request re-sent (different case/spacing) is deduplicated');
select t.eq($q$select (public.create_booking_v1('{"name":"Other","email":"zzz@example.com","service":"other","description":"completely different text here"}'::jsonb, null, 'clientkey0001'))->>'duplicate'$q$, 'true', 'D6 the same client_key is idempotent');
select t.rows('select 1 from public.bookings', 1, 'D7 only one booking row exists after 3 submissions');
select t.rows('select 1 from public.notification_deliveries', 1, 'D8 duplicates create no extra notifications');
select t.eq($q$select (public.create_booking_v1('{"name":"Abel Tester","email":"abel@example.com","delivery_channel":"whatsapp","service":"ai-assistant","description":"A different service request entirely."}'::jsonb))->>'duplicate'$q$, 'false', 'D9 a genuinely different request is accepted');
select t.eq($q$select (public.create_booking_v1('{"name":"","email":"a@b.co","service":"other","description":"0123456789"}'::jsonb))->>'field'$q$, 'name', 'D10 empty name rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"not-an-email","service":"other","description":"0123456789"}'::jsonb))->>'field'$q$, 'email', 'D11 bad email rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","service":"other","description":"0123456789"}'::jsonb))->>'error'$q$, 'contact_required', 'D12 email or WhatsApp is required');
select t.eq($q$select (public.create_booking_v1('{"name":"A","whatsapp":"0912345","service":"other","description":"0123456789"}'::jsonb))->>'field'$q$, 'whatsapp', 'D13 non-international WhatsApp rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"a@b.co","service":"hacking","description":"0123456789"}'::jsonb))->>'field'$q$, 'service', 'D14 unknown service rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"a@b.co","delivery_channel":"fax","service":"other","description":"0123456789"}'::jsonb))->>'field'$q$, 'delivery_channel', 'D14b unknown notification channel rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"a@b.co","service":"other","description":"short"}'::jsonb))->>'field'$q$, 'description', 'D15 too-short description rejected');
select t.eq($q$select (public.create_booking_v1(jsonb_build_object('name','A','email','a@b.co','service','other','description',repeat('x',2001))))->>'field'$q$, 'description', 'D16 too-long description rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"a@b.co","service":"other","budget":"a million","description":"0123456789"}'::jsonb))->>'field'$q$, 'budget', 'D17 unknown budget rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"a@b.co","service":"other","description":"bad\u0001control"}'::jsonb))->>'ok'$q$, 'false', 'D18 control characters rejected');
select t.eq($q$select (public.create_booking_v1('{"name":"A","email":"a@b.co","service":"other","description":"0123456789"}'::jsonb, null, 'bad key!'))->>'field'$q$, 'client_key', 'D19 malformed client_key rejected');
select t.rows('select 1 from public.bookings', 2, 'D20 rejected submissions stored nothing');
select t.errs($q$insert into public.bookings (reference,name,service,description,dedupe_hash) values ('Z','z','other','0123456789','h')$q$, '23514', 'D21 table constraint: a booking needs email or WhatsApp');

select t.eq($q$select (public.create_feedback_v1('{"name":"Sam","category":"idea","message":"Please add a dark mode toggle."}'::jsonb, 'iphash1', 'fbkey000001'))->>'ok'$q$, 'true', 'D22 valid feedback is stored');
select t.eq($q$select (public.create_feedback_v1('{"category":"idea","message":"Another one entirely"}'::jsonb))->>'ok'$q$, 'true', 'D23 anonymous feedback (no name/email) is accepted');
select t.eq($q$select (public.create_feedback_v1('{"category":"idea","message":"Please add a dark mode toggle."}'::jsonb, null, 'fbkey000001'))->>'duplicate'$q$, 'true', 'D24 feedback client_key is idempotent');
select t.eq($q$select (public.create_feedback_v1('{"category":"weird","message":"hello there"}'::jsonb))->>'field'$q$, 'category', 'D25 unknown feedback category rejected');
select t.eq($q$select (public.create_feedback_v1('{"category":"bug","message":"hi"}'::jsonb))->>'field'$q$, 'message', 'D26 too-short feedback rejected');
select t.eq($q$select (public.create_feedback_v1('{"category":"bug","email":"nope","message":"valid message"}'::jsonb))->>'field'$q$, 'email', 'D27 invalid optional feedback email rejected');
select t.rows('select 1 from public.feedback', 2, 'D28 two feedback rows stored');

select t.eq($q$select public.record_event_v1('page_view', '/', null, null, 'abcdef0123456789abcdef')::text$q$, 'true', 'D29 valid analytics event stored');
select t.eq($q$select public.record_event_v1('project_view', '#work', 'aurex-ai', null, 'abcdef0123456789abcdef')::text$q$, 'true', 'D30 project_view stored');
select t.eq($q$select public.record_event_v1('contact_click', '#contact', null, 'telegram', 'abcdef0123456789abcdef')::text$q$, 'true', 'D31 contact_click stored');
select t.eq($q$select public.record_event_v1('hack', '/')::text$q$, 'false', 'D32 unknown event is dropped');
select t.eq($q$select public.record_event_v1('page_view', '/ with spaces and <script>')::text$q$, 'false', 'D33 hostile path is dropped');
select t.eq($q$select public.record_event_v1('contact_click', null, null, 'facebook')::text$q$, 'false', 'D34 facebook is not a valid contact target');
select t.eq($q$select public.record_event_v1('page_view', '/', null, null, 'Robert); DROP TABLE')::text$q$, 'false', 'D35 malformed visitor hash is dropped');
select t.rows('select 1 from public.analytics_events', 3, 'D36 only the 3 valid events are stored');

select t.eq($q$select string_agg(public.check_rate_limit_v1('t:b1', 3, 60)::text, ',')  from generate_series(1,5)$q$, 'true,true,true,false,false', 'D37 rate limit allows 3 then blocks');
select t.eq($q$select public.check_rate_limit_v1('t:b2', 3, 60)::text$q$, 'true', 'D38 buckets are independent');
select t.errs($q$select public.check_rate_limit_v1('x', 0, 60)$q$, '22023', 'D39 bad rate-limit arguments rejected');
commit;

-- =============================================================================
-- E. Notification delivery state machine (service role)
-- =============================================================================
begin; select t.as_service();
select t.eq($q$select jsonb_array_length(public.claim_notifications_v1(50))::text$q$, '2', 'E1 claim returns one selected delivery for each of the two bookings');
select t.eq($q$select jsonb_array_length(public.claim_notifications_v1(50))::text$q$, '0', 'E2 claimed rows are not handed out twice');
select t.rows($q$select 1 from public.notification_deliveries where status = 'sending' and attempts = 1$q$, 2, 'E3 selected-channel rows are sending with attempts = 1');
commit;

begin; select t.as_service();
-- booking 1 (Abel / website): Telegram succeeds; booking 2 (AI assistant): WhatsApp fails
select t.eq($q$select public.complete_notification_v1((select d.id from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='website' and d.channel='telegram'), true, 'tg-1')$q$, 'sent', 'E4 telegram success -> sent');
select t.eq($q$select public.complete_notification_v1((select d.id from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='ai-assistant' and d.channel='whatsapp'), false, null, 'timeout')$q$, 'failed', 'E5 selected WhatsApp delivery failure -> failed');
select t.eq($q$select d.status from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='website' and d.channel='telegram'$q$, 'sent', 'E6 telegram stays sent when whatsapp fails');
select t.eq($q$select (next_attempt_at > now())::text from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='ai-assistant' and d.channel='whatsapp'$q$, 'true', 'E7 selected WhatsApp failure is scheduled for a later retry (backoff)');
select t.eq($q$select jsonb_array_length(public.claim_notifications_v1(50))::text$q$, '0', 'E8 a failed delivery is not retried before its backoff elapses');
select t.eq($q$select public.complete_notification_v1((select id from public.notification_deliveries where status='sent' limit 1), true)$q$, 'ignored', 'E9 completing a row that is not sending is ignored');
commit;

-- make the failed delivery due and retry until it is dead
update public.notification_deliveries set next_attempt_at = now() - interval '1 second' where status = 'failed';
begin; select t.as_service();
select t.eq($q$select jsonb_array_length(public.claim_notifications_v1(50))::text$q$, '1', 'E10 due failed delivery is claimed again');
select t.eq($q$select attempts::text from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='ai-assistant' and d.channel='whatsapp'$q$, '2', 'E11 attempts incremented on retry');
commit;
do $$ declare i int; r text; id_ uuid; begin
  select d.id into id_ from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='ai-assistant' and d.channel='whatsapp';
  for i in 1..10 loop
    update public.notification_deliveries set status = 'sending', claimed_at = now() where id = id_ and status = 'failed';
    select public.complete_notification_v1(id_, false, null, 'still failing') into r;
    exit when r = 'dead';
    update public.notification_deliveries set status = 'failed', next_attempt_at = now() - interval '1 second', attempts = attempts + 1 where id = id_ and status = 'failed';
  end loop;
  if r <> 'dead' then raise exception 'FAIL: E12 delivery never became dead'; end if;
  perform t.pass('E12 after max_attempts failures the delivery becomes dead (no endless retries)');
end $$;

-- not_configured is not a failure and never retries on its own
update public.notification_deliveries set status = 'sending', claimed_at = now(), attempts = 1 where booking_id = (select id from public.bookings where service = 'ai-assistant') and channel = 'whatsapp';
begin; select t.as_service();
select t.eq($q$select public.complete_notification_v1((select d.id from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='ai-assistant' and d.channel='whatsapp'), false, null, 'TELEGRAM_BOT_TOKEN not set', true)$q$, 'not_configured', 'E13 missing credentials -> not_configured');
select t.eq($q$select jsonb_array_length(public.claim_notifications_v1(50))::text$q$, '0', 'E14 not_configured rows are not auto-retried');
commit;

-- WhatsApp: "sent" only becomes "delivered" through a provider receipt
update public.notification_deliveries set status = 'sending', claimed_at = now(), attempts = 1 where booking_id = (select id from public.bookings where service = 'ai-assistant') and channel = 'whatsapp';
begin; select t.as_service();
select t.eq($q$select public.complete_notification_v1((select d.id from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.service='ai-assistant' and d.channel='whatsapp'), true, 'wamid.TEST1')$q$, 'sent', 'E15 provider accepted -> sent (NOT delivered)');
select t.eq($q$select (delivered_at is null)::text from public.notification_deliveries where provider_message_id = 'wamid.TEST1'$q$, 'true', 'E16 no delivered timestamp without a receipt');
select t.eq($q$select public.mark_whatsapp_delivery_v1('wamid.TEST1', 'delivered')::text$q$, 'true', 'E17 provider delivery receipt -> delivered');
select t.eq($q$select status from public.notification_deliveries where provider_message_id = 'wamid.TEST1'$q$, 'delivered', 'E18 status is delivered');
select t.eq($q$select public.mark_whatsapp_delivery_v1('wamid.TEST1', 'failed', 'late')::text$q$, 'false', 'E19 a late failure receipt cannot downgrade a delivered message');
select t.eq($q$select public.mark_whatsapp_delivery_v1('wamid.UNKNOWN', 'delivered')::text$q$, 'false', 'E20 unknown message id is ignored');
select t.eq($q$select public.mark_whatsapp_delivery_v1('tg-1', 'delivered')::text$q$, 'false', 'E21 a receipt can never mark a Telegram row delivered');
select t.eq($q$select public.mark_whatsapp_delivery_v1('wamid.TEST1', 'sent')::text$q$, 'false', 'E22 unsupported receipt status ignored');
commit;

-- a worker that died mid-send: stale "sending" rows are recovered, or buried once attempts are used
insert into public.bookings (reference, name, email, service, description, dedupe_hash) values ('DB-STALE001','Stale','s@example.com','other','stale worker test row','h-stale');
insert into public.notification_deliveries (booking_id, channel, status, attempts, claimed_at)
  select id, 'telegram', 'sending', 1, now() - interval '10 minutes' from public.bookings where reference = 'DB-STALE001';
insert into public.notification_deliveries (booking_id, channel, status, attempts, claimed_at)
  select id, 'whatsapp', 'sending', 5, now() - interval '10 minutes' from public.bookings where reference = 'DB-STALE001';
begin; select t.as_service();
select t.eq($q$select jsonb_array_length(public.claim_notifications_v1(50))::text$q$, '1', 'E23 a stale sending row is recovered by the next worker');
select t.eq($q$select d.status from public.notification_deliveries d join public.bookings b on b.id=d.booking_id where b.reference='DB-STALE001' and d.channel='whatsapp'$q$, 'dead', 'E24 a stale row with no attempts left is buried, not retried forever');
commit;

-- =============================================================================
-- F. Editor (non-owner admin)
-- =============================================================================
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000002');
select t.rows('select 1 from public.site_content', 46, 'F1 editor sees all 46 content fields');
select t.dml($q$update public.site_content set draft = 'I BUILD WHAT MATTERS' where key = 'hero.line1'$q$, 1, 'F2 editor can edit a draft');
select t.errs($q$update public.site_content set draft = 'http://t.me/x' where key = 'contact.telegram'$q$, '23514', 'F3 http:// URL rejected');
select t.errs($q$update public.site_content set draft = 'https://facebook.com/someone' where key = 'contact.telegram'$q$, '23514', 'F4 Facebook URL rejected');
select t.errs($q$update public.site_content set draft = 'https://fb.me/someone' where key = 'contact.instagram'$q$, '23514', 'F5 fb.me URL rejected');
select t.errs($q$update public.site_content set draft = 'javascript:alert(1)' where key = 'contact.tiktok'$q$, '23514', 'F6 javascript: URL rejected');
select t.errs($q$update public.site_content set draft = '0912345678' where key = 'contact.whatsapp'$q$, '23514', 'F7 WhatsApp must be international format');
select t.errs($q$update public.site_content set draft = 'not an email' where key = 'contact.email'$q$, '23514', 'F8 email format enforced');
select t.errs($q$update public.site_content set draft = 'projects/../../etc/passwd.png' where key = 'media.portrait_hero'$q$, '23514', 'F9 image path traversal rejected');
select t.errs($q$update public.site_content set draft = 'https://evil.example/x.png' where key = 'media.portrait_hero'$q$, '23514', 'F10 image must be an uploaded storage path');
select t.errs($q$update public.site_content set draft = 'purple' where key = 'visual.accent'$q$, '23514', 'F11 select values limited to options');
select t.errs($q$update public.site_content set draft = repeat('x', 500) where key = 'hero.line1'$q$, '23514', 'F12 max length enforced');
select t.dml($q$update public.site_content set draft = 'site/portrait.webp' where key = 'media.portrait_hero'$q$, 1, 'F13 valid image path accepted');
select t.dml($q$update public.site_content set draft = 'aqua' where key = 'visual.accent'$q$, 1, 'F14 valid select option accepted');
select t.denied($q$update public.site_content set published = 'sneaky' where key = 'hero.line1'$q$, 'F15 editor cannot write the published column directly');
select t.rows('select 1 from public.bookings', 0, 'F16 editor cannot see bookings');
select t.rows('select 1 from public.feedback', 0, 'F17 editor cannot see feedback');
select t.rows('select 1 from public.admin_audit_log', 0, 'F18 editor cannot see the audit log');
select t.errs('select public.admin_overview()', '42501', 'F19 editor cannot open the owner overview');
select t.errs($q$insert into public.testimonials (author_name, quote, published) values ('Fake', 'Amazing work!!', true)$q$, '42501', 'F20 editor cannot create/publish testimonials');
select t.ok($q$insert into public.projects (slug, title, category, status) values ('new-demo', 'New Demo', 'ai', 'draft')$q$, 'F21 editor can create a draft project');
select t.errs($q$update public.projects set demo_url = 'https://www.facebook.com/page' where slug = 'new-demo'$q$, '23514', 'F22 Facebook demo URL rejected');
select t.errs($q$update public.projects set demo_url = 'http://insecure.example' where slug = 'new-demo'$q$, '23514', 'F23 non-https demo URL rejected');
select t.dml($q$update public.projects set demo_url = 'https://demo.example.com/app', thumbnail_path = 'projects/new-demo/thumb.webp', technologies = array['Deno','Postgres'] where slug = 'new-demo'$q$, 1, 'F24 valid demo URL, thumbnail and technologies accepted');
select t.errs($q$update public.projects set slug = 'Bad Slug!' where slug = 'new-demo'$q$, '23514', 'F25 slug format enforced');
select t.errs($q$update public.projects set accent = 'neon' where slug = 'new-demo'$q$, '23514', 'F26 unknown accent rejected');
select t.dml($q$delete from public.projects where slug = 'aurex-ai'$q$, 0, 'F27 a published project cannot be deleted (unpublish/archive first)');
select t.dml($q$update public.projects set status = 'archived' where slug = 'derya-pulse-ai'$q$, 1, 'F28 editor can archive a project');
select t.dml($q$delete from public.projects where slug = 'derya-pulse-ai'$q$, 1, 'F29 an archived project can be deleted');
select t.ok($q$insert into public.project_media (project_id, path, alt) select id, 'projects/new-demo/shot1.png', 'Home screen' from public.projects where slug = 'new-demo'$q$, 'F30 editor can attach media');
select t.errs($q$insert into public.project_media (project_id, path) select id, '../shot.png' from public.projects where slug = 'new-demo'$q$, '23514', 'F31 media path traversal rejected');
select t.ok($q$select public.admin_reorder_projects(array(select id from public.projects order by slug desc))$q$, 'F32 editor can reorder projects');
select t.ok($q$select public.admin_publish_content(array['hero.line1','visual.accent','media.portrait_hero'])$q$, 'F33 editor can publish selected fields');
commit;

-- =============================================================================
-- G. What the public site sees after publishing
-- =============================================================================
begin; select t.as_anon();
select t.eq($q$select public.get_public_site()->'content'->>'hero.line1'$q$, 'I BUILD WHAT MATTERS', 'G1 published content is visible to the public');
select t.eq($q$select (public.get_public_site()->'content' ? 'contact.telegram')::text$q$, 'false', 'G2 unpublished fields are not exposed');
select t.eq($q$select jsonb_array_length(public.get_public_site()->'projects')::text$q$, '3', 'G3 archived/deleted/draft projects are not exposed (3 published remain)');
select t.eq($q$select (public.get_public_site()->'projects'->0->>'slug')$q$, 'rent-manager', 'G4 projects come back in the reorder the admin chose');
select t.eq($q$select (public.get_public_site()::text ~ 'new-demo')::text$q$, 'false', 'G5 draft project "new-demo" is not exposed');
commit;
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000002');
select t.dml($q$update public.projects set status = 'published' where slug = 'new-demo'$q$, 1, 'G6 editor publishes the draft project');
commit;
begin; select t.as_anon();
select t.eq($q$select ((public.get_public_site()->'projects') @> '[{"slug":"new-demo","demo_url":"https://demo.example.com/app"}]'::jsonb)::text$q$, 'true', 'G7 published project now carries its demo URL');
select t.eq($q$select jsonb_array_length((select p->'media' from jsonb_array_elements(public.get_public_site()->'projects') p where p->>'slug'='new-demo'))::text$q$, '1', 'G8 published project exposes its media');
commit;

-- =============================================================================
-- H. Owner
-- =============================================================================
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select t.rows('select 1 from public.bookings', 3, 'H1 owner sees all bookings');
select t.rows('select 1 from public.feedback', 2, 'H2 owner sees all feedback');
select t.rows('select 1 from public.notification_deliveries', 4, 'H3 owner sees selected-channel rows plus two stale test rows');
select t.dml($q$update public.bookings set status = 'read' where service = 'website'$q$, 1, 'H4 owner can change booking status');
select t.dml($q$update public.bookings set status = 'contacted' where service = 'website'$q$, 1, 'H5 owner can mark contacted');
select t.errs($q$update public.bookings set status = 'archived-by-me'$q$, '23514', 'H6 unknown booking status rejected');
select t.denied($q$update public.bookings set name = 'tampered'$q$, 'H7 owner cannot rewrite what a customer submitted');
select t.denied($q$update public.bookings set description = 'tampered'$q$, 'H8 owner cannot rewrite the booking description');
select t.denied($q$delete from public.bookings$q$, 'H9 bookings cannot be deleted from the admin API');
select t.denied($q$delete from public.feedback$q$, 'H10 feedback cannot be deleted from the admin API');
select t.denied($q$delete from public.admin_audit_log$q$, 'H11 audit log cannot be deleted');
select t.denied($q$update public.admin_audit_log set action = 'x'$q$, 'H12 audit log cannot be edited');
select t.denied($q$insert into public.admin_audit_log (action) values ('forged')$q$, 'H13 audit log cannot be forged');
select t.denied($q$insert into public.notification_deliveries (booking_id, channel, status) select id,'telegram','sent' from public.bookings limit 1$q$, 'H14 delivery status cannot be faked from the admin API');
select t.denied($q$update public.notification_deliveries set status = 'delivered'$q$, 'H15 delivery status cannot be edited from the admin API');
select t.ok($q$insert into public.booking_notes (booking_id, note) select id, 'Called him, wants a quote.' from public.bookings where service = 'website'$q$, 'H16 owner can add a private note');
select t.denied($q$insert into public.booking_notes (booking_id, note, author) select id, 'x', 'aaaaaaaa-0000-0000-0000-000000000002' from public.bookings limit 1$q$, 'H17 note author cannot be set by the client');
select t.eq($q$select author::text from public.booking_notes$q$, 'aaaaaaaa-0000-0000-0000-000000000001', 'H18 note author is stamped server-side');
select t.dml($q$update public.feedback set status = 'read' where category = 'idea' and name = 'Sam'$q$, 1, 'H19 owner can mark feedback read');
select t.errs($q$update public.feedback set status = 'public' $q$, '23514', 'H20 feedback has no "public" status');
select t.ok($q$insert into public.feedback_replies (feedback_id, body) select id, 'Thanks, noted.' from public.feedback where name = 'Sam'$q$, 'H21 owner can write a private reply');
select t.rows('select 1 from public.feedback_replies', 1, 'H22 reply stored');
select t.ok($q$insert into public.testimonials (author_name, quote, source_feedback_id) select 'Sam', 'Great work.', id from public.feedback where name = 'Sam'$q$, 'H23 owner can turn feedback into a testimonial draft');
commit;
begin; select t.as_anon();
select t.eq($q$select jsonb_array_length(public.get_public_site()->'testimonials')::text$q$, '0', 'H24 an unpublished testimonial is not public');
commit;
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select t.dml($q$update public.testimonials set published = true$q$, 1, 'H25 owner explicitly publishes the testimonial');
commit;
begin; select t.as_anon();
select t.eq($q$select (public.get_public_site()->'testimonials'->0->>'author_name')$q$, 'Sam', 'H26 published testimonial is public');
select t.eq($q$select (public.get_public_site()->'testimonials'->0 ? 'source_feedback_id')::text$q$, 'false', 'H27 the link back to private feedback is not exposed');
select t.eq($q$select (public.get_public_site()::text ~ 'dark mode')::text$q$, 'false', 'H28 private feedback text never appears on the public site');
commit;
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select t.ok($q$select public.admin_overview()$q$, 'H29 owner can open the overview');
select t.eq($q$select (public.admin_overview()->'bookings'->>'contacted')$q$, '1', 'H30 overview counts bookings by status');
select t.eq($q$select (public.admin_overview()->'notifications'->>'whatsapp:dead')$q$, '2', 'H31 overview shows dead/failed deliveries');
select t.eq($q$select public.admin_retry_notification((select id from public.notification_deliveries where status = 'dead' limit 1))::text$q$, 'true', 'H32 owner can re-queue a dead delivery');
select t.eq($q$select public.admin_retry_notification((select id from public.notification_deliveries where status = 'sent' limit 1))::text$q$, 'false', 'H33 a delivered/sent message cannot be re-queued (no double notifications)');
select t.denied($q$insert into public.admin_users (user_id, role) values ('aaaaaaaa-0000-0000-0000-000000000003','owner')$q$, 'H34 owner cannot add admins through the API either');
commit;

-- the audit log records who/what changed, without personal data
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select t.eq($q$select (count(*) >= 1)::text from public.admin_audit_log where table_name = 'bookings' and action = 'update' and changed_columns = array['status']$q$, 'true', 'H35 booking status changes are audit-logged');
select t.eq($q$select (count(*) = 0)::text from public.admin_audit_log where detail::text ~* '(@|tampered|wants a quote|dark mode|Abel)'$q$, 'true', 'H36 the audit log holds no names, emails, notes or messages');
select t.eq($q$select (count(*) >= 1)::text from public.admin_audit_log where action = 'publish'$q$, 'true', 'H37 publishes are audit-logged');
select t.eq($q$select (count(*) >= 1)::text from public.admin_audit_log where table_name = 'projects' and action = 'delete'$q$, 'true', 'H38 project deletions are audit-logged');
commit;

-- =============================================================================
-- I. MFA setting and revoked admins
-- =============================================================================
update private.app_config set value = 'true' where key = 'admin_require_mfa';
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001', 'aal1');
select t.rows('select 1 from public.bookings', 0, 'I1 with MFA required, an aal1 session sees nothing');
select t.errs('select public.admin_overview()', '42501', 'I2 with MFA required, an aal1 session is refused');
commit;
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001', 'aal2');
select t.rows('select 1 from public.bookings', 3, 'I3 with MFA required, an aal2 session works');
commit;
update private.app_config set value = 'false' where key = 'admin_require_mfa';
update public.admin_users set active = false where user_id = 'aaaaaaaa-0000-0000-0000-000000000002';
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000002');
select t.rows('select 1 from public.site_content', 0, 'I4 a deactivated admin loses access immediately');
select t.errs($q$select public.admin_publish_content()$q$, '42501', 'I5 a deactivated admin cannot publish');
commit;
update public.admin_users set active = true where user_id = 'aaaaaaaa-0000-0000-0000-000000000002';

-- =============================================================================
-- J. Storage policies
-- =============================================================================
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000002');
select t.ok($q$insert into storage.objects (bucket_id, name) values ('portfolio-media', 'projects/new-demo/hero.webp')$q$, 'J1 editor can upload a valid image path');
select t.errs($q$insert into storage.objects (bucket_id, name) values ('portfolio-media', 'projects/../secrets.png')$q$, '42501', 'J2 path traversal upload rejected');
select t.errs($q$insert into storage.objects (bucket_id, name) values ('portfolio-media', 'other/x.png')$q$, '42501', 'J3 uploads outside projects/ and site/ rejected');
select t.errs($q$insert into storage.objects (bucket_id, name) values ('portfolio-media', 'projects/shell.php')$q$, '42501', 'J4 non-image extension rejected');
select t.errs($q$insert into storage.objects (bucket_id, name) values ('some-other-bucket', 'projects/x.png')$q$, '42501', 'J5 other buckets are untouched');
commit;
select t.eq($q$select concat_ws('|', public::text, file_size_limit::text, array_to_string(allowed_mime_types, ',')) from storage.buckets where id = 'portfolio-media'$q$, 'true|5242880|image/jpeg,image/png,image/webp,image/avif', 'J6 bucket is public-read, 5 MB, images only');

-- =============================================================================
-- K. Analytics summary and housekeeping
-- =============================================================================
insert into public.analytics_events (event, path, visitor_hash, day) values ('page_view', '/', 'abcdef0123456789abcdef', current_date - 1), ('page_view', '/', '1234567890abcdef12', current_date - 1);
insert into public.analytics_events (event, project_slug, day) values ('demo_click', 'new-demo', current_date), ('project_view', 'new-demo', current_date);
insert into public.analytics_events (event, day) values ('page_view', current_date - 500);
begin; select t.as_user('aaaaaaaa-0000-0000-0000-000000000001');
select t.eq($q$select (public.admin_analytics_summary(current_date - 7, current_date)->'totals'->>'page_view')$q$, '3', 'K1 summary counts page views in range (old row excluded)');
select t.eq($q$select (public.admin_analytics_summary(current_date - 7, current_date)->>'unique_visitors_estimate')$q$, '3', 'K2 unique-visitor estimate sums distinct daily hashes');
select t.eq($q$select (public.admin_analytics_summary(current_date - 7, current_date)->'top_projects'->0->>'slug')$q$, 'new-demo', 'K3 top projects reported');
select t.errs($q$select public.admin_analytics_summary(current_date, current_date - 5)$q$, '22023', 'K4 inverted date range rejected');
select t.errs($q$select public.admin_analytics_summary(current_date - 1000, current_date)$q$, '22023', 'K5 oversized date range rejected');
commit;
begin; select t.as_service();
select t.eq($q$select (public.purge_old_rows_v1()->>'analytics_events')$q$, '1', 'K6 purge removes analytics older than 400 days');
commit;
select t.eq($q$select count(*)::text from information_schema.columns where table_name = 'analytics_events' and column_name ~* '(ip|agent|email|name)'$q$, '0', 'K7 analytics_events has no IP / user-agent / email / name column');

\echo ALL SQL ASSERTIONS PASSED
