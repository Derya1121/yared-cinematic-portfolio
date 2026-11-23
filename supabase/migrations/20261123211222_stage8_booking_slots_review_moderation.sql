-- Stage 8.1: real appointment slots and review moderation.
create table if not exists public.booking_slots (
  id uuid primary key default gen_random_uuid(),
  service text check (service is null or service in ('website','ai-assistant','automation','software','other')),
  starts_at timestamptz not null, ends_at timestamptz not null,
  capacity smallint not null default 1 check (capacity between 1 and 20),
  active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists booking_slots_start_idx on public.booking_slots (starts_at) where active;
alter table public.booking_slots enable row level security;
revoke all on public.booking_slots from anon, authenticated, public, service_role;
drop policy if exists booking_slots_owner_all on public.booking_slots;
create policy booking_slots_owner_all on public.booking_slots for all to authenticated
  using (private.is_admin('owner')) with check (private.is_admin('owner'));

alter table public.bookings add column if not exists slot_id uuid;
alter table public.bookings add column if not exists requested_at timestamptz;
alter table public.bookings add column if not exists reschedule_note text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='bookings_slot_id_fkey' and conrelid='public.bookings'::regclass) then
    alter table public.bookings add constraint bookings_slot_id_fkey foreign key(slot_id) references public.booking_slots(id) on delete set null;
  end if;
end $$;
create index if not exists bookings_slot_id_idx on public.bookings(slot_id) where slot_id is not null;

alter table public.feedback add column if not exists rating smallint not null default 5;
alter table public.feedback add column if not exists moderation_status text not null default 'pending';
do $$ begin
  if not exists (select 1 from pg_constraint where conname='feedback_rating_check' and conrelid='public.feedback'::regclass) then
    alter table public.feedback add constraint feedback_rating_check check(rating between 1 and 5);
  end if;
  if not exists (select 1 from pg_constraint where conname='feedback_moderation_status_check' and conrelid='public.feedback'::regclass) then
    alter table public.feedback add constraint feedback_moderation_status_check check(moderation_status in ('pending','approved','rejected'));
  end if;
end $$;
alter table public.testimonials add column if not exists rating smallint;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='testimonials_rating_check' and conrelid='public.testimonials'::regclass) then
    alter table public.testimonials add constraint testimonials_rating_check check(rating is null or rating between 1 and 5);
  end if;
end $$;

create or replace function public.get_available_booking_slots(p_from timestamptz,p_to timestamptz,p_service text)
returns table(id uuid,starts_at timestamptz,ends_at timestamptz,remaining_capacity integer)
language plpgsql stable security definer set search_path='' as $$
begin
 if p_from is null or p_to is null or p_to<=p_from or p_to>p_from+interval '60 days'
    or p_service not in ('website','ai-assistant','automation','software','other') then
   raise exception 'invalid availability range or service' using errcode='22023';
 end if;
 return query select s.id,s.starts_at,s.ends_at,(s.capacity-count(b.id))::integer
 from public.booking_slots s left join public.bookings b on b.slot_id=s.id and b.status<>'rejected'
 where s.active and s.starts_at>=greatest(p_from,now()) and s.starts_at<p_to
   and (s.service is null or s.service=p_service)
 group by s.id having count(b.id)<s.capacity order by s.starts_at limit 200;
end $$;
revoke all on function public.get_available_booking_slots(timestamptz,timestamptz,text) from public;
grant execute on function public.get_available_booking_slots(timestamptz,timestamptz,text) to anon,authenticated;

create or replace function public.admin_reschedule_booking(p_booking_id uuid,p_slot_id uuid,p_note text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_booking public.bookings; v_slot public.booking_slots; v_used integer;
begin
 if not private.is_admin('owner') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into v_booking from public.bookings where id=p_booking_id for update;
 if not found or v_booking.status='rejected' then return false; end if;
 select * into v_slot from public.booking_slots where id=p_slot_id and active for update;
 if not found or v_slot.starts_at<=now() or (v_slot.service is not null and v_slot.service<>v_booking.service) then
  raise exception 'slot unavailable' using errcode='22023';
 end if;
 select count(*) into v_used from public.bookings where slot_id=p_slot_id and status<>'rejected' and id<>p_booking_id;
 if v_used>=v_slot.capacity then raise exception 'slot is full' using errcode='23514'; end if;
 update public.bookings set slot_id=p_slot_id,requested_at=v_slot.starts_at,reschedule_note=nullif(left(coalesce(p_note,''),500),'') where id=p_booking_id;
 return true;
end $$;
revoke all on function public.admin_reschedule_booking(uuid,uuid,text) from public;
grant execute on function public.admin_reschedule_booking(uuid,uuid,text) to authenticated;

create or replace function public.get_public_site()
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'content',coalesce((select jsonb_object_agg(key,published) from public.site_content where published is not null and published<>''),'{}'::jsonb),
  'projects',coalesce((select jsonb_agg(p order by p.sort_order,p.created_at) from (
   select pr.slug,pr.title,pr.type_label,pr.summary,pr.description,pr.category,pr.technologies,pr.demo_url,pr.accent,pr.thumbnail_path,pr.featured,pr.sort_order,pr.created_at,
    coalesce((select jsonb_agg(jsonb_build_object('path',m.path,'alt',m.alt,'kind',m.kind) order by m.sort_order) from public.project_media m where m.project_id=pr.id),'[]'::jsonb) as media
   from public.projects pr where pr.status='published') p),'[]'::jsonb),
  'testimonials',coalesce((select jsonb_agg(jsonb_build_object('author_name',t.author_name,'author_role',t.author_role,'quote',t.quote,'rating',t.rating) order by t.sort_order) from public.testimonials t where t.published),'[]'::jsonb)
 );
$$;