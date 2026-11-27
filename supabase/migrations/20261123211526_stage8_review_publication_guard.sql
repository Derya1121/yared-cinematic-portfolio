-- A review can be public only while its source feedback is owner-approved.
create or replace function private.testimonial_publication_guard()
returns trigger language plpgsql set search_path='' as $$
declare v_status text;
begin
 if new.published and new.source_feedback_id is not null then
  select moderation_status into v_status from public.feedback where id=new.source_feedback_id;
  if v_status is distinct from 'approved' then raise exception 'feedback must be approved before publication' using errcode='42501'; end if;
 end if;
 new.updated_at:=now(); return new;
end $$;
drop trigger if exists testimonial_publication_guard on public.testimonials;
create trigger testimonial_publication_guard before insert or update on public.testimonials for each row execute function private.testimonial_publication_guard();

create or replace function private.unpublish_rejected_feedback()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.moderation_status is distinct from old.moderation_status and new.moderation_status<>'approved' then
  update public.testimonials set published=false,updated_at=now() where source_feedback_id=new.id and published;
 end if;
 return new;
end $$;
drop trigger if exists feedback_unpublish_rejected on public.feedback;
create trigger feedback_unpublish_rejected after update of moderation_status on public.feedback for each row execute function private.unpublish_rejected_feedback();