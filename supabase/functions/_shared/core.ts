// Shared helpers for the Stage 8 edge functions. Pure TypeScript, no Deno-only APIs,
// so they can be unit-tested with Node (see ../tests). Secrets are read ONLY from
// server-side environment variables via deps.env — never from the request.

export interface RpcResult { data: unknown; error: { message: string } | null }
export interface Deps {
  env: (key: string) => string | undefined;
  rpc: (fn: string, args: Record<string, unknown>) => Promise<RpcResult>;
  fetch: typeof fetch;
  now: () => number;
  /** keep running after the response is sent (EdgeRuntime.waitUntil on Supabase) */
  background: (p: Promise<unknown>) => void;
}

export const MAX_BODY_BYTES = 16 * 1024;

export function corsHeaders(req: Request, deps: Deps): Record<string, string> {
  const allowed = (deps.env("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const origin = req.headers.get("origin") ?? "";
  const h: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "content-type",
    "Access-Control-Max-Age": "600",
  };
  // Only an explicitly listed origin is echoed back. No "*" and no default.
  if (origin && allowed.includes(origin)) h["Access-Control-Allow-Origin"] = origin;
  return h;
}

export function json(body: unknown, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...cors },
  });
}

export function originAllowed(req: Request, deps: Deps): boolean {
  const origin = req.headers.get("origin");
  if (!origin) return false; // browsers always send Origin on cross-origin POST
  return (deps.env("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).includes(origin);
}

export async function readJson(req: Request): Promise<{ ok: true; value: Record<string, unknown> } | { ok: false; status: number; error: string }> {
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > MAX_BODY_BYTES) return { ok: false, status: 413, error: "too_large" };
  const ct = req.headers.get("content-type") ?? "";
  if (!ct.toLowerCase().startsWith("application/json") && !ct.toLowerCase().startsWith("text/plain")) {
    return { ok: false, status: 415, error: "unsupported_type" };
  }
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) return { ok: false, status: 413, error: "too_large" };
  try {
    const v = JSON.parse(text);
    if (v === null || typeof v !== "object" || Array.isArray(v)) return { ok: false, status: 400, error: "bad_json" };
    return { ok: true, value: v as Record<string, unknown> };
  } catch {
    return { ok: false, status: 400, error: "bad_json" };
  }
}

export function clientIp(req: Request): string {
  const xf = req.headers.get("x-forwarded-for") ?? req.headers.get("cf-connecting-ip") ?? "";
  return xf.split(",")[0].trim() || "unknown";
}

const enc = new TextEncoder();
function hex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(await crypto.subtle.sign("HMAC", key, enc.encode(message)));
}
export function utcDay(ms: number): string { return new Date(ms).toISOString().slice(0, 10); }

/** Salted, day-scoped hash. The raw IP is never stored or logged; the hash rotates every UTC day. */
export async function ipHash(req: Request, deps: Deps): Promise<string> {
  const salt = deps.env("IP_HASH_SALT") ?? "";
  return (await hmacHex(salt || "unsalted-dev-only", `${clientIp(req)}|${utcDay(deps.now())}`)).slice(0, 32);
}
export async function visitorHash(req: Request, deps: Deps): Promise<string> {
  const salt = deps.env("IP_HASH_SALT") ?? "";
  const ua = req.headers.get("user-agent") ?? "";
  return (await hmacHex(salt || "unsalted-dev-only", `v|${clientIp(req)}|${ua}|${utcDay(deps.now())}`)).slice(0, 32);
}

export function str(v: unknown, max: number): string {
  return typeof v === "string" ? v.slice(0, max) : "";
}

export const MIN_FILL_MS = 3000;
/**
 * Spam guard shared by the booking and feedback forms:
 *  - `website` is a honeypot input hidden from people; bots fill it.
 *  - `t` is the epoch-ms the form was rendered; a human takes > MIN_FILL_MS to fill it.
 * Returns true when the request looks automated. Bots get a normal-looking success so they learn nothing.
 */
export function looksLikeBot(body: Record<string, unknown>, deps: Deps): boolean {
  if (typeof body.website === "string" && body.website.trim() !== "") return true;
  const t = Number(body.t);
  if (!Number.isFinite(t)) return true;
  const elapsed = deps.now() - t;
  return elapsed < MIN_FILL_MS || elapsed > 6 * 60 * 60 * 1000;
}

export async function rateLimited(deps: Deps, bucket: string, limit: number, windowSeconds: number): Promise<boolean> {
  const r = await deps.rpc("check_rate_limit_v1", { p_bucket: bucket, p_limit: limit, p_window_seconds: windowSeconds });
  if (r.error) throw new Error("rate_limit_unavailable"); // fail closed: never accept unmetered writes
  return r.data === false;
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
