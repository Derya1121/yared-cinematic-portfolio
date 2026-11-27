-- Stage 8.2: enforce selected appointment slots and store 1–5 star reviews.
create or replace function public.create_booking_v1(p jsonb,p_ip_hash text default null,p_client_key text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_name text:=btrim(coalesce(p->>'name',''));
 v_business text:=nullif(btrim(coalesce(p->>'business','')),'');
 v_email text:=nullif(lower(btrim(coalesce(p->>'email',''))),'');
 v_wa text:=nullif(regexp_replace(coalesce(p->>'whatsapp',''),'[\s().-]','','g'),'');
 v_channel text:=coalesce(nullif(btrim(p->>'delivery_channel'),''),'telegram');
 v_service text:=btrim(coalesce(p->>'service',''));
 v_budget text:=nullif(btrim(coalesce(p->>'budget','')),'');
 v_desc text:=btrim(coalesce(p->>'description',''));
 v_slot_id uuid:=nullif(p->>'slot_id','')::uuid;
 v_slot public.booking_slots; v_used int; v_hash text; v_id uuid; v_ref text; v_existing public.bookings; i int:=0;
begin
 if length(v_name) not between 1 and 100 then return jsonb_build_object('ok',false,'field','name','error','invalid'); end if;
 if v_business is not null and length(v_business)>120 then return jsonb_build_object('ok',false,'field','business','error','invalid'); end if;
 if v_email is not null and (length(v_email)>254 or v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') then return jsonb_build_object('ok',false,'field','email','error','invalid'); end if;
 if v_wa is not null and v_wa !~ '^\+[1-9][0-9]{7,14}$' then return jsonb_build_object('ok',false,'field','whatsapp','error','invalid'); end if;
 if v_email is null and v_wa is null then return jsonb_build_object('ok',false,'field','email','error','contact_required'); end if;
 if v_channel not in ('telegram','whatsapp') then return jsonb_build_object('ok',false,'field','delivery_channel','error','invalid'); end if;
 if v_service not in ('website','ai-assistant','automation','software','other') then return jsonb_build_object('ok',false,'field','service','error','invalid'); end if;
 if v_budget is not null and v_budget not in ('under-500','500-1500','1500-5000','5000-plus','unsure') then return jsonb_build_object('ok',false,'field','budget','error','invalid'); end if;
 if length(v_desc) not between 10 and 2000 then return jsonb_build_object('ok',false,'field','description','error','invalid'); end if;
 if v_slot_id is null then return jsonb_build_object('ok',false,'field','slot_id','error','required'); end if;
 if p_client_key is not null and p_client_key !~ '^[A-Za-z0-9_-]{8,64}$' then return jsonb_build_object('ok',false,'field','client_key','error','invalid'); end if;
 v_hash:=encode(sha256(convert_to(coalesce(v_email,'')||'|'||coalesce(v_wa,'')||'|'||v_service||'|'||regexp_replace(lower(v_desc),'\s+',' ','g'),'UTF8')),'hex');
 perform pg_advisory_xact_lock(hashtextextended(v_hash,0));
 select * into v_existing from public.bookings where (p_client_key is not null and client_key=p_client_key) or (dedupe_hash=v_hash and created_at>now()-interval '24 hours') order by created_at limit 1;
 if found then return jsonb_build_object('ok',true,'duplicate',true,'id',v_existing.id,'reference',v_existing.reference); end if;
 select * into v_slot from public.booking_slots where id=v_slot_id and active for update;
 if not found or v_slot.starts_at<=now() or (v_slot.service is not null and v_slot.service<>v_service) then return jsonb_build_object('ok',false,'field','slot_id','error','slot_unavailable'); end if;
 select count(*) into v_used from public.bookings where slot_id=v_slot_id and status<>'rejected';
 if v_used>=v_slot.capacity then return jsonb_build_object('ok',false,'field','slot_id','error','slot_unavailable'); end if;
 loop
  v_ref:='DB-'||upper(substr(md5(random()::text||clock_timestamp()::text||i::text),1,8));
  begin
   insert into public.bookings(reference,name,business,email,whatsapp,delivery_channel,service,budget,description,dedupe_hash,client_key,ip_hash,slot_id,requested_at)
   values(v_ref,v_name,v_business,v_email,v_wa,v_channel,v_service,v_budget,v_desc,v_hash,p_client_key,p_ip_hash,v_slot.id,v_slot.starts_at) returning id into v_id;
   exit;
  exception when unique_violation then i:=i+1; if i>5 then raise; end if;
  end;
 end loop;
 insert into public.notification_deliveries(booking_id,channel) values(v_id,v_channel);
 return jsonb_build_object('ok',true,'duplicate',false,'id',v_id,'reference',v_ref);
end $$;

create or replace function public.create_feedback_v1(p jsonb,p_ip_hash text default null,p_client_key text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 v_name text:=nullif(btrim(coalesce(p->>'name','')),'');
 v_email text:=nullif(lower(btrim(coalesce(p->>'email',''))),'');
 v_cat text:=btrim(coalesce(p->>'category',''));
 v_msg text:=btrim(coalesce(p->>'message',''));
 v_rating int:=coalesce(nullif(p->>'rating','')::int,0);
 v_ref text; v_id uuid; v_existing public.feedback; i int:=0;
begin
 if v_name is not null and length(v_name)>80 then return jsonb_build_object('ok',false,'field','name','error','invalid'); end if;
 if v_email is not null and (length(v_email)>254 or v_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') then return jsonb_build_object('ok',false,'field','email','error','invalid'); end if;
 if v_cat not in ('general','design','bug','idea','praise','other') then return jsonb_build_object('ok',false,'field','category','error','invalid'); end if;
 if length(v_msg) not between 5 and 2000 then return jsonb_build_object('ok',false,'field','message','error','invalid'); end if;
 if v_rating not between 1 and 5 then return jsonb_build_object('ok',false,'field','rating','error','invalid'); end if;
 if (coalesce(v_name,'')||v_msg) ~ '[\x01-\x08\x0b\x0c\x0e-\x1f]' then return jsonb_build_object('ok',false,'field','message','error','invalid'); end if;
 if p_client_key is not null and p_client_key !~ '^[A-Za-z0-9_-]{8,64}$' then return jsonb_build_object('ok',false,'field','client_key','error','invalid'); end if;
 if p_client_key is not null then
  perform pg_advisory_xact_lock(hashtextextended(p_client_key,1));
  select * into v_existing from public.feedback where client_key=p_client_key;
  if found then return jsonb_build_object('ok',true,'duplicate',true,'reference',v_existing.reference); end if;
 end if;
 loop
  v_ref:='FB-'||upper(substr(md5(random()::text||clock_timestamp()::text||i::text),1,8));
  begin
   insert into public.feedback(reference,name,email,category,message,rating,client_key,ip_hash)
   values(v_ref,v_name,v_email,v_cat,v_msg,v_rating,p_client_key,p_ip_hash) returning id into v_id;
   exit;
  exception when unique_violation then i:=i+1; if i>5 then raise; end if;
  end;
 end loop;
 return jsonb_build_object('ok',true,'duplicate',false,'reference',v_ref);
end $$;