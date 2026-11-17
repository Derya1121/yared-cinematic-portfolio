// Deno/Supabase wiring (not unit-tested; exercised only after the project exists).
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase into edge functions at runtime.
// The service-role key lives only in the function's environment — never in any file in this repo.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import type { Deps } from "./core.ts";

// deno-lint-ignore no-explicit-any
declare const Deno: any; declare const EdgeRuntime: any;

export function realDeps(): Deps {
  const client = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return {
    env: (k) => Deno.env.get(k),
    rpc: async (fn, args) => {
      const { data, error } = await client.rpc(fn, args);
      return { data, error: error ? { message: error.message } : null };
    },
    fetch: (...a) => fetch(...a),
    now: () => Date.now(),
    background: (p) => { try { EdgeRuntime.waitUntil(p); } catch { /* local serve: promise just runs */ } },
  };
}
