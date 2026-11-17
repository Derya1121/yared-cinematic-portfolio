# Stage 8 setup and safety notes

**Status: prepared only. No Supabase project has been created or modified. No migration or Edge Function has been deployed.**

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
- `WHATSAPP_ACCESS_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_OWNER_NUMBER`.
- `WHATSAPP_TEMPLATE_NAME` and optional `WHATSAPP_TEMPLATE_LANG`.
- `WHATSAPP_APP_SECRET` and `WHATSAPP_VERIFY_TOKEN` for the signed webhook.
- `NOTIFY_CRON_SECRET` for the private notification retry worker.

Supabase injects `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions. Do not copy these into the website or commit them.

## Telegram requirements

Create a private bot with BotFather, open the bot from the owner Telegram account, press Start, and securely determine the owner's chat ID. Set the token and chat ID as server-side secrets. A username alone is not sufficient for a bot to send a direct message to a user who has never started the bot.

## WhatsApp requirements

Use the official WhatsApp Business Cloud API. The business phone number, access token, phone-number ID and an approved outbound message template are required. Configure the webhook and verify delivery receipts. A normal wa.me link does not provide automatic server-side delivery.

## Booking delivery selection

The public booking form requires the customer to choose Telegram or WhatsApp. The Edge Function rejects missing/unsupported choices, and the database stores the selected channel and creates one delivery row for that channel only. The database column has a Telegram default for internal compatibility, but the public Edge Function does not accept a missing choice. Verify this behaviour with the SQL and unit tests before deployment.

## Test and deployment gates

- SQL test script is designed for a throw-away local PostgreSQL database only; it explicitly refuses a remote PGHOST.
- Edge Function unit tests use fake database/provider dependencies; they do not prove live Telegram or WhatsApp delivery.
- Public browser tests use a mocked backend; they do not prove real Supabase connectivity.
- Do not treat a green mock test as production verification.
- Keep Stage 8 on its feature branch. Do not merge to main or publish a production deployment without explicit owner approval.
