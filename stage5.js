/* Stage 5: frontend-only gallery filtering and optional desktop cursor light. */
(function () {
  'use strict';

  var filterGroup = document.querySelector('.project-filters');
  var filterButtons = Array.prototype.slice.call(document.querySelectorAll('[data-project-filter]'));
  var cards = Array.prototype.slice.call(document.querySelectorAll('[data-project-category]'));
  var status = document.getElementById('project-filter-status');

  if (filterGroup && filterButtons.length && cards.length) {
    var labelFor = function (filter) {
      return filter === 'all' ? 'all' : filter;
    };
    var applyFilter = function (filter) {
      var shown = 0;
      cards.forEach(function (card) {
        var visible = filter === 'all' || card.getAttribute('data-project-category') === filter;
        card.hidden = !visible;
        if (visible) shown += 1;
      });
      filterButtons.forEach(function (button) {
        button.setAttribute('aria-pressed', button.getAttribute('data-project-filter') === filter ? 'true' : 'false');
      });
      if (status) {
        status.textContent = filter === 'all'
          ? 'Showing all four projects.'
          : 'Showing ' + shown + ' ' + labelFor(filter) + (shown === 1 ? ' project.' : ' projects.');
      }
    };
    filterButtons.forEach(function (button) {
      button.addEventListener('click', function () {
        applyFilter(button.getAttribute('data-project-filter'));
      });
    });
    filterGroup.hidden = false;
  }

  var reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  var finePointer = window.matchMedia('(hover: hover) and (pointer: fine)').matches;
  if (!reduced && finePointer) {
    var glow = document.createElement('span');
    glow.className = 'cursor-glow';
    glow.setAttribute('aria-hidden', 'true');
    document.body.appendChild(glow);
    var frame = 0;
    var x = 0;
    var y = 0;
    var paint = function () {
      glow.style.transform = 'translate3d(' + x + 'px,' + y + 'px,0) translate3d(-50%,-50%,0)';
      frame = 0;
    };
    document.addEventListener('pointermove', function (event) {
      x = event.clientX;
      y = event.clientY;
      document.body.classList.add('cursor-ready');
      if (!frame) frame = window.requestAnimationFrame(paint);
    }, { passive: true });
    document.addEventListener('pointerover', function (event) {
      var target = event.target;
      if (target && target.closest && target.closest('a, button, [role="button"]')) {
        glow.classList.add('is-interactive');
      }
    });
    document.addEventListener('pointerout', function (event) {
      var next = event.relatedTarget;
      if (!next || !next.closest || !next.closest('a, button, [role="button"]')) {
        glow.classList.remove('is-interactive');
      }
    });
  }
})();
