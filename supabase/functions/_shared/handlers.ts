// Request handlers for the Stage 8 edge functions. Each takes injected Deps so tests can
// run them without Deno, Supabase, Telegram or WhatsApp.
import {
  type Deps, clientIp, corsHeaders, hmacHex, ipHash, json, looksLikeBot, originAllowed, rateLimited, readJson,
  str, timingSafeEqual, visitorHash,
} from "./core.ts";
import { type BookingForMessage, sendTelegram, sendWhatsApp } from "./notify.ts";

type Handler = (req: Request) => Promise<Response>;

async function guarded(req: Request, deps: Deps, run: (body: Record<string, unknown>, cors: Record<string, string>) => Promise<Response>): Promise<Response> {
  const cors = corsHeaders(req, deps);
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  // Side-effect-free probe: forms stay disabled until origin and privacy hashing are configured.
  const saltConfigured = (deps.env("IP_HASH_SALT") ?? "").length >= 32;
  if (req.method === "GET" && new URL(req.url).searchParams.has("health") && originAllowed(req, deps)) {
    return saltConfigured ? json({ ok: true }, 200, cors) : json({ ok: false, error: "not_configured" }, 503, cors);
  }
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405, cors);
  if (!originAllowed(req, deps)) return json({ ok: false, error: "origin_not_allowed" }, 403, cors);
  if (!saltConfigured) return json({ ok: false, error: "not_configured" }, 503, cors);
  const body = await readJson(req);
  if (!body.ok) return json({ ok: false, error: body.error }, body.status, cors);
  try {
    return await run(body.value, cors);
  } catch {
    // never leak internals; the client is told only that nothing was saved
    return json({ ok: false, error: "unavailable" }, 503, cors);
  }
}

// ---------------------------------------------------------------------------
export function submitBooking(deps: Deps): Handler {
  return (req) => guarded(req, deps, async (b, cors) => {
    if (looksLikeBot(b, deps)) {
      // Pretend success so bots learn nothing. Nothing is stored.
      return json({ ok: true, saved: true, reference: "DB-00000000", duplicate: false }, 200, cors);
    }
    const deliveryChannel = str(b.delivery_channel, 20);
    if (deliveryChannel !== "telegram" && deliveryChannel !== "whatsapp") {
      return json({ ok: false, error: "invalid", field: "delivery_channel", reason: "invalid" }, 422, cors);
    }
    const slotId = str(b.slot_id, 64);
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(slotId)) {
      return json({ ok: false, error: "invalid", field: "slot_id", reason: "required" }, 422, cors);
    }
    const ip = await ipHash(req, deps);
    if (await rateLimited(deps, `booking:${ip}`, 5, 3600)) return json({ ok: false, error: "rate_limited" }, 429, cors);
    const r = await deps.rpc("create_booking_v1", {
      p: {
        name: str(b.name, 200), business: str(b.business, 200), email: str(b.email, 300), whatsapp: str(b.whatsapp, 40), delivery_channel: deliveryChannel,
        service: str(b.service, 40), budget: str(b.budget, 40), description: str(b.description, 4000), slot_id: slotId,
      },
      p_ip_hash: ip, p_client_key: str(b.client_key, 64) || null,
    });
    if (r.error) return json({ ok: false, error: "unavailable" }, 503, cors);
    const d = r.data as { ok: boolean; field?: string; error?: string; duplicate?: boolean; reference?: string };
    if (!d.ok) return json({ ok: false, error: "invalid", field: d.field, reason: d.error }, 422, cors);
    if (!d.duplicate) {
      // Saved first. Notifications run afterwards and can fail without affecting the booking.
      deps.background(dispatchNotifications(deps, 10).catch(() => undefined));
      deps.background(deps.rpc("record_event_v1", { p_event: "booking_submit", p_path: "#book" }).catch(() => undefined));
    }
    return json({ ok: true, saved: true, reference: d.reference, duplicate: !!d.duplicate }, 200, cors);
  });
}

export function submitFeedback(deps: Deps): Handler {
  return (req) => guarded(req, deps, async (b, cors) => {
    if (looksLikeBot(b, deps)) return json({ ok: true, saved: true, reference: "FB-00000000", duplicate: false }, 200, cors);
    const rating = Number(b.rating);
    if (!Number.isInteger(rating) || rating < 1 || rating > 5) return json({ ok: false, error: "invalid", field: "rating", reason: "invalid" }, 422, cors);
    const ip = await ipHash(req, deps);
    if (await rateLimited(deps, `feedback:${ip}`, 5, 3600)) return json({ ok: false, error: "rate_limited" }, 429, cors);
    const r = await deps.rpc("create_feedback_v1", {
      p: { name: str(b.name, 200), email: str(b.email, 300), category: str(b.category, 40), message: str(b.message, 4000), rating },
      p_ip_hash: ip, p_client_key: str(b.client_key, 64) || null,
    });
    if (r.error) return json({ ok: false, error: "unavailable" }, 503, cors);
    const d = r.data as { ok: boolean; field?: string; error?: string; duplicate?: boolean; reference?: string };
    if (!d.ok) return json({ ok: false, error: "invalid", field: d.field, reason: d.error }, 422, cors);
    if (!d.duplicate) deps.background(deps.rpc("record_event_v1", { p_event: "feedback_submit", p_path: "#feedback" }).catch(() => undefined));
    return json({ ok: true, saved: true, reference: d.reference, duplicate: !!d.duplicate }, 200, cors);
  });
}

const EVENTS = new Set(["page_view", "project_view", "demo_click", "contact_click"]);
export function trackEvent(deps: Deps): Handler {
  return (req) => guarded(req, deps, async (b, cors) => {
    // Honour Do-Not-Track / Global Privacy Control server-side too.
    if (req.headers.get("dnt") === "1" || req.headers.get("sec-gpc") === "1") return json({ ok: true, stored: false }, 202, cors);
    const event = str(b.event, 30);
    if (!EVENTS.has(event)) return json({ ok: false, error: "invalid_event" }, 400, cors);
    const ip = await ipHash(req, deps);
    if (await rateLimited(deps, `evt:${ip}`, 120, 60)) return json({ ok: false, error: "rate_limited" }, 429, cors);
    const r = await deps.rpc("record_event_v1", {
      p_event: event, p_path: str(b.path, 100), p_project_slug: str(b.project, 60), p_target: str(b.target, 20),
      p_visitor_hash: await visitorHash(req, deps),
    });
    return json({ ok: true, stored: r.data === true }, 202, cors);
  });
}

// ---------------------------------------------------------------------------
/** Claims due deliveries, sends each channel independently, records each result. */
export async function dispatchNotifications(deps: Deps, limit: number): Promise<{ claimed: number; sent: number; failed: number }> {
  const claim = await deps.rpc("claim_notifications_v1", { p_limit: limit });
  if (claim.error) throw new Error("claim_failed");
  const rows = (claim.data as { id: string; channel: string; booking: BookingForMessage }[]) ?? [];
  let sent = 0, failed = 0;
  await Promise.all(rows.map(async (row) => {
    const res = row.channel === "telegram" ? await sendTelegram(deps, row.booking) : await sendWhatsApp(deps, row.booking);
    await deps.rpc("complete_notification_v1", {
      p_id: row.id, p_ok: res.ok, p_provider_id: res.providerId ?? null, p_error: res.error ?? null, p_not_configured: !!res.notConfigured,
    });
    if (res.ok) sent++; else failed++;
  }));
  return { claimed: rows.length, sent, failed };
}

/** Scheduled retry runner. Protected by a shared secret header — never callable by browsers. */
export function processNotifications(deps: Deps): Handler {
  return async (req) => {
    const secret = deps.env("NOTIFY_CRON_SECRET") ?? "";
    const given = req.headers.get("x-cron-secret") ?? "";
    if (req.method !== "POST" || secret.length < 16 || !timingSafeEqual(secret, given)) {
      return json({ ok: false, error: "forbidden" }, 403, {});
    }
    try {
      return json({ ok: true, ...(await dispatchNotifications(deps, 20)) }, 200, {});
    } catch {
      return json({ ok: false, error: "unavailable" }, 503, {});
    }
  };
}

// ---------------------------------------------------------------------------
export function whatsappWebhook(deps: Deps): Handler {
  return async (req) => {
    if (req.method === "GET") {
      const u = new URL(req.url);
      const verify = deps.env("WHATSAPP_VERIFY_TOKEN") ?? "";
      if (verify.length >= 16 && u.searchParams.get("hub.mode") === "subscribe" &&
          timingSafeEqual(verify, u.searchParams.get("hub.verify_token") ?? "")) {
        return new Response(u.searchParams.get("hub.challenge") ?? "", { status: 200 });
      }
      return new Response("forbidden", { status: 403 });
    }
    if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
    const appSecret = deps.env("WHATSAPP_APP_SECRET") ?? "";
    const raw = await req.text();
    if (!appSecret || raw.length > 256 * 1024) return new Response("forbidden", { status: 403 });
    const expected = "sha256=" + await hmacHex(appSecret, raw);
    if (!timingSafeEqual(expected, req.headers.get("x-hub-signature-256") ?? "")) return new Response("forbidden", { status: 403 });
    let payload: any;
    try { payload = JSON.parse(raw); } catch { return new Response("bad request", { status: 400 }); }
    const statuses: { id?: string; status?: string; errors?: { title?: string }[] }[] = [];
    for (const e of payload?.entry ?? []) for (const c of e?.changes ?? []) for (const s of c?.value?.statuses ?? []) statuses.push(s);
    for (const s of statuses.slice(0, 50)) {
      if (typeof s.id !== "string" || typeof s.status !== "string") continue;
      await deps.rpc("mark_whatsapp_delivery_v1", { p_provider_id: s.id, p_status: s.status, p_error: s.errors?.[0]?.title ?? null });
    }
    return new Response("ok", { status: 200 });
  };
}

export { clientIp };
