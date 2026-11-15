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
