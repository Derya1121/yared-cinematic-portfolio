-- Prevent reopening an old slot over a newer active slot.
create or replace function public.admin_set_booking_slot_active(p_id uuid,p_active boolean)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_slot public.booking_slots; n int;
begin
 if not private.is_admin('owner') then raise exception 'forbidden' using errcode='42501'; end if;
 select * into v_slot from public.booking_slots where id=p_id for update;
 if not found then return false; end if;
 if p_active then
  if v_slot.starts_at<=now() then raise exception 'past appointment slots cannot be reopened' using errcode='22023'; end if;
  if exists(select 1 from public.booking_slots s where s.id<>p_id and s.active and s.starts_at<v_slot.ends_at and s.ends_at>v_slot.starts_at) then raise exception 'reopened slot overlaps another active slot' using errcode='23P01'; end if;
 end if;
 update public.booking_slots set active=p_active,updated_at=now() where id=p_id;
 get diagnostics n=row_count;
 if n>0 then insert into public.admin_audit_log(actor,action,table_name,row_id,detail) values((select auth.uid()),case when p_active then 'reopen' else 'close' end,'booking_slots',p_id::text,jsonb_build_object('active',p_active)); end if;
 return n>0;
end $$;