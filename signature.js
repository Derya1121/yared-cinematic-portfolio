/* signature.js — DERYA startup signature.
 *
 * Timeline (about 3.6s, shorter in lite mode): letters are drawn one after another by a travelling
 * point of gold light that sheds particles, a swash underlines them, a sheen sweeps across, the
 * tagline appears, then the curtains part into the homepage.
 *
 * Safety: the page never depends on this script. The head script releases the overlay after a
 * timeout, reduced-motion users never see it, and Esc / Enter / Space / click / the Skip button
 * all end it immediately. While it runs, the page behind it is inert for keyboards and screen readers.
 */
(function () {
  'use strict';

  var root = document.documentElement;
  var intro = document.getElementById('derya-intro');
  if (!intro) return;

  function finishNow() { /* used when the intro is not going to run */
    root.classList.remove('intro-on'); root.classList.add('intro-done');
    if (intro.parentNode) intro.parentNode.removeChild(intro);
  }
  if (!root.classList.contains('intro-on')) { finishNow(); return; }

  if (window.__diTimer) clearTimeout(window.__diTimer);          // we own the lifecycle now
  var lite = root.classList.contains('lite');
  var svg = intro.querySelector('.di-sig');
  var canvas = intro.querySelector('.di-canvas');
  var tag = intro.querySelector('.di-tag');
  var skipBtn = intro.querySelector('.di-skip');
  var SVGNS = 'http://www.w3.org/2000/svg';
  var XLINK = 'http://www.w3.org/1999/xlink';

  /* ---- inert page while the overlay is up ---- */
  var inertEls = Array.prototype.slice.call(document.querySelectorAll('header.topbar, main, footer, .skip-link'));
  inertEls.forEach(function (el) { el.setAttribute('inert', ''); });

  /* ---- geometry: letters in the order they are signed ---- */
  var GROUP_X = 30;
  var SKEW = Math.tan(-8 * Math.PI / 180);
  var SPEED = lite ? 0.72 : 1;
  var plan = [
    { id: 'D', x: 20,  start: 0.10, dur: 0.62 },
    { id: 'E', x: 175, start: 0.52, dur: 0.66 },
    { id: 'R', x: 315, start: 0.95, dur: 0.70 },
    { id: 'Y', x: 470, start: 1.40, dur: 0.62 },
    { id: 'A', x: 618, start: 1.78, dur: 0.66 },
    { id: 'S', x: 0,   start: 2.20, dur: 0.62, swash: true }
  ].map(function (p) {
    return { id: p.id, x: p.x, start: p.start * SPEED, dur: p.dur * SPEED, swash: !!p.swash };
  });
  var T_FILL = 2.55 * SPEED, T_SHEEN = 2.95 * SPEED, T_TAG = 2.7 * SPEED, T_END = 3.65 * SPEED;

  /* ---- build the layered letters (extrusion, body, highlight, sheen) ---- */
  function use(id, attrs) {
    var u = document.createElementNS(SVGNS, 'use');
    u.setAttributeNS(XLINK, 'href', '#dl-' + id); u.setAttribute('href', '#dl-' + id);
    Object.keys(attrs).forEach(function (k) { u.setAttribute(k, attrs[k]); });
    return u;
  }
  function g(cls) { var e = document.createElementNS(SVGNS, 'g'); if (cls) e.setAttribute('class', cls); return e; }

  var defs = svg.querySelector('defs');
  var layers = [];   // per-letter drawable handles
  plan.forEach(function (p) {
    var host = svg.querySelector('.di-letter[data-letter="' + p.id + '"]');
    var paths = [];
    var depth = lite ? 3 : 6, i;

    // soft guide so the empty canvas reads as a signature line waiting to be drawn
    var guide = g(); guide.style.opacity = 0;
    guide.appendChild(use(p.id, { stroke: 'rgba(205,170,107,.16)', 'stroke-width': p.swash ? 1.5 : 1.4 }));
    host.appendChild(guide);

    var ext = g();                                    // 3D-like extrusion: dark offset copies
    for (i = depth; i >= 1; i--) {
      var e = use(p.id, { stroke: 'url(#diEdge)', 'stroke-width': p.swash ? 6 : 9, transform: 'translate(' + (i * 1.1) + ' ' + (i * 1.35) + ')' });
      ext.appendChild(e); paths.push(e);
    }
    host.appendChild(ext);

    var glow = use(p.id, { stroke: 'rgba(236,200,120,.30)', 'stroke-width': p.swash ? 11 : 16 });
    host.appendChild(glow); paths.push(glow);
    var body = use(p.id, { stroke: 'url(#diGold)', 'stroke-width': p.swash ? 4.4 : 9 });
    host.appendChild(body); paths.push(body);
    var hi = use(p.id, { stroke: '#fff4d8', 'stroke-width': p.swash ? 1 : 1.8, transform: 'translate(-1.6 -2)' });
    host.appendChild(hi); paths.push(hi);

    // sheen: its own gradient, offset into this letter's coordinate space
    var gid = 'diSheen' + p.id;
    var lg = document.createElementNS(SVGNS, 'linearGradient');
    lg.setAttribute('id', gid); lg.setAttribute('gradientUnits', 'userSpaceOnUse'); lg.setAttribute('x1', -300); lg.setAttribute('x2', -200); lg.setAttribute('y1', 0); lg.setAttribute('y2', 0);
    lg.innerHTML = '<stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".5" stop-color="#fffbe8" stop-opacity=".95"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>';
    defs.appendChild(lg);
    var sheen = use(p.id, { stroke: 'url(#' + gid + ')', 'stroke-width': p.swash ? 4.4 : 9 });
    host.appendChild(sheen);

    paths.forEach(function (n) { n.style.strokeDasharray = '1 1'; n.style.strokeDashoffset = 1; });
    var ref = defs.querySelector('#dl-' + p.id);
    layers.push({ p: p, guide: guide, paths: paths, sheen: sheen, grad: lg, ref: ref, len: ref.getTotalLength(), ext: ext });
    host.style.opacity = 1;
  });

  /* ---- particle field ---- */
  var ctx = canvas.getContext('2d');
  var dpr = Math.min(window.devicePixelRatio || 1, lite ? 1.25 : 2);
  var W = 0, H = 0, parts = [], dust = [];
  function resize() {
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  resize(); window.addEventListener('resize', resize);
  var DUST = lite ? 16 : 46, i;
  for (i = 0; i < DUST; i++) {
    dust.push({ x: Math.random(), y: Math.random(), r: .6 + Math.random() * 1.6, z: .2 + Math.random() * .8, a: .15 + Math.random() * .5, ph: Math.random() * 6.28 });
  }

  function toScreen(layer, t01) {
    var pt = layer.ref.getPointAtLength(layer.len * t01);
    var x = pt.x + SKEW * pt.y + layer.p.x + GROUP_X;
    var y = pt.y;
    if (layer.p.swash) { x = pt.x + GROUP_X; }
    var r = svg.getBoundingClientRect(), s = r.width / 800;
    return { x: r.left + x * s, y: r.top + y * s, s: s };
  }
  function spawn(sp, n) {
    for (var k = 0; k < n && parts.length < (lite ? 90 : 240); k++) {
      var a = Math.random() * 6.283, v = 10 + Math.random() * 60;
      parts.push({ x: sp.x, y: sp.y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 14, life: 0, max: .5 + Math.random() * .8, r: .7 + Math.random() * 1.8 });
    }
  }

  /* ---- animation loop (time based: slow devices drop frames, not duration) ---- */
  var t0 = performance.now(), last = t0, raf = 0, ended = false, tagOn = false, heads = [];
  function ease(x) { return x < 0 ? 0 : x > 1 ? 1 : 1 - Math.pow(1 - x, 3); }

  function frame(now) {
    if (ended) return;
    var t = (now - t0) / 1000, dt = Math.min(.05, (now - last) / 1000); last = now;
    heads.length = 0;

    layers.forEach(function (L) {
      var q = (t - L.p.start) / L.p.dur, e = ease(q);
      if (q > -.2) L.guide.style.opacity = Math.min(1, (q + .2) * 2);
      var off = (1 - e).toFixed(4);
      for (var k = 0; k < L.paths.length; k++) L.paths[k].style.strokeDashoffset = off;
      if (q > 0 && q < 1) heads.push(toScreen(L, e));
      // sheen sweep across each letter after the fill moment
      var sq = (t - T_SHEEN - L.p.start * .18) / (.7 * SPEED);
      if (sq > 0 && sq < 1) {
        var x0 = -260 + sq * 1000 - (L.p.swash ? 0 : L.p.x + GROUP_X);
        L.grad.setAttribute('x1', x0); L.grad.setAttribute('x2', x0 + 110);
      }
    });

    if (t > T_TAG && !tagOn) { tagOn = true; tag.classList.add('on'); }

    // draw
    ctx.clearRect(0, 0, W, H);
    ctx.globalCompositeOperation = 'lighter';
    var tt = now / 1000;
    for (i = 0; i < dust.length; i++) {
      var d = dust[i];
      var dx = Math.sin(tt * .25 * d.z + d.ph) * 14 * d.z, dy = ((d.y * H - tt * 8 * d.z) % H + H) % H;
      ctx.fillStyle = 'rgba(236,217,168,' + (d.a * (.5 + .5 * Math.sin(tt * .9 + d.ph)) * Math.min(1, t / .8)) + ')';
      ctx.beginPath(); ctx.arc(d.x * W + dx, dy, d.r * d.z, 0, 6.283); ctx.fill();
    }
    heads.forEach(function (h) {
      spawn(h, lite ? 1 : 3);
      var rad = 26 * h.s + 8;
      var grd = ctx.createRadialGradient(h.x, h.y, 0, h.x, h.y, rad);
      grd.addColorStop(0, 'rgba(255,244,216,.95)'); grd.addColorStop(.25, 'rgba(236,200,120,.55)'); grd.addColorStop(1, 'rgba(205,170,107,0)');
      ctx.fillStyle = grd; ctx.beginPath(); ctx.arc(h.x, h.y, rad, 0, 6.283); ctx.fill();
    });
    for (i = parts.length - 1; i >= 0; i--) {
      var p = parts[i]; p.life += dt;
      if (p.life >= p.max) { parts.splice(i, 1); continue; }
      p.x += p.vx * dt; p.y += p.vy * dt; p.vy += 22 * dt; p.vx *= .985;
      var a = 1 - p.life / p.max;
      ctx.fillStyle = 'rgba(246,222,160,' + (a * .85).toFixed(3) + ')';
      ctx.beginPath(); ctx.arc(p.x, p.y, p.r * (.4 + a * .6), 0, 6.283); ctx.fill();
    }
    ctx.globalCompositeOperation = 'source-over';

    if (t >= T_END) { leave(false); return; }
    raf = requestAnimationFrame(frame);
  }

  /* ---- ending ---- */
  var watchdog = setTimeout(function () { leave(true); }, 9000);
  function leave(fast) {
    if (ended) return; ended = true;
    cancelAnimationFrame(raf); clearTimeout(watchdog);
    window.removeEventListener('resize', resize);
    document.removeEventListener('keydown', onKey, true);
    try { sessionStorage.setItem('derya-intro', '1'); } catch (e) { /* storage unavailable */ }
    if (fast) intro.classList.add('is-fast');
    intro.classList.add('is-leaving');
    // start the hero sequence as the curtains begin to part
    setTimeout(function () { root.classList.add('intro-done'); }, fast ? 80 : 260);
    setTimeout(function () {
      root.classList.remove('intro-on');
      inertEls.forEach(function (el) { el.removeAttribute('inert'); });
      if (intro.parentNode) intro.parentNode.removeChild(intro);
      var main = document.getElementById('main');
      if (main) main.focus({ preventScroll: true });
    }, fast ? 520 : 1250);
  }

  function onKey(e) {
    if (e.key === 'Escape' || e.key === 'Enter' || e.key === ' ') { e.preventDefault(); leave(true); }
    else if (e.key === 'Tab') { e.preventDefault(); skipBtn.focus(); }
  }
  document.addEventListener('keydown', onKey, true);
  skipBtn.addEventListener('click', function (e) { e.stopPropagation(); leave(true); });
  intro.addEventListener('click', function () { leave(true); });

  skipBtn.focus({ preventScroll: true });
  raf = requestAnimationFrame(function (now) { t0 = last = now; frame(now); });
})();
