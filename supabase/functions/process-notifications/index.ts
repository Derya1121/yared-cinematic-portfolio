// deno-lint-ignore-file no-explicit-any
import { realDeps } from "../_shared/deno_deps.ts";
import { processNotifications } from "../_shared/handlers.ts";
declare const Deno: any;
Deno.serve(processNotifications(realDeps()));
