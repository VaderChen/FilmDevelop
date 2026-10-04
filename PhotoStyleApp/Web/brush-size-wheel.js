(function () {
  'use strict';
  // 修復與液化共用滾輪手勢；數值範圍及步進直接取自各自的滑桿。
  window.PhotoBrushSizeWheel = function (canvas, options) {
    var remainder = 0, previousValue = null, previousTime = 0, previousDirection = 0;
    canvas.addEventListener('wheel', function (event) {
      if (!event.shiftKey || event.ctrlKey || event.metaKey || event.altKey) { remainder = 0; return; }
      // 即使筆畫／原生處理尚未結束，也不讓 Shift 滾輪落入照片縮放。
      event.preventDefault(); event.stopPropagation();
      var control = options.control();
      if (!control || control.disabled || !options.ready()) { remainder = 0; return; }
      // 部分平台在按 Shift 時將垂直滾動轉成 deltaX。
      var delta = event.deltaY || event.deltaX;
      var unit = event.deltaMode === 1 ? 16 : (event.deltaMode === 2 ? Math.max(1, canvas.clientHeight) : 1);
      var value = Number(control.value), min = Number(control.min), max = Number(control.max), step = Number(control.step) || 1;
      if (!Number.isFinite(delta) || !delta || !Number.isFinite(value) || !Number.isFinite(min) || !Number.isFinite(max)) return;
      var direction = Math.sign(delta);
      if (value !== previousValue || direction !== previousDirection || event.timeStamp - previousTime > 250) remainder = 0;
      previousTime = event.timeStamp; previousDirection = direction; previousValue = value;
      // 保留觸控板的小數增量；每 24 CSS px 移動一個滑桿步進。
      remainder -= Math.max(-240, Math.min(240, delta * unit));
      var steps = Math.trunc(remainder / 24); remainder -= steps * 24;
      var next = Math.max(min, Math.min(max, value + steps * step));
      if ((next === min && direction > 0) || (next === max && direction < 0)) remainder = 0;
      if (next === value) return;
      control.value = String(next); previousValue = Number(control.value);
      options.update(previousValue, event);
    }, { passive: false });
  };
})();
