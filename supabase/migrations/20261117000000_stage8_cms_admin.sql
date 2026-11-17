-- =====================================================================
-- DERYA portfolio — Stage 8: CMS + private admin command center
-- PREPARED, NOT APPLIED. Do not run against any Supabase project until the
-- owner has approved it (see docs/STAGE8_SETUP.md).
-- Idempotent: safe to run more than once.
-- Written for a fresh, dedicated Supabase project. It does not reuse or
-- depend on the unfinished recovery-branch booking/CMS migration.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Private schema, configuration, admin helper
-- ---------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create table if not exists private.app_config (
  key text primary key,
  value text not null
);
-- 'true' => admin access additionally requires an MFA (aal2) session.
insert into private.app_config (key, value) values ('admin_require_mfa', 'false')
  on conflict (key) do nothing;
revoke all on private.app_config from public, anon, authenticated;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text,
  role text not null default 'owner' check (role in ('owner', 'editor')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Is the caller an active admin (optionally with MFA)? 'editor' = any admin, 'owner' = owner only.
create or replace function private.is_admin(min_role text default 'owner')
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.admin_users a
    where a.user_id = (select auth.uid())
      and a.active
      and (min_role = 'editor' or a.role = 'owner')
      and (
        coalesce((select c.value from private.app_config c where c.key = 'admin_require_mfa'), 'false') <> 'true'
        or (select auth.jwt() ->> 'aal') = 'aal2'
      )
  );
$$;
revoke all on function private.is_admin(text) from public, anon;
grant execute on function private.is_admin(text) to authenticated, service_role;

create or replace function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- ---------------------------------------------------------------------
-- 1. Website content (registry + draft/published values)
-- ---------------------------------------------------------------------
create table if not exists public.content_fields (
  key text primary key,
  section text not null,
  label text not null,
  kind text not null check (kind in ('text','longtext','url','email','phone','image','select','toggle')),
  max_length int not null default 200 check (max_length between 1 and 2000),
  options text[],
  default_value text not null default '',
  sort_order int not null default 0
);

create table if not exists public.site_content (
  key text primary key references public.content_fields (key) on delete cascade,
  draft text,
  published text,
  published_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

-- Returns an error message, or null when the value is acceptable for the field kind.
create or replace function private.check_field(p_kind text, p_value text, p_max int, p_options text[])
returns text language plpgsql immutable set search_path = '' as $$
begin
  if p_value is null or p_value = '' then return null; end if;
  if length(p_value) > p_max then return 'too long (max ' || p_max || ')'; end if;
  if p_value ~ '[\x01-\x08\x0b\x0c\x0e-\x1f]' then return 'contains control characters'; end if;
  case p_kind
    when 'url' then
      if (length(p_value) > 500 or p_value !~ '^https://[^\s<>"'']+$') then return 'must be an https:// URL'; end if;
      if p_value ~* 'facebook|fb\.com|fb\.me' then return 'Facebook links are not allowed'; end if;
    when 'email' then
      if p_value !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' then return 'must be an email address'; end if;
    when 'phone' then
      if p_value !~ '^\+[1-9][0-9]{7,14}$' then return 'must be international format, e.g. +251902389561'; end if;
    when 'image' then
      if p_value !~ '^(projects|site)/[A-Za-z0-9_./-]{1,150}\.(jpg|jpeg|png|webp|avif)$' or p_value like '%..%'
        then return 'must be an uploaded image path'; end if;
    when 'select' then
      if not (p_value = any (coalesce(p_options, '{}'))) then return 'not an allowed option'; end if;
    when 'toggle' then
      if p_value not in ('on','off') then return 'must be on or off'; end if;
    else null;
  end case;
  return null;
end $$;

create or replace function private.site_content_guard() returns trigger
language plpgsql set search_path = '' as $$
declare f public.content_fields; err text;
begin
  select * into f from public.content_fields where key = new.key;
  if not found then raise exception 'unknown content key %', new.key using errcode = '23514'; end if;
  if tg_op = 'INSERT' or new.draft is distinct from old.draft then
    err := private.check_field(f.kind, new.draft, f.max_length, f.options);
    if err is not null then raise exception 'invalid value for %: %', new.key, err using errcode = '23514'; end if;
  end if;
  if tg_op = 'UPDATE' then
    -- the published value and its timestamp are only ever written by admin_publish_content
    if current_user in ('authenticated', 'anon') then
      new.published := old.published; new.published_at := old.published_at;
    end if;
    new.updated_by := (select auth.uid());
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists site_content_guard on public.site_content;
create trigger site_content_guard before insert or update on public.site_content
  for each row execute function private.site_content_guard();

-- ---------------------------------------------------------------------
-- 2. Projects, media, testimonials
-- ---------------------------------------------------------------------
create table if not exists public.projects (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,58}[a-z0-9]$'),
  title text not null check (length(title) between 1 and 120),
  summary text not null default '' check (length(summary) <= 300),
  description text not null default '' check (length(description) <= 4000),
  type_label text not null default '' check (length(type_label) <= 60),
  category text not null default 'software' check (category in ('ai','business','software')),
  technologies text[] not null default '{}' check (cardinality(technologies) <= 12),
  demo_url text check (demo_url is null or (length(demo_url) <= 500 and demo_url ~ '^https://[^\s<>"'']{3,}$' and demo_url !~* 'facebook|fb\.com|fb\.me')),
  accent text not null default 'aurex' check (accent in ('aurex','derya','rent','pulse')),
  thumbnail_path text check (thumbnail_path is null or (thumbnail_path ~ '^(projects|site)/[A-Za-z0-9_./-]{1,150}\.(jpg|jpeg|png|webp|avif)$' and thumbnail_path not like '%..%')),
  status text not null default 'draft' check (status in ('draft','published','archived')),
  featured boolean not null default false,
  sort_order int not null default 100,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.project_media (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects (id) on delete cascade,
  path text not null check (path ~ '^(projects|site)/[A-Za-z0-9_./-]{1,150}\.(jpg|jpeg|png|webp|avif)$' and path not like '%..%'),
  alt text not null default '' check (length(alt) <= 200),
  kind text not null default 'screenshot' check (kind in ('screenshot','thumbnail')),
  sort_order int not null default 100,
  created_at timestamptz not null default now()
);
create index if not exists project_media_project_idx on public.project_media (project_id, sort_order);

create or replace function private.projects_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status is distinct from 'published') then
    new.published_at := now();
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists projects_guard on public.projects;
create trigger projects_guard before insert or update on public.projects
  for each row execute function private.projects_guard();

-- Feedback comes first so testimonials can reference it.
create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  name text check (name is null or length(name) between 1 and 80),
  email text check (email is null or (length(email) <= 254 and email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')),
  category text not null check (category in ('general','design','bug','idea','praise','other')),
  message text not null check (length(message) between 5 and 2000),
  status text not null default 'unread' check (status in ('unread','read','resolved','archived')),
  client_key text,
  ip_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists feedback_client_key_idx on public.feedback (client_key) where client_key is not null;
create index if not exists feedback_status_idx on public.feedback (status, created_at desc);

create table if not exists public.feedback_replies (
  id uuid primary key default gen_random_uuid(),
  feedback_id uuid not null references public.feedback (id) on delete cascade,
  body text not null check (length(body) between 1 and 2000),
  author uuid,
  created_at timestamptz not null default now()
);

create table if not exists public.testimonials (
  id uuid primary key default gen_random_uuid(),
  author_name text not null check (length(author_name) between 1 and 80),
  author_role text not null default '' check (length(author_role) <= 120),
  quote text not null check (length(quote) between 5 and 600),
  published boolean not null default false,   -- only ever true when the owner publishes it
  sort_order int not null default 100,
  source_feedback_id uuid references public.feedback (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Bookings, notes, notification deliveries
-- ---------------------------------------------------------------------
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  name text not null check (length(name) between 1 and 100),
  business text check (business is null or length(business) <= 120),
  email text check (email is null or (length(email) <= 254 and email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$')),
  whatsapp text check (whatsapp is null or whatsapp ~ '^\+[1-9][0-9]{7,14}$'),
  service text not null check (service in ('website','ai-assistant','automation','software','other')),
  budget text check (budget is null or budget in ('under-500','500-1500','1500-5000','5000-plus','unsure')),
  description text not null check (length(description) between 10 and 2000),
  status text not null default 'unread' check (status in ('unread','read','contacted','accepted','rejected')),
  dedupe_hash text not null,
  client_key text,
  ip_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (email is not null or whatsapp is not null)
);
create unique index if not exists bookings_client_key_idx on public.bookings (client_key) where client_key is not null;
create index if not exists bookings_dedupe_idx on public.bookings (dedupe_hash, created_at desc);
create index if not exists bookings_status_idx on public.bookings (status, created_at desc);

create table if not exists public.booking_notes (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  note text not null check (length(note) between 1 and 2000),
  author uuid,
  created_at timestamptz not null default now()
);

-- 'sent' = the provider accepted the message. 'delivered' only ever comes from a provider
-- delivery receipt (WhatsApp webhook). Telegram never reports delivery, so it stops at 'sent'.
create table if not exists public.notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  channel text not null check (channel in ('telegram','whatsapp')),
  status text not null default 'pending'
    check (status in ('pending','sending','sent','delivered','failed','dead','not_configured')),
  attempts int not null default 0,
  max_attempts int not null default 5 check (max_attempts between 1 and 10),
  next_attempt_at timestamptz default now(),
  claimed_at timestamptz,
  last_error text check (last_error is null or length(last_error) <= 300),
  provider_message_id text,
  sent_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (booking_id, channel)
);
create index if not exists notif_due_idx on public.notification_deliveries (status, next_attempt_at);
create index if not exists notif_provider_idx on public.notification_deliveries (provider_message_id) where provider_message_id is not null;

-- ---------------------------------------------------------------------
-- 4. Analytics, rate limits, audit log
-- ---------------------------------------------------------------------
create table if not exists public.analytics_events (
  id bigint generated always as identity primary key,
  event text not null check (event in ('page_view','project_view','demo_click','booking_submit','feedback_submit','contact_click')),
  path text check (path is null or (length(path) <= 100 and path ~ '^[/#A-Za-z0-9_.-]*$')),
  project_slug text check (project_slug is null or project_slug ~ '^[a-z0-9][a-z0-9-]{1,58}[a-z0-9]$'),
  target text check (target is null or target in ('email','whatsapp','telegram','instagram','tiktok')),
  visitor_hash text check (visitor_hash is null or visitor_hash ~ '^[0-9a-f]{16,64}$'),
  day date not null default (now() at time zone 'utc')::date,
  created_at timestamptz not null default now()
);
create index if not exists analytics_day_idx on public.analytics_events (day, event);

create table if not exists private.rate_limits (
  bucket text not null,
  window_start timestamptz not null,
  hits int not null default 0,
  primary key (bucket, window_start)
);

create table if not exists public.admin_audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor uuid,
  action text not null,
  table_name text,
  row_id text,
  changed_columns text[],
  detail jsonb
);
create index if not exists audit_at_idx on public.admin_audit_log (at desc);

-- Audit trigger: records WHO changed WHICH columns. Values are stored only for a few
-- non-personal workflow columns, never for names, emails, messages or notes.
create or replace function private.audit_row() returns trigger
language plpgsql security definer set search_path = '' as $$
declare o jsonb; n jsonb; cols text[]; det jsonb := '{}'; c text; rid text;
begin
  if (select auth.uid()) is null then return coalesce(new, old); end if;  -- system/service writes are not admin actions
  n := case when tg_op = 'DELETE' then '{}'::jsonb else to_jsonb(new) end;
  o := case when tg_op = 'INSERT' then '{}'::jsonb else to_jsonb(old) end;
  rid := coalesce(n ->> 'id', o ->> 'id', n ->> 'key', o ->> 'key');
  select coalesce(array_agg(k order by k), '{}') into cols from (
    select k from jsonb_object_keys(n || o) k
    where k not in ('updated_at','updated_by') and (n -> k) is distinct from (o -> k)) s;
  foreach c in array array['status','featured','sort_order','published','active','role'] loop
    if cols @> array[c] then det := det || jsonb_build_object(c, coalesce(n -> c, o -> c)); end if;
  end loop;
  insert into public.admin_audit_log (actor, action, table_name, row_id, changed_columns, detail)
  values ((select auth.uid()), lower(tg_op), tg_table_name, rid, cols, det);
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['site_content','projects','project_media','testimonials','bookings',
                           'booking_notes','feedback','feedback_replies','admin_users'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$s', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$s
                    for each row execute function private.audit_row()', t);
  end loop;
end $$;

-- author columns are never trusted from the client
create or replace function private.set_author() returns trigger
language plpgsql set search_path = '' as $$
begin new.author := (select auth.uid()); return new; end $$;
drop trigger if exists booking_notes_author on public.booking_notes;
create trigger booking_notes_author before insert on public.booking_notes for each row execute function private.set_author();
drop trigger if exists feedback_replies_author on public.feedback_replies;
create trigger feedback_replies_author before insert on public.feedback_replies for each row execute function private.set_author();

do $$ declare t text; begin
  foreach t in array array['bookings','feedback','testimonials','notification_deliveries'] loop
    execute format('drop trigger if exists touch_%1$s on public.%1$s', t);
    execute format('create trigger touch_%1$s before update on public.%1$s for each row execute function private.touch_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 5. Row level security + least-privilege grants
-- ---------------------------------------------------------------------
do $$ declare t text; begin
  foreach t in array array['admin_users','content_fields','site_content','projects','project_media','testimonials',
    'feedback','feedback_replies','bookings','booking_notes','notification_deliveries','analytics_events','admin_audit_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on table public.%I from public, anon, authenticated', t);
  end loop;
end $$;
alter table private.rate_limits enable row level security;
revoke all on table private.rate_limits from public, anon, authenticated;

do $$ declare r record; cmd text; pol text; role_ text; begin
  for r in select * from (values
    ('admin_users','owner','select'), ('content_fields','editor','select'),
    ('site_content','editor','select,update'), ('projects','editor','select,insert,update,delete'),
    ('project_media','editor','select,insert,update,delete'), ('testimonials','owner','select,insert,update,delete'),
    ('bookings','owner','select,update'), ('booking_notes','owner','select,insert'),
    ('feedback','owner','select,update'), ('feedback_replies','owner','select,insert'),
    ('notification_deliveries','owner','select'), ('admin_audit_log','owner','select')
  ) v(t, role_, cmds) loop
    foreach cmd in array string_to_array(r.cmds, ',') loop
      pol := r.t || '_admin_' || cmd;
      execute format('drop policy if exists %I on public.%I', pol, r.t);
      execute format('create policy %I on public.%I for %s to authenticated %s', pol, r.t, cmd,
        case cmd when 'insert' then format('with check (private.is_admin(%L))', r.role_)
                 when 'update' then format('using (private.is_admin(%1$L)) with check (private.is_admin(%1$L))', r.role_)
                 else format('using (private.is_admin(%L))', r.role_) end);
    end loop;
  end loop;
end $$;
-- a published project must be unpublished/archived before it can be deleted
drop policy if exists projects_admin_delete on public.projects;
create policy projects_admin_delete on public.projects for delete to authenticated
  using (private.is_admin('editor') and status <> 'published');

grant select (user_id, email, role, active) on public.admin_users to authenticated;
grant select on public.content_fields, public.site_content, public.projects, public.project_media,
  public.testimonials, public.feedback, public.feedback_replies, public.bookings, public.booking_notes,
  public.notification_deliveries, public.admin_audit_log to authenticated;
grant update (draft) on public.site_content to authenticated;
grant insert, update, delete on public.projects, public.project_media to authenticated;
grant insert, update, delete on public.testimonials to authenticated;
grant update (status) on public.bookings, public.feedback to authenticated;
grant insert (booking_id, note) on public.booking_notes to authenticated;
grant insert (feedback_id, body) on public.feedback_replies to authenticated;
-- anon gets NOTHING on any table. The public site reads through get_public_site() only.

-- ---------------------------------------------------------------------
-- 6. Public read RPC (the only thing anon may call)
-- ---------------------------------------------------------------------
create or replace function public.get_public_site() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'content', coalesce((select jsonb_object_agg(key, published) from public.site_content where published is not null and published <> ''), '{}'::jsonb),
    'projects', coalesce((select jsonb_agg(p order by p.sort_order, p.created_at) from (
        select pr.slug, pr.title, pr.type_label, pr.summary, pr.description, pr.category, pr.technologies, pr.demo_url,
               pr.accent, pr.thumbnail_path, pr.featured, pr.sort_order, pr.created_at,
               coalesce((select jsonb_agg(jsonb_build_object('path', m.path, 'alt', m.alt, 'kind', m.kind) order by m.sort_order)
                         from public.project_media m where m.project_id = pr.id), '[]'::jsonb) as media
        from public.projects pr where pr.status = 'published') p), '[]'::jsonb),
    'testimonials', coalesce((select jsonb_agg(jsonb_build_object('author_name', t.author_name, 'author_role', t.author_role, 'quote', t.quote) order by t.sort_order)
                              from public.testimonials t where t.published), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------------------
-- 7. Admin RPCs (authenticated + is_admin check inside)
-- ---------------------------------------------------------------------
create or replace function public.admin_publish_content(p_keys text[] default null) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not private.is_admin('editor') then raise exception 'forbidden' using errcode = '42501'; end if;
  with u as (
    update public.site_content s set published = s.draft, published_at = now()
    where s.draft is distinct from s.published and (p_keys is null or s.key = any (p_keys))
    returning s.key)
  select count(*) into n from u;
  insert into public.admin_audit_log (actor, action, table_name, changed_columns, detail)
  values ((select auth.uid()), 'publish', 'site_content', p_keys, jsonb_build_object('count', n));
  return n;
end $$;

create or replace function public.admin_reorder_projects(p_ids uuid[]) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.is_admin('editor') then raise exception 'forbidden' using errcode = '42501'; end if;
  if cardinality(p_ids) > 200 then raise exception 'too many ids' using errcode = '22023'; end if;
  update public.projects p set sort_order = o.ord * 10
  from unnest(p_ids) with ordinality as o(id, ord) where p.id = o.id;
  insert into public.admin_audit_log (actor, action, table_name, detail)
  values ((select auth.uid()), 'reorder', 'projects', jsonb_build_object('count', cardinality(p_ids)));
end $$;

create or replace function public.admin_retry_notification(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not private.is_admin('owner') then raise exception 'forbidden' using errcode = '42501'; end if;
  update public.notification_deliveries
     set status = 'pending', attempts = 0, next_attempt_at = now(), last_error = null, claimed_at = null
   where id = p_id and status in ('failed','dead','not_configured');
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.admin_audit_log (actor, action, table_name, row_id)
    values ((select auth.uid()), 'retry', 'notification_deliveries', p_id::text);
  end if;
  return n > 0;
end $$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin('owner') then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object(
    'bookings', (select jsonb_object_agg(status, c) from (select status, count(*) c from public.bookings group by 1) s),
    'feedback', (select jsonb_object_agg(status, c) from (select status, count(*) c from public.feedback group by 1) s),
    'notifications', (select jsonb_object_agg(channel || ':' || status, c) from (select channel, status, count(*) c from public.notification_deliveries group by 1,2) s),
    'projects', (select jsonb_object_agg(status, c) from (select status, count(*) c from public.projects group by 1) s),
    'draft_changes', (select count(*) from public.site_content where draft is distinct from published),
    'recent_activity', coalesce((select jsonb_agg(a) from (select at, action, table_name, changed_columns from public.admin_audit_log order by at desc limit 10) a), '[]'::jsonb));
end $$;

create or replace function public.admin_analytics_summary(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_admin('owner') then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid date range' using errcode = '22023';
  end if;
  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'totals', coalesce((select jsonb_object_agg(event, c) from (select event, count(*) c from public.analytics_events where day between p_from and p_to group by 1) s), '{}'::jsonb),
    -- visitor hashes rotate daily, so this is the sum of each day's distinct visitors (an estimate)
    'unique_visitors_estimate', coalesce((select sum(v) from (select count(distinct visitor_hash) v from public.analytics_events where event = 'page_view' and day between p_from and p_to group by day) s), 0),
    'daily', coalesce((select jsonb_agg(d order by d.day) from (select day, event, count(*) c from public.analytics_events where day between p_from and p_to group by 1,2) d), '[]'::jsonb),
    'top_pages', coalesce((select jsonb_agg(x) from (select coalesce(path,'/') path, count(*) c from public.analytics_events where event = 'page_view' and day between p_from and p_to group by 1 order by 2 desc limit 10) x), '[]'::jsonb),
    'top_projects', coalesce((select jsonb_agg(x) from (select project_slug slug, count(*) filter (where event = 'project_view') views, count(*) filter (where event = 'demo_click') demo_clicks from public.analytics_events where project_slug is not null and day between p_from and p_to group by 1 order by 2 desc, 3 desc limit 10) x), '[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(x) from (select target, count(*) c from public.analytics_events where event = 'contact_click' and day between p_from and p_to group by 1 order by 2 desc) x), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------
-- 8. Service-role RPCs (called only by the edge functions; never by browsers)
-- ---------------------------------------------------------------------
create or replace function public.check_rate_limit_v1(p_bucket text, p_limit int, p_window_seconds int) returns boolean
language plpgsql security definer set search_path = '' as $$
declare w timestamptz; h int;
begin
  if p_bucket is null or length(p_bucket) > 120 or p_limit < 1 or p_window_seconds < 1 or p_window_seconds > 86400 then
    raise exception 'bad rate limit arguments' using errcode = '22023';
  end if;
  w := to_timestamp(floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into private.rate_limits as r (bucket, window_start, hits) values (p_bucket, w, 1)
  on conflict (bucket, window_start) do update set hits = r.hits + 1 returning r.hits into h;
  return h <= p_limit;
end $$;

create or replace function public.create_booking_v1(p jsonb, p_ip_hash text default null, p_client_key text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := btrim(coalesce(p ->> 'name', ''));
  v_business text := nullif(btrim(coalesce(p ->> 'business', '')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_wa text := nullif(regexp_replace(coalesce(p ->> 'whatsapp', ''), '[\s().-]', '', 'g'), '');
  v_channel text := coalesce(nullif(btrim(p ->> 'delivery_channel'), ''), 'telegram');
  v_service text := btrim(coalesce(p ->> 'service', ''));
  v_budget text := nullif(btrim(coalesce(p ->> 'budget', '')), '');
  v_desc text := btrim(coalesce(p ->> 'description', ''));
  v_hash text; v_id uuid; v_ref text; v_existing public.bookings; i int := 0;
begin
  if length(v_name) not between 1 and 100 then return jsonb_build_object('ok', false, 'field', 'name', 'error', 'invalid'); end if;
  if v_business is not null and length(v_business) > 120 then return jsonb_build_object('ok', false, 'field', 'business', 'error', 'invalid'); end if;
  if v_email is not null and (length(v_email) > 254 or v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') then return jsonb_build_object('ok', false, 'field', 'email', 'error', 'invalid'); end if;
  if v_wa is not null and v_wa !~ '^\+[1-9][0-9]{7,14}$' then return jsonb_build_object('ok', false, 'field', 'whatsapp', 'error', 'invalid'); end if;
  if v_email is null and v_wa is null then return jsonb_build_object('ok', false, 'field', 'email', 'error', 'contact_required'); end if;
  if v_channel not in ('telegram','whatsapp') then return jsonb_build_object('ok', false, 'field', 'delivery_channel', 'error', 'invalid'); end if;
  if v_service not in ('website','ai-assistant','automation','software','other') then return jsonb_build_object('ok', false, 'field', 'service', 'error', 'invalid'); end if;
  if v_budget is not null and v_budget not in ('under-500','500-1500','1500-5000','5000-plus','unsure') then return jsonb_build_object('ok', false, 'field', 'budget', 'error', 'invalid'); end if;
  if length(v_desc) not between 10 and 2000 then return jsonb_build_object('ok', false, 'field', 'description', 'error', 'invalid'); end if;
  if (v_name || coalesce(v_business,'') || v_desc) ~ '[\x01-\x08\x0b\x0c\x0e-\x1f]' then return jsonb_build_object('ok', false, 'field', 'description', 'error', 'invalid'); end if;
  if p_client_key is not null and p_client_key !~ '^[A-Za-z0-9_-]{8,64}$' then return jsonb_build_object('ok', false, 'field', 'client_key', 'error', 'invalid'); end if;

  v_hash := encode(sha256(convert_to(coalesce(v_email,'') || '|' || coalesce(v_wa,'') || '|' || v_service || '|' ||
            regexp_replace(lower(v_desc), '\s+', ' ', 'g'), 'UTF8')), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(v_hash, 0));

  select * into v_existing from public.bookings
   where (p_client_key is not null and client_key = p_client_key)
      or (dedupe_hash = v_hash and created_at > now() - interval '24 hours')
   order by created_at limit 1;
  if found then
    return jsonb_build_object('ok', true, 'duplicate', true, 'id', v_existing.id, 'reference', v_existing.reference);
  end if;

  loop
    v_ref := 'DB-' || upper(substr(md5(random()::text || clock_timestamp()::text || i::text), 1, 8));
    begin
      insert into public.bookings (reference, name, business, email, whatsapp, delivery_channel, service, budget, description, dedupe_hash, client_key, ip_hash)
      values (v_ref, v_name, v_business, v_email, v_wa, v_channel, v_service, v_budget, v_desc, v_hash, p_client_key, p_ip_hash)
      returning id into v_id;
      exit;
    exception when unique_violation then
      i := i + 1; if i > 5 then raise; end if;
    end;
  end loop;

  insert into public.notification_deliveries (booking_id, channel) values (v_id, v_channel);
  return jsonb_build_object('ok', true, 'duplicate', false, 'id', v_id, 'reference', v_ref);
end $$;

create or replace function public.create_feedback_v1(p jsonb, p_ip_hash text default null, p_client_key text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
  v_email text := nullif(lower(btrim(coalesce(p ->> 'email', ''))), '');
  v_cat text := btrim(coalesce(p ->> 'category', ''));
  v_msg text := btrim(coalesce(p ->> 'message', ''));
  v_ref text; v_id uuid; v_existing public.feedback; i int := 0;
begin
  if v_name is not null and length(v_name) > 80 then return jsonb_build_object('ok', false, 'field', 'name', 'error', 'invalid'); end if;
  if v_email is not null and (length(v_email) > 254 or v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') then return jsonb_build_object('ok', false, 'field', 'email', 'error', 'invalid'); end if;
  if v_cat not in ('general','design','bug','idea','praise','other') then return jsonb_build_object('ok', false, 'field', 'category', 'error', 'invalid'); end if;
  if length(v_msg) not between 5 and 2000 then return jsonb_build_object('ok', false, 'field', 'message', 'error', 'invalid'); end if;
  if (coalesce(v_name,'') || v_msg) ~ '[\x01-\x08\x0b\x0c\x0e-\x1f]' then return jsonb_build_object('ok', false, 'field', 'message', 'error', 'invalid'); end if;
  if p_client_key is not null and p_client_key !~ '^[A-Za-z0-9_-]{8,64}$' then return jsonb_build_object('ok', false, 'field', 'client_key', 'error', 'invalid'); end if;

  if p_client_key is not null then
    perform pg_advisory_xact_lock(hashtextextended(p_client_key, 1));
    select * into v_existing from public.feedback where client_key = p_client_key;
    if found then return jsonb_build_object('ok', true, 'duplicate', true, 'reference', v_existing.reference); end if;
  end if;
  loop
    v_ref := 'FB-' || upper(substr(md5(random()::text || clock_timestamp()::text || i::text), 1, 8));
    begin
      insert into public.feedback (reference, name, email, category, message, client_key, ip_hash)
      values (v_ref, v_name, v_email, v_cat, v_msg, p_client_key, p_ip_hash) returning id into v_id;
      exit;
    exception when unique_violation then
      i := i + 1; if i > 5 then raise; end if;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'duplicate', false, 'reference', v_ref);
end $$;

create or replace function public.record_event_v1(p_event text, p_path text default null, p_project_slug text default null,
                                                   p_target text default null, p_visitor_hash text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.analytics_events (event, path, project_slug, target, visitor_hash)
  values (p_event, nullif(p_path, ''), nullif(p_project_slug, ''), nullif(p_target, ''), nullif(p_visitor_hash, ''));
  return true;
exception when check_violation then
  return false;   -- invalid analytics events are dropped, never stored
end $$;

create or replace function public.claim_notifications_v1(p_limit int default 10) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb;
begin
  p_limit := least(greatest(coalesce(p_limit, 10), 1), 50);
  -- a worker that died mid-send leaves rows in 'sending'; give up on them once attempts are used up
  update public.notification_deliveries set status = 'dead', last_error = 'worker stopped before reporting a result'
   where status = 'sending' and claimed_at < now() - interval '5 minutes' and attempts >= max_attempts;
  with due as (
      select id from public.notification_deliveries
       where (status in ('pending','failed') and next_attempt_at <= now())
          or (status = 'sending' and claimed_at < now() - interval '5 minutes' and attempts < max_attempts)
       order by next_attempt_at nulls first limit p_limit for update skip locked),
    c as (
      update public.notification_deliveries d set status = 'sending', claimed_at = now(), attempts = d.attempts + 1
        from due where d.id = due.id returning d.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'channel', c.channel, 'attempts', c.attempts,
        'booking', jsonb_build_object('reference', b.reference, 'name', b.name, 'business', b.business, 'email', b.email,
                                      'whatsapp', b.whatsapp, 'service', b.service, 'budget', b.budget,
                                      'description', b.description, 'created_at', b.created_at))), '[]'::jsonb)
    into result
    from c join public.bookings b on b.id = c.booking_id;
  return result;
end $$;

create or replace function public.complete_notification_v1(p_id uuid, p_ok boolean, p_provider_id text default null,
                                                            p_error text default null, p_not_configured boolean default false) returns text
language plpgsql security definer set search_path = '' as $$
declare d public.notification_deliveries; s text;
begin
  select * into d from public.notification_deliveries where id = p_id and status = 'sending' for update;
  if not found then return 'ignored'; end if;
  if p_ok then
    update public.notification_deliveries set status = 'sent', sent_at = now(), provider_message_id = left(p_provider_id, 200),
      last_error = null, next_attempt_at = null, claimed_at = null where id = p_id;
    return 'sent';
  elsif p_not_configured then
    s := 'not_configured';
    update public.notification_deliveries set status = s, last_error = left(coalesce(p_error, 'channel not configured'), 300),
      next_attempt_at = null, claimed_at = null, attempts = greatest(attempts - 1, 0) where id = p_id;
    return s;
  elsif d.attempts >= d.max_attempts then
    update public.notification_deliveries set status = 'dead', last_error = left(coalesce(p_error, 'failed'), 300),
      next_attempt_at = null, claimed_at = null where id = p_id;
    return 'dead';
  else
    update public.notification_deliveries set status = 'failed', last_error = left(coalesce(p_error, 'failed'), 300), claimed_at = null,
      next_attempt_at = now() + least(interval '1 hour', interval '30 seconds' * power(4, d.attempts - 1)) where id = p_id;
    return 'failed';
  end if;
end $$;

create or replace function public.mark_whatsapp_delivery_v1(p_provider_id text, p_status text, p_error text default null) returns boolean
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if p_provider_id is null or p_status not in ('delivered','read','failed') then return false; end if;
  if p_status = 'failed' then
    update public.notification_deliveries set status = 'failed', last_error = left(coalesce(p_error, 'provider reported failure'), 300),
      next_attempt_at = null
     where channel = 'whatsapp' and provider_message_id = p_provider_id and status = 'sent';
  else
    update public.notification_deliveries set status = 'delivered', delivered_at = coalesce(delivered_at, now())
     where channel = 'whatsapp' and provider_message_id = p_provider_id and status in ('sent','delivered');
  end if;
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.purge_old_rows_v1() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a int; r int;
begin
  delete from public.analytics_events where day < (now() at time zone 'utc')::date - 400; get diagnostics a = row_count;
  delete from private.rate_limits where window_start < now() - interval '2 days'; get diagnostics r = row_count;
  return jsonb_build_object('analytics_events', a, 'rate_limits', r);
end $$;

-- ---------------------------------------------------------------------
-- 9. Function privileges (explicit; nothing is callable by accident)
-- ---------------------------------------------------------------------
do $$ declare f text; begin
  foreach f in array array[
    'public.get_public_site()',
    'public.admin_publish_content(text[])', 'public.admin_reorder_projects(uuid[])',
    'public.admin_retry_notification(uuid)', 'public.admin_overview()', 'public.admin_analytics_summary(date,date)',
    'public.check_rate_limit_v1(text,int,int)', 'public.create_booking_v1(jsonb,text,text)',
    'public.create_feedback_v1(jsonb,text,text)', 'public.record_event_v1(text,text,text,text,text)',
    'public.claim_notifications_v1(int)', 'public.complete_notification_v1(uuid,boolean,text,text,boolean)',
    'public.mark_whatsapp_delivery_v1(text,text,text)', 'public.purge_old_rows_v1()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function public.get_public_site() to anon, authenticated, service_role;
grant execute on function public.admin_publish_content(text[]), public.admin_reorder_projects(uuid[]),
  public.admin_retry_notification(uuid), public.admin_overview(), public.admin_analytics_summary(date,date) to authenticated;
grant execute on function public.check_rate_limit_v1(text,int,int), public.create_booking_v1(jsonb,text,text),
  public.create_feedback_v1(jsonb,text,text), public.record_event_v1(text,text,text,text,text),
  public.claim_notifications_v1(int), public.complete_notification_v1(uuid,boolean,text,text,boolean),
  public.mark_whatsapp_delivery_v1(text,text,text), public.purge_old_rows_v1() to service_role;

-- ---------------------------------------------------------------------
-- 10. Storage: public-read bucket, admin-only writes, strict names
-- ---------------------------------------------------------------------
do $$ begin
  if to_regclass('storage.objects') is null then raise notice 'storage schema not found; skipping bucket'; return; end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('portfolio-media', 'portfolio-media', true, 5242880, array['image/jpeg','image/png','image/webp','image/avif'])
  on conflict (id) do update set public = true, file_size_limit = 5242880,
    allowed_mime_types = array['image/jpeg','image/png','image/webp','image/avif'];

  drop policy if exists portfolio_media_admin_insert on storage.objects;
  drop policy if exists portfolio_media_admin_update on storage.objects;
  drop policy if exists portfolio_media_admin_delete on storage.objects;
  drop policy if exists portfolio_media_admin_select on storage.objects;
  create policy portfolio_media_admin_select on storage.objects for select to authenticated
    using (bucket_id = 'portfolio-media' and private.is_admin('editor'));
  create policy portfolio_media_admin_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'portfolio-media' and private.is_admin('editor')
      and name ~ '^(projects|site)/[A-Za-z0-9_./-]{1,150}\.(jpg|jpeg|png|webp|avif)$' and name not like '%..%');
  create policy portfolio_media_admin_update on storage.objects for update to authenticated
    using (bucket_id = 'portfolio-media' and private.is_admin('editor'))
    with check (bucket_id = 'portfolio-media' and private.is_admin('editor')
      and name ~ '^(projects|site)/[A-Za-z0-9_./-]{1,150}\.(jpg|jpeg|png|webp|avif)$' and name not like '%..%');
  create policy portfolio_media_admin_delete on storage.objects for delete to authenticated
    using (bucket_id = 'portfolio-media' and private.is_admin('editor'));
end $$;

-- ---------------------------------------------------------------------
-- 11. Seeds: field registry (defaults mirror the current Stage 7 page text) and the four projects
-- ---------------------------------------------------------------------
insert into public.content_fields (key, section, label, kind, max_length, options, default_value, sort_order) values
 ('hero.eyebrow','hero','Hero eyebrow','text',60,null,'INDEPENDENT TECHNOLOGY FOUNDER',10),
 ('hero.line1','hero','Headline line 1','text',40,null,'I BUILD THE FUTURE',11),
 ('hero.line2','hero','Headline line 2','text',40,null,'THROUGH',12),
 ('hero.line2_em','hero','Headline line 2 (highlight)','text',40,null,'TECHNOLOGY.',13),
 ('hero.intro','hero','Hero intro','text',160,null,'I am Yared — Founder, AI Software Developer, and Technology Innovator.',14),
 ('hero.body','hero','Hero body','longtext',300,null,'I transform ambitious ideas into intelligent software, AI-powered systems, and digital solutions that solve real-world problems.',15),
 ('hero.signature','hero','Hero signature line','text',80,null,'THINK BEYOND. BUILD DIFFERENT. CREATE IMPACT.',16),
 ('about.eyebrow','about','About eyebrow','text',60,null,'A PURPOSE-DRIVEN APPROACH',20),
 ('about.heading','about','About heading','text',60,null,'Meaningful technology.',21),
 ('about.heading_em','about','About heading (highlight)','text',60,null,'Real-world impact.',22),
 ('about.body','about','About body','longtext',300,null,'My focus is simple: build meaningful technology, create real value, and turn possibilities into reality.',23),
 ('expertise.1_title','expertise','Expertise 1 title','text',60,null,'AI & Intelligent Systems',30),
 ('expertise.1_desc','expertise','Expertise 1 text','longtext',200,null,'AI-powered experiences, assistants and practical intelligent workflows.',31),
 ('expertise.2_title','expertise','Expertise 2 title','text',60,null,'Software & Web Development',32),
 ('expertise.2_desc','expertise','Expertise 2 text','longtext',200,null,'Digital products and responsive web experiences built around real needs.',33),
 ('expertise.3_title','expertise','Expertise 3 title','text',60,null,'Automation & Integration',34),
 ('expertise.3_desc','expertise','Expertise 3 text','longtext',200,null,'Connected systems that reduce repetitive work and improve operations.',35),
 ('expertise.4_title','expertise','Expertise 4 title','text',60,null,'Digital Business Solutions',36),
 ('expertise.4_desc','expertise','Expertise 4 text','longtext',200,null,'Technology-led solutions designed to create value for businesses.',37),
 ('services.1_title','services','Service 1 title','text',60,null,'AI Software & Assistants',40),
 ('services.1_desc','services','Service 1 description','longtext',200,null,'',41),
 ('services.2_title','services','Service 2 title','text',60,null,'Websites & Digital Products',42),
 ('services.2_desc','services','Service 2 description','longtext',200,null,'',43),
 ('services.3_title','services','Service 3 title','text',60,null,'Business Automation',44),
 ('services.3_desc','services','Service 3 description','longtext',200,null,'',45),
 ('services.4_title','services','Service 4 title','text',60,null,'Digital Solutions & Integration',46),
 ('services.4_desc','services','Service 4 description','longtext',200,null,'',47),
 ('profile.eyebrow','profile','Profile eyebrow','text',60,null,'THE PERSON BEHIND THE WORK',50),
 ('profile.heading','profile','Profile heading','text',60,null,'Yared.',51),
 ('profile.heading_em','profile','Profile heading (highlight)','text',60,null,'Founder & builder.',52),
 ('profile.body','profile','Profile body','longtext',300,null,'I transform ambitious ideas into intelligent software, AI-powered systems, and digital solutions that solve real-world problems.',53),
 ('contact.eyebrow','contact','Contact eyebrow','text',60,null,'HAVE AN IDEA IN MIND?',60),
 ('contact.heading','contact','Contact heading','text',60,null,'Let''s build',61),
 ('contact.heading_em','contact','Contact heading (highlight)','text',60,null,'what''s next.',62),
 ('contact.body','contact','Contact body','longtext',300,null,'Have a project, a challenge or an ambitious idea? Let''s start a conversation.',63),
 ('contact.email','contact','Email','email',254,null,'yed024691@gmail.com',64),
 ('contact.whatsapp','contact','WhatsApp number','phone',20,null,'+251902389561',65),
 ('contact.telegram','contact','Telegram link','url',200,null,'https://t.me/Deryacapital',66),
 ('contact.instagram','contact','Instagram link','url',200,null,'https://instagram.com/Derya_Capital',67),
 ('contact.tiktok','contact','TikTok link','url',200,null,'https://www.tiktok.com/@derya_capital444',68),
 ('media.portrait_hero','media','Hero portrait','image',200,null,'',70),
 ('media.portrait_about','media','About portrait','image',200,null,'',71),
 ('media.portrait_profile','media','Profile portrait','image',200,null,'',72),
 ('visual.accent','visual','Accent colour','select',20,array['default','aqua','ember','rose'],'default',80),
 ('visual.effects','visual','Visual effects','select',20,array['full','calm'],'full',81),
 ('visual.intro','visual','Cinematic intro','toggle',3,null,'on',82)
on conflict (key) do update set section = excluded.section, label = excluded.label, kind = excluded.kind,
  max_length = excluded.max_length, options = excluded.options, default_value = excluded.default_value, sort_order = excluded.sort_order;

-- Rows start with draft = default and published = null, so the live page keeps its built-in
-- text until the owner presses Publish.
insert into public.site_content (key, draft)
select key, nullif(default_value, '') from public.content_fields on conflict (key) do nothing;

-- The four existing portfolio entries, published, with NO invented demo URLs or screenshots.
-- (An empty projects table in the public RPC keeps the built-in cards; once these exist the CMS drives the reel.)
insert into public.projects (slug, title, type_label, summary, category, accent, status, featured, sort_order, published_at) values
 ('aurex-ai','AUREX AI','AI ASSISTANT CONCEPT','An AI assistant project exploring intelligent interaction and digital productivity.','ai','aurex','published',true,10,now()),
 ('derya-capital','DERYA CAPITAL','BUSINESS TECHNOLOGY','A business and technology initiative.','business','derya','published',false,20,now()),
 ('rent-manager','Rent Manager','MANAGEMENT SOFTWARE','A property-management software project.','software','rent','published',false,30,now()),
 ('derya-pulse-ai','DERYA PULSE AI','TRADING TECHNOLOGY','An AI-assisted trading technology project.','ai','pulse','published',false,40,now())
on conflict (slug) do nothing;
