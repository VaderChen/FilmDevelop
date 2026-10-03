// 在真實 WKWebView／WebView2 中觀測逐幀畫面；不更改正式顯影狀態。
window.runDevelopmentSmoke = async function () {
  'use strict';
  const completed = [], samples = [];
  const root = document.getElementById('exportDevelopment').cloneNode(true);
  root.removeAttribute('id');
  root.querySelector('strong').removeAttribute('id');
  root.removeAttribute('aria-labelledby');
  document.body.appendChild(root);
  const development = new window.PhotoExportDevelopment(root, function () {});
  const image = root.querySelector('img');
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  const require = (ok, text) => { if (!ok) throw new Error(text); completed.push(text); };
  const canvas = document.createElement('canvas');
  canvas.width = 2048; canvas.height = 1536;
  const context = canvas.getContext('2d'), gradient = context.createLinearGradient(0, 0, 2048, 1536);
  gradient.addColorStop(0, '#df9575'); gradient.addColorStop(1, '#345f95');
  context.fillStyle = gradient; context.fillRect(0, 0, 2048, 1536);
  const source = canvas.toDataURL('image/jpeg');
  let observing = true, observer;
  function observe(now) {
    if (!observing) return;
    samples.push({time:now, value:Number(image.style.opacity), phase:root.dataset.phase});
    observer = requestAnimationFrame(observe);
  }
  async function until(test) {
    const start = performance.now();
    while (!test()) { if (performance.now() - start > 12000) throw new Error('顯影 Smoke 逾時'); await wait(20); }
  }
  try {
    development.start('sparse', source);
    development.update('sparse', 'render', 0);
    await until(() => image.complete && image.naturalWidth > 0);
    observer = requestAnimationFrame(observe);
    await wait(2500);
    const early = Number(image.style.opacity);
    await wait(1500);
    const later = Number(image.style.opacity);
    require(later - early > 0.04, '顯影遇到稀疏進度仍持續平順顯現');
    development.update('sparse', 'write', 1);
    await wait(300);
    require(root.dataset.phase === 'developing' && Number(image.style.opacity) < 1, '寫入成功前不提前完成顯影');
    development.finish('sparse', null, 4300);
    await until(() => root.dataset.phase === 'fixed');
    require(Number(image.style.opacity) === 1 && image.style.filter === 'none', '定影完整顯示同一張已解碼照片');
    const moving = samples.filter(s => s.value > 0.01 && s.value < 0.99);
    const changed = moving.slice(1).filter((s, i) => s.value > moving[i].value).length;
    require(moving.length > 30 && changed / (moving.length - 1) > 0.70, '顯影隨畫面逐幀更新，沒有固定低幀率階梯');
    require(moving.every((s, i) => !i || s.value >= moving[i-1].value), '顯影與定影銜接不倒退');
    await until(() => root.hidden);
    require(!image.hasAttribute('src') && !image.style.willChange, '顯影結束釋放圖片與合成圖層');
    development.start('cancelled', source);
    development.cancel('cancelled');
    development.finish('cancelled', null, 10);
    await wait(100);
    require(root.hidden && !image.hasAttribute('src'), '取消後延遲解碼與完成事件不重開視窗');
    development.start('old', source);
    development.start('new', source);
    development.cancel('old'); development.finish('old', null, 1);
    require(development.isVisible(), '過期工作不會關閉新的顯影對話框');
    development.cancel('new');
    const matchMedia = window.matchMedia;
    let reduced;
    try {
      window.matchMedia = () => ({matches:true});
      reduced = new window.PhotoExportDevelopment(root, function () {});
    } finally { window.matchMedia = matchMedia; }
    try {
      const started = performance.now();
      reduced.start('reduced', source);
      reduced.finish('reduced', null, 1);
      await until(() => root.hidden);
      require(performance.now() - started < 1500, '減少動態效果模式不等待完整顯影動畫');
    } finally { reduced.cancel('reduced'); }
    window.developmentSmokeMetrics = {sampledFrames:moving.length, changedFrameRatio:changed/(moving.length-1), sparseAdvance:later-early};
    return completed;
  } finally {
    observing = false; cancelAnimationFrame(observer);
    development.cancel('sparse'); development.cancel('cancelled'); development.cancel('old'); development.cancel('new');
    root.remove();
  }
};
