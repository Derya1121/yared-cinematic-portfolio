/* Public, non-secret configuration. Leave empty until the owner has created the Supabase project
   and deployed the functions (see docs/STAGE8_SETUP.md). While empty, the site behaves exactly as
   Stage 7 and the booking / feedback forms stay disabled and labelled NOT LIVE.
   Only the project URL and the *publishable (anon)* key belong here. NEVER put a service-role key,
   bot token or any other secret in this file. */
window.DERYA_CONFIG = {
  supabaseUrl: "",       // e.g. "https://abcdxyz.supabase.co"
  supabaseAnonKey: ""    // the publishable anon key
};
