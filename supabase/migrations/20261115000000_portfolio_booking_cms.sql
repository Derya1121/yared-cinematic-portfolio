-- =============================================================================
-- DERYA portfolio: booking system + CMS schema
--
-- Target: Supabase (Postgres 15+, Supabase Auth, Supabase Storage).
-- NOT applied to any live project yet. See docs/BACKEND.md for how to apply it.
--
-- Security model
--   * The browser only ever holds the public (anon / publishable) key.
--   * anon can read PUBLISHED content and call three booking functions. Nothing else.
--   * Everything else requires an authenticated user who is listed in public.admins.
--   * Booking rules (validation, availability, anti-spam, double-booking) are
--     enforced here in the database, never only in the browser.
--
-- Seed data marked "ASSUMPTION" is a placeholder the owner must confirm in the CMS.
-- =============================================================================

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create table if not exists public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;  -- no policies: invisible to API roles

create or replace function private.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.admins a where a.user_id = (select auth.uid()));
$$;
revoke all on function private.is_admin() from public;
grant execute on function private.is_admin() to anon, authenticated;

create or replace function private.touch_updated_at()
returns trigger language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end $$;

-- ---------------------------------------------------------------------------
-- CMS content
-- ---------------------------------------------------------------------------
create table if not exists public.site_content (
  key        text primary key check (key ~ '^[a-z0-9_]{2,60}$'),
  value      text not null check (char_length(value) <= 2000),
  label      text not null,
  group_name text not null default 'Homepage',
  sort_order integer not null default 0,
  published  boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.categories (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name       text not null check (char_length(name) between 1 and 60),
  sort_order integer not null default 0,
  published  boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.projects (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title        text not null check (char_length(title) between 1 and 80),
  category_id  uuid references public.categories (id) on delete set null,
  type_label   text check (char_length(type_label) <= 60),
  summary      text check (char_length(summary) <= 240),
  description  text check (char_length(description) <= 2000),
  status_note  text not null default 'PROJECT SHOWCASE · DEMO LINK TO BE ADDED' check (char_length(status_note) <= 120),
  demo_url     text check (demo_url is null or demo_url ~* '^https?://[^\s]+$'),
  art_variant  text not null default 'none' check (art_variant in ('aurex','derya','rent','pulse','none')),
  image_path   text,           -- path inside the project-media storage bucket
  image_alt    text check (char_length(image_alt) <= 160),
  featured     boolean not null default false,
  sort_order   integer not null default 0,
  published    boolean not null default false,   -- new projects start as drafts
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists public.project_media (
  id            uuid primary key default gen_random_uuid(),
  project_id    uuid not null references public.projects (id) on delete cascade,
  kind          text not null check (kind in ('image','video')),
  storage_path  text,
  external_url  text check (external_url is null or external_url ~* '^https://[^\s]+$'),
  alt           text check (char_length(alt) <= 160),
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  check (storage_path is not null or external_url is not null)
);

create table if not exists public.services (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title       text not null check (char_length(title) between 1 and 80),
  description text check (char_length(description) <= 300),
  bookable    boolean not null default true,
  sort_order  integer not null default 0,
  published   boolean not null default true,
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Booking
-- ---------------------------------------------------------------------------
create table if not exists public.booking_settings (
  id               boolean primary key default true check (id),   -- single row
  timezone         text    not null default 'Africa/Addis_Ababa',
  window_days      integer not null default 21 check (window_days between 1 and 120),
  min_notice_hours integer not null default 12 check (min_notice_hours between 0 and 168)
);

create table if not exists public.availability_rules (
  id           uuid primary key default gen_random_uuid(),
  weekday      smallint not null check (weekday between 0 and 6),   -- 0 = Sunday
  start_time   time not null,
  end_time     time not null,
  slot_minutes integer not null default 60 check (slot_minutes between 15 and 240),
  active       boolean not null default true,
  check (end_time > start_time)
);

create table if not exists public.blocked_dates (
  day    date primary key,
  reason text check (char_length(reason) <= 120)
);

create table if not exists public.bookings (
  id            uuid primary key default gen_random_uuid(),
  ref           text not null unique,
  service_id    uuid references public.services (id) on delete set null,
  service_title text not null,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  name          text not null,
  contact       text not null,
  contact_type  text not null check (contact_type in ('email','phone')),
  contact_hash  text not null,
  ip_hash       text,
  message       text,
  status        text not null default 'pending' check (status in ('pending','confirmed','cancelled','completed')),
  admin_note    text check (char_length(admin_note) <= 1000),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (ends_at > starts_at),
  -- A slot can never be double booked, even under concurrent requests.
  constraint bookings_no_overlap exclude using gist (tstzrange(starts_at, ends_at) with &&)
    where (status in ('pending','confirmed'))
);
create index if not exists bookings_starts_at_idx on public.bookings (starts_at);
create index if not exists bookings_contact_hash_idx on public.bookings (contact_hash, created_at);

create table if not exists private.booking_attempts (
  id         bigint generated always as identity primary key,
  ip_hash    text not null,
  created_at timestamptz not null default now()
);
create index if not exists booking_attempts_ip_idx on private.booking_attempts (ip_hash, created_at);

create table if not exists private.app_secret (
  id     boolean primary key default true check (id),
  secret text not null default gen_random_uuid()::text
);
insert into private.app_secret (id) values (true) on conflict do nothing;

-- updated_at triggers
do $$
declare t text;
begin
  foreach t in array array['site_content','categories','projects','services','bookings'] loop
    execute format('drop trigger if exists touch_%1$s on public.%1$s', t);
    execute format('create trigger touch_%1$s before update on public.%1$s for each row execute function private.touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Row level security and grants
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['site_content','categories','projects','project_media','services',
                           'booking_settings','availability_rules','blocked_dates','bookings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
alter table private.booking_attempts enable row level security;
alter table private.app_secret       enable row level security;
revoke all on private.booking_attempts, private.app_secret from anon, authenticated;
revoke all on public.admins from anon, authenticated;

-- public read of published content
grant select on public.site_content, public.categories, public.projects,
                public.project_media, public.services to anon, authenticated;
-- admin CRUD (still gated by policies below)
grant select, insert, update, delete on
  public.site_content, public.categories, public.projects, public.project_media, public.services,
  public.booking_settings, public.availability_rules, public.blocked_dates, public.bookings
  to authenticated;

drop policy if exists site_content_read on public.site_content;
create policy site_content_read on public.site_content for select to anon, authenticated using (published);
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories for select to anon, authenticated using (published);
drop policy if exists projects_read on public.projects;
create policy projects_read on public.projects for select to anon, authenticated using (published);
drop policy if exists services_read on public.services;
create policy services_read on public.services for select to anon, authenticated using (published);
drop policy if exists project_media_read on public.project_media;
create policy project_media_read on public.project_media for select to anon, authenticated
  using (exists (select 1 from public.projects p where p.id = project_id and p.published));

do $$
declare t text;
begin
  foreach t in array array['site_content','categories','projects','project_media','services',
                           'booking_settings','availability_rules','blocked_dates','bookings'] loop
    execute format('drop policy if exists %1$s_admin on public.%1$s', t);
    execute format('create policy %1$s_admin on public.%1$s for all to authenticated using (private.is_admin()) with check (private.is_admin())', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Availability engine
-- ---------------------------------------------------------------------------
create or replace function private.slots_for_date(p_date date)
returns table (slot_start timestamptz, slot_end timestamptz, local_time text, available boolean)
language plpgsql stable security definer set search_path = ''
as $$
declare
  s public.booking_settings;
  v_today date;
begin
  select * into s from public.booking_settings where id;
  v_today := (now() at time zone s.timezone)::date;
  if p_date < v_today or p_date > v_today + s.window_days then return; end if;
  if exists (select 1 from public.blocked_dates b where b.day = p_date) then return; end if;

  return query
    select distinct on (x.st)
           x.st,
           x.st + make_interval(mins => r.slot_minutes),
           to_char(x.st at time zone s.timezone, 'HH24:MI'),
           (x.st >= now() + make_interval(hours => s.min_notice_hours)
            and not exists (
              select 1 from public.bookings b
              where b.status in ('pending','confirmed')
                and tstzrange(b.starts_at, b.ends_at) && tstzrange(x.st, x.st + make_interval(mins => r.slot_minutes))))
    from public.availability_rules r
    cross join lateral generate_series(
        (p_date + r.start_time)::timestamp,
        (p_date + r.end_time - make_interval(mins => r.slot_minutes))::timestamp,
        make_interval(mins => r.slot_minutes)) as g(naive)
    cross join lateral (select (g.naive at time zone s.timezone) as st) x
    where r.active and r.weekday = extract(dow from p_date)::int
    order by x.st;
end $$;
revoke all on function private.slots_for_date(date) from public;

create or replace function public.get_booking_config()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object('timezone', timezone, 'window_days', window_days, 'min_notice_hours', min_notice_hours)
  from public.booking_settings where id;
$$;

create or replace function public.get_booking_days()
returns table (day date, available_slots integer)
language plpgsql stable security definer set search_path = ''
as $$
declare s public.booking_settings; v_today date;
begin
  select * into s from public.booking_settings where id;
  v_today := (now() at time zone s.timezone)::date;
  return query
    select d::date,
           (select count(*)::integer from private.slots_for_date(d::date) sl where sl.available)
    from generate_series(v_today, v_today + s.window_days, interval '1 day') d;
end $$;

create or replace function public.get_available_slots(p_date date)
returns table (slot_start timestamptz, local_time text, available boolean)
language sql stable security definer set search_path = ''
as $$
  select sl.slot_start, sl.local_time, sl.available from private.slots_for_date(p_date) sl;
$$;

-- ---------------------------------------------------------------------------
-- Booking creation: the only way a visitor can write anything.
-- Returns {"ok": true, ...} only after the row is committed-ready in this
-- transaction; any failure returns {"ok": false, "code": ...} or raises.
-- ---------------------------------------------------------------------------
create or replace function public.create_booking(
  p_service_id uuid,
  p_starts_at  timestamptz,
  p_name       text,
  p_contact    text,
  p_message    text    default null,
  p_website    text    default null,   -- honeypot: must stay empty
  p_elapsed_ms integer default null    -- ms the visitor spent on the form
)
returns jsonb
language plpgsql volatile security definer set search_path = ''
as $$
declare
  v_name    text := btrim(coalesce(p_name, ''));
  v_contact text := btrim(coalesce(p_contact, ''));
  v_message text := nullif(btrim(coalesce(p_message, '')), '');
  v_ctype   text;
  v_norm    text;
  v_hdr     json;
  v_ip      text;
  v_iph     text;
  v_ch      text;
  v_salt    text;
  v_tz      text;
  v_svc     public.services;
  v_slot    record;
  v_ref     text;
  v_try     integer := 0;
begin
  -- visitor fingerprint (hashed; the raw address is never stored)
  begin
    v_hdr := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_hdr := null;
  end;
  v_ip := coalesce(nullif(btrim(split_part(coalesce(v_hdr ->> 'x-forwarded-for', ''), ',', 1)), ''),
                   nullif(v_hdr ->> 'x-real-ip', ''), 'unknown');
  select secret into v_salt from private.app_secret where id;
  v_iph := encode(sha256(convert_to(v_salt || v_ip, 'utf8')), 'hex');

  -- throttle: per visitor and a global circuit breaker
  delete from private.booking_attempts where created_at < now() - interval '2 days';
  if (select count(*) from private.booking_attempts where ip_hash = v_iph and created_at > now() - interval '1 hour') >= 8
     or (select count(*) from private.booking_attempts where created_at > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  insert into private.booking_attempts (ip_hash) values (v_iph);

  -- bot checks: honeypot filled, form submitted implausibly fast, or timing missing
  if coalesce(btrim(p_website), '') <> '' or p_elapsed_ms is null or p_elapsed_ms < 2500 then
    return jsonb_build_object('ok', false, 'code', 'rejected');
  end if;

  -- validation
  if char_length(v_name) < 2 or char_length(v_name) > 80 or v_name ~ '[[:cntrl:]]' then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'field', 'name');
  end if;
  if char_length(v_contact) <= 254 and v_contact ~* '^[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+$' then
    v_ctype := 'email'; v_norm := lower(v_contact);
  elsif regexp_replace(v_contact, '[\s().-]', '', 'g') ~ '^\+?[0-9]{7,15}$' then
    v_ctype := 'phone'; v_norm := regexp_replace(v_contact, '[\s().-]', '', 'g');
  else
    return jsonb_build_object('ok', false, 'code', 'invalid', 'field', 'contact');
  end if;
  if v_message is not null then
    if char_length(v_message) > 600 or v_message ~ E'[\\x01-\\x08\\x0b\\x0c\\x0e-\\x1f]' then
      return jsonb_build_object('ok', false, 'code', 'invalid', 'field', 'message');
    end if;
    if (char_length(v_message) - char_length(replace(lower(v_message), 'http', ''))) / 4 > 2 then
      return jsonb_build_object('ok', false, 'code', 'rejected');
    end if;
  end if;
  if p_starts_at is null then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'field', 'time');
  end if;

  select * into v_svc from public.services where id = p_service_id and published and bookable;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'invalid', 'field', 'service');
  end if;

  -- the requested start must be a real slot, and still free
  select timezone into v_tz from public.booking_settings where id;
  select * into v_slot from private.slots_for_date((p_starts_at at time zone v_tz)::date) sl
   where sl.slot_start = p_starts_at;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'slot_unavailable');
  end if;
  if not v_slot.available then
    return jsonb_build_object('ok', false, 'code', 'slot_taken');
  end if;

  -- duplicate / abuse protection per contact
  v_ch := encode(sha256(convert_to(v_salt || v_norm, 'utf8')), 'hex');
  if exists (select 1 from public.bookings where contact_hash = v_ch and starts_at = p_starts_at and status <> 'cancelled') then
    return jsonb_build_object('ok', false, 'code', 'duplicate');
  end if;
  if (select count(*) from public.bookings where contact_hash = v_ch and created_at > now() - interval '24 hours') >= 3 then
    return jsonb_build_object('ok', false, 'code', 'rate_limited');
  end if;
  if (select count(*) from public.bookings where contact_hash = v_ch and status in ('pending','confirmed') and starts_at > now()) >= 2 then
    return jsonb_build_object('ok', false, 'code', 'too_many_open');
  end if;

  loop
    v_try := v_try + 1;
    v_ref := 'DRY-' || upper(substr(md5(random()::text || clock_timestamp()::text || v_try::text), 1, 6));
    begin
      insert into public.bookings (ref, service_id, service_title, starts_at, ends_at, name, contact,
                                   contact_type, contact_hash, ip_hash, message)
      values (v_ref, v_svc.id, v_svc.title, v_slot.slot_start, v_slot.slot_end, v_name, v_norm,
              v_ctype, v_ch, v_iph, v_message);
      exit;
    exception
      when exclusion_violation then
        return jsonb_build_object('ok', false, 'code', 'slot_taken');
      when unique_violation then
        if v_try >= 5 then raise; end if;
    end;
  end loop;

  return jsonb_build_object('ok', true, 'ref', v_ref, 'status', 'pending', 'service', v_svc.title,
                            'starts_at', v_slot.slot_start, 'ends_at', v_slot.slot_end,
                            'local_time', v_slot.local_time);
end $$;

revoke all on function public.get_booking_config(), public.get_booking_days(),
                       public.get_available_slots(date),
                       public.create_booking(uuid, timestamptz, text, text, text, text, integer) from public;
grant execute on function public.get_booking_config(), public.get_booking_days(),
                          public.get_available_slots(date),
                          public.create_booking(uuid, timestamptz, text, text, text, text, integer)
  to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage: public-read bucket for project images, admin-only writes
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('project-media', 'project-media', true, 5242880,
        array['image/jpeg','image/png','image/webp','image/avif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists project_media_admin_insert on storage.objects;
create policy project_media_admin_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'project-media' and private.is_admin());
drop policy if exists project_media_admin_update on storage.objects;
create policy project_media_admin_update on storage.objects for update to authenticated
  using (bucket_id = 'project-media' and private.is_admin())
  with check (bucket_id = 'project-media' and private.is_admin());
drop policy if exists project_media_admin_delete on storage.objects;
create policy project_media_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'project-media' and private.is_admin());

-- ---------------------------------------------------------------------------
-- Seed: mirrors the current static site so nothing changes visually on day one
-- ---------------------------------------------------------------------------
insert into public.booking_settings (id) values (true) on conflict do nothing;

-- ASSUMPTION: Monday to Friday, 09:00-17:00, 60-minute calls. Confirm or change in the CMS.
insert into public.availability_rules (weekday, start_time, end_time, slot_minutes)
select d, time '09:00', time '17:00', 60
from generate_series(1, 5) d
where not exists (select 1 from public.availability_rules);

insert into public.categories (slug, name, sort_order) values
  ('ai',       'AI & Assistants',      10),
  ('business', 'Business',             20),
  ('software', 'Software',             30),
  ('trading',  'Trading & Analytics',  40)
on conflict (slug) do nothing;

insert into public.projects (slug, title, category_id, type_label, summary, description, art_variant, featured, sort_order, published)
select v.slug, v.title, c.id, v.type_label, v.summary, v.description, v.art, v.featured, v.sort_order, true
from (values
  ('aurex-ai',      'AUREX AI',      'ai',       'AI ASSISTANT CONCEPT',  'An AI assistant project exploring intelligent interaction and digital productivity.',
   'An AI assistant project exploring intelligent interaction and digital productivity.', 'aurex', true,  10),
  ('derya-capital', 'DERYA CAPITAL', 'business', 'BUSINESS TECHNOLOGY',   'A business and technology initiative.',
   'A business and technology initiative.', 'derya', false, 20),
  ('rent-manager',  'Rent Manager',  'software', 'MANAGEMENT SOFTWARE',   'A property-management software project.',
   'A property-management software project.', 'rent', false, 30),
  ('derya-pulse-ai','DERYA PULSE AI','trading',  'TRADING TECHNOLOGY',    'An AI-assisted trading technology project.',
   'An AI-assisted trading technology project.', 'pulse', false, 40)
) as v(slug, title, cat, type_label, summary, description, art, featured, sort_order)
join public.categories c on c.slug = v.cat
on conflict (slug) do nothing;

insert into public.services (slug, title, description, sort_order) values
  ('ai-software-assistants',         'AI Software & Assistants',        'AI-powered experiences, assistants and practical intelligent workflows.', 10),
  ('websites-digital-products',      'Websites & Digital Products',     'Digital products and responsive web experiences built around real needs.', 20),
  ('business-automation',            'Business Automation',             'Connected systems that reduce repetitive work and improve operations.', 30),
  ('digital-solutions-integration',  'Digital Solutions & Integration', 'Technology-led solutions designed to create value for businesses.', 40)
on conflict (slug) do nothing;

insert into public.site_content (key, value, label, group_name, sort_order) values
  ('hero_eyebrow',   'INDEPENDENT TECHNOLOGY FOUNDER',
     'Hero label', 'Homepage', 10),
  ('hero_intro',     'Founder, AI Software Developer, and Technology Innovator.',
     'Hero introduction', 'Homepage', 20),
  ('hero_body',      'I transform ambitious ideas into intelligent software, AI-powered systems, and digital solutions that solve real-world problems.',
     'Hero paragraph', 'Homepage', 30),
  ('statement_text', 'My focus is simple: build meaningful technology, create real value, and turn possibilities into reality.',
     'About statement', 'Homepage', 40),
  ('booking_intro',  'Choose a service and a time that suits you. Yared confirms every request personally, by email or WhatsApp.',
     'Booking introduction', 'Booking', 50)
on conflict (key) do nothing;
