(function () {
  'use strict';
  var L = window.PhotoL10n;

  var historyKey = 'photoStyle.exportDuration.v1';
  var minimumReveal = 7000;
  var stages = {
    prepare: { order: 0, floor: 0, ceiling: 0.10, share: 0.12, text: '影像正在慢慢顯現' },
    render: { order: 1, floor: 0.08, ceiling: 0.72, share: 0.72, text: '影像正在慢慢顯現' },
    encode: { order: 2, floor: 0.72, ceiling: 0.88, share: 0.12, text: '正在保留色彩與細節' },
    write: { order: 3, floor: 0.88, ceiling: 0.94, share: 0.04, text: '正在儲存照片' }
  };
  function clamp(value, low, high) { return Math.max(low, Math.min(high, value)); }
  function smooth(value) { return value * value * (3 - 2 * value); }
  function history() {
    try {
      var value = JSON.parse(localStorage.getItem(historyKey) || '{}');
      return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
    } catch (_) { return {}; }
  }
  function estimate(profile, units) {
    var record = history()[profile];
    var rate = record && Number(record.rate);
    // Until a comparable export has been measured, use a conservative first estimate.
    return Math.max(9000, (Number.isFinite(rate) && rate > 0 ? rate : 650) * units);
  }
  function remember(job, milliseconds) {
    if (!job.profile || !Number.isFinite(milliseconds) || milliseconds <= 0) return;
    var records = history();
    var observed = clamp(milliseconds / job.units, 10, 600000);
    var previous = records[job.profile];
    // Include slow real exports, while smoothing isolated stalls rather than copying them blindly.
    records[job.profile] = { rate: previous && Number.isFinite(previous.rate)
      ? previous.rate * 0.35 + observed * 0.65 : observed, date: Date.now() };
    Object.keys(records).sort(function (a, b) { return (records[b].date || 0) - (records[a].date || 0); })
      .slice(32).forEach(function (key) { delete records[key]; });
    try { localStorage.setItem(historyKey, JSON.stringify(records)); } catch (_) { /* Optional pacing history. */ }
  }

  // Kept outside the editor DOM so native progress updates never restart the reveal.
  window.PhotoExportDevelopment = function (root, onVisibilityChange) {
    var image = root.querySelector('img');
    var title = root.querySelector('strong');
    var detail = root.querySelector('span');
    var caption = root.querySelector('.development-caption');
    var current = null;
    var timers = new Set();
    var reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');

    function later(job, delay, action) {
      var timer = setTimeout(function () {
        timers.delete(timer);
        if (current === job) action();
      }, delay);
      timers.add(timer);
    }

    function close() {
      timers.forEach(clearTimeout);
      timers.clear();
      image.getAnimations().forEach(function (animation) { animation.cancel(); });
      root.getAnimations().forEach(function (animation) { animation.cancel(); });
      caption.getAnimations().forEach(function (animation) { animation.cancel(); });
      current = null;
      root.hidden = true;
      root.removeAttribute('data-phase');
      image.removeAttribute('src');
      onVisibilityChange();
    }

    async function load(job, source) {
      if (!source) return;
      var decoded = new Image();
      decoded.src = source;
      try {
        await decoded.decode();
        if (current === job) image.src = source;
      } catch (_) { /* Keep the last valid preview if a display copy cannot decode. */ }
    }

    function paint(job) {
      var value = clamp(job.progress, 0, 1);
      image.style.opacity = String(value);
      image.style.filter = reducedMotion.matches || value === 1 ? 'none'
        : 'brightness(' + (0.10 + value * 0.90) + ') contrast(' + (1.7 - value * 0.7)
          + ') saturate(' + (0.2 + value * 0.8) + ') blur(' + (12 * Math.pow(1 - value, 2)) + 'px)';
    }

    function tick(job) {
      if (current !== job) return;
      var now = performance.now();
      if (job.finishReady) {
        var fraction = clamp((now - job.finishStarted) / job.finishDuration, 0, 1);
        job.progress = job.finishFrom + (1 - job.finishFrom) * smooth(fraction);
        paint(job);
        if (fraction === 1) {
          root.dataset.phase = 'fixed';
          title.textContent = L.text('輸出完成');
          detail.textContent = L.text('定影完成');
          later(job, reducedMotion.matches ? 0 : 900, function () {
            var fade = reducedMotion.matches ? 100 : 450;
            root.animate([{ opacity: 1 }, { opacity: 0 }], { duration: fade, fill: 'forwards' });
            later(job, fade, close);
          });
          return;
        }
      } else {
        var stage = stages[job.stage];
        var elapsed = Math.max(0, now - job.stageStarted);
        var budget = Math.max(1000, job.estimated * stage.share);
        // A slow stage keeps developing gently, but can never impersonate completed work.
        var target = stage.floor + (stage.ceiling - stage.floor) * elapsed / (elapsed + budget);
        var visualAge = now - job.visualStarted;
        var visibleLimit = 0.94 * smooth(clamp((visualAge - 500) / minimumReveal, 0, 1));
        if (reducedMotion.matches) target = Math.min(target, 0.88);
        else target = Math.min(target, visibleLimit);
        var delta = Math.max(0, now - job.lastTick);
        job.progress = Math.max(job.progress, job.progress + (target - job.progress) * (1 - Math.exp(-delta / 650)));
        paint(job);
      }
      job.lastTick = now;
      later(job, 50, function () { tick(job); });
    }

    this.isVisible = function () { return current !== null; };

    this.start = function (id, source, timing) {
      if (current && current.id === id) return;
      close();
      timing = timing || {};
      var now = performance.now();
      var units = Number(timing.workUnits);
      units = Number.isFinite(units) && units > 0 ? units : 1;
      var profile = typeof timing.profile === 'string' ? timing.profile : '';
      var job = { id: id, started: now, finishing: false, profile: profile, units: units,
        estimated: estimate(profile, units), stage: 'prepare', stageStarted: now, progress: 0 };
      current = job;
      root.hidden = false;
      root.dataset.phase = 'developing';
      title.textContent = L.text('正在輸出照片');
      detail.textContent = L.text(stages.prepare.text);
      image.style.opacity = '0';
      image.style.filter = 'brightness(0)';
      if (!reducedMotion.matches) caption.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 650, delay: 300, fill: 'both' });
      onVisibilityChange();
      job.loading = load(job, source).then(function () {
        if (current !== job) return;
        job.visualStarted = performance.now();
        job.lastTick = job.visualStarted;
        tick(job);
      });
    };

    this.update = function (id, stageName) {
      var job = current;
      var stage = stages[stageName];
      if (!job || job.id !== id || job.finishing || !stage || stage.order <= stages[job.stage].order) return;
      job.stage = stageName;
      job.stageStarted = performance.now();
      detail.textContent = L.text(stage.text);
    };

    this.finish = function (id, source, durationMs) {
      var job = current;
      if (!job || job.id !== id || job.finishing) return;
      job.finishing = true;
      // Learn native processing time, excluding the visual hold and Web image decode.
      remember(job, Number(durationMs));
      Promise.resolve(job.loading).then(function () { return load(job, source); }).then(function () {
        if (current !== job) return;
        var now = performance.now();
        job.finishFrom = job.progress;
        job.finishStarted = now;
        job.finishDuration = reducedMotion.matches ? 140 : Math.max(
          1800, minimumReveal - (now - job.visualStarted), (1 - job.progress) * 6000
        );
        job.finishReady = true;
        root.dataset.phase = 'fixing';
        detail.textContent = L.text('正在定影');
      });
    };

    this.cancel = function (id) {
      if (current && current.id === id) close();
    };
  };
})();
