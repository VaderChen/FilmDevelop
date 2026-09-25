(function () {
  'use strict';
  window.PhotoSidebarReorder = function (options) {
    var drag = null, frame = null, suppressClickUntil = 0;
    var root = options.root;
    function row(node) { return node instanceof Element ? node.closest('.sidebar-style[data-select-style]') : null; }
    function clearMarker() {
      root.querySelectorAll('.reorder-before,.reorder-after').forEach(function (node) {
        node.classList.remove('reorder-before', 'reorder-after');
      });
    }
    function cancel() {
      cancelAnimationFrame(frame); frame = null;
      if (!drag) return;
      var previous = drag; drag = null;
      if (previous.moved) suppressClickUntil = performance.now() + 250;
      clearMarker();
      previous.button.classList.remove('reordering');
      if (previous.button.hasPointerCapture(previous.pointer)) previous.button.releasePointerCapture(previous.pointer);
    }
    function locate() {
      clearMarker(); drag.target = null;
      var bounds = drag.list.getBoundingClientRect();
      if (drag.x < bounds.left || drag.x > bounds.right || drag.y < bounds.top || drag.y > bounds.bottom) return;
      // Group boundaries and Original's fixed position cannot be crossed.
      var target = row(document.elementFromPoint(drag.x, drag.y));
      if (!target || target === drag.button || target.dataset.sortGroup !== drag.button.dataset.sortGroup) return;
      drag.target = target;
      var rect = target.getBoundingClientRect();
      drag.after = drag.y >= rect.top + rect.height / 2;
      target.classList.add(drag.after ? 'reorder-after' : 'reorder-before');
    }
    function scroll() {
      frame = null;
      if (!drag || !drag.moved) return;
      if (!options.available() || !drag.button.isConnected) { cancel(); return; }
      var rect = drag.list.getBoundingClientRect();
      if (drag.x >= rect.left && drag.x <= rect.right && drag.y >= rect.top && drag.y <= rect.bottom) {
        var delta = drag.y < rect.top + 32 ? -7 : drag.y > rect.bottom - 32 ? 7 : 0;
        if (delta) { drag.list.scrollTop += delta; locate(); }
      }
      frame = requestAnimationFrame(scroll);
    }
    root.addEventListener('pointerdown', function (event) {
      var button = row(event.target);
      if (!button || event.button !== 0 || !event.isPrimary || button.dataset.sortGroup === 'original' || !options.available()) return;
      cancel();
      drag = { button: button, list: button.closest('.sidebar-style-list'), pointer: event.pointerId,
        startX: event.clientX, startY: event.clientY, x: event.clientX, y: event.clientY, moved: false, target: null };
      button.setPointerCapture(event.pointerId);
    });
    root.addEventListener('pointermove', function (event) {
      if (!drag || drag.pointer !== event.pointerId) return;
      drag.x = event.clientX; drag.y = event.clientY;
      if (!drag.moved && Math.hypot(drag.x - drag.startX, drag.y - drag.startY) < 7) return;
      event.preventDefault();
      if (!drag.moved) {
        drag.moved = true; options.begin();
        drag.button.classList.add('reordering'); frame = requestAnimationFrame(scroll);
      }
      locate();
    });
    root.addEventListener('pointerup', function (event) {
      if (!drag || drag.pointer !== event.pointerId) return;
      var previous = drag;
      if (previous.moved) { event.preventDefault(); suppressClickUntil = performance.now() + 250; }
      cancel();
      if (previous.moved && previous.target && options.available()) {
        options.commit(previous.button.dataset.selectStyle, previous.target.dataset.selectStyle, previous.after);
      }
    });
    root.addEventListener('click', function (event) {
      if (row(event.target) && performance.now() < suppressClickUntil) { event.preventDefault(); event.stopImmediatePropagation(); }
    }, true);
    ['pointercancel', 'lostpointercapture'].forEach(function (name) {
      root.addEventListener(name, function (event) { if (drag && drag.pointer === event.pointerId) cancel(); });
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape' && drag) { event.preventDefault(); cancel(); }
    }, true);
    window.addEventListener('blur', cancel);
    this.cancel = cancel;
  };
})();
