// Server-side owner notifications. Telegram via Bot API; WhatsApp via the official Cloud API.
// A "sent" result only means the provider ACCEPTED the message. WhatsApp "delivered" is set
// separately from the provider's webhook. Credentials come from env only and are never logged.
import type { Deps } from "./core.ts";

export interface BookingForMessage {
  reference: string; name: string; business: string | null; email: string | null;
  whatsapp: string | null; service: string; budget: string | null; description: string; created_at?: string;
}
export interface SendResult { ok: boolean; providerId?: string; error?: string; notConfigured?: boolean }

const SERVICE_LABEL: Record<string, string> = {
  website: "Website / digital product", "ai-assistant": "AI software / assistant",
  automation: "Business automation", software: "Software / integration", other: "Other",
};
const BUDGET_LABEL: Record<string, string> = {
  "under-500": "Under $500", "500-1500": "$500–1,500", "1500-5000": "$1,500–5,000", "5000-plus": "$5,000+", unsure: "Not sure yet",
};

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

export function telegramText(b: BookingForMessage): string {
  const lines = [
    `<b>New booking ${escapeHtml(b.reference)}</b>`,
    `Name: ${escapeHtml(b.name)}`,
    b.business ? `Business: ${escapeHtml(b.business)}` : "",
    b.email ? `Email: ${escapeHtml(b.email)}` : "",
    b.whatsapp ? `WhatsApp: ${escapeHtml(b.whatsapp)}` : "",
    `Service: ${escapeHtml(SERVICE_LABEL[b.service] ?? b.service)}`,
    b.budget ? `Budget: ${escapeHtml(BUDGET_LABEL[b.budget] ?? b.budget)}` : "",
    "",
    escapeHtml(b.description.slice(0, 1500)),
  ];
  return lines.filter((l, i) => l !== "" || i === 7).join("\n").slice(0, 4000);
}

/** WhatsApp template parameters must be single-line and short. */
export function waParam(s: string, max = 60): string {
  return s.replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim().slice(0, max) || "-";
}

function safeError(label: string, status: number, detail: unknown, secrets: string[]): string {
  let d = typeof detail === "string" ? detail : "";
  for (const s of secrets) if (s) d = d.split(s).join("***");
  return `${label} HTTP ${status}${d ? `: ${d.slice(0, 160)}` : ""}`;
}

export async function sendTelegram(deps: Deps, b: BookingForMessage): Promise<SendResult> {
  const token = deps.env("TELEGRAM_BOT_TOKEN"); const chat = deps.env("TELEGRAM_OWNER_CHAT_ID");
  if (!token || !chat) return { ok: false, notConfigured: true, error: "TELEGRAM_BOT_TOKEN / TELEGRAM_OWNER_CHAT_ID not set" };
  try {
    const res = await deps.fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST", headers: { "content-type": "application/json" },
      body: JSON.stringify({ chat_id: chat, text: telegramText(b), parse_mode: "HTML", disable_web_page_preview: true }),
    });
    const body = await res.json().catch(() => ({})) as { ok?: boolean; description?: string; result?: { message_id?: number } };
    if (res.ok && body.ok && body.result?.message_id !== undefined) return { ok: true, providerId: String(body.result.message_id) };
    return { ok: false, error: safeError("telegram", res.status, body.description, [token, chat]) };
  } catch (e) {
    return { ok: false, error: safeError("telegram network error", 0, (e as Error).message, [token, chat]) };
  }
}

export async function sendWhatsApp(deps: Deps, b: BookingForMessage): Promise<SendResult> {
  const tokenV = deps.env("WHATSAPP_ACCESS_TOKEN"); const phoneId = deps.env("WHATSAPP_PHONE_NUMBER_ID");
  const to = deps.env("WHATSAPP_OWNER_NUMBER"); const tpl = deps.env("WHATSAPP_TEMPLATE_NAME");
  if (!tokenV || !phoneId || !to || !tpl) {
    return { ok: false, notConfigured: true, error: "WhatsApp Cloud API credentials/template not set" };
  }
  const lang = deps.env("WHATSAPP_TEMPLATE_LANG") ?? "en";
  const contact = b.whatsapp ?? b.email ?? "-";
  try {
    const res = await deps.fetch(`https://graph.facebook.com/v21.0/${encodeURIComponent(phoneId)}/messages`, {
      method: "POST", headers: { "content-type": "application/json", authorization: `Bearer ${tokenV}` },
      body: JSON.stringify({
        messaging_product: "whatsapp", to: to.replace(/[^0-9]/g, ""), type: "template",
        template: { name: tpl, language: { code: lang }, components: [{ type: "body", parameters: [
          waParam(b.reference), waParam(b.business ? `${b.name} (${b.business})` : b.name),
          waParam(SERVICE_LABEL[b.service] ?? b.service), waParam(contact),
        ].map((text) => ({ type: "text", text })) }] },
      }),
    });
    const body = await res.json().catch(() => ({})) as { messages?: { id?: string }[]; error?: { message?: string } };
    const id = body.messages?.[0]?.id;
    if (res.ok && id) return { ok: true, providerId: id };
    return { ok: false, error: safeError("whatsapp", res.status, body.error?.message, [tokenV, phoneId, to]) };
  } catch (e) {
    return { ok: false, error: safeError("whatsapp network error", 0, (e as Error).message, [tokenV, phoneId, to]) };
  }
}
