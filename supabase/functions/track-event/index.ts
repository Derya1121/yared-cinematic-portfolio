// deno-lint-ignore-file no-explicit-any
import { realDeps } from "../_shared/deno_deps.ts";
import { trackEvent } from "../_shared/handlers.ts";
declare const Deno: any;
Deno.serve(trackEvent(realDeps()));
