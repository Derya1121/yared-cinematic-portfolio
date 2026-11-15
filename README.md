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
- Facebook: https://www.facebook.com/profile.php?id=61595421795326
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
