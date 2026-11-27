-- The owner moderation UI may change only the moderation_status field; RLS still enforces owner access.
grant update (moderation_status) on table public.feedback to authenticated;
