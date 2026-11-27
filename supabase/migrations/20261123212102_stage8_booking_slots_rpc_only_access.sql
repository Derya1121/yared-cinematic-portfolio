-- Public booking availability and owner slot management are exposed through guarded RPCs only.
revoke all on table public.booking_slots from anon, authenticated, public, service_role;
