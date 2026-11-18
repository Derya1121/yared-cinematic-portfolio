# Stage 8 setup and safety notes

**Status (2026-11-18):** The dedicated development Supabase project `lyeccydsfwjtxhpkhukh` is independently reachable and reports `ACTIVE_HEALTHY`. Migration `20261117184931 / stage8_cms_admin` is recorded in the live migration history. Five Edge Functions are registered and active. The owner-only follow-up migration `20261118000000_stage8_owner_only_security.sql` is **not applied**.

**Live security gate:** the current live `private.is_admin()` still allows active editor accounts through checks that request the editor role. Several content, project, media and storage policies use that helper. The dashboard refuses editor accounts, but database authorization is not yet consistent. There are currently zero Auth users and zero `admin_users` rows. Do not create the owner account or activate the admin until the owner-only migration is reviewed and explicitly applied. The live `private.app_config` table also does not yet have RLS enabled; the follow-up migration enables it.

The live Security Advisor reports two RLS-enabled tables without policies (`public.analytics_events`, `private.rate_limits`), one public `get_public_site()` SECURITY DEFINER warning, and six authenticated SECURITY DEFINER warnings. The public RPC returns published site data by design. The admin RPCs contain authorization checks; their warnings still require review and should not be mistaken for a clean Advisor report.

**Critical deployed-code mismatch (verified 2026-11-18):** all five live Edge Functions currently run version 1 and bundle an older `_shared/notify.ts` that does not contain the `WHATSAPP_PAID_MESSAGING_APPROVED === "true"` guard present on the reviewed GitHub branch. Therefore the WhatsApp cost gate is **not active in the deployed functions**. Do not add WhatsApp credentials or submit WhatsApp-channel test bookings. Redeploy the reviewed shared notification code to the development project only after explicit owner approval, then re-fetch each deployed function and verify the guard is present before any WhatsApp credentials are configured.

The database has no `cron.job` relation, so the Supabase pg_cron scheduler is not installed. An external scheduler has not been verified. Notification retries are therefore not considered operational until a scheduler is configured and a safe retry test succeeds.

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
