// Run: node --test --experimental-strip-types supabase/functions/tests/
// Uses fakes only: no Supabase, Telegram or WhatsApp is contacted.
import { test } from "node:test";
import assert from "node:assert/strict";
import { type Deps, hmacHex } from "../_shared/core.ts";
import {
  dispatchNotifications, processNotifications, submitBooking, submitFeedback, trackEvent, whatsappWebhook,
} from "../_shared/handlers.ts";
import { sendTelegram, sendWhatsApp, telegramText, waParam } from "../_shared/notify.ts";

const ORIGIN = "https://derya.example";
const NOW = 1_800_000_000_000;
type Call = { fn: string; args: Record<string, unknown> };

function make(over: { env?: Record<string, string>; rpc?: (fn: string, a: any) => any; fetch?: any } = {}) {
  const calls: Call[] = []; const bg: Promise<unknown>[] = []; const fetches: { url: string; init: any }[] = [];
  const env: Record<string, string> = { ALLOWED_ORIGINS: ORIGIN, IP_HASH_SALT: "salt-salt-salt-salt", ...over.env };
  const deps: Deps = {
    env: (k) => env[k], now: () => NOW,
    rpc: async (fn, args) => { calls.push({ fn, args }); return over.rpc ? over.rpc(fn, args) : { data: fn === "check_rate_limit_v1" ? true : { ok: true, duplicate: false, reference: "DB-ABCDEF12" }, error: null }; },
    fetch: (async (url: string, init: any) => { fetches.push({ url, init }); return over.fetch ? over.fetch(url, init) : new Response("{}", { status: 200 }); }) as any,
    background: (p) => { bg.push(p); },
  };
  return { deps, calls, bg, fetches, env };
}
const post = (body: unknown, headers: Record<string, string> = {}) => new Request("https://f.example/fn", {
  method: "POST", headers: { origin: ORIGIN, "content-type": "application/json", "x-forwarded-for": "203.0.113.7", "user-agent": "UA-TEST", ...headers },
  body: typeof body === "string" ? body : JSON.stringify(body),
});
const booking = (o: Record<string, unknown> = {}) => ({ name: "Abel", email: "a@b.co", delivery_channel: "telegram", service: "website", description: "I need a website", slot_id: "11111111-1111-4111-8111-111111111111", t: NOW - 10_000, website: "", client_key: "key-12345678", ...o });

test("CORS: unlisted origin is refused; listed origin is echoed; no wildcard", async () => {
  const { deps } = make();
  const bad = await submitBooking(deps)(post(booking(), { origin: "https://evil.example" }));
  assert.equal(bad.status, 403); assert.equal(bad.headers.get("access-control-allow-origin"), null);
  const ok = await submitBooking(deps)(post(booking()));
  assert.equal(ok.headers.get("access-control-allow-origin"), ORIGIN);
  const none = make({ env: { ALLOWED_ORIGINS: "" } });
  assert.equal((await submitBooking(none.deps)(post(booking()))).status, 403);
});

test("health probe: side-effect free, only for allowed origins", async () => {
  const m = make(); const h = submitBooking(m.deps);
  const ok = await h(new Request("https://f.example/fn?health=1", { method: "GET", headers: { origin: ORIGIN } }));
  assert.equal(ok.status, 200); assert.equal(m.calls.length, 0);
  assert.equal((await h(new Request("https://f.example/fn?health=1", { method: "GET", headers: { origin: "https://evil.example" } }))).status, 405);
});

test("method/body hygiene: OPTIONS 204, GET 405, bad JSON 400, wrong type 415, oversize 413", async () => {
  const { deps } = make(); const h = submitBooking(deps);
  assert.equal((await h(new Request("https://f.example", { method: "OPTIONS", headers: { origin: ORIGIN } }))).status, 204);
  assert.equal((await h(new Request("https://f.example", { method: "GET", headers: { origin: ORIGIN } }))).status, 405);
  assert.equal((await h(post("{nope"))).status, 400);
  assert.equal((await h(post("[1,2]"))).status, 400);
  assert.equal((await h(post("x", { "content-type": "application/xml" }))).status, 415);
  assert.equal((await h(post(booking({ description: "x".repeat(20_000) })))).status, 413);
});

test("honeypot / too-fast / missing timestamp: fake success, nothing stored", async () => {
  for (const o of [{ website: "http://spam" }, { t: NOW - 500 }, { t: undefined }, { t: "abc" }]) {
    const { deps, calls } = make(); const r = await submitBooking(deps)(post(booking(o)));
    assert.equal(r.status, 200);
    assert.equal(calls.some((c) => c.fn === "create_booking_v1"), false);
  }
});

test("rate limit: 429 and no write; limiter outage fails closed (503)", async () => {
  const a = make({ rpc: (fn: string) => ({ data: fn === "check_rate_limit_v1" ? false : null, error: null }) });
  assert.equal((await submitBooking(a.deps)(post(booking()))).status, 429);
  assert.equal(a.calls.some((c) => c.fn === "create_booking_v1"), false);
  const b = make({ rpc: (fn: string) => fn === "check_rate_limit_v1" ? { data: null, error: { message: "down" } } : { data: null, error: null } });
  const r = await submitBooking(b.deps)(post(booking()));
  assert.equal(r.status, 503); assert.equal(b.calls.some((c) => c.fn === "create_booking_v1"), false);
});

test("valid booking: saved, honest response, hashed IP only, notifications run in background", async () => {
  const m = make(); const r = await submitBooking(m.deps)(post(booking()));
  const j = await r.json() as any;
  assert.equal(r.status, 200); assert.equal(j.saved, true); assert.equal(j.reference, "DB-ABCDEF12");
  assert.equal("notified" in j, false, "response must not claim notifications were sent");
  const create = m.calls.find((c) => c.fn === "create_booking_v1")!;
  assert.equal((create.args.p as Record<string, unknown>).delivery_channel, "telegram");
  assert.match(String(create.args.p_ip_hash), /^[0-9a-f]{32}$/);
  assert.equal(JSON.stringify(m.calls).includes("203.0.113.7"), false, "raw IP must never be sent to the database");
  await Promise.all(m.bg);
  assert.ok(m.calls.some((c) => c.fn === "claim_notifications_v1"), "dispatch was started after saving");
});

test("duplicate booking is acknowledged without dispatching again", async () => {
  const m = make({ rpc: (fn: string) => ({ data: fn === "check_rate_limit_v1" ? true : { ok: true, duplicate: true, reference: "DB-OLD00001" }, error: null }) });
  const j = await (await submitBooking(m.deps)(post(booking()))).json() as any;
  assert.equal(j.duplicate, true); await Promise.all(m.bg);
  assert.equal(m.calls.some((c) => c.fn === "claim_notifications_v1"), false);
});

test("validation errors surface as 422 with the field; database outage as 503 'not saved'", async () => {
  const bad = make({ rpc: (fn: string) => ({ data: fn === "check_rate_limit_v1" ? true : { ok: false, field: "email", error: "invalid" }, error: null }) });
  const r = await submitBooking(bad.deps)(post(booking())); const j = await r.json() as any;
  assert.equal(r.status, 422); assert.equal(j.field, "email"); assert.equal(j.saved, undefined);
  const down = make({ rpc: (fn: string) => fn === "check_rate_limit_v1" ? { data: true, error: null } : { data: null, error: { message: "boom" } } });
  const r2 = await submitBooking(down.deps)(post(booking())); const j2 = await r2.json() as any;
  assert.equal(r2.status, 503); assert.notEqual(j2.saved, true); assert.equal(JSON.stringify(j2).includes("boom"), false);
});

test("public booking and feedback require valid slot and rating", async () => {
  const b = make(); const missingSlot = await submitBooking(b.deps)(post(booking({ slot_id: "" })));
  assert.equal(missingSlot.status, 422); assert.equal(((await missingSlot.json()) as any).field, "slot_id");
  const f = make(); const missingRating = await submitFeedback(f.deps)(post({ category: "idea", message: "Nice site", t: NOW - 9000, website: "" }));
  assert.equal(missingRating.status, 422); assert.equal(((await missingRating.json()) as any).field, "rating");
});

test("feedback: stored privately via RPC; bots get a silent fake success", async () => {
  const m = make({ rpc: (fn: string) => ({ data: fn === "check_rate_limit_v1" ? true : { ok: true, duplicate: false, reference: "FB-ABCDEF12" }, error: null }) });
  const r = await submitFeedback(m.deps)(post({ category: "idea", message: "Nice site", rating: 4, t: NOW - 9000, website: "" }));
  assert.equal(((await r.json()) as any).reference, "FB-ABCDEF12");
  assert.ok(m.calls.some((c) => c.fn === "create_feedback_v1"));
  const bot = make(); await submitFeedback(bot.deps)(post({ category: "idea", message: "buy pills", t: NOW - 9000, website: "x" }));
  assert.equal(bot.calls.some((c) => c.fn === "create_feedback_v1"), false);
});

test("analytics: DNT/GPC respected, invalid events rejected, no raw IP/UA stored", async () => {
  const dnt = make(); const r = await trackEvent(dnt.deps)(post({ event: "page_view", path: "/" }, { dnt: "1" }));
  assert.equal(((await r.json()) as any).stored, false); assert.equal(dnt.calls.length, 0);
  const gpc = make(); await trackEvent(gpc.deps)(post({ event: "page_view" }, { "sec-gpc": "1" })); assert.equal(gpc.calls.length, 0);
  const inv = make(); assert.equal((await trackEvent(inv.deps)(post({ event: "drop table" }))).status, 400);
  assert.equal((await trackEvent(inv.deps)(post({ event: "booking_submit" }))).status, 400, "booking_submit can only be recorded server-side");
  const ok = make({ rpc: (fn: string) => ({ data: true, error: null }) });
  assert.equal((await trackEvent(ok.deps)(post({ event: "contact_click", target: "telegram", path: "#contact" }))).status, 202);
  const ev = ok.calls.find((c) => c.fn === "record_event_v1")!;
  assert.match(String(ev.args.p_visitor_hash), /^[0-9a-f]{32}$/);
  const dump = JSON.stringify(ok.calls); assert.equal(dump.includes("203.0.113.7") || dump.includes("UA-TEST"), false);
});

// ---------------- notifications ----------------
const B = { reference: "DB-ABCDEF12", name: "Abel <b>X</b>", business: "Shop & Co", email: "a@b.co", whatsapp: "+251912345678", service: "website", budget: "500-1500", description: "Need <script>alert(1)</script> a site\nplease" };
const tgEnv = { TELEGRAM_BOT_TOKEN: "123456:SECRET-TOKEN", TELEGRAM_OWNER_CHAT_ID: "987654321" };
const waEnv = { WHATSAPP_ACCESS_TOKEN: "EAAG-SECRET", WHATSAPP_PHONE_NUMBER_ID: "1122334455", WHATSAPP_OWNER_NUMBER: "+251 90 238 9561", WHATSAPP_TEMPLATE_NAME: "new_booking", WHATSAPP_TEMPLATE_LANG: "en", WHATSAPP_PAID_MESSAGING_APPROVED: "true" };

test("Telegram text escapes HTML; WhatsApp params are single-line", () => {
  const t = telegramText(B);
  assert.equal(t.includes("<script>"), false); assert.ok(t.includes("&lt;script&gt;")); assert.ok(t.includes("Shop &amp; Co"));
  assert.equal(waParam("a\nb\t  c"), "a b c"); assert.equal(waParam(""), "-");
});

test("Telegram: success returns message id; unconfigured is flagged, not failed; token never in errors", async () => {
  const ok = make({ env: tgEnv, fetch: () => new Response(JSON.stringify({ ok: true, result: { message_id: 42 } }), { status: 200 }) });
  assert.deepEqual(await sendTelegram(ok.deps, B), { ok: true, providerId: "42" });
  assert.match(ok.fetches[0].url, /^https:\/\/api\.telegram\.org\/bot123456:SECRET-TOKEN\/sendMessage$/);
  assert.equal(JSON.parse(ok.fetches[0].init.body).chat_id, "987654321");
  const none = make(); const n = await sendTelegram(none.deps, B); assert.equal(n.notConfigured, true); assert.equal(none.fetches.length, 0);
  const bad = make({ env: tgEnv, fetch: () => new Response(JSON.stringify({ ok: false, description: "Unauthorized 123456:SECRET-TOKEN" }), { status: 401 }) });
  const r = await sendTelegram(bad.deps, B); assert.equal(r.ok, false); assert.equal(String(r.error).includes("SECRET-TOKEN"), false);
  const net = make({ env: tgEnv, fetch: () => { throw new Error("connect failed to bot123456:SECRET-TOKEN"); } });
  assert.equal(String((await sendTelegram(net.deps, B)).error).includes("SECRET-TOKEN"), false);
});

test("WhatsApp: official Cloud API template message; 'sent' needs a provider message id; unconfigured flagged", async () => {
  const ok = make({ env: waEnv, fetch: () => new Response(JSON.stringify({ messages: [{ id: "wamid.XYZ" }] }), { status: 200 }) });
  assert.deepEqual(await sendWhatsApp(ok.deps, B), { ok: true, providerId: "wamid.XYZ" });
  const f = ok.fetches[0]; const body = JSON.parse(f.init.body);
  assert.match(f.url, /graph\.facebook\.com\/v21\.0\/1122334455\/messages$/);
  assert.equal(f.init.headers.authorization, "Bearer EAAG-SECRET");
  assert.equal(body.to, "251902389561"); assert.equal(body.type, "template"); assert.equal(body.template.name, "new_booking");
  assert.equal(body.template.components[0].parameters.length, 4);
  assert.ok(body.template.components[0].parameters.every((p: any) => !/[\n\t]/.test(p.text)));
  const noId = make({ env: waEnv, fetch: () => new Response(JSON.stringify({}), { status: 200 }) });
  assert.equal((await sendWhatsApp(noId.deps, B)).ok, false, "200 without a message id is not success");
  const err = make({ env: waEnv, fetch: () => new Response(JSON.stringify({ error: { message: "Invalid token EAAG-SECRET" } }), { status: 401 }) });
  assert.equal(String((await sendWhatsApp(err.deps, B)).error).includes("EAAG-SECRET"), false);
  assert.equal((await sendWhatsApp(make().deps, B)).notConfigured, true);
});

test("dispatch: each channel is recorded independently; one failure does not affect the other", async () => {
  const rows = [{ id: "t1", channel: "telegram", booking: B }, { id: "w1", channel: "whatsapp", booking: B }];
  const m = make({ env: { ...tgEnv, ...waEnv },
    rpc: (fn: string) => ({ data: fn === "claim_notifications_v1" ? rows : "ok", error: null }),
    fetch: (url: string) => url.includes("telegram") ? new Response(JSON.stringify({ ok: true, result: { message_id: 7 } }), { status: 200 }) : new Response(JSON.stringify({ error: { message: "template not approved" } }), { status: 400 }) });
  const out = await dispatchNotifications(m.deps, 10);
  assert.deepEqual(out, { claimed: 2, sent: 1, failed: 1 });
  const done = m.calls.filter((c) => c.fn === "complete_notification_v1");
  assert.equal(done.find((c) => c.args.p_id === "t1")!.args.p_ok, true);
  const w = done.find((c) => c.args.p_id === "w1")!.args; assert.equal(w.p_ok, false); assert.match(String(w.p_error), /template not approved/);
});

test("dispatch with no credentials records not_configured (not 'sent')", async () => {
  const m = make({ rpc: (fn: string) => ({ data: fn === "claim_notifications_v1" ? [{ id: "t1", channel: "telegram", booking: B }] : "ok", error: null }) });
  await dispatchNotifications(m.deps, 5);
  const c = m.calls.find((x) => x.fn === "complete_notification_v1")!.args; assert.equal(c.p_ok, false); assert.equal(c.p_not_configured, true);
});

test("process-notifications requires the cron secret", async () => {
  const secret = "cron-secret-0123456789";
  const m = make({ env: { NOTIFY_CRON_SECRET: secret }, rpc: () => ({ data: [], error: null }) });
  const h = processNotifications(m.deps);
  const req = (hdr: Record<string, string>) => new Request("https://f.example", { method: "POST", headers: hdr });
  assert.equal((await h(req({}))).status, 403);
  assert.equal((await h(req({ "x-cron-secret": "wrong" }))).status, 403);
  assert.equal((await h(req({ "x-cron-secret": secret }))).status, 200);
  const unset = make({ rpc: () => ({ data: [], error: null }) });
  assert.equal((await processNotifications(unset.deps)(req({ "x-cron-secret": "" }))).status, 403, "unset secret must not open the endpoint");
});

test("WhatsApp webhook: verify handshake, signature check, receipts forwarded", async () => {
  const env = { WHATSAPP_VERIFY_TOKEN: "verify-token-0123456789", WHATSAPP_APP_SECRET: "app-secret-xyz" };
  const m = make({ env, rpc: () => ({ data: true, error: null }) }); const h = whatsappWebhook(m.deps);
  const g = (t: string) => new Request(`https://f.example/?hub.mode=subscribe&hub.verify_token=${t}&hub.challenge=CHAL`);
  assert.equal(await (await h(g(env.WHATSAPP_VERIFY_TOKEN))).text(), "CHAL");
  assert.equal((await h(g("nope"))).status, 403);
  const body = JSON.stringify({ entry: [{ changes: [{ value: { statuses: [{ id: "wamid.XYZ", status: "delivered" }, { id: "wamid.ABC", status: "failed", errors: [{ title: "Undeliverable" }] }] } }] }] });
  const sig = "sha256=" + await hmacHex(env.WHATSAPP_APP_SECRET, body);
  assert.equal((await h(new Request("https://f.example", { method: "POST", body, headers: { "x-hub-signature-256": "sha256=00" } }))).status, 403);
  assert.equal(m.calls.length, 0, "unsigned requests must not touch the database");
  assert.equal((await h(new Request("https://f.example", { method: "POST", body, headers: { "x-hub-signature-256": sig } }))).status, 200);
  assert.deepEqual(m.calls.map((c) => [c.args.p_provider_id, c.args.p_status]), [["wamid.XYZ", "delivered"], ["wamid.ABC", "failed"]]);
  const noSecret = make({ env: { WHATSAPP_VERIFY_TOKEN: env.WHATSAPP_VERIFY_TOKEN } });
  assert.equal((await whatsappWebhook(noSecret.deps)(new Request("https://f.example", { method: "POST", body, headers: { "x-hub-signature-256": sig } }))).status, 403);
});

// ---------------- approved channel policy: one channel per booking, WhatsApp cost-gated ----------------
const claimRows = (rows: unknown[]) => (fn: string) => ({ data: fn === "claim_notifications_v1" ? rows : "ok", error: null });
const tgOk = () => new Response(JSON.stringify({ ok: true, result: { message_id: 9 } }), { status: 200 });
const waOk = () => new Response(JSON.stringify({ messages: [{ id: "wamid.Z" }] }), { status: 200 });

test("Telegram-selected booking: only Telegram is contacted, WhatsApp is never touched", async () => {
  const m = make({ env: { ...tgEnv, ...waEnv }, rpc: claimRows([{ id: "t1", channel: "telegram", booking: B }]), fetch: (u: string) => u.includes("telegram") ? tgOk() : waOk() });
  assert.deepEqual(await dispatchNotifications(m.deps, 5), { claimed: 1, sent: 1, failed: 0 });
  assert.equal(m.fetches.length, 1); assert.match(m.fetches[0].url, /api\.telegram\.org/);
});

test("WhatsApp-selected booking: only WhatsApp is contacted, Telegram is never touched", async () => {
  const m = make({ env: { ...tgEnv, ...waEnv }, rpc: claimRows([{ id: "w1", channel: "whatsapp", booking: B }]), fetch: (u: string) => u.includes("telegram") ? tgOk() : waOk() });
  assert.deepEqual(await dispatchNotifications(m.deps, 5), { claimed: 1, sent: 1, failed: 0 });
  assert.equal(m.fetches.length, 1); assert.match(m.fetches[0].url, /graph\.facebook\.com/);
});

test("WhatsApp is cost-gated: credentials alone send nothing; flag must be exactly 'true'", async () => {
  for (const flag of [undefined, "", "false", "TRUE", "1", "yes"]) {
    const env: Record<string, string> = { ...waEnv }; if (flag === undefined) delete env.WHATSAPP_PAID_MESSAGING_APPROVED; else env.WHATSAPP_PAID_MESSAGING_APPROVED = flag;
    const m = make({ env, rpc: claimRows([{ id: "w1", channel: "whatsapp", booking: B }]), fetch: waOk });
    await dispatchNotifications(m.deps, 5);
    assert.equal(m.fetches.length, 0, `no request may leave when flag=${String(flag)}`);
    const c = m.calls.find((x) => x.fn === "complete_notification_v1")!.args;
    assert.equal(c.p_ok, false); assert.equal(c.p_not_configured, true); assert.match(String(c.p_error), /disabled/);
  }
});

test("Telegram keeps working while WhatsApp is disabled (free channel is independent)", async () => {
  const env = { ...tgEnv, ...waEnv, WHATSAPP_PAID_MESSAGING_APPROVED: "false" };
  const m = make({ env, rpc: claimRows([{ id: "t1", channel: "telegram", booking: B }]), fetch: tgOk });
  assert.deepEqual(await dispatchNotifications(m.deps, 5), { claimed: 1, sent: 1, failed: 0 });
});

test("no duplicate sends: an empty claim sends nothing, and each claimed row is sent exactly once", async () => {
  const none = make({ env: { ...tgEnv, ...waEnv }, rpc: claimRows([]), fetch: tgOk });
  await dispatchNotifications(none.deps, 5); assert.equal(none.fetches.length, 0);
  const one = make({ env: tgEnv, rpc: claimRows([{ id: "t1", channel: "telegram", booking: B }]), fetch: tgOk });
  await dispatchNotifications(one.deps, 5);
  assert.equal(one.fetches.length, 1); assert.equal(one.calls.filter((c) => c.fn === "complete_notification_v1").length, 1);
});
