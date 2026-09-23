(function () {
  'use strict';

  // Temporary view state is deliberately separate from the editor's saved state.
  window.PhotoFilmHoverPreview = function (options) {
    var active = null;
    var timer = null;
    var sequence = 0;
    var root = options.root;
    var selector = '.sidebar-style[data-select-style]';
    function buttonAt(node) { return node instanceof Element ? node.closest(selector) : null; }
    function contextKey() { return JSON.stringify(options.context()); }
    function mark() {
      root.querySelectorAll(selector).forEach(function (button) {
        button.classList.toggle('is-reviewing', !!active && !!active.image && button.dataset.selectStyle === active.look);
      });
    }
    function cancel() {
      clearTimeout(timer); timer = null;
      if (!active) return;
      var previous = active;
      active = null;
      if (previous.sent) options.post('cancelFilmHover', { requestID: previous.id });
      mark();
      if (previous.context === contextKey()) options.restoreView(previous.view);
      options.changed();
    }
    function enter(event) {
      var button = buttonAt(event.target);
      if (event.pointerType === 'touch' || event.buttons || !button || button.disabled) return;
      var look = button.dataset.selectStyle;
      if (!options.available() || look === options.context().selectedLook) { cancel(); return; }
      if (active && active.look === look && active.context === contextKey()) return;
      cancel();
      active = { id: 'film-hover-' + (++sequence), look: look, context: contextKey(), image: null, sent: false, view: options.captureView() };
      var request = active;
      // Avoid rendering every row passed while the user moves down the list.
      timer = setTimeout(function () {
        timer = null;
        if (active !== request || !options.available() || contextKey() !== request.context) { cancel(); return; }
        request.sent = true;
        options.post('previewFilmHover', Object.assign({}, options.context(), { style: look, requestID: request.id }));
      }, 120);
    }
    root.addEventListener('pointerover', enter);
    root.addEventListener('pointermove', enter);
    root.addEventListener('pointerout', function (event) {
      var from = buttonAt(event.target), to = buttonAt(event.relatedTarget);
      if (from && active && active.look === from.dataset.selectStyle
          && (!to || from.dataset.selectStyle !== to.dataset.selectStyle)) cancel();
    });
    document.addEventListener('pointerdown', cancel, true);
    document.addEventListener('pointercancel', cancel, true);
    document.addEventListener('keydown', cancel, true);
    document.addEventListener('visibilitychange', function () { if (document.hidden) cancel(); });
    window.addEventListener('blur', cancel);
    window.addEventListener('pagehide', cancel);

    this.cancel = cancel;
    this.sync = function () {
      if (active && (!options.available() || active.context !== contextKey())) cancel();
      mark();
    };
    this.imageSource = function () { return active && active.image; };
    this.displaySize = function (source) { return active && active.image === source ? active.size : null; };
    this.look = function () { return active && active.image ? active.look : null; };
    this.receive = function (payload) {
      if (!active || !payload || !options.available() || active.context !== contextKey()
          || payload.requestID !== active.id || payload.style !== active.look
          || payload.photoGeneration !== options.context().photoGeneration
          || payload.previewRevision !== options.context().previewRevision || !payload.image) return;
      active.image = payload.image;
      active.size = { width: payload.width, height: payload.height };
      mark();
      options.changed();
    };
  };
})();
