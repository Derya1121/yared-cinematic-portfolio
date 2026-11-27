-- Restrict booking rescheduling to signed-in users; the RPC also verifies owner role.
revoke all on function public.admin_reschedule_booking(uuid,uuid,text) from public,anon;
grant execute on function public.admin_reschedule_booking(uuid,uuid,text) to authenticated;
