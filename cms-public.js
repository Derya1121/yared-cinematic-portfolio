/* Stage 8 public layer: CMS content, projects, booking + private-feedback forms, privacy-friendly analytics.
   Everything here is OPTIONAL. With an empty config.js nothing is fetched, nothing is changed and the forms
   stay disabled and labelled NOT LIVE. All CMS text is written with textContent (never innerHTML).
   Only the public project URL + publishable key are used; no secret ever reaches this file. */
(function () {
  'use strict';
  var cfg = window.DERYA_CONFIG || {};
  var BASE = String(cfg.supabaseUrl || '').replace(/\/+$/, '');
  var KEY = String(cfg.supabaseAnonKey || '');
  var CONFIGURED = /^https:\/\/[^\s/]+$/.test(BASE) && KEY.length > 20;
  var doc = document;
  function q(s, r) { return (r || doc).querySelector(s); }
  function qa(s, r) { return Array.prototype.slice.call((r || doc).querySelectorAll(s)); }
  function store(k, v) { try { sessionStorage.setItem(k, v); } catch (e) {} }
  function stored(k) { try { return sessionStorage.getItem(k); } catch (e) { return null; } }
  var IMG = /^(projects|site)\/[A-Za-z0-9_.\/-]{1,150}\.(jpg|jpeg|png|webp|avif)$/;
  function safeUrl(u) { return typeof u === 'string' && /^https:\/\/[^\s<>"']+$/.test(u) && !/facebook|fb\.com|fb\.me/i.test(u) ? u : null; }
  function mediaUrl(p) { return IMG.test(p) && p.indexOf('..') < 0 ? BASE + '/storage/v1/object/public/portfolio-media/' + p.split('/').map(encodeURIComponent).join('/') : null; }
  var ACC = { aqua: ['#46e3d1', '#d6fff9'], ember: ['#ff8a5c', '#ffe2d2'], rose: ['#ff5fa2', '#ffd9ea'] };

  /* ---------------- content ---------------- */
  function applyContent(c) {
    qa('[data-cms]').forEach(function (el) {
      var k = el.getAttribute('data-cms');
      if (Object.prototype.hasOwnProperty.call(c, k) && typeof c[k] === 'string') { el.textContent = c[k]; if (el.hasAttribute('hidden') && c[k]) el.hidden = false; }
    });
    qa('[data-cms-href]').forEach(function (a) {
      var k = a.getAttribute('data-cms-href'), v = c[k], href = null;
      if (typeof v !== 'string' || !v) return;
      if (k === 'contact.email') href = /^[^\s@<>"']+@[^\s@<>"']+$/.test(v) ? 'mailto:' + v : null;
      else if (k === 'contact.whatsapp') href = /^\+[1-9]\d{7,14}$/.test(v) ? 'https://wa.me/' + v.slice(1) : null;
      else href = safeUrl(v);
      if (href) a.setAttribute('href', href);
    });
    qa('[data-cms-src]').forEach(function (img) {
      var v = c[img.getAttribute('data-cms-src')], u = typeof v === 'string' && v ? mediaUrl(v) : null;
      if (!u) return;
      img.style.display = ''; img.src = u;
      var p = img.parentElement; if (p) { p.classList.remove('is-pending'); p.classList.remove('portrait-pending'); }
    });
    var vis = { accent: c['visual.accent'], effects: c['visual.effects'], intro: c['visual.intro'] };
    if (ACC[vis.accent]) { doc.documentElement.style.setProperty('--gold', ACC[vis.accent][0]); doc.documentElement.style.setProperty('--gold2', ACC[vis.accent][1]); }
    // effects / intro are read by cms-boot.js on the NEXT visit, before the Stage 6/7 scripts run
    try { localStorage.setItem('derya-cms-visual', JSON.stringify(vis)); } catch (e) {}
  }

  /* ---------------- projects ---------------- */
  var CAT = { ai: 'AI', business: 'BUSINESS', software: 'SOFTWARE' };
  function syncProjects(list) {
    var track = q('.s7-reel-track'); if (!track || !Array.isArray(list) || !list.length) return;
    var existing = {}; qa('.project-card', track).forEach(function (c) { existing[c.getAttribute('data-slug') || ''] = c; });
    var keep = {};
    list.forEach(function (p, i) {
      if (!p || typeof p.slug !== 'string') return;
      var card = existing[p.slug], fresh = false;
      if (!card) {
        var tpl = q('.project-card[data-accent="' + p.accent + '"]', track) || q('.project-card', track);
        if (!tpl) return;
        card = tpl.cloneNode(true); fresh = true; card.setAttribute('data-slug', p.slug); card.hidden = false;
        qa('.s8-demo, .s8-thumb', card).forEach(function (n) { n.remove(); });
        var art = q('.project-art', card), t = String(p.title || '');
        var w = q('.art-word', art); if (w) w.textContent = t.toUpperCase().slice(0, 14);
        var sy = q('.art-symbol', art); if (sy) sy.textContent = (t.charAt(0) || 'D').toUpperCase() + '.';
        var rw = q('.rent-window', art); if (rw) rw.textContent = t;
        var sm = q('small', art); if (sm) sm.textContent = (CAT[p.category] || '').toUpperCase();
      }
      keep[p.slug] = card;
      card.setAttribute('data-project-category', p.category); card.setAttribute('data-accent', p.accent);
      var ty = q('.project-type', card); if (ty) ty.textContent = p.type_label || CAT[p.category] || '';
      var h = q('h3', card); if (h) h.textContent = p.title;
      var sp = q('.project-meta p', card); if (sp) sp.textContent = p.summary || '';
      var num = q('.project-number', card); if (num) num.textContent = ('0' + (i + 1)).slice(-2);
      var note = q('.status-note', card), demo = safeUrl(p.demo_url), old = q('.s8-demo', card);
      if (old) old.remove();
      if (demo && note) {
        var a = doc.createElement('a'); a.className = 's8-demo'; a.href = demo; a.target = '_blank'; a.rel = 'noopener noreferrer';
        a.setAttribute('data-demo', p.slug); a.textContent = 'View live demo ↗'; note.hidden = true; note.parentNode.insertBefore(a, note.nextSibling);
      } else if (note) note.hidden = false;
      var th = q('.s8-thumb', card), tu = p.thumbnail_path ? mediaUrl(p.thumbnail_path) : null;
      if (th) th.remove();
      if (tu) { var im = doc.createElement('img'); im.className = 's8-thumb'; im.alt = ''; im.loading = 'lazy'; im.decoding = 'async'; im.src = tu; im.onerror = function () { im.remove(); }; var ar = q('.project-art', card); if (ar) ar.insertBefore(im, ar.firstChild); }
      track.appendChild(card);
      if (fresh && window.__s6BindTilt) window.__s6BindTilt(card);
    });
    // a published list is authoritative: cards the owner unpublished/archived are removed, not merely hidden
    Object.keys(existing).forEach(function (s) { if (!keep[s]) existing[s].remove(); });
    var st = q('#project-filter-status'); if (st) st.textContent = 'Showing all ' + Object.keys(keep).length + ' projects.';
    if (window.__s6Remeasure) window.__s6Remeasure();
    qa('.project-card', track).forEach(observeProject);
  }

  /* ---------------- analytics (no cookies, no raw IP/UA stored, honours DNT/GPC) ---------------- */
  var LIVE_FN = false;
  function dnt() { return navigator.doNotTrack === '1' || window.doNotTrack === '1' || navigator.globalPrivacyControl === true; }
  function track(ev, extra) {
    if (!CONFIGURED || dnt()) return;
    var body = JSON.stringify(Object.assign({ event: ev }, extra || {})), url = BASE + '/functions/v1/track-event';
    try { if (navigator.sendBeacon && navigator.sendBeacon(url, new Blob([body], { type: 'text/plain;charset=UTF-8' }))) return; } catch (e) {}
    try { fetch(url, { method: 'POST', body: body, headers: { 'content-type': 'text/plain;charset=UTF-8' }, keepalive: true }).catch(function () {}); } catch (e) {}
  }
  var io = null, seen = {};
  function observeProject(card) {
    if (!CONFIGURED || !('IntersectionObserver' in window)) return;
    io = io || new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        var s = e.target.getAttribute('data-slug');
        if (e.isIntersecting && s && !seen[s] && !stored('s8-pv-' + s)) { seen[s] = 1; store('s8-pv-' + s, '1'); track('project_view', { project: s, path: '#work' }); }
      });
    }, { threshold: 0.6 });
    io.observe(card);
  }
  doc.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('.s8-demo, [data-contact]'); if (!a) return;
    if (a.classList.contains('s8-demo')) track('demo_click', { project: a.getAttribute('data-demo'), path: '#work' });
    else track('contact_click', { target: a.getAttribute('data-contact'), path: '#contact' });
  }, true);

  /* ---------------- forms ---------------- */
  function fnUrl(n) { return BASE + '/functions/v1/' + n; }
  function rid() { var a = new Uint8Array(16); (window.crypto || window.msCrypto).getRandomValues(a); return Array.prototype.map.call(a, function (b) { return ('0' + b.toString(16)).slice(-2); }).join(''); }
  var MSG = {
    name: 'Please enter your name.', delivery_channel: 'Choose Telegram or WhatsApp for the booking notification.', email: 'That email address does not look right.', whatsapp: 'Use international format, e.g. +251912345678.',
    service: 'Please choose a service.', description: 'Please describe what you need (at least 10 characters).', contact_required: 'Add an email or a WhatsApp number so I can reply.',
    message: 'Please write a message (at least 5 characters).', category: 'Please choose a topic.', budget: 'Please pick a budget option.'
  };
  function setupForm(form, fn, kind) {
    var fields = q('[data-s8-fields]', form), state = q('[data-s8-state]', form), note = q('[data-s8-note]', form), status = q('[data-s8-status]', form), btn = q('.s8-submit', form);
    var firstTouch = 0, key = rid();
    fetch(fnUrl(fn) + '?health=1', { method: 'GET' }).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) {
      if (!j || j.ok !== true) return;
      fields.disabled = false; form.classList.add('is-live');
      state.lastChild.textContent = ' OPEN';
      note.textContent = kind === 'booking' ? 'Requests are saved to a private inbox and answered personally.' : 'Feedback is private. It is stored for the owner only and never shown on this site.';
      if (kind === 'booking') {
        var card = q('#booking-preview-title'); card = card && card.closest('.capability-card');
        if (card) { var s = q('.capability-status', card); if (s && s.lastChild) s.lastChild.textContent = ' OPEN'; var p = card.querySelectorAll('p')[1]; if (p) p.textContent = 'Booking is open: use the form below. Requests are saved to a private inbox.'; }
      }
    }).catch(function () { /* stays NOT LIVE */ });
    form.addEventListener('focusin', function () { if (!firstTouch) firstTouch = Date.now(); });
    form.addEventListener('submit', function (e) {
      e.preventDefault(); if (fields.disabled || btn.disabled) return;
      var d = {}; qa('input, select, textarea', form).forEach(function (el) { if (el.name) d[el.name] = el.value.trim(); });
      var err = null, bad = null;
      if (kind === 'booking') {
        if (!d.name) err = 'name'; else if (d.delivery_channel !== 'telegram' && d.delivery_channel !== 'whatsapp') err = 'delivery_channel'; else if (!d.email && !d.whatsapp) err = 'contact_required';
        else if (d.email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(d.email)) err = 'email';
        else if (d.whatsapp && !/^\+[1-9][0-9\s().-]{7,18}$/.test(d.whatsapp)) err = 'whatsapp';
        else if (!d.service) err = 'service'; else if (d.description.length < 10) err = 'description';
      } else if (d.message.length < 5) err = 'message';
      if (err) { bad = err === 'contact_required' ? 'email' : err; status.textContent = MSG[err]; status.className = 's8-status is-error'; var f = form.elements[bad]; if (f && f.focus) f.focus(); return; }
      btn.disabled = true; status.className = 's8-status'; status.textContent = 'Sending…';
      // The server treats a form completed in under ~3 s as automated. Autofill can beat that, so wait it out.
      var wait = Math.max(0, 3500 - (Date.now() - (firstTouch || Date.now())));
      setTimeout(function () {
        var payload = Object.assign({}, d, { t: firstTouch || Date.now() - 4000, client_key: key });
        fetch(fnUrl(fn), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(payload) })
          .then(function (r) { return r.json().catch(function () { return {}; }).then(function (j) { return { s: r.status, j: j }; }); })
          .then(function (o) {
            if (o.s === 200 && o.j && o.j.saved) {
              status.className = 's8-status is-ok';
              status.textContent = (o.j.duplicate ? 'This was already saved. ' : 'Saved. ') + 'Your reference is ' + o.j.reference + '.' + (kind === 'booking' ? ' Your request is saved. I will reply using your contact details.' : ' Thank you.');
              form.reset(); key = rid(); firstTouch = 0;
            } else if (o.s === 422) {
              status.className = 's8-status is-error'; status.textContent = MSG[o.j.reason === 'contact_required' ? 'contact_required' : o.j.field] || 'Please check the form and try again.';
              var g = o.j.field && form.elements[o.j.field]; if (g && g.focus) g.focus();
            } else if (o.s === 429) { status.className = 's8-status is-error'; status.textContent = 'Too many requests from this connection. Nothing was saved. Please try again later.'; }
            else { status.className = 's8-status is-error'; status.textContent = 'Nothing was saved. Please try again, or use Email, WhatsApp or Telegram below.'; }
          })
          .catch(function () { status.className = 's8-status is-error'; status.textContent = 'Nothing was saved (network problem). Please try again, or use Email, WhatsApp or Telegram below.'; })
          .then(function () { btn.disabled = false; });
      }, wait);
    });
  }

  /* ---------------- boot ---------------- */
  if (!CONFIGURED) return;
  var path = location.pathname.replace(/index\.html$/, '') || '/';
  track('page_view', { path: path.length <= 100 && /^[\/A-Za-z0-9_.-]*$/.test(path) ? path : '/' });
  var bf = q('#s8-booking'), ff = q('#s8-feedback');
  if (bf) setupForm(bf, 'submit-booking', 'booking');
  if (ff) setupForm(ff, 'submit-feedback', 'feedback');
  fetch(BASE + '/rest/v1/rpc/get_public_site', { method: 'POST', headers: { apikey: KEY, 'content-type': 'application/json' }, body: '{}' })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (site) {
      if (!site || typeof site !== 'object') return;
      if (site.content && typeof site.content === 'object') applyContent(site.content);
      syncProjects(site.projects);
    }).catch(function () { /* the static Stage 7 page stays exactly as it is */ });
})();
