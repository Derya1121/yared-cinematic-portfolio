/* Public runtime configuration.
 *
 * Leave supabaseUrl and supabaseAnonKey empty and the site runs as a static portfolio:
 * the booking form shows an honest "not connected" notice and the CMS content layer stays off.
 *
 * The anon / publishable key is designed to be public. NEVER put a service_role key,
 * database password or any other secret in this file. Row level security protects the data.
 * See docs/BACKEND.md.
 */
window.DERYA_CONFIG = {
  supabaseUrl: "",       // e.g. "https://<project-ref>.supabase.co"
  supabaseAnonKey: ""    // the project's public anon / publishable key
};
