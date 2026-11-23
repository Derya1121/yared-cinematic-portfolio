-- Owner-only RPC access avoids exposing the new booking_slots table through PostgREST.
create or replace function public.admin_list_booking_slots()
returns table(id uuid,service text,starts_at timestamptz,ends_at timestamptz,capacity smallint,active boolean,booked_count bigint)
language plpgsql stable security definer set search_path='' as $$
begin
 if not private.is_admin('owner') then raise exception 'forbidden' using errcode='42501'; end if;
 return query select s.id,s.service,s.starts_at,s.ends_at,s.capacity,s.active,count(b.id) filter(where b.status<>'rejected')
 from public.booking_slots s left join public.bookings b on b.slot_id=s.id group by s.id order by s.starts_at desc;
end $$;
revoke all on function public.admin_list_booking_slots() from public,anon;
grant execute on function public.admin_list_booking_slots() to authenticated;

create or replace function public.admin_create_booking_slot(p_service text,p_starts_at timestamptz,p_ends_at timestamptz,p_capacity smallint default 1)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
 if not private.is_admin('owner') then raise exception 'forbidden' using errcode='42501'; end if;
 if p_service is not null and p_service not in ('website','ai-assistant','automation','software','other') then raise exception 'invalid service' using errcode='22023'; end if;
 if p_starts_at is null or p_ends_at is null or p_starts_at<=now() or p_ends_at<=p_starts_at or p_ends_at-p_starts_at>interval '8 hours' or p_capacity not between 1 and 20 then raise exception 'invalid slot range or capacity' using errcode='22023'; end if;
 if exists(select 1 from public.booking_slots s where s.active and s.starts_at<p_ends_at and s.ends_at>p_starts_at) then raise exception 'appointment slot overlaps an existing active slot' using errcode='23P01'; end if;
 insert into public.booking_slots(service,starts_at,ends_at,capacity,active) values(p_service,p_starts_at,p_ends_at,p_capacity,true) returning id into v_id;
 insert into public.admin_audit_log(actor,action,table_name,row_id,detail) values((select auth.uid()),'create','booking_slots',v_id::text,jsonb_build_object('service',p_service,'starts_at',p_starts_at,'ends_at',p_ends_at,'capacity',p_capacity));
 return v_id;
end $$;
revoke all on function public.admin_create_booking_slot(text,timestamptz,timestamptz,smallint) from public,anon;
grant execute on function public.admin_create_booking_slot(text,timestamptz,timestamptz,smallint) to authenticated;

create or replace function public.admin_set_booking_slot_active(p_id uuid,p_active boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare n int;
begin
 if not private.is_admin('owner') then raise exception 'forbidden' using errcode='42501'; end if;
 update public.booking_slots set active=p_active,updated_at=now() where id=p_id;
 get diagnostics n=row_count;
 if n>0 then insert into public.admin_audit_log(actor,action,table_name,row_id,detail) values((select auth.uid()),case when p_active then 'reopen' else 'close' end,'booking_slots',p_id::text,jsonb_build_object('active',p_active)); end if;
 return n>0;
end $$;
revoke all on function public.admin_set_booking_slot_active(uuid,boolean) from public,anon;
grant execute on function public.admin_set_booking_slot_active(uuid,boolean) to authenticated;