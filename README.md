# Yared — Cinematic Personal Portfolio

A responsive, cinematic black-and-gold personal portfolio for Yared — Founder & Technology Innovator.

## Current foundation

- Cinematic hero and animated intro
- Responsive navigation and mobile layout
- Portrait frame prepared for the owner's supplied photograph
- About, expertise, selected work, services and contact sections
- External Design Intelligence Demo link to https://www.uupm.cc/#styles
- Email, WhatsApp and social profile links
- Scroll reveal and reduced-motion support

## Local preview

This is a static HTML/CSS/JavaScript site. Open `index.html` in a browser or serve the repository root with any static web server.

## Required asset

Place the approved portrait at:

`assets/yared-portrait.jpg`

The image itself has not yet been committed to this repository. Do not replace it with a generated or stock portrait.

## Project demo links

The AUREX AI, DERYA CAPITAL, Rent Manager and DERYA PULSE AI cards are currently informational showcases. Add a verified live URL to each card only after confirming the destination and what it demonstrates.

The supplied UI UX Pro Max / UUPM resource is linked as an external resource. This portfolio does not copy its proprietary source, branding or content.

## Not yet implemented

- Persistent booking backend and admin booking management
- Live multilingual AI assistant and server-side model integration
- Verified live demo URLs for the four project cards
- Deployment and production verification

Do not present these pending features as operational until integrated and tested.

## Contact

- Email: yed024691@gmail.com
- WhatsApp: https://wa.me/251902389561
- Telegram: https://t.me/Deryacapital
- Instagram: https://instagram.com/Derya_Capital
- TikTok: https://www.tiktok.com/@derya_capital444

## Cinematic enhancement layer

Added on branch `claude/cinematic-frontend-polish` on top of the foundation. `styles.css` and `app.js` are unchanged; the layer lives in two extra files loaded after them, so removing the `cinematic.css` link and `cinematic.js` script tag returns the exact foundation look.

- `cinematic.css` — motion, portrait presentation, header, responsive and accessibility refinements
- `cinematic.js` — optional behaviour (intro skip, headline line reveal, portrait parallax, active nav, scroll progress, menu accessibility)

What it adds:

- Intro curtain wipe that plays once per session; click or Esc skips it
- Hero sequence: headline lines rise from a mask, then the supporting copy settles in
- Portrait: viewfinder corner marks, slow light sweep, pointer-driven depth parallax (mouse/trackpad only), 4:5 aspect ratio that scales at every width, caption aligned to the frame
- Sticky header that tightens on scroll, active-section highlight, scroll progress line
- Featured project spans the grid on wide screens
- Fixes: 200px hidden horizontal overflow, caption colliding with the portrait frame, infinite animations looping at 0.01ms under reduced motion, intro ignoring reduced motion
- Accessibility: skip link, visible keyboard focus, `aria-expanded` on the menu button, Esc and outside-click to close the menu, 44px menu touch target, higher-contrast micro text

The portrait is still not included. Add the approved photo at `assets/yared-portrait.jpg` (4:5 works best); the placeholder disappears automatically once it loads.

## Stage 6: 3D cinematic layer

Added on branch `claude/stage6-3d-cinematic`, based on Stage 5 (`e4def2e`). Nothing from Stage 5 or earlier was edited except `index.html` (small additive changes) and this README. The layer is two extra files loaded last; remove the `stage6.css` link and `stage6.js` script tag to return to Stage 5 exactly.

- `stage6.css` — CSS 3D hero, liquid-glass panels, card tilt styles, entrances, low-power and reduced-motion rules
- `stage6.js` — gold light field (canvas), scroll parallax, card tilt, entrances, performance governor. No dependencies.

What it adds:

- **Hero:** perspective stage with three tilted gyroscope rings, floating glass tags at different depths, a perspective gold floor grid, dimensional lettering on the gold headline word, and pointer-driven 3D tilt of the portrait frame (touch devices get a slow breathing tilt instead)
- **Light:** drifting gold embers on three depth layers, occasional comet trails, and a short light trail behind a mouse pointer
- **Project panels:** liquid-glass surface, 3D tilt, pointer-following glare and rim light, layered depth inside each card, flip-in when a category filter changes
- **Motion:** scroll parallax at different rates, camera-style section entrances, a hairline of light drawn at each section
- **Header:** floating glass pill navigation on desktop

Performance and accessibility:

- Low-end mode starts automatically for data-saver, 2 GB memory or 2 CPU cores, and a frame-time governor switches to it (then stops the canvas) if frames are slow. Low-end mode freezes the rings and floating tags, removes the third ring, floor grid, comet and pointer trails and the heavy blurs, and halves the ember count.
- `prefers-reduced-motion` removes all of the above and shows a single still frame of embers.
- All new decorative elements are `aria-hidden` and ignore the pointer. Keyboard focus rings are unchanged and visible.
- With JavaScript disabled the page shows all content.

Facebook: the link was removed from the site's social links. The Facebook account itself is untouched. To restore it, re-add the anchor from git history (commit before this change) in `index.html`.

Unchanged and still pending: the booking preview stays marked NOT LIVE and the assistant preview NOT CONNECTED. No portrait, screenshots, testimonials, demo URLs or backend were added.

## Stage 7: immersive 3D cinematic experience

Branch `claude/stage7-immersive-3d-inbox`, based on Stage 6 (`15e4643`). Two new files loaded last (`stage7.css`, `stage7.js`); `index.html` was restructured into scenes and `stage6.js` gained a small particle-palette hook (defaults unchanged). Remove the `stage7` link/script to return to Stage 6 behaviour.

- **Intro:** dimensional DERYA (stacked 3D letters), warp light trails, gyro rings, camera push-through into the page. About 5.6 s, 3.6 s on low-end. Skip button, Esc/Enter/Space or click. Plays once per session, never under reduced motion, 9 s failsafe.
- **Colour:** ink base with iris, aqua, ember and rose light; the page ambience changes per scene. Legacy gold tokens are re-mapped.
- **Scenes:** cover, introduction (+ portrait), selected work, capabilities, profile (+ portrait), contact. Sections enter and leave with a camera move; a scene rail (desktop) shows position.
- **Selected work:** covers are cinematic 3D panels in a reel. Desktop: vertical scroll drives the reel sideways (pinned). Touch, tablet, low-end and reduced motion: native swipe with snap. Category filters still work and re-measure the reel.
- **Technology:** CSS 3D and one canvas (the Stage 6 light field). No WebGL, no libraries, so there is nothing to fall back from.

Portrait: no approved photo is in the repository. Three slots (cover, introduction, profile) all read `assets/yared-portrait.jpg` and show a clear "PORTRAIT PENDING" state until it exists. Nothing is generated or substituted.

Not implemented (unchanged): booking stays NOT LIVE and the assistant NOT CONNECTED. No inbox, backend or database was added in this commit.

## Stage 8: private admin foundation (development deployment)

Branch: `claude/stage8-cms-admin`. This branch remains isolated from `main` and preserves the Stage 7 visual base.

Implemented in the branch:
- CMS/admin schema, booking/feedback/analytics RPCs and scratch-Postgres tests.
- Public-site CMS hooks and booking/feedback forms, kept disabled until the owner configures the approved public origin and public Supabase key.
- Private `/admin/` owner portal: sign-in, overview, content drafts/publish, project management, media, booking inbox, feedback inbox, analytics, activity and notification retry controls.
- Owner-only database authorization migration, now applied to the dedicated development Supabase project.
- Five active development Edge Functions, deployed at version 2 with the current shared handlers. The WhatsApp paid-send gate is present in every deployed function and remains closed unless the owner explicitly sets the approval secret to the exact value `true`.

Development backend status (verified 2026-11-18):
- Dedicated Supabase project `lyeccydsfwjtxhpkhukh` is `ACTIVE_HEALTHY`.
- Base CMS migration and owner-only security migration are applied.
- `private.app_config` has RLS enabled; `private.is_admin()` permits active owners only and enforces the configured MFA requirement.
- All five Edge Functions are active, version 2. No provider credentials were added and no real messages were sent.
- Public signup is disabled. There are still zero Auth users and zero owner rows; owner invitation and account verification remain to be completed.
- The website's `config.js` intentionally remains empty, so the public site still labels backend forms NOT LIVE until the owner approves the final host origin and the public URL/anon key are configured.
- Notification retries need a protected external scheduler; Supabase pg_cron is not installed.
- Telegram delivery, WhatsApp webhook delivery, real bookings, live admin sign-in and real browser-to-Supabase end-to-end behavior have not yet been verified.

Still pending before delivery:
- Add the owner's approved portrait at `assets/yared-portrait.jpg`; it is not in the repository.
- Confirm the final hosting domain and add it to the Edge Function `ALLOWED_ORIGINS` secret.
- Configure `config.js` with only the Supabase project URL and publishable/anon key.
- Invite the owner at the approved email, then add that Auth UUID to `public.admin_users` with role `owner` and active status.
- Configure Telegram server-side secrets and perform a safe, explicitly authorized test. Keep WhatsApp paid messaging disabled unless the owner separately approves Meta pricing and charges.
- Configure the protected retry scheduler and test one safe retry.
- Run the GitHub Actions checks and browser tests against the actual hosted preview, then review the remaining Security Advisor warnings.

See [Stage 8 setup and safety notes](docs/STAGE8_SETUP.md). Do not merge this branch to `main` or deploy production without separate owner approval.
