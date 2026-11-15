/* cinematic.js — enhancement layer. Loaded after app.js; never edits it.
   Every feature is optional: if this file fails, the foundation site still works. */
(function () {
  'use strict';

  var root = document.documentElement;
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var finePointer = window.matchMedia('(hover: hover) and (pointer: fine)').matches;

  function rememberIntro() {
    try { sessionStorage.setItem('yared-intro', '1'); } catch (e) { /* storage unavailable */ }
  }

  /* ---- Intro: play once per session; click or Esc skips it ---- */
  var intro = document.getElementById('intro');
  if (intro) {
    var skip = function () { root.classList.add('intro-skip'); rememberIntro(); };
    intro.addEventListener('click', skip);
    intro.addEventListener('animationend', function (e) {
      if (e.target === intro && e.animationName === 'introCurtain') rememberIntro();
    });
    window.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && document.body.contains(intro)) skip();
    });
  }

  /* ---- Hero headline: split into masked lines for the rise-in ---- */
  var h1 = document.querySelector('.hero h1');
  if (h1 && !h1.querySelector('.line')) {
    var esc = function (s) {
      return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    };
    var lines = [''];
    Array.prototype.forEach.call(h1.childNodes, function (n) {
      if (n.nodeName === 'BR') lines.push('');
      else if (n.nodeType === 3) lines[lines.length - 1] += esc(n.textContent);
      else if (n.nodeType === 1) lines[lines.length - 1] += n.outerHTML;
    });
    h1.innerHTML = lines.map(function (l, i) {
      return '<span class="line"><span class="line-in" style="--l:' + i + '">' + l + '</span></span>';
    }).join('');
  }

  /* ---- Portrait: if the asset is missing, make sure the placeholder shows ---- */
  var img = document.querySelector('.portrait-frame img');
  if (img && img.complete && img.naturalWidth === 0) {
    img.style.display = 'none';
    img.parentElement.classList.add('portrait-pending');
  }

  /* ---- Portrait depth parallax (mouse/trackpad only, never with reduced motion) ---- */
  var hero = document.getElementById('home');
  var wrap = document.querySelector('.portrait-wrap');
  if (hero && wrap && finePointer && !reduceMotion) {
    var tx = 0, ty = 0, cx = 0, cy = 0, raf = 0;
    var step = function () {
      cx += (tx - cx) * 0.08;
      cy += (ty - cy) * 0.08;
      wrap.style.setProperty('--px', cx.toFixed(4));
      wrap.style.setProperty('--py', cy.toFixed(4));
      raf = (Math.abs(tx - cx) > 0.001 || Math.abs(ty - cy) > 0.001) ? requestAnimationFrame(step) : 0;
    };
    var kick = function () { if (!raf) raf = requestAnimationFrame(step); };
    hero.addEventListener('pointermove', function (e) {
      var r = hero.getBoundingClientRect();
      tx = ((e.clientX - r.left) / r.width - 0.5) * 2;
      ty = ((e.clientY - r.top) / r.height - 0.5) * 2;
      kick();
    });
    hero.addEventListener('pointerleave', function () { tx = 0; ty = 0; kick(); });
  }

  /* ---- Scroll progress + header state ---- */
  var bar = document.createElement('div');
  bar.className = 'scroll-progress';
  bar.setAttribute('aria-hidden', 'true');
  document.body.appendChild(bar);

  var ticking = false;
  var onScroll = function () {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(function () {
      var y = window.scrollY || root.scrollTop;
      var max = root.scrollHeight - root.clientHeight;
      bar.style.setProperty('--p', max > 0 ? Math.min(1, y / max).toFixed(4) : 0);
      root.classList.toggle('is-scrolled', y > 24);
      ticking = false;
    });
  };
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  /* ---- Active section in the navigation ---- */
  var links = Array.prototype.slice.call(document.querySelectorAll('#nav a[href^="#"]'));
  var byId = {};
  links.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });
  var ids = ['home'].concat(Object.keys(byId));
  var sections = ids.map(function (id) { return document.getElementById(id); }).filter(Boolean);

  if ('IntersectionObserver' in window && sections.length) {
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        links.forEach(function (l) { l.classList.remove('is-active'); l.removeAttribute('aria-current'); });
        var active = byId[entry.target.id];
        if (active) { active.classList.add('is-active'); active.setAttribute('aria-current', 'true'); }
      });
    }, { rootMargin: '-45% 0px -50% 0px' });
    sections.forEach(function (s) { spy.observe(s); });
  }

  /* ---- Mobile menu accessibility: aria state, Esc, outside click ---- */
  var toggle = document.getElementById('menuToggle');
  var nav = document.getElementById('nav');
  if (toggle && nav) {
    toggle.setAttribute('aria-controls', 'nav');
    var sync = function () {
      toggle.setAttribute('aria-expanded', nav.classList.contains('open') ? 'true' : 'false');
    };
    sync();
    new MutationObserver(sync).observe(nav, { attributes: true, attributeFilter: ['class'] });

    document.addEventListener('keydown', function (e) {
      if (e.key === 'Escape' && nav.classList.contains('open')) {
        nav.classList.remove('open');
        toggle.focus();
      }
    });
    document.addEventListener('click', function (e) {
      if (nav.classList.contains('open') && !nav.contains(e.target) && !toggle.contains(e.target)) {
        nav.classList.remove('open');
      }
    });
  }
})();
