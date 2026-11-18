# Stage 8 setup and safety notes

**Status (2026-11-18): the owner reports a dedicated dev project `lyeccydsfwjtxhpkhukh` exists with the migration applied and five functions deployed. That has NOT been independently verified from this repository's tooling (the assistant's Supabase connector has no access to that project). Owner account, notification secrets and the retry schedule are still pending, and no notification channel may be called live until a real test message is received.**

## Repository

- Repository: `Derya1121/yared-cinematic-portfolio`
- Feature branch: `claude/stage8-cms-admin`
- Public site: existing Stage 7 foundation plus Stage 8 public integration.
- Private admin: `/admin/` (static interface; requires the dedicated Supabase backend).

## Before any live setup

1. Create a dedicated Supabase project for YARED Portfolio. Do not reuse DERYA BOT, AUREX AI, Rent Manager or any other project.
2. Keep the new project isolated and development-first.
3. Review `supabase/migrations/20261117000000_stage8_cms_admin.sql` and the SQL test suite.
4. Run the migration only after the owner explicitly approves the project and migration.
5. Create the owner account with Supabase Auth after signup is disabled. Then insert that user's Auth UUID into `public.admin_users` with role `owner` and `active = true`. Never expose or commit the password.
6. Deploy the Edge Functions only after the schema is applied and secrets are configured.
7. Configure `config.js` with only the project's HTTPS URL and publishable/anon key. Never place service-role keys, bot tokens or WhatsApp access tokens in browser files.
8. Set the exact public website origin in `ALLOWED_ORIGINS`.
9. Verify the admin login, RLS denial cases, storage upload, booking/feedback writes and provider delivery in a controlled test environment before public activation.

## Edge Function secrets

Configure these in the Supabase project's server-side Edge Function secrets only:

- `ALLOWED_ORIGINS` — exact portfolio origin(s), comma-separated.
- `IP_HASH_SALT` — long random secret used for daily rotating privacy hashes.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_CHAT_ID`.
- `WHATSAPP_PAID_MESSAGING_APPROVED` — leave **unset** (or anything other than the exact text `true`). While it is not `true`, no WhatsApp request is ever made, even if every other WhatsApp secret is present; such bookings are recorded as `not_configured` in the admin inbox. Set it to `true` only after the owner has confirmed Meta's current pricing and approved the cost in writing.
- `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_OWNER_NUMBER`.
- `WHATSAPP_TEMPLATE_NAME` and optional `WHATSAPP_TEMPLATE_LANG`.
- `WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` for the signed webhook.
- `NOTIFY_CRON_SECRET` for the private notification retry worker.

Supabase injects `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions. Do not copy these into the website or commit them.

## Telegram requirements

Create a private bot with BotFather, open the bot from the owner Telegram account, press Start, and securely determine the owner's chat ID. Set the token and chat ID as server-side secrets. A username alone is not sufficient for a bot to send a direct message to a user who has never started the bot.

## WhatsApp requirements

Use the official WhatsApp Business Cloud API. The business phone number, access token, phone-number ID and an approved outbound message template are required. Configure the webhook and verify delivery receipts. A normal wa.me link does not provide automatic server-side delivery.

## Automatic notification retries (required for live delivery)

A newly saved booking triggers an immediate notification attempt. The retry queue also needs a scheduler; the Edge Function does not schedule itself.

After deploying `process-notifications` and setting the server-side `NOTIFY_CRON_SECRET`, configure Supabase Cron or a trusted server-side scheduler to send a **POST every minute** to:

`https://<PROJECT_REF>.supabase.co/functions/v1/process-notifications`

Request headers:

- `content-type: application/json`
- `x-cron-secret: <the exact NOTIFY_CRON_SECRET value>`

Request body: `{}`

Keep the secret in the scheduler's protected secret store. Never put it in website JavaScript, a public GitHub file, a browser request, or a URL. Do not use the service-role key as the scheduler credential. The endpoint rejects requests without the matching secret and processes a bounded batch of due notifications.

Before public activation, test a failed delivery in the dedicated development project and verify that the scheduled worker retries it, updates its status, and stops at the configured attempt limit. WhatsApp final delivery/read status is still confirmed separately by the signed webhook.

## Booking delivery selection (approved policy, 2026-11-18)

- The customer chooses Telegram **or** WhatsApp on the booking form. The Edge Function rejects a missing/unknown choice, and the database stores it and creates exactly one delivery row for that channel (`unique (booking_id, channel)`), so a booking can never notify twice.
- **Telegram is the free operational channel** and works as soon as `TELEGRAM_BOT_TOKEN` and `TELEGRAM_OWNER_CHAT_ID` are set.
- **WhatsApp is prepared but cost-gated** (see `WHATSAPP_PAID_MESSAGING_APPROVED` above). Until approved, a booking that chose WhatsApp is still saved and shown in the admin inbox with a `not_configured` delivery; nothing is sent. Re-queue it from the admin once approved.
- Each channel's result is recorded on its own; "sent" means the provider accepted the message, and WhatsApp "delivered" only comes from the signed webhook. Telegram never reports delivery.

## Test and deployment gates

- SQL test script is designed for a throw-away local PostgreSQL database only; it explicitly refuses a remote PGHOST.
- Edge Function unit tests use fake database/provider dependencies; they do not prove live Telegram or WhatsApp delivery.
- Public browser tests use a mocked backend; they do not prove real Supabase connectivity.
- Do not treat a green mock test as production verification.
- Keep Stage 8 on its feature branch. Do not merge to main or publish a production deployment without explicit owner approval.
