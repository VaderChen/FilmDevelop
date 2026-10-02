(async function () {
  'use strict';
  let latest = {}, failure = null, sawSwitch = false;
  const completed = [], original = window.handleNativeState;
  window.handleNativeState = function (payload) {
    latest = Object.assign({}, latest, payload);
    original(payload);
    if (latest.isSwitchingComputeBackend) sawSwitch = true;
  };
  window.handleNativeToast = payload => { failure = payload.message; };
  const post = (action, fields) => window.PhotoNativeBridge.post(Object.assign({action}, fields));
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function until(test, label) {
    const started = performance.now();
    while (!test()) {
      if (failure) throw new Error(failure);
      if (performance.now() - started > 45000) throw new Error('等待逾時：' + label);
      await wait(20);
    }
  }
  async function settled() {
    await until(() => !latest.isRenderingPreview && !!latest.outputImage, '預覽結果');
    await until(() => {
      const image = document.querySelector('.preview-image');
      return image && image.getAttribute('src') === latest.outputImage && image.complete &&
        image.naturalWidth > 0 && !image._pendingPreviewDecode && !image._previewReveal;
    }, 'JPEG 顯示');
  }
  try {
    post('getState');
    await until(() => latest.styles?.length === 37, 'Go 底片目錄');
    if (window.windowsSmokeMode === 'restore') {
      if (latest.computeBackend !== 'vulkan' || latest.rawDecoderBackend !== 'software') throw new Error('重新啟動沒有恢復實機支援的選項');
      completed.push('重新啟動保留 Vulkan 與 LibRaw');
    } else if (latest.computeBackend !== 'system' || latest.rawDecoderBackend !== 'system') throw new Error('首次啟動未預設系統後端');
    document.querySelector('[data-page="settings"]').click();
    document.querySelector('[data-settings-section="acceleration"]').click();
    const raw = document.getElementById('rawDecoderSelect');
    const compute = document.getElementById('computeBackendSelect');
    const choices = select => Array.from(select.options, option => option.value).filter(Boolean);
    if (JSON.stringify(choices(raw)) !== JSON.stringify(latest.rawDecoders) || JSON.stringify(choices(compute)) !== JSON.stringify(latest.computeBackends)) throw new Error('加速選單與系統偵測不符');
    completed.push('RAW／GPU 選單來自實機探測');
    if (raw.closest('.settings-row').nextElementSibling?.getAttribute('role') === 'status') throw new Error('RAW 下方仍顯示說明文字');
    completed.push('RAW 下方不顯示額外說明文字');
    if (window.windowsSmokeMode !== 'restore') {
      document.querySelector('[data-page="home"]').click();
      window.runtime.EventsEmit('filmdevelop:smoke-reopen');
      await until(() => latest.hasImage, '開啟 JPEG');
      await settled(); completed.push('Go → C++ → WebView2 JPEG 顯示');
      const before = latest.outputImage;
      post('updateAdjustment', {style:'original', key:'printExposure', value:1});
      await until(() => latest.outputImage !== before, '曝光套用');
      await settled(); completed.push('曝光調整更新實際影像');
      for (const style of ['filmEktachrome100', 'filmHP5', 'fujiProvia', 'gr3-negative']) {
        const before = latest.outputImage;
        post('setStyle', {style});
        await until(() => latest.selectedStyle === style && latest.outputImage !== before, '套用配方：' + style);
        await settled();
        completed.push('切換配方並顯示成品：' + style);
      }
      document.querySelector('[data-page="settings"]').click();
      document.querySelector('[data-settings-section="acceleration"]').click();
      const selector = document.getElementById('computeBackendSelect');
      if (!latest.computeBackends.includes('vulkan')) throw new Error('本次 GPU 驗證需要可用 Vulkan');
      selector.value = 'vulkan'; selector.dispatchEvent(new Event('change', {bubbles:true}));
      await until(() => latest.computeBackend === 'vulkan' && !latest.isSwitchingComputeBackend, 'GPU 切換');
      if (!sawSwitch) throw new Error('沒有收到切換等待狀態');
      completed.push('GPU 切換等待與預覽完成');
      const rawSelector = document.getElementById('rawDecoderSelect');
      rawSelector.value = 'software'; rawSelector.dispatchEvent(new Event('change', {bubbles:true}));
      await until(() => latest.rawDecoderBackend === 'software' && !latest.isRenderingPreview, 'RAW 切換');
      completed.push('RAW 選項切換完成');
    }
    window.runtime.EventsEmit('filmdevelop:smoke-result', {passed:true, completed, computeBackends:latest.computeBackends, rawDecoders:latest.rawDecoders, computeBackend:latest.computeBackend, rawDecoderBackend:latest.rawDecoderBackend});
  } catch (error) {
    window.runtime.EventsEmit('filmdevelop:smoke-result', {passed:false, error:String(error), completed});
  }
})();
