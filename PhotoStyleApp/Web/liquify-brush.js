(function () {
  'use strict';
  // 液化的原圖、網格與顯示畫布各自獨立；每次只取樣未變形的原始預覽。
  window.PhotoLiquifyBrush = function (env) {
    var radius = 64, strength = 65, mode = 'push', sequence = 0;
    var frame = null, canvas = null, cursor = null, observer = null, raf = 0;
    var pointer = null, drawingCanvas = null, pending = null, generation = '';
    var mesh = null, pixels = null, output = null, bitmapCanvas = null, bitmapContext = null, bitmapData = null, cache = null;
    var displayed = null;
    var paintedRevision = -1, loading = false, loadingContext = null, loadToken = 0, failedSource = null;
    var text = env.text, escape = env.escape;
    function state() { return env.state(); }
    function active() { return !!state().liquifyEditing; }
    function busy() { return !!pending || loading || env.busy() || state().isRenderingPreview; }
    function button(label, action, disabled) {
      return '<button type="button" class="photo-directory-button" data-liquify-action="' + action + '"' + (disabled ? ' disabled' : '') + '>' + escape(text(label)) + '</button>';
    }
    this.active = active;
    this.toolbar = function () {
      if (state().supportsLiquify !== true) return '';
      return '<button type="button" class="photo-directory-button liquify-toggle" data-liquify-toggle title="' + escape(text('液化筆刷：拖曳照片，局部推移或還原畫面。')) + '" aria-label="' + escape(text('液化筆刷')) + '" aria-pressed="' + active() + '"' + (!state().hasImage || env.busy() || state().isRenderingPreview ? ' disabled' : '') + '><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 4c8-4 0 12 8 8s0 16 8 8M3 12c3 0 4-2 7-2s5 4 8 4h3M12 3v3m0 12v3"/></svg></button>';
    };
    this.panel = function () {
      if (!active()) return '';
      var disabled = busy() ? ' disabled' : '';
      return '<section class="liquify-panel" aria-label="' + escape(text('液化筆刷')) + '"><label for="liquifyMode">' + escape(text('筆刷模式')) + '</label><select id="liquifyMode" class="compact-select"' + disabled + '><option value="push"' + (mode === 'push' ? ' selected' : '') + '>' + escape(text('推移')) + '</option><option value="restore"' + (mode === 'restore' ? ' selected' : '') + '>' + escape(text('局部還原')) + '</option></select>' +
        '<label for="liquifyRadius">' + escape(text('半徑')) + '</label><input id="liquifyRadius" type="range" min="12" max="180" step="1" title="' + escape(text('按住 Shift＋滾輪調整筆刷大小。')) + '" value="' + radius + '"' + disabled + '><output id="liquifyRadiusValue">' + radius + ' px</output>' +
        '<label for="liquifyStrength">' + escape(text('強度')) + '</label><input id="liquifyStrength" type="range" min="0" max="100" step="1" value="' + strength + '"' + disabled + '><output id="liquifyStrengthValue">' + strength + '%</output>' +
        button('完成', 'done', !!pending) + (pending || loading ? '<span class="liquify-status" role="status"><span class="preview-spinner"></span>' + escape(text(pending ? '正在套用液化…' : '正在準備液化預覽…')) + '</span>' : '') + '</section>';
    };
    this.overlay = function () { return active() ? '<canvas class="liquify-overlay" aria-label="' + escape(text('拖曳以局部變形')) + '"></canvas><span class="liquify-cursor" hidden></span>' : ''; };

    function clearCache() {
      ++loadToken; loading = false; loadingContext = null; mesh = null; pixels = null; output = null; cache = null; failedSource = null;
      if (bitmapCanvas) bitmapCanvas.width = bitmapCanvas.height = 1;
      bitmapCanvas = null; bitmapContext = null; bitmapData = null; paintedRevision = -1; displayed = null;
    }
    function cancelDrawing() {
      if (pointer === null) return;
      var oldPointer = pointer, oldCanvas = drawingCanvas;
      pointer = null; drawingCanvas = null;
      if (mesh) mesh.cancelStroke();
      if (oldCanvas && oldCanvas.hasPointerCapture(oldPointer)) oldCanvas.releasePointerCapture(oldPointer);
      schedule();
    }
    function report(message) { if (env.toast) env.toast(message); }
    function geometry() {
      var image = env.image();
      if (!image || !image.complete || !image.naturalWidth || !frame || !frame.isConnected) return null;
      var imageRect = image.getBoundingClientRect(), frameRect = frame.getBoundingClientRect();
      if (!imageRect.width || !imageRect.height || !frameRect.width || !frameRect.height) return null;
      return { image: imageRect, frame: frameRect };
    }
    function sourceMatches() {
      var s = state();
      return cache && mesh && pixels && cache.generation === s.photoGeneration && cache.revision === (s.liquifyRevision || '') && cache.source === s.liquifySourceImage;
    }
    function ensureSource() {
      if (!active() || loading || sourceMatches()) return;
      var s = state(), source = s.liquifySourceImage;
      if (!source || failedSource === source) return;
      var expected = { generation: s.photoGeneration, revision: s.liquifyRevision || '', source: source, data: s.liquifyMesh };
      // 筆畫、復原只改網格；相同來源與取樣尺寸沿用不可變原圖像素。
      if (cache && cache.generation === expected.generation && cache.source === source && bitmapCanvas &&
          bitmapCanvas.width === (expected.data ? expected.data.referenceWidth : cache.defaultWidth) &&
          bitmapCanvas.height === (expected.data ? expected.data.referenceHeight : cache.defaultHeight)) {
        try {
          mesh = expected.data ? window.PhotoLiquifyCore.LiquifyMesh.fromData(expected.data, { historyBytes: 0 }) :
            new window.PhotoLiquifyCore.LiquifyMesh(cache.defaultWidth, cache.defaultHeight, { spacing: 4, historyBytes: 0 });
          expected.defaultWidth = cache.defaultWidth; expected.defaultHeight = cache.defaultHeight;
          cache = expected; paintedRevision = -1; displayed = null;
          return;
        } catch (_) {
          clearCache(); failedSource = source;
          report('無法準備液化預覽，請重新開啟液化工具。'); env.render(); return;
        }
      }
      clearCache();
      var token = ++loadToken, image = new Image();
      loading = true; loadingContext = expected;
      image.onload = function () {
        if (token !== loadToken || !active() || state().photoGeneration !== expected.generation) return;
        try {
          var width, height, scale = Math.min(1, 1024 / Math.max(image.naturalWidth, image.naturalHeight));
          expected.defaultWidth = Math.max(2, Math.round(image.naturalWidth * scale));
          expected.defaultHeight = Math.max(2, Math.round(image.naturalHeight * scale));
          if (expected.data) { width = expected.data.referenceWidth; height = expected.data.referenceHeight; }
          else {
            width = expected.defaultWidth; height = expected.defaultHeight;
          }
          var next = expected.data ? window.PhotoLiquifyCore.LiquifyMesh.fromData(expected.data, { historyBytes: 0 }) : new window.PhotoLiquifyCore.LiquifyMesh(width, height, { spacing: 4, historyBytes: 0 });
          var buffer = document.createElement('canvas'); buffer.width = width; buffer.height = height;
          var context = buffer.getContext('2d', { willReadFrequently: true }); context.drawImage(image, 0, 0, width, height);
          var nextPixels = context.getImageData(0, 0, width, height).data;
          mesh = next; pixels = nextPixels; output = new Uint8ClampedArray(pixels.length); bitmapCanvas = buffer;
          bitmapContext = context; bitmapData = new ImageData(output, width, height);
          cache = expected; paintedRevision = -1; loading = false; loadingContext = null;
          env.render();
        } catch (_) {
          loading = false; loadingContext = null; failedSource = source; report('無法準備液化預覽，請重新開啟液化工具。'); env.render();
        }
      };
      image.onerror = function () {
        if (token !== loadToken) return;
        loading = false; loadingContext = null; failedSource = source; report('無法載入液化預覽，請重新開啟液化工具。'); env.render();
      };
      image.src = source;
      // 解碼期間同步面板停用狀態，避免新 DOM 看似已可操作。
      env.render();
    }
    function redraw() {
      raf = 0;
      if (!active() || !canvas || !canvas.isConnected) return;
      ensureSource();
      var g = geometry(); if (!g || !mesh || !pixels || !bitmapCanvas) return;
      var dpr = Math.min(window.devicePixelRatio || 1, 2), w = Math.max(1, Math.round(g.frame.width * dpr)), h = Math.max(1, Math.round(g.frame.height * dpr));
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; displayed = null; }
      if (paintedRevision !== mesh.renderRevision) {
        window.PhotoLiquifyCore.renderWarp(pixels, mesh.width, mesh.height, mesh, output);
        bitmapContext.putImageData(bitmapData, 0, 0);
        paintedRevision = mesh.renderRevision; displayed = null;
      }
      var x = g.image.left - g.frame.left, y = g.image.top - g.frame.top;
      if (displayed && displayed.canvas === canvas && displayed.dpr === dpr && displayed.x === x && displayed.y === y &&
          displayed.width === g.image.width && displayed.height === g.image.height &&
          displayed.frameWidth === g.frame.width && displayed.frameHeight === g.frame.height) return;
      var ctx = canvas.getContext('2d'); ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, g.frame.width, g.frame.height);
      ctx.drawImage(bitmapCanvas, x, y, g.image.width, g.image.height);
      displayed = { canvas: canvas, dpr: dpr, x: x, y: y, width: g.image.width, height: g.image.height,
        frameWidth: g.frame.width, frameHeight: g.frame.height };
    }
    function schedule() { if (!raf) raf = requestAnimationFrame(redraw); }
    function point(e, outside, g) {
      if (!g || !mesh) return null;
      var x = (e.clientX - g.image.left) / g.image.width, y = (e.clientY - g.image.top) / g.image.height;
      if (!outside && (x < 0 || x > 1 || y < 0 || y > 1)) return null;
      return { x: Math.max(0, Math.min(1, x)) * (mesh.width - 1), y: Math.max(0, Math.min(1, y)) * (mesh.height - 1) };
    }
    function cursorAt(e, g) {
      var p = point(e, false, g); if (!cursor || !g) return;
      cursor.hidden = !p || busy();
      if (!p) return;
      var size = radius * 2 * g.image.width / (mesh.width - 1);
      cursor.style.width = size + 'px'; cursor.style.height = size + 'px';
      cursor.style.left = (e.clientX - g.frame.left) + 'px'; cursor.style.top = (e.clientY - g.frame.top) + 'px';
      cursor.classList.toggle('restore', mode === 'restore');
    }
    function finish(e) {
      if (pointer !== e.pointerId || !mesh) return;
      e.preventDefault(); e.stopPropagation();
      if (e.type !== 'pointerup') { cancelDrawing(); return; }
      var p = point(e, true, geometry()); if (p) mesh.moveStroke(p);
      var changed = mesh.endStroke(), oldCanvas = drawingCanvas, oldPointer = pointer;
      pointer = null; drawingCanvas = null;
      if (oldCanvas && oldCanvas.hasPointerCapture(oldPointer)) oldCanvas.releasePointerCapture(oldPointer);
      if (!changed) { schedule(); return; }
      var s = state();
      pending = { requestID: String(s.photoGeneration) + ':' + (++sequence), generation: s.photoGeneration,
        baseRevision: s.liquifyRevision || '', acceptedRevision: null, replied: false };
      s.isApplyingLiquify = true;
      env.post('applyLiquifyBrush', { requestID: pending.requestID, photoGeneration: s.photoGeneration,
        previewRevision: s.previewRevision, liquifyRevision: pending.baseRevision, mesh: mesh.toData() });
      env.render();
    }
    function bind() {
      cancelDrawing();
      if (observer) observer.disconnect(); observer = null;
      frame = env.root.querySelector('.preview-frame'); canvas = env.root.querySelector('.liquify-overlay'); cursor = env.root.querySelector('.liquify-cursor');
      displayed = null;
      var toggle = env.root.querySelector('[data-liquify-toggle]');
      if (toggle) toggle.onclick = function () {
        if (toggle.disabled) return;
        if (active()) { close(); env.render(); return; }
        env.prepare(); state().liquifyEditing = true; failedSource = null; env.render();
      };
      env.root.querySelectorAll('[data-liquify-action]').forEach(function (b) { b.onclick = function () {
        if (b.disabled) return;
        if (b.dataset.liquifyAction === 'done') close();
        env.render();
      }; });
      [['liquifyRadius', 'liquifyRadiusValue'], ['liquifyStrength', 'liquifyStrengthValue']].forEach(function (ids) {
        var control = env.root.querySelector('#' + ids[0]);
        if (control) control.oninput = function () {
          cancelDrawing(); if (ids[0] === 'liquifyRadius') radius = Number(control.value); else strength = Number(control.value);
          env.root.querySelector('#' + ids[1]).textContent = control.value + (ids[0] === 'liquifyRadius' ? ' px' : '%');
          if (cursor) cursor.hidden = true;
        };
      });
      var select = env.root.querySelector('#liquifyMode'); if (select) select.onchange = function () { cancelDrawing(); mode = select.value; };
      if (!active() || !canvas || !frame) return;
      var image = env.image(); if (image) image.addEventListener('load', schedule, { once: true });
      if (window.ResizeObserver) { observer = new ResizeObserver(schedule); observer.observe(frame); }
      window.PhotoBrushSizeWheel(canvas, {
        control: function () { return env.root.querySelector('#liquifyRadius'); },
        ready: function () { return active() && !busy() && pointer === null && !!sourceMatches(); },
        update: function (value, event) {
          radius = value; env.root.querySelector('#liquifyRadiusValue').textContent = radius + ' px';
          cursorAt(event, geometry());
        }
      });
      canvas.addEventListener('pointerdown', function (e) {
        if (e.button !== 0 || pointer !== null || busy() || !sourceMatches()) return;
        var g = geometry(), p = point(e, false, g); if (!p) return;
        e.preventDefault(); e.stopPropagation(); env.cancelGesture();
        mesh.beginStroke(p, { radius: radius, strength: strength / 100, mode: mode });
        pointer = e.pointerId; drawingCanvas = canvas; canvas.setPointerCapture(pointer); cursorAt(e, g); schedule();
      });
      canvas.addEventListener('pointermove', function (e) {
        var g = geometry(); cursorAt(e, g); if (pointer !== e.pointerId) return;
        e.preventDefault(); e.stopPropagation();
        var samples = typeof e.getCoalescedEvents === 'function' ? e.getCoalescedEvents() : [];
        (samples.length ? samples : [e]).forEach(function (sample) { var p = point(sample, true, g); if (p) mesh.moveStroke(p); });
        schedule();
      });
      ['pointerup', 'pointercancel', 'lostpointercapture'].forEach(function (name) { canvas.addEventListener(name, finish); });
      canvas.addEventListener('pointerleave', function () { if (cursor) cursor.hidden = true; });
      schedule();
    }
    function close() {
      cancelDrawing(); state().liquifyEditing = false;
      if (!pending) clearCache();
      if (cursor) cursor.hidden = true;
      if (observer) observer.disconnect(); observer = null;
      if (raf) cancelAnimationFrame(raf); raf = 0;
    }
    this.bind = bind;
    this.redraw = schedule;
    this.cancelStroke = cancelDrawing;
    this.isDrawing = function () { return pointer !== null; };
    this.close = close;
    this.receive = function (next) {
      if (generation && next.photoGeneration !== generation) {
        cancelDrawing(); pending = null; next.isApplyingLiquify = false; next.liquifyEditing = false; clearCache();
      } else if ((cache && (cache.revision !== (next.liquifyRevision || '') || cache.source !== next.liquifySourceImage)) ||
          (loadingContext && (loadingContext.revision !== (next.liquifyRevision || '') || loadingContext.source !== next.liquifySourceImage))) {
        cancelDrawing();
        if (cache && cache.source === next.liquifySourceImage && next.liquifyEditing) {
          mesh = null; paintedRevision = -1; displayed = null;
        } else clearCache();
      }
      generation = next.photoGeneration;
      if (pending) {
        next.isApplyingLiquify = true;
        if (pending.replied && (next.liquifyRevision || '') === pending.acceptedRevision) {
          pending = null; next.isApplyingLiquify = false;
        }
      }
    };
    this.result = function (result) {
      if (!pending || !result || result.requestID !== pending.requestID || result.photoGeneration !== pending.generation || result.photoGeneration !== state().photoGeneration) return;
      if (!result.success) {
        pending = null; state().isApplyingLiquify = false; cancelDrawing(); clearCache();
        report('液化未完成，已保留上一筆編輯。');
      } else {
        pending.replied = true; pending.acceptedRevision = result.liquifyRevision || '';
        if ((state().liquifyRevision || '') === pending.acceptedRevision) { pending = null; state().isApplyingLiquify = false; }
      }
      env.render();
    };
    this.escape = function () {
      if (!active()) return false;
      if (pointer !== null) { cancelDrawing(); return true; }
      if (!pending) { close(); env.render(); }
      return true;
    };
    window.addEventListener('blur', cancelDrawing);
    document.addEventListener('visibilitychange', function () { if (document.hidden) cancelDrawing(); });
  };
})();
