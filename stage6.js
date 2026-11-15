/* stage6.js — 3D cinematic layer. Loaded after stage5.js; edits nothing in it.
 *
 * What it does
 *   1. Gold light field: drifting embers on three depth layers, occasional comet trails, and
 *      (mouse only) a short light trail behind the pointer.
 *   2. Scroll parallax: a handful of elements move at different rates.
 *   3. 3D tilt, glare and rim light on project cards.
 *   4. Camera-style entrances as sections scroll into view; cards flip in when a filter changes.
 *
 * Performance and safety
 *   - Reduced motion: one still frame of embers, nothing else runs.
 *   - Low-end: detected up front (save-data, <=2GB, <=2 cores) and at runtime (a frame-time
 *     governor switches the page to lite mode, and stops the canvas if it still struggles).
 *   - Every feature is optional. If this file fails, Stage 5 works unchanged.
 */
(function () {
  'use strict';

  var root = document.documentElement;
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var finePointer = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  var conn = navigator.connection || {};
  var lowEnd = !!(conn.saveData ||
    (navigator.deviceMemory && navigator.deviceMemory <= 2) ||
    (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 2));
  if (lowEnd) root.classList.add('lite');
  var isLite = function () { return root.classList.contains('lite'); };

  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }

  /* ======================================================================
     1. Gold light field
     ====================================================================== */
  var field = null;

  function makeSprite() {
    var s = document.createElement('canvas'); s.width = s.height = 64;
    var c = s.getContext('2d'), g = c.createRadialGradient(32, 32, 0, 32, 32, 32);
    g.addColorStop(0, 'rgba(255,244,216,1)');
    g.addColorStop(.22, 'rgba(236,200,125,.55)');
    g.addColorStop(1, 'rgba(205,170,107,0)');
    c.fillStyle = g; c.fillRect(0, 0, 64, 64);
    return s;
  }

  function startField() {
    var canvas = document.createElement('canvas');
    canvas.className = 'gold-field';
    canvas.setAttribute('aria-hidden', 'true');
    document.body.insertBefore(canvas, document.body.firstChild);
    var ctx = canvas.getContext('2d');
    if (!ctx) return;
    var sprite = makeSprite();

    var W = 0, H = 0, dpr = 1, motes = [], comets = [];
    var scrollY = window.scrollY || 0, px = 0, py = 0, tpx = 0, tpy = 0;
    var raf = 0, last = 0, nextComet = 2200, running = false, slow = 0, level = 0, acc = 0;

    function targetCount() {
      var n = clamp(Math.round((W * H) / 20000), 26, 96);
      if (!finePointer) n = Math.round(n * .55);
      if (isLite()) n = Math.round(n * .5);
      return Math.max(14, n);
    }
    function makeMote(initial) {
      return {
        x: Math.random(), y: initial ? Math.random() : 1.05, z: .15 + Math.random() * .85,
        ph: Math.random() * 6.283, sp: .004 + Math.random() * .014
      };
    }
    function resize() {
      dpr = Math.min(window.devicePixelRatio || 1, isLite() ? 1.25 : 1.75);
      W = window.innerWidth; H = window.innerHeight;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      var want = targetCount();
      while (motes.length < want) motes.push(makeMote(true));
      motes.length = want;
      if (!running) draw(0);                       // keep the still frame correct after a resize
    }

    function drawMotes(t) {
      ctx.globalCompositeOperation = 'lighter';
      for (var i = 0; i < motes.length; i++) {
        var m = motes[i];
        var x = m.x * W + px * m.z * 26;
        var y = (((m.y * H - scrollY * m.z * .16) % H) + H) % H + py * m.z * 16;
        var r = 2 + m.z * 7;
        var tw = reduced ? .8 : .55 + .45 * Math.sin(t * .0011 * (.6 + m.z) + m.ph);
        ctx.globalAlpha = (.12 + m.z * .5) * tw;
        ctx.drawImage(sprite, x - r, y - r, r * 2, r * 2);
      }
      ctx.globalAlpha = 1;
    }

    function spawnComet() {
      if (comets.length >= 2) return;
      var fromTop = Math.random() < .6;
      var ang = (24 + Math.random() * 18) * Math.PI / 180;           // heading down and to the left
      var speed = (W * .72) + Math.random() * W * .35;                // px / second
      comets.push({
        x: fromTop ? W * (.35 + Math.random() * .65) : W * 1.05,
        y: fromTop ? -20 : H * (.05 + Math.random() * .4),
        vx: -Math.cos(ang) * speed, vy: Math.sin(ang) * speed,
        age: 0, life: 1.15 + Math.random() * .5, len: 130 + Math.random() * 120
      });
    }
    function drawComets(dt) {
      ctx.globalCompositeOperation = 'lighter';
      for (var i = comets.length - 1; i >= 0; i--) {
        var c = comets[i]; c.age += dt;
        if (c.age > c.life) { comets.splice(i, 1); continue; }
        c.x += c.vx * dt; c.y += c.vy * dt;
        var k = Math.sin((c.age / c.life) * Math.PI);                 // fade in, then out
        var mag = Math.sqrt(c.vx * c.vx + c.vy * c.vy), tx = c.x - c.vx / mag * c.len, ty = c.y - c.vy / mag * c.len;
        var g = ctx.createLinearGradient(c.x, c.y, tx, ty);
        g.addColorStop(0, 'rgba(255,240,205,' + (.85 * k).toFixed(3) + ')');
        g.addColorStop(.35, 'rgba(231,196,120,' + (.3 * k).toFixed(3) + ')');
        g.addColorStop(1, 'rgba(205,170,107,0)');
        ctx.strokeStyle = g; ctx.lineWidth = 1.6; ctx.lineCap = 'round';
        ctx.beginPath(); ctx.moveTo(c.x, c.y); ctx.lineTo(tx, ty); ctx.stroke();
        ctx.globalAlpha = k; ctx.drawImage(sprite, c.x - 11, c.y - 11, 22, 22); ctx.globalAlpha = 1;
      }
    }

    function draw(t, dt) {
      ctx.globalCompositeOperation = 'source-over';
      ctx.clearRect(0, 0, W, H);
      drawMotes(t);
      if (dt && !reduced && !isLite()) drawComets(dt);
      ctx.globalCompositeOperation = 'source-over';
    }

    /* frame-time governor: slow devices lose effects before they lose smoothness */
    function govern(ms) {
      if (ms > 38) slow++; else slow = Math.max(0, slow - 2);
      if (slow > 50) {
        slow = 0; level++;
        if (level === 1) { root.classList.add('lite'); comets.length = 0; resize(); }
        else { stop(); canvas.style.display = 'none'; }
      }
    }

    function loop(now) {
      if (!running) return;
      var ms = now - last; last = now;
      var dt = Math.min(.05, ms / 1000);
      govern(ms);
      // lite / touch: draw at ~30fps
      if (isLite() || !finePointer) { acc += ms; if (acc < 30) { raf = requestAnimationFrame(loop); return; } acc = 0; }
      px += (tpx - px) * .06; py += (tpy - py) * .06;
      for (var i = 0; i < motes.length; i++) {
        var m = motes[i]; m.y -= m.sp * dt * 3.2; m.x += Math.sin(now * .0002 + m.ph) * .00006;
        if (m.y < -.05) { m.y = 1.05; m.x = Math.random(); }
      }
      nextComet -= ms;
      if (nextComet <= 0 && !isLite() && !document.hidden) { spawnComet(); nextComet = 2600 + Math.random() * 3600; }
      draw(now, dt);
      raf = requestAnimationFrame(loop);
    }
    function begin() { if (running || reduced) return; running = true; last = performance.now(); raf = requestAnimationFrame(loop); }
    function stop() { running = false; cancelAnimationFrame(raf); }

    window.addEventListener('scroll', function () {
      scrollY = window.scrollY || 0;
      if (!running) draw(0);
    }, { passive: true });
    var rt = 0;
    window.addEventListener('resize', function () { clearTimeout(rt); rt = setTimeout(resize, 150); });
    document.addEventListener('visibilitychange', function () { if (document.hidden) stop(); else begin(); });
    if (finePointer && !reduced) {
      window.addEventListener('pointermove', function (e) {
        tpx = (e.clientX / W - .5) * 2; tpy = (e.clientY / H - .5) * 2;
      }, { passive: true });
    }
    resize();
    if (reduced) draw(0); else begin();
    field = { stop: stop };
  }

  /* pointer light trail (mouse and pen only) */
  function startTrail() {
    if (reduced || !finePointer || isLite()) return;
    var canvas = document.createElement('canvas');
    canvas.className = 'gold-trail'; canvas.setAttribute('aria-hidden', 'true');
    document.body.appendChild(canvas);
    var ctx = canvas.getContext('2d'); if (!ctx) return;
    var W = 0, H = 0, dpr = 1, pts = [], raf = 0;
    function size() {
      dpr = Math.min(window.devicePixelRatio || 1, 1.5); W = innerWidth; H = innerHeight;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    size(); window.addEventListener('resize', size);
    function paint(now) {
      ctx.clearRect(0, 0, W, H);
      while (pts.length && now - pts[0].t > 520) pts.shift();
      if (pts.length > 1) {
        ctx.globalCompositeOperation = 'lighter'; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        for (var i = 1; i < pts.length; i++) {
          var a = 1 - (now - pts[i].t) / 520;
          ctx.strokeStyle = 'rgba(236,208,140,' + (a * .55).toFixed(3) + ')';
          ctx.lineWidth = 1 + a * 2.2;
          ctx.beginPath(); ctx.moveTo(pts[i - 1].x, pts[i - 1].y); ctx.lineTo(pts[i].x, pts[i].y); ctx.stroke();
        }
      }
      raf = pts.length ? requestAnimationFrame(paint) : 0;
    }
    window.addEventListener('pointermove', function (e) {
      if (e.pointerType === 'touch' || isLite()) return;
      pts.push({ x: e.clientX, y: e.clientY, t: performance.now() });
      if (pts.length > 26) pts.shift();
      if (!raf) raf = requestAnimationFrame(paint);
    }, { passive: true });
  }

  /* ======================================================================
     2. Scroll parallax
     ====================================================================== */
  function startParallax() {
    if (reduced || isLite()) return;
    var plan = [
      ['.hero-copy', -0.05], ['.portrait-wrap', 0.07],
      ['.statement h2', -0.045], ['.section-heading h2', -0.035],
      ['.project-card:nth-child(odd)', 0.05], ['.project-card:nth-child(even)', -0.04],
      ['.external-demo', -0.03], ['.capability-card:nth-child(2)', 0.04]
    ];
    var items = [];
    plan.forEach(function (p) {
      Array.prototype.forEach.call(document.querySelectorAll(p[0]), function (el) { items.push({ el: el, d: p[1], c: 0, on: false }); });
    });
    if (!items.length) return;

    function pageCenter(el) {                       // layout position, unaffected by our own transforms
      var y = 0, h = el.offsetHeight, n = el;
      while (n) { y += n.offsetTop; n = n.offsetParent; }
      return y + h / 2;
    }
    function measure() { items.forEach(function (it) { it.c = pageCenter(it.el); }); }

    var vh = innerHeight, sy = scrollY, ticking = false;
    function apply() {
      ticking = false;
      var mid = sy + vh / 2;
      for (var i = 0; i < items.length; i++) {
        var it = items[i]; if (!it.on) continue;
        it.el.style.translate = '0 ' + clamp((it.c - mid) * it.d, -46, 46).toFixed(1) + 'px';
      }
    }
    function request() { sy = window.scrollY || 0; if (!ticking) { ticking = true; requestAnimationFrame(apply); } }

    if ('IntersectionObserver' in window) {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          for (var i = 0; i < items.length; i++) if (items[i].el === e.target) { items[i].on = e.isIntersecting; }
        });
        request();
      }, { rootMargin: '25% 0px 25% 0px' });
      items.forEach(function (it) { io.observe(it.el); });
    } else { items.forEach(function (it) { it.on = true; }); }

    measure(); request();
    window.addEventListener('scroll', request, { passive: true });
    window.addEventListener('resize', function () { vh = innerHeight; measure(); request(); });
    window.addEventListener('load', function () { measure(); request(); });
    if ('ResizeObserver' in window) { new ResizeObserver(function () { measure(); request(); }).observe(document.body); }
    window.__s6Remeasure = function () { measure(); request(); };
  }

  /* ======================================================================
     3. Card tilt (mouse, pen; brief press-tilt on touch)
     ====================================================================== */
  function startTilt() {
    if (reduced) return;
    Array.prototype.forEach.call(document.querySelectorAll('.project-card'), function (card) {
      var raf = 0, nx = 0, ny = 0, pressed = false;
      function paint() {
        raf = 0;
        card.style.setProperty('--tx', (-ny * 11).toFixed(2) + 'deg');
        card.style.setProperty('--ty', (nx * 13).toFixed(2) + 'deg');
        card.style.setProperty('--gx', ((nx + .5) * 100).toFixed(1) + '%');
        card.style.setProperty('--gy', ((ny + .5) * 100).toFixed(1) + '%');
        card.style.setProperty('--rim', (Math.atan2(ny, nx) * 180 / Math.PI + 90).toFixed(0) + 'deg');
      }
      function move(e) {
        if (e.pointerType === 'touch' && !pressed) return;
        var r = card.getBoundingClientRect();
        nx = clamp((e.clientX - r.left) / r.width - .5, -.5, .5);
        ny = clamp((e.clientY - r.top) / r.height - .5, -.5, .5);
        card.classList.add('is-tilting');
        if (!raf) raf = requestAnimationFrame(paint);
      }
      function rest() {
        pressed = false; nx = 0; ny = 0;
        card.classList.remove('is-tilting');
        if (!raf) raf = requestAnimationFrame(paint);
      }
      card.addEventListener('pointermove', move);
      card.addEventListener('pointerdown', function (e) { if (e.pointerType === 'touch') { pressed = true; move(e); } });
      ['pointerleave', 'pointerup', 'pointercancel'].forEach(function (n) { card.addEventListener(n, rest); });
    });
  }

  /* ======================================================================
     4. Entrances + filter flip
     ====================================================================== */
  function startEntrances() {
    var sections = Array.prototype.slice.call(document.querySelectorAll('.section:not(.hero)'));
    if (!('IntersectionObserver' in window)) return;

    if (!reduced) {
      var targets = '.section-heading, .statement .eyebrow, .statement h2, .statement-bottom, .expertise-grid article, ' +
        '.project-filters, .project-card, .external-demo, .service-list > div, .capability-card, .contact > *';
      var els = Array.prototype.slice.call(document.querySelectorAll(targets));
      var seen = new Map();
      var rev = new IntersectionObserver(function (entries) {
        entries.forEach(function (e) {
          if (!e.isIntersecting) return;
          e.target.classList.add('s6-in'); rev.unobserve(e.target);
        });
      }, { threshold: .12, rootMargin: '0px 0px -6% 0px' });
      els.forEach(function (el) {
        var p = el.parentElement, i = seen.get(p) || 0; seen.set(p, i + 1);
        el.style.setProperty('--i', Math.min(i, 5));
        el.classList.add('s6-r'); rev.observe(el);
      });
      root.classList.add('s6-js');
      // safety net: never leave content hidden if the observer is delayed
      setTimeout(function () {
        els.forEach(function (el) {
          var r = el.getBoundingClientRect();
          if (r.top < innerHeight * 1.1) el.classList.add('s6-in');
        });
      }, 2500);
    }

    var seenSections = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add('s6-seen'); seenSections.unobserve(e.target); } });
    }, { threshold: .08 });
    sections.forEach(function (s) { seenSections.observe(s); });

    // flip cards in when a category filter reveals them (Stage 5 toggles the hidden attribute)
    var grid = document.querySelector('.project-grid');
    if (grid && !reduced && 'MutationObserver' in window) {
      new MutationObserver(function (list) {
        list.forEach(function (m) {
          var card = m.target;
          if (m.attributeName !== 'hidden' || card.hidden || !card.classList.contains('project-card')) return;
          card.classList.remove('s6-flip'); void card.offsetWidth; card.classList.add('s6-flip');
          card.addEventListener('animationend', function done() { card.classList.remove('s6-flip'); card.removeEventListener('animationend', done); });
        });
        if (window.__s6Remeasure) window.__s6Remeasure();
      }).observe(grid, { attributes: true, attributeFilter: ['hidden'], subtree: true });
    }
  }

  /* ---- start everything, each part isolated so one failure cannot stop the rest ---- */
  [startField, startTrail, startParallax, startTilt, startEntrances].forEach(function (fn) {
    try { fn(); } catch (err) { if (window.console) console.warn('[stage6] ' + fn.name + ' skipped:', err); }
  });
})();
