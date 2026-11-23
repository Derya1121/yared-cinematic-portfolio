# Stage 8 setup and safety notes

**Status (2026-11-18):** The dedicated development Supabase project `lyeccydsfwjtxhpkhukh` is reachable and reports `ACTIVE_HEALTHY`. Base migration `20261117184931 / stage8_cms_admin` and owner-only migration `20261118103942 / stage8_owner_only_security` are recorded in the live migration history. The owner-only migration is applied. `private.app_config` now has RLS enabled and `private.is_admin()` grants access only to active owners (plus the configured MFA condition). A direct live check with no authenticated user returned false for both editor and owner checks, as expected.

**Owner account (owner-reported, 2026-11-23):** the owner states that one active owner account now exists, that the booking and feedback tables hold zero rows, and that all five Edge Functions are active. These points were **not independently verified** from this repository's tooling: the Supabase connector used for Stage 8 work still returns "no permission" for this project (it lists only the Derya1121 organization's other projects). The earlier line "zero Auth users and zero `admin_users` rows" (2026-11-18) is superseded. Public signup remains disabled. Re-verify before relying on any of this: run the checks in "Setup gates" below against the live project.

**Frontend configuration is still empty:** `config.js` has no `supabaseUrl` or `supabaseAnonKey`, which is why the public forms read NOT LIVE. Only the project URL (`https://lyeccydsfwjtxhpkhukh.supabase.co`) and the *publishable* key belong there. `ALLOWED_ORIGINS` must list the exact Preview origin; use the stable branch alias of the Preview (not the per-deployment URL, which changes on every push) and no wildcards.

**Edge Functions:** all five deployed functions are now version 2 and active: `submit-booking`, `submit-feedback`, `track-event`, `process-notifications`, and `whatsapp-webhook`. Each was re-fetched after deployment. All five contain the current shared `notify.ts` and its exact `WHATSAPP_PAID_MESSAGING_APPROVED === "true"` send gate. Each also contains the cron-secret handler. JWT verification remains disabled as in the existing configuration; each public endpoint performs its own origin/secret/signature validation. No provider credentials were added and no real external messages were sent.

**Current Security Advisor:** three RLS-enabled tables have no policies: `private.app_config` (intentional: no client access), `private.rate_limits` (server-side only), and `public.analytics_events` (server-side only). It also reports one public `get_public_site()` SECURITY DEFINER warning and six authenticated SECURITY DEFINER warnings (five admin RPCs plus the public-site RPC). The admin RPCs rely on the owner-only helper; the public RPC returns published site content. Review grants and helper checks before production. Performance/health advisor currently reports no findings.

**Notification retry scheduling:** the database has no `cron.job` relation, so Supabase pg_cron is not installed. An external scheduler has not been verified. Notification retries are not operational until a scheduler is configured and a safe retry test succeeds.

No real Telegram or WhatsApp delivery has been verified. Do not describe either channel as live until a controlled real-provider test succeeds. WhatsApp paid messaging must remain disabled unless the owner confirms Meta pricing and explicitly approves the cost.

## Repository

- Repository: `Derya1121/yared-cinematic-portfolio`
- Feature branch: `claude/stage8-cms-admin`
- Public site: existing Stage 7 foundation plus Stage 8 public integration.
- Private admin: `/admin/` (static interface; requires the dedicated Supabase backend).

## Current setup gates

1. Keep the existing dedicated development project isolated. Do not create another project or reuse DERYA BOT, AUREX AI, Rent Manager or any other project.
2. Review and explicitly approve `supabase/migrations/20261118000000_stage8_owner_only_security.sql` before applying it to the development project. Do not apply it to production.
3. After applying the owner-only migration, verify editor denial and owner access against the real Supabase project before creating the owner account.
4. Create the owner account with Supabase Auth only after signup is disabled. Then insert that user's Auth UUID into `public.admin_users` with role `owner` and `active = true`. Never expose or commit the password.
5. Confirm the deployed Edge Function versions match the reviewed branch before enabling booking or notification traffic.
6. Configure `config.js` with only the project's HTTPS URL and publishable/anon key. Never place service-role keys, bot tokens or WhatsApp access tokens in browser files.
7. Set the exact public website origin in `ALLOWED_ORIGINS`.
8. Verify admin login, RLS denial cases, storage upload, booking/feedback writes and provider delivery in a controlled development environment before public activation.

## Edge Function secrets

Configure these in the Supabase project's server-side Edge Function secrets only:

- `ALLOWED_ORIGINS` — exact portfolio origin(s), comma-separated.
- `IP_HASH_SALT` — long random secret used for daily rotating privacy hashes.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_CHAT_ID`.
- `NOTIFY_CRON_SECRET` — long random secret (at least 16 characters) for the private notification retry worker.
- `WHATSAPP_PAID_MESSAGING_APPROVED` — leave **unset** (or anything other than the exact text `true`). While it is not `true`, no WhatsApp request is made, even if every other WhatsApp secret is present; such bookings are recorded as `not_configured`. Set it to `true` only after the owner has confirmed Meta's current pricing and approved the cost in writing.
- `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_OWNER_NUMBER`.
- `WHATSAPP_TEMPLATE_NAME` and optional `WHATSAPP_TEMPLATE_LANG`.
- `WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` for the signed webhook.

Supabase injects `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions. Do not copy these into the website or commit them. Do not paste secrets into chat.

## Telegram requirements

Create a private bot with BotFather, open the bot from the owner Telegram account, press Start, and securely determine the owner's chat ID. Set the token and chat ID as server-side secrets. A username alone is not sufficient for a bot to send a direct message to a user who has never started the bot.

## WhatsApp requirements

Use the official WhatsApp Business Cloud API. The business phone number, access token, phone-number ID and an approved outbound message template are required. Configure the webhook and verify delivery receipts. A normal wa.me link does not provide automatic server-side delivery. Keep the paid-messaging approval flag unset until costs are confirmed and explicitly approved.

## Automatic notification retries

A newly saved booking triggers an immediate notification attempt. The retry queue also needs a scheduler; the Edge Function does not schedule itself.

After deploying `process-notifications` and setting the server-side `NOTIFY_CRON_SECRET`, configure Supabase Cron or a trusted server-side scheduler to send a **POST every minute** to:

`https://<PROJECT_REF>.supabase.co/functions/v1/process-notifications`

Request headers:

- `content-type: application/json`
- `x-cron-secret: <the exact NOTIFY_CRON_SECRET value>`

Request body: `{}`

Keep the secret in the scheduler's protected secret store. Never put it in website JavaScript, a public GitHub file, a browser request, or a URL. Do not use the service-role key as the scheduler credential. The endpoint rejects requests without the matching secret and processes a bounded batch of due notifications.

Before public activation, test a failed delivery in the dedicated development project and verify that the scheduled worker retries it, updates its status, and stops at the configured attempt limit. WhatsApp final delivery/read status is confirmed separately by the signed webhook.

## Booking delivery selection (approved policy, 2026-11-18)

- The customer chooses Telegram **or** WhatsApp on the booking form. The Edge Function rejects a missing/unknown choice, and the database stores it and creates exactly one delivery row for that channel (`unique (booking_id, channel)`), so a booking cannot notify twice.
- **Telegram is the free operational channel** and works as soon as `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_CHAT_ID` are set and the owner has started the bot.
- **WhatsApp is prepared but cost-gated.** Until paid messaging is explicitly approved, a booking that chose WhatsApp is still saved and shown in the admin inbox with a `not_configured` delivery; nothing is sent. Re-queue it only after the owner approves paid delivery.
- Each channel's result is recorded independently. "Sent" means the provider accepted the message; WhatsApp "delivered" only comes from the signed webhook. Telegram does not report delivery.

## Test and deployment gates

- SQL tests run only against a throw-away local PostgreSQL database; the script refuses a remote `PGHOST`.
- The database suite applies every migration in filename order, reapplies them, and compares schema dumps to check idempotency.
- Edge Function unit tests use fake database/provider dependencies; they do not prove live Telegram or WhatsApp delivery.
- Public browser tests use a mocked backend; they do not prove real Supabase connectivity.
- Do not treat green mock tests as production verification.
- Keep Stage 8 on its feature branch. Do not merge to `main` or publish a production deployment without explicit owner approval.
