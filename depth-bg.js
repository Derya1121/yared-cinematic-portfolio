/* depth-bg.js — desktop-only cinematic background: soft gold light, drifting gold motes on three depths, and a few
   thin gold wireframe solids that turn slowly and respond to scrolling. One canvas, ~40 fps cap, paused when the tab
   is hidden, and it switches itself off if the machine struggles. Everything is optional: if this file fails, the
   page is unchanged. */
(function () {
  'use strict';
  var root = document.documentElement;
  var mq = window.matchMedia('(min-width: 1024px) and (hover: hover) and (pointer: fine) and (prefers-reduced-motion: no-preference)');
  var canvas = null, ctx = null, W = 0, H = 0, dpr = 1, raf = 0, running = false, last = 0, slow = 0, dead = false;
  var sy = window.scrollY || 0, docH = 1, px = 0, py = 0, tpx = 0, tpy = 0, motes = [], sprite = null;

  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }

  // wireframe solids as [vertices, edges]
  var SOLIDS = {
    octa: [[[1,0,0],[-1,0,0],[0,1,0],[0,-1,0],[0,0,1],[0,0,-1]],
           [[0,2],[0,3],[0,4],[0,5],[1,2],[1,3],[1,4],[1,5],[2,4],[2,5],[3,4],[3,5]]],
    cube: [[[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]],
           [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]],
    tetra: [[[1,1,1],[-1,-1,1],[-1,1,-1],[1,-1,-1]], [[0,1],[0,2],[0,3],[1,2],[1,3],[2,3]]]
  };
  function ring(n) { var v = [], e = []; for (var i = 0; i < n; i++) { var a = i / n * 6.2832; v.push([Math.cos(a), Math.sin(a), 0]); e.push([i, (i + 1) % n]); } return [v, e]; }
  SOLIDS.ring = ring(48);

  // placed toward the edges so they frame, never cover, the content. x,y in 0..1 of the viewport; z = depth (1 near)
  var items = [
    { s: 'octa',  x: .07, y: .22, z: .85, r: 74, ax: .00045, ay: .0007,  sc: .00028 },
    { s: 'cube',  x: .93, y: .38, z: .62, r: 60, ax: .0006,  ay: -.0005, sc: -.00022 },
    { s: 'ring',  x: .90, y: .80, z: .9,  r: 96, ax: .0004,  ay: .0003,  sc: .0003 },
    { s: 'tetra', x: .12, y: .74, z: .5,  r: 52, ax: -.0005, ay: .0006,  sc: -.00026 },
    { s: 'octa',  x: .52, y: .93, z: .38, r: 40, ax: .0007,  ay: -.0004, sc: .00018 }
  ];

  function makeSprite() {
    var s = document.createElement('canvas'); s.width = s.height = 48;
    var c = s.getContext('2d'), g = c.createRadialGradient(24, 24, 0, 24, 24, 24);
    g.addColorStop(0, 'rgba(255,244,214,1)'); g.addColorStop(.25, 'rgba(240,215,160,.5)'); g.addColorStop(1, 'rgba(201,168,106,0)');
    c.fillStyle = g; c.fillRect(0, 0, 48, 48); return s;
  }
  function makeMote(initial) {
    return { x: Math.random(), y: initial ? Math.random() : 1.05, z: .15 + Math.random() * .85, ph: Math.random() * 6.283, sp: .006 + Math.random() * .012 };
  }
  function resize() {
    if (!canvas) return;
    dpr = Math.min(window.devicePixelRatio || 1, 1.5);
    W = window.innerWidth; H = window.innerHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    docH = Math.max(1, document.documentElement.scrollHeight - H);
    var want = clamp(Math.round(W * H / 38000), 26, 54);
    while (motes.length < want) motes.push(makeMote(true));
    motes.length = want;
  }

  function project(v, rx, ry) {
    var x = v[0], y = v[1], z = v[2], c = Math.cos(rx), s = Math.sin(rx);
    var y1 = y * c - z * s, z1 = y * s + z * c; c = Math.cos(ry); s = Math.sin(ry);
    var x2 = x * c + z1 * s, z2 = -x * s + z1 * c, f = 3.2 / (3.2 + z2);
    return [x2 * f, y1 * f, f];
  }
  function drawSolid(it, t) {
    var def = SOLIDS[it.s], verts = def[0], edges = def[1];
    var depthShift = (sy * (.05 + .1 * it.z)) % (H * 1.4);                 // nearer solids drift further as you scroll
    var cx = it.x * W + px * it.z * 22, cy = ((it.y * H - depthShift) % (H * 1.3) + H * 1.3) % (H * 1.3) - H * .15 + py * it.z * 14;
    var rx = t * it.ax + sy * it.sc * 2.2, ry = t * it.ay + sy * it.sc * 3;
    var size = it.r * (.55 + it.z * .6), alpha = .08 + it.z * .16;
    var P = verts.map(function (v) { var p = project(v, rx, ry); return [cx + p[0] * size, cy + p[1] * size, p[2]]; });
    ctx.lineWidth = 1; ctx.lineCap = 'round';
    for (var i = 0; i < edges.length; i++) {
      var a = P[edges[i][0]], b = P[edges[i][1]], k = (a[2] + b[2]) / 2;
      ctx.strokeStyle = 'rgba(226,192,120,' + (alpha * clamp(k * .9, .4, 1.2)).toFixed(3) + ')';
      ctx.beginPath(); ctx.moveTo(a[0], a[1]); ctx.lineTo(b[0], b[1]); ctx.stroke();
    }
    ctx.globalCompositeOperation = 'lighter';
    for (var j = 0; j < P.length; j += (it.s === 'ring' ? 12 : 1)) { ctx.globalAlpha = alpha * 2.2; ctx.drawImage(sprite, P[j][0] - 5, P[j][1] - 5, 10, 10); }
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
  }

  function draw(t, dt) {
    ctx.clearRect(0, 0, W, H);
    // atmospheric light: a warm pool that travels down the page as you scroll
    var prog = clamp(sy / docH, 0, 1);
    var gx = W * (.78 - .46 * prog), gy = H * (.22 + .5 * prog), gr = Math.max(W, H) * .55;
    var g = ctx.createRadialGradient(gx + px * 40, gy + py * 30, 0, gx, gy, gr);
    g.addColorStop(0, 'rgba(201,168,106,.10)'); g.addColorStop(.5, 'rgba(160,120,50,.04)'); g.addColorStop(1, 'rgba(201,168,106,0)');
    ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
    for (var i = 0; i < items.length; i++) drawSolid(items[i], t);
    ctx.globalCompositeOperation = 'lighter';
    for (var k = 0; k < motes.length; k++) {
      var m = motes[k];
      m.y -= m.sp * dt * .9; if (m.y < -.05) { m.y = 1.05; m.x = Math.random(); }
      var x = m.x * W + Math.sin(t * .00025 + m.ph) * 14 * m.z + px * m.z * 26;
      var y = (((m.y * H - sy * m.z * .14) % H) + H) % H + py * m.z * 16;
      var r = 1.6 + m.z * 5, tw = .55 + .45 * Math.sin(t * .0011 * (.6 + m.z) + m.ph);
      ctx.globalAlpha = (.1 + m.z * .42) * tw;
      ctx.drawImage(sprite, x - r, y - r, r * 2, r * 2);
    }
    ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over';
  }

  function loop(now) {
    if (!running) return;
    raf = requestAnimationFrame(loop);
    var ms = now - last;
    if (ms < 24) return;                                   // ~40 fps cap
    last = now;
    if (ms > 38) slow++; else slow = Math.max(0, slow - 2);
    if (slow > 90) { dead = true; stop(); canvas.style.display = 'none'; return; }
    px += (tpx - px) * .05; py += (tpy - py) * .05;
    draw(now, Math.min(ms, 60) / 16);
  }
  function start() {
    if (running || dead || !mq.matches || root.classList.contains('lite')) return;
    if (!canvas) {
      canvas = document.createElement('canvas'); canvas.className = 'depth-bg'; canvas.setAttribute('aria-hidden', 'true');
      document.body.insertBefore(canvas, document.body.firstChild);
      ctx = canvas.getContext('2d'); if (!ctx) { canvas.remove(); canvas = null; dead = true; return; }
      sprite = makeSprite();
    }
    resize(); running = true; last = performance.now(); raf = requestAnimationFrame(loop);
  }
  function stop() { running = false; cancelAnimationFrame(raf); }

  window.addEventListener('scroll', function () { sy = window.scrollY || 0; }, { passive: true });
  window.addEventListener('pointermove', function (e) { if (!running) return; tpx = (e.clientX / W - .5) * 2; tpy = (e.clientY / H - .5) * 2; }, { passive: true });
  var rt = 0;
  window.addEventListener('resize', function () { clearTimeout(rt); rt = setTimeout(function () { if (mq.matches) { if (running) resize(); else start(); } else stop(); }, 150); });
  document.addEventListener('visibilitychange', function () { if (document.hidden) stop(); else start(); });
  if (mq.addEventListener) mq.addEventListener('change', function () { if (mq.matches) start(); else stop(); });
  try { start(); } catch (err) { if (window.console) console.warn('[depth-bg] skipped:', err); }
})();
