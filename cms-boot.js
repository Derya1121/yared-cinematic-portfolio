/* Runs before the Stage 5-7 scripts. Applies the owner's cached visual settings (accent colour,
   calm effects, intro on/off) so there is no flash and the Stage 7 intro/low-end logic can honour them.
   Cached from the last successful CMS fetch; absent cache = untouched Stage 7 behaviour. */
(function () {
  try {
    var raw = localStorage.getItem('derya-cms-visual'); if (!raw) return;
    var v = JSON.parse(raw), r = document.documentElement;
    var ACC = { aqua: ['#46e3d1', '#d6fff9'], ember: ['#ff8a5c', '#ffe2d2'], rose: ['#ff5fa2', '#ffd9ea'] };
    if (ACC[v.accent]) { r.style.setProperty('--gold', ACC[v.accent][0]); r.style.setProperty('--gold2', ACC[v.accent][1]); }
    if (v.effects === 'calm') r.classList.add('lite');
    if (v.intro === 'off') { r.classList.remove('s7-intro'); r.classList.add('intro-seen'); }
  } catch (e) {}
})();
