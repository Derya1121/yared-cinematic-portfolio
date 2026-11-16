/* Stage 7: immersive 3D layer. No dependencies. Each module is isolated; a failure in one never stops the page.
   1 intro   2 hero depth   3 scenes (scroll camera + ambient colour + rail)   4 reel   5 portraits */
(function () {
  'use strict';

  var root = document.documentElement;
  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var fine = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  var isLite = function () { return root.classList.contains('lite'); };
  var clamp = function (v, a, b) { return v < a ? a : v > b ? b : v; };
  var $ = function (s, c) { return (c || document).querySelector(s); };
  var $$ = function (s, c) { return Array.prototype.slice.call((c || document).querySelectorAll(s)); };

  /* ====================================================================
     1. Intro: dimensional DERYA, warp light trails, camera push-through
     ==================================================================== */
  function intro() {
    var el = $('#s7-intro');
    if (!el || !root.classList.contains('s7-intro')) { if (el) el.remove(); return; }

    var lite = isLite();
    if (lite) el.classList.add('is-lite');

    // dimensional letters: stacked copies pushed back along Z
    var word = $('#s7-word'), layers = lite ? 5 : 9, letters = 'DERYA'.split('');
    letters.forEach(function (ch, n) {
      var l = document.createElement('span');
      l.className = 's7-l'; l.style.setProperty('--n', n);
      for (var k = 0; k < layers; k++) {
        var s = document.createElement('span');
        s.className = 's7-s' + (k === layers - 1 ? ' is-glow' : '');
        s.style.setProperty('--k', k); s.textContent = ch;
        l.appendChild(s);
      }
      word.appendChild(l);
    });

    var total = lite ? 3600 : 5600, ended = false, started = 0, raf = 0, timers = [];
    var canvas = $('.s7-warp', el), ctx = canvas && canvas.getContext && canvas.getContext('2d');
    var W = 0, H = 0, stars = [], speed = .0035, boost = 1;
    var cols = ['138,125,255', '70,227,209', '255,138,92', '230,232,255'];

    function size() {
      var dpr = Math.min(window.devicePixelRatio || 1, lite ? 1 : 1.5);
      W = innerWidth; H = innerHeight;
      canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    function spawn(i) { return { a: Math.random() * 6.2832, z: Math.random() * .95 + .05, c: cols[i % cols.length], pz: 0 }; }
    if (ctx) {
      size();
      var count = lite ? 60 : 150;
      for (var i = 0; i < count; i++) stars.push(spawn(i));
      window.addEventListener('resize', size);
    }
    function draw(now) {
      if (ended) return;
      var t = now - started;
      // light trails accelerate as the camera pushes through the lettering
      var target = t < total * .62 ? 1 : 1 + (t - total * .62) / (total * .38) * 14;
      boost += (target - boost) * .08;
      ctx.fillStyle = 'rgba(2,3,10,' + (boost > 3 ? .35 : .22) + ')';
      ctx.fillRect(0, 0, W, H);
      ctx.globalCompositeOperation = 'lighter'; ctx.lineCap = 'round';
      var cx = W / 2, cy = H * .52, R = Math.max(W, H) * .75;
      for (var i = 0; i < stars.length; i++) {
        var s = stars[i];
        s.pz = s.z; s.z -= speed * boost;
        if (s.z <= .02) { stars[i] = spawn(i); stars[i].z = 1; continue; }
        var x0 = cx + Math.cos(s.a) * R * (.04 / s.pz), y0 = cy + Math.sin(s.a) * R * (.04 / s.pz);
        var x1 = cx + Math.cos(s.a) * R * (.04 / s.z), y1 = cy + Math.sin(s.a) * R * (.04 / s.z);
        var al = clamp(1 - s.z, 0, 1) * .85;
        ctx.strokeStyle = 'rgba(' + s.c + ',' + al.toFixed(3) + ')';
        ctx.lineWidth = .6 + (1 - s.z) * 2.2;
        ctx.beginPath(); ctx.moveTo(x0, y0); ctx.lineTo(x1, y1); ctx.stroke();
      }
      ctx.globalCompositeOperation = 'source-over';
      raf = requestAnimationFrame(draw);
    }

    function finish() {
      timers.forEach(clearTimeout); cancelAnimationFrame(raf);
      window.removeEventListener('resize', size);
      document.removeEventListener('keydown', onKey, true);
      try { sessionStorage.setItem('derya-s7-intro', '1'); } catch (e) { /* storage unavailable */ }
      root.classList.remove('s7-intro');
      el.remove();
      if (window.__s6Remeasure) window.__s6Remeasure();
      window.scrollTo(0, 0);
    }
    function end(fast) {
      if (ended) return; ended = true;
      el.classList.add(fast ? 'is-fast' : 'is-leave');
      timers.push(setTimeout(finish, fast ? 460 : 720));
    }
    function onKey(e) {
      if (e.key === 'Escape' || e.key === 'Enter' || e.key === ' ') { e.preventDefault(); end(true); }
    }

    $('#s7-skip', el).addEventListener('click', function () { end(true); });
    el.addEventListener('click', function () { end(true); });
    document.addEventListener('keydown', onKey, true);

    requestAnimationFrame(function () {
      started = performance.now();
      el.classList.add('is-run');
      try { $('#s7-skip', el).focus({ preventScroll: true }); } catch (e) { /* ignore */ }
      if (ctx) raf = requestAnimationFrame(draw);
      timers.push(setTimeout(function () { end(false); }, total));
    });
    document.addEventListener('visibilitychange', function () { if (document.hidden && !ended) end(true); });
  }

  /* ====================================================================
     2. Hero depth: pointer moves the floating objects and giant lettering
     ==================================================================== */
  function heroDepth() {
    var hero = $('.hero');
    if (!hero || reduced || !fine) return;
    var tx = 0, ty = 0, x = 0, y = 0, raf = 0;
    function loop() {
      x += (tx - x) * .08; y += (ty - y) * .08;
      hero.style.setProperty('--mx', x.toFixed(3)); hero.style.setProperty('--my', y.toFixed(3));
      raf = (Math.abs(tx - x) > .002 || Math.abs(ty - y) > .002) ? requestAnimationFrame(loop) : 0;
    }
    hero.addEventListener('pointermove', function (e) {
      if (isLite()) return;
      var r = hero.getBoundingClientRect();
      tx = clamp(((e.clientX - r.left) / r.width - .5) * 2, -1, 1);
      ty = clamp(((e.clientY - r.top) / r.height - .5) * 2, -1, 1);
      if (!raf) raf = requestAnimationFrame(loop);
    }, { passive: true });
    hero.addEventListener('pointerleave', function () { tx = 0; ty = 0; if (!raf) raf = requestAnimationFrame(loop); });
  }

  /* ====================================================================
     3. Scenes: camera move per section, ambient colour, scene rail
     ==================================================================== */
  function scenes() {
    var secs = $$('main > .section'), rail = $$('.s7-rail a'), ticking = false, current = '';
    var names = { home: 1, about: 1, work: 1, expertise: 1, services: 1, previews: 1, profile: 1, contact: 1 };
    var railMap = { home: 'home', about: 'about', work: 'work', expertise: 'expertise', services: 'expertise', previews: 'expertise', profile: 'profile', contact: 'contact' };
    var ease = function (t) { return t * t * (3 - 2 * t); };

    function update() {
      ticking = false;
      var vh = window.innerHeight, mid = vh * .5, active = '';
      var cam = !reduced && !isLite();
      secs.forEach(function (s) {
        var r = s.getBoundingClientRect();
        if (r.bottom < -vh * .5 || r.top > vh * 1.5) return;
        if (cam) {
          s.style.setProperty('--s7-in', (1 - ease(clamp((vh - r.top) / (vh * .55), 0, 1))).toFixed(3));
          s.style.setProperty('--s7-out', ease(clamp(1 - r.bottom / (vh * .55), 0, 1)).toFixed(3));
        }
        s.style.setProperty('--sp', clamp((vh - r.top) / (vh + r.height), 0, 1).toFixed(3));
        if (r.top <= mid && r.bottom > mid) active = s.getAttribute('data-scene') || '';
      });
      if (active && active !== current && names[active]) {
        current = active; root.setAttribute('data-scene', active);
        rail.forEach(function (a) {
          var on = a.getAttribute('data-scene') === railMap[active];
          a.classList.toggle('is-active', on);
          if (on) a.setAttribute('aria-current', 'true'); else a.removeAttribute('aria-current');
        });
      }
    }
    function request() { if (!ticking) { ticking = true; requestAnimationFrame(update); } }
    root.setAttribute('data-scene', 'home');
    window.addEventListener('scroll', request, { passive: true });
    window.addEventListener('resize', request);
    update();
  }

  /* ====================================================================
     4. Reel: pinned sideways scroll (desktop) or native swipe (everything else)
     ==================================================================== */
  function reel() {
    var wrap = $('#s7-reel'), track = wrap && $('.s7-reel-track', wrap);
    if (!wrap || !track) return;
    var bar = $('.s7-reel-bar i', wrap), mode = '', cards = [], ticking = false;

    function pinOK() { return window.innerWidth >= 1000 && fine && !reduced && !isLite(); }
    // stable content width from layout (scrollWidth would include our own 3D-rotated card extents)
    function trackWidth() {
      var last = cards[cards.length - 1];
      return last ? last.offsetLeft + last.offsetWidth + window.innerWidth * .10 : track.scrollWidth;
    }
    function visibleCards() { return $$('.project-card', track).filter(function (c) { return !c.hidden; }); }

    function layout() {
      cards = visibleCards();
      var want = pinOK() ? 'pin' : 'swipe';
      if (want !== mode) {
        mode = want;
        root.classList.toggle('s7-pin', mode === 'pin');
        track.style.transform = ''; track.scrollLeft = 0;
        if (mode === 'swipe') { track.setAttribute('tabindex', '0'); track.setAttribute('role', 'region'); track.setAttribute('aria-label', 'Selected projects. Use the arrow keys or swipe to move sideways.'); }
        else { track.removeAttribute('tabindex'); track.removeAttribute('role'); track.removeAttribute('aria-label'); }
      }
      if (mode === 'pin') {
        var travel = Math.max(0, trackWidth() - window.innerWidth + 40);
        wrap.style.setProperty('--reel-h', Math.round(travel + window.innerHeight) + 'px');
      } else { wrap.style.removeProperty('--reel-h'); }
      tick();
    }

    function tick() {
      ticking = false;
      var vw = window.innerWidth, x = 0, p = 0;
      if (mode === 'pin') {
        var r = wrap.getBoundingClientRect(), span = wrap.offsetHeight - window.innerHeight;
        p = span > 0 ? clamp(-r.top / span, 0, 1) : 0;
        x = -p * Math.max(0, trackWidth() - vw + 40);
        track.style.transform = 'translate3d(' + x.toFixed(1) + 'px,0,0)';
      } else {
        var max = track.scrollWidth - track.clientWidth;
        p = max > 0 ? track.scrollLeft / max : 0;
        x = -track.scrollLeft;
      }
      if (bar) bar.style.transform = 'scaleX(' + (.12 + p * .88).toFixed(3) + ')';
      // card centre in the viewport, computed from layout (offsetLeft) so our own transforms never feed back
      var left = (mode === 'pin' ? wrap : track).getBoundingClientRect().left;
      cards.forEach(function (c) {
        var centre = left + c.offsetLeft + c.offsetWidth / 2 + (mode === 'pin' ? x : -track.scrollLeft);
        var n = clamp((centre - vw / 2) / (vw * .55), -1.2, 1.2);
        c.style.setProperty('--c', n.toFixed(3)); c.style.setProperty('--ca', Math.abs(n).toFixed(3));
      });
    }
    function request() { if (!ticking) { ticking = true; requestAnimationFrame(tick); } }

    window.addEventListener('scroll', function () { if (mode === 'pin') request(); }, { passive: true });
    track.addEventListener('scroll', function () { if (mode === 'swipe') request(); }, { passive: true });
    window.addEventListener('resize', function () { layout(); });
    // filter changes hide / show cards: re-measure after the layout settles
    if ('MutationObserver' in window) {
      new MutationObserver(function () { setTimeout(function () { layout(); if (window.__s6Remeasure) window.__s6Remeasure(); }, 30); })
        .observe(track, { attributes: true, attributeFilter: ['hidden'], subtree: true });
    }
    window.addEventListener('load', layout);
    layout();
  }

  /* ====================================================================
     5. Portraits: pending state honesty + pointer depth on the figures
     ==================================================================== */
  function portraits() {
    $$('.s7-figure img').forEach(function (img) {
      var card = img.parentElement;
      if (img.complete && !img.naturalWidth && img.getAttribute('src')) { img.style.display = 'none'; card.classList.add('is-pending'); }
    });
    if (reduced || !fine) return;
    $$('[data-s7-figure]').forEach(function (fig) {
      var raf = 0, fx = 0, fy = 0;
      function paint() { fig.style.setProperty('--fx', fx.toFixed(3)); fig.style.setProperty('--fy', fy.toFixed(3)); raf = 0; }
      fig.addEventListener('pointermove', function (e) {
        if (isLite()) return;
        var r = fig.getBoundingClientRect();
        fx = clamp(((e.clientX - r.left) / r.width - .5) * 2, -1, 1); fy = clamp(((e.clientY - r.top) / r.height - .5) * 2, -1, 1);
        if (!raf) raf = requestAnimationFrame(paint);
      }, { passive: true });
      fig.addEventListener('pointerleave', function () { fx = 0; fy = 0; if (!raf) raf = requestAnimationFrame(paint); });
    });
  }

  [intro, heroDepth, scenes, reel, portraits].forEach(function (fn) {
    try { fn(); } catch (e) { if (window.console) console.warn('[stage7] ' + fn.name + ' skipped:', e && e.message); }
  });
})();
