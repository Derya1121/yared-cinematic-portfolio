-- Assertions for supabase/migrations/20261115000000_portfolio_booking_cms.sql
-- Run with:  psql -v ON_ERROR_STOP=1 -f 01_booking_cms.test.sql <db>
-- Any failed assertion raises and aborts with a non-zero exit code.

create schema if not exists t;
create or replace function t.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;
create or replace function t.denied(stmt text, msg text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when insufficient_privilege or others then
    if sqlstate in ('42501') then raise notice 'PASS: %', msg; return; end if;
    raise exception 'FAIL: % (unexpected error % %)', msg, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL: % (statement was allowed)', msg;
end $$;
grant usage on schema t to anon, authenticated;
grant execute on all functions in schema t to anon, authenticated;

-- Helpers to impersonate API callers the way PostgREST does.
create or replace function t.as_anon(ip text default '203.0.113.9') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.headers', json_build_object('x-forwarded-for', ip)::text, true);
  execute 'set local role anon';
end $$;
create or replace function t.as_user(uid uuid, ip text default '203.0.113.10') returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',uid)::text, true);
  perform set_config('request.headers', json_build_object('x-forwarded-for', ip)::text, true);
  execute 'set local role authenticated';
end $$;
-- first bookable weekday slots: returns the day with the most free slots on distinct dates
create or replace function t.free_days(n int) returns setof date language sql as $$
  select day from public.get_booking_days() where available_slots > 0 order by day limit n
$$;

-- ---------------------------------------------------------------- 1. anonymous access
do $$
declare n int;
begin
  perform t.as_anon();
  select count(*) into n from public.projects;
  perform t.ok(n = 4, 'anon sees the 4 seeded published projects');
  select count(*) into n from public.services;
  perform t.ok(n = 4, 'anon sees the 4 published services');
  select count(*) into n from public.site_content;
  perform t.ok(n = 5, 'anon sees published site content');
  perform t.denied('select * from public.bookings', 'anon cannot read bookings');
  perform t.denied('select * from public.admins', 'anon cannot read admins');
  perform t.denied('select * from public.availability_rules', 'anon cannot read availability rules directly');
  perform t.denied('select * from private.booking_attempts', 'anon cannot read private attempt log');
  perform t.denied('select * from private.app_secret', 'anon cannot read the hashing secret');
  perform t.denied('select * from private.slots_for_date(current_date)', 'anon cannot call private slot engine');
  perform t.denied($q$insert into public.projects (slug,title) values ('x','x')$q$, 'anon cannot insert projects');
  perform t.denied($q$update public.projects set title='hacked'$q$, 'anon cannot update projects');
  perform t.denied($q$delete from public.projects$q$, 'anon cannot delete projects');
  perform t.denied($q$insert into storage.objects (bucket_id,name) values ('project-media','a.png')$q$, 'anon cannot upload to storage');
  reset role;
end $$;

-- ---------------------------------------------------------------- 2. publish / unpublish
do $$
declare n int;
begin
  update public.projects set published = false where slug = 'rent-manager';
  perform t.as_anon();
  select count(*) into n from public.projects;
  perform t.ok(n = 3, 'unpublished project is hidden from anon');
  reset role;
  update public.projects set published = true where slug = 'rent-manager';

  insert into public.project_media (project_id, kind, storage_path)
    select id, 'image', 'x.png' from public.projects where slug = 'aurex-ai';
  update public.projects set published = false where slug = 'aurex-ai';
  perform t.as_anon();
  select count(*) into n from public.project_media;
  perform t.ok(n = 0, 'media of an unpublished project is hidden');
  reset role;
  update public.projects set published = true where slug = 'aurex-ai';
  delete from public.project_media;
end $$;

-- ---------------------------------------------------------------- 3. availability
do $$
declare d date; n int; wk date; sat date; blocked date;
begin
  perform t.as_anon();
  select count(*) into n from public.get_booking_days();
  perform t.ok(n = 22, 'booking window lists today + 21 days');
  select d0 into d from (select t.free_days(1) as d0) q;
  perform t.ok(d is not null, 'there is at least one day with free slots');
  select count(*) into n from public.get_available_slots(d);
  perform t.ok(n >= 1, 'a free day returns slots');
  select min(day) into sat from public.get_booking_days() g
   where extract(dow from g.day) = 6;
  select count(*) into n from public.get_available_slots(sat);
  perform t.ok(n = 0, 'Saturday has no slots (no rule)');
  select count(*) into n from public.get_available_slots(current_date - 3);
  perform t.ok(n = 0, 'past dates have no slots');
  select count(*) into n from public.get_available_slots(current_date + 60);
  perform t.ok(n = 0, 'dates beyond the window have no slots');
  reset role;

  -- blocked date removes a day
  select d0 into blocked from (select t.free_days(1) as d0) q;
  insert into public.blocked_dates (day, reason) values (blocked, 'test');
  perform t.as_anon();
  select count(*) into n from public.get_available_slots(blocked);
  perform t.ok(n = 0, 'blocked date has no slots');
  reset role;
  delete from public.blocked_dates;
end $$;

-- ---------------------------------------------------------------- 4. create_booking
do $$
declare
  days date[]; svc uuid; r jsonb; n int; i int; stored record;
  s1 timestamptz; s2 timestamptz; s3 timestamptz; s4 timestamptz;
begin
  select array_agg(day order by day) into days from (select t.free_days(3) as day) q;
  select id into svc from public.services where slug = 'business-automation';

  perform t.as_anon();
  select slot_start into s1 from public.get_available_slots(days[1]) where available order by slot_start limit 1;
  select slot_start into s2 from public.get_available_slots(days[1]) where available order by slot_start offset 1 limit 1;
  select slot_start into s3 from public.get_available_slots(days[2]) where available order by slot_start limit 1;
  select slot_start into s4 from public.get_available_slots(days[3]) where available order by slot_start limit 1;

  -- bot checks
  perform t.as_anon('203.0.113.10');
  r := public.create_booking(svc, s1, 'Test User', 'a@example.com', null, 'http://spam', 5000);
  perform t.ok(r->>'code' = 'rejected', 'honeypot filled is rejected');
  r := public.create_booking(svc, s1, 'Test User', 'a@example.com', null, null, 500);
  perform t.ok(r->>'code' = 'rejected', 'form filled in 0.5s is rejected');
  r := public.create_booking(svc, s1, 'Test User', 'a@example.com', null, null, null);
  perform t.ok(r->>'code' = 'rejected', 'missing timing is rejected');

  -- validation (separate visitor so the hourly throttle is not involved)
  perform t.as_anon('203.0.113.11');
  r := public.create_booking(svc, s1, 'A', 'a@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'invalid' and r->>'field' = 'name', 'one-letter name is invalid');
  r := public.create_booking(svc, s1, 'Test User', 'not-an-email', null, null, 6000);
  perform t.ok(r->>'code' = 'invalid' and r->>'field' = 'contact', 'bad contact is invalid');
  r := public.create_booking(svc, s1, 'Test User', '12345', null, null, 6000);
  perform t.ok(r->>'code' = 'invalid' and r->>'field' = 'contact', 'short phone is invalid');
  r := public.create_booking(svc, s1, 'Test User', 'a@example.com', repeat('x', 601), null, 6000);
  perform t.ok(r->>'code' = 'invalid' and r->>'field' = 'message', 'over-long message is invalid');
  r := public.create_booking(svc, s1, 'Test User', 'a@example.com', 'http://a http://b http://c', null, 6000);
  perform t.ok(r->>'code' = 'rejected', 'link-stuffed message is rejected');
  r := public.create_booking(gen_random_uuid(), s1, 'Test User', 'a@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'invalid' and r->>'field' = 'service', 'unknown service is invalid');
  r := public.create_booking(svc, s1 + interval '7 minutes', 'Test User', 'a@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'slot_unavailable', 'off-grid start time is not a slot');
  r := public.create_booking(svc, now() - interval '2 days', 'Test User', 'a@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'slot_unavailable', 'past time is not a slot');

  -- success
  perform t.as_anon('203.0.113.12');
  r := public.create_booking(svc, s1, '  Test User  ', 'A@Example.COM', 'Hello', null, 6000);
  perform t.ok((r->>'ok')::boolean and r->>'ref' ~ '^DRY-[0-9A-F]{6}$', 'valid booking succeeds with a reference');
  reset role;
  select * into stored from public.bookings where ref = r->>'ref';
  perform t.ok(stored.status = 'pending' and stored.contact = 'a@example.com' and stored.name = 'Test User',
               'booking is stored pending with normalised fields');
  perform t.ok(stored.ip_hash is not null and stored.ip_hash !~ '203\.0\.113', 'only a hash of the IP is stored');

  -- same slot again
  perform t.as_anon('203.0.113.50');
  r := public.create_booking(svc, s1, 'Other Person', 'b@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'slot_taken', 'a taken slot cannot be booked again');
  select count(*) into n from public.get_available_slots(days[1]) where slot_start = s1 and available;
  perform t.ok(n = 0, 'taken slot is reported unavailable');

  -- per-contact limit on open bookings (2)
  r := public.create_booking(svc, s2, 'Test User', 'a@example.com', null, null, 6000);
  perform t.ok((r->>'ok')::boolean, 'second open booking for the same contact is allowed');
  r := public.create_booking(svc, s3, 'Test User', 'a@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'too_many_open', 'third open booking for the same contact is refused');

  -- duplicate (same contact + same start, previous booking already completed)
  reset role;
  update public.bookings set status = 'completed' where starts_at = s1;
  perform t.as_anon('203.0.113.51');
  r := public.create_booking(svc, s1, 'Test User', 'a@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'duplicate', 'same contact and same start is a duplicate');
  reset role;

  -- per-IP throttle: 8 attempts per hour
  delete from private.booking_attempts;
  perform t.as_anon('198.51.100.7');
  for i in 1..8 loop
    r := public.create_booking(svc, s4, 'X', 'bad', null, null, 6000);
  end loop;
  r := public.create_booking(svc, s4, 'Valid Name', 'c@example.com', null, null, 6000);
  perform t.ok(r->>'code' = 'rate_limited', 'ninth attempt from one visitor in an hour is rate limited');
  reset role;
  delete from private.booking_attempts;
  delete from public.bookings;
end $$;

-- ---------------------------------------------------------------- 5. admin vs non-admin
do $$
declare
  adm uuid := gen_random_uuid(); usr uuid := gen_random_uuid();
  n int; svc uuid; r jsonb; s1 timestamptz; d date; bid uuid;
begin
  insert into auth.users (id, email) values (adm, 'admin@example.test'), (usr, 'user@example.test');
  insert into public.admins (user_id) values (adm);
  select id into svc from public.services limit 1;
  select day into d from (select t.free_days(1) as day) q;
  select slot_start into s1 from public.get_available_slots(d) where available limit 1;

  perform t.as_anon('203.0.113.77');
  r := public.create_booking(svc, s1, 'Visitor', 'v@example.com', null, null, 6000);
  perform t.ok((r->>'ok')::boolean, 'visitor booking for admin tests succeeded');
  reset role;
  update public.projects set published = false where slug = 'derya-capital';

  -- admin
  perform t.as_user(adm);
  select count(*) into n from public.bookings;
  perform t.ok(n = 1, 'admin can read bookings');
  select count(*) into n from public.projects;
  perform t.ok(n = 4, 'admin sees unpublished projects too');
  update public.bookings set status = 'confirmed' returning id into bid;
  perform t.ok(bid is not null, 'admin can confirm a booking');
  insert into public.projects (slug, title) values ('admin-draft', 'Admin draft');
  perform t.ok(exists (select 1 from public.projects where slug = 'admin-draft' and published = false),
               'admin-created project starts as a draft');
  insert into storage.objects (bucket_id, name) values ('project-media', 'ok.png');
  perform t.ok(true, 'admin can upload to the media bucket');
  reset role;

  -- signed-in non-admin
  perform t.as_user(usr);
  select count(*) into n from public.bookings;
  perform t.ok(n = 0, 'non-admin user sees no bookings');
  update public.bookings set status = 'cancelled';
  get diagnostics n = row_count;
  perform t.ok(n = 0, 'non-admin cannot update bookings');
  perform t.denied($q$insert into public.projects (slug,title) values ('evil','evil')$q$, 'non-admin cannot insert projects');
  select count(*) into n from public.projects;
  perform t.ok(n = 3, 'non-admin sees only the 3 published projects');
  perform t.denied($q$insert into storage.objects (bucket_id,name) values ('project-media','evil.png')$q$, 'non-admin cannot upload');
  reset role;
end $$;

-- ---------------------------------------------------------------- 6. constraints
do $$
begin
  begin
    insert into public.projects (slug, title, demo_url) values ('bad-url', 'x', 'javascript:alert(1)');
    raise exception 'FAIL: javascript: demo URL was accepted';
  exception when check_violation then raise notice 'PASS: demo_url must be http(s)';
  end;
  begin
    insert into public.bookings (ref, service_title, starts_at, ends_at, name, contact, contact_type, contact_hash)
      values ('R1','s','2030-01-01 10:00+00','2030-01-01 11:00+00','n','c','email','h');
    insert into public.bookings (ref, service_title, starts_at, ends_at, name, contact, contact_type, contact_hash)
      values ('R2','s','2030-01-01 10:30+00','2030-01-01 11:30+00','n','c','email','h');
    raise exception 'FAIL: overlapping bookings were accepted';
  exception when exclusion_violation then raise notice 'PASS: database refuses overlapping bookings';
  end;
end $$;

select 'ALL SQL TESTS PASSED' as result;
