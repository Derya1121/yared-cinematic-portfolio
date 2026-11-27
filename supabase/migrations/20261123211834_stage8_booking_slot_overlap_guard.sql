-- Prevent overlapping slots even when an earlier slot was closed after bookings existed.
create or replace function public.admin_create_booking_slot(p_service text,p_starts_at timestamptz,p_ends_at timestamptz,p_capacity smallint default 1)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not private.is_admin('owner') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_service is not null and p_service not in ('website','ai-assistant','automation','software','other') then raise exception 'invalid service' using errcode='22023'; end if;
 if p_starts_at is null or p_ends_at is null or p_starts_at<=now() or p_ends_at<=p_starts_at or p_ends_at-p_starts_at>interval '8 hours' or p_capacity not between 1 and 20 then raise exception 'invalid slot range or capacity' using errcode='22023'; end if;
 if exists(select 1 from public.booking_slots s where s.starts_at<p_ends_at and s.ends_at>p_starts_at and (s.active or exists(select 1 from public.bookings b where b.slot_id=s.id and b.status<>'rejected'))) then raise exception 'appointment slot overlaps an existing active slot or booked appointment' using errcode='23P01'; end if;
 insert into public.booking_slots(service,starts_at,ends_at,capacity,active) values(p_service,p_starts_at,p_ends_at,p_capacity,true) returning id into v_id;
 insert into public.admin_audit_log(actor,action,table_name,row_id,detail) values((select auth.uid()),'create','booking_slots',v_id::text,jsonb_build_object('service',p_service,'starts_at',p_starts_at,'ends_at',p_ends_at,'capacity',p_capacity));
 return v_id;
end $$;