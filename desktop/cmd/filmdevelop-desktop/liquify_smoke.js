(async function () {
  'use strict';
  let latest = {}, result = null, failure = null, exported = false;
  const completed = [], originalState = window.handleNativeState, originalResult = window.handleLiquifyResult;
  window.handleNativeState = function (payload) { latest = Object.assign({}, latest, payload); originalState(payload); };
  window.handleLiquifyResult = function (payload) { result = payload; originalResult(payload); };
  window.handleNativeToast = function (payload) {
    if ((payload.message || '').startsWith('已匯出：')) exported = true;
    else failure = payload.message;
  };
  const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
  async function until(test, label) {
    const start = performance.now();
    while (!test()) {
      if (failure) throw new Error(failure);
      if (performance.now() - start > 45000) throw new Error('等待逾時：' + label);
      await wait(20);
    }
  }
  const post = (action, fields) => window.PhotoNativeBridge.post(Object.assign({action}, fields));
  const idle = () => until(() => latest.outputImage && !latest.isRenderingPreview && !latest.isLoadingImage, '完成原生預覽');
  function check(value, name) { if (!value) throw new Error(name); completed.push(name); }
  function brushWheel(canvasSelector, sliderID, outputID, cursorSelector, name) {
    const canvas = document.querySelector(canvasSelector), slider = document.getElementById(sliderID);
    const image = document.querySelector('.preview-image'), rect = image.getBoundingClientRect();
    const initial = Number(slider.value), revision = latest.previewRevision, meshRevision = latest.liquifyRevision;
    const wheel = (delta, fields = {}) => {
      const event = new WheelEvent('wheel', Object.assign({bubbles:true, cancelable:true, shiftKey:true,
        clientX:rect.left + rect.width / 2, clientY:rect.top + rect.height / 2, deltaY:delta}, fields));
      canvas.dispatchEvent(event);
      return event;
    };
    const first = wheel(-48);
    if (!first.defaultPrevented || Number(slider.value) !== initial + 2) {
      throw new Error(name + '滾輪狀態：' + JSON.stringify({prevented:first.defaultPrevented, shift:first.shiftKey,
        delta:first.deltaY, initial, current:slider.value, disabled:slider.disabled, connected:slider.isConnected}));
    }
    check(true, name + '：Shift＋滾輪向上放大並攔截照片縮放');
    check(document.getElementById(outputID).textContent === (initial + 2) + ' px' &&
      !document.querySelector(cursorSelector).hidden, name + '：滑桿數值與游標同步');
    check(wheel(48).defaultPrevented && Number(slider.value) === initial, name + '：向下縮小');
    check(wheel(0, {deltaX:-48}).defaultPrevented && Number(slider.value) === initial + 2, name + '：支援 Shift 橫軸轉換');
    slider.value = initial; slider.dispatchEvent(new Event('input', {bubbles:true}));
    check(latest.previewRevision === revision && latest.liquifyRevision === meshRevision, name + '：調整大小不提交修圖');
  }
  try {
    post('getState'); await until(() => latest.styles?.length && latest.supportsLiquify, '液化能力');
    window.runtime.EventsEmit('filmdevelop:smoke-reopen');
    await until(() => latest.hasImage, '載入照片'); await idle();
    const toggle = document.querySelector('[data-liquify-toggle]'), repair = document.querySelector('[data-repair-toggle]');
    check(toggle && repair && !!(toggle.compareDocumentPosition(repair) & Node.DOCUMENT_POSITION_FOLLOWING), '液化按鈕位於修復筆刷左邊');
    if (window.liquifySmokeMode === 'restore') {
      check(!!latest.liquifyMesh && !!latest.liquifyRevision, '重新啟動還原照片液化網格');
      check(latest.cropSourceImage !== latest.liquifySourceImage, '重新啟動保留液化與未液化的編輯預覽');
    } else {
      const before = latest.outputImage, beforeRevision = latest.previewRevision;
      const preview = new Image(); preview.src = latest.liquifySourceImage; await preview.decode();
      const w = 257, h = Math.max(2, Math.round(w * preview.naturalHeight / preview.naturalWidth));
      const mesh = new window.PhotoLiquifyCore.LiquifyMesh(w, h, {historyBytes: 0});
      mesh.beginStroke({x:w*.4,y:h*.5},{radius:Math.min(w,h)*.2,strength:.9});
      mesh.moveStroke({x:w*.58,y:h*.5}); mesh.endStroke();
      result = null;
      post('applyLiquifyBrush',{requestID:'native-smoke-1',photoGeneration:latest.photoGeneration,previewRevision:latest.previewRevision,liquifyRevision:latest.liquifyRevision||'',mesh:mesh.toData()});
      await until(() => result, '網格提交回覆'); check(result.success && result.requestID === 'native-smoke-1', 'Go宿主接受有效筆畫並回傳同筆識別碼');
      await until(() => latest.previewRevision !== beforeRevision && !!latest.liquifyRevision, '新網格狀態'); await idle();
      const warped = latest.outputImage, revision = latest.liquifyRevision;
      check(warped !== before && latest.cropSourceImage !== latest.liquifySourceImage, '原生渲染液化並保留裁切與筆刷各自座標');
      check(latest.repairSourceImage === latest.liquifySourceImage, '修復筆刷沿用未液化原圖座標');
      result = null;
      post('applyLiquifyBrush',{requestID:'native-stale',photoGeneration:latest.photoGeneration,previewRevision:beforeRevision,liquifyRevision:'',mesh:null});
      await until(() => result, '過期筆畫拒絕'); check(!result.success && latest.liquifyRevision === revision, '過期筆畫不覆蓋已提交液化');
      post('undoEdit'); await until(() => !latest.liquifyRevision, '復原'); await idle();
      check(latest.outputImage === before, '全域復原還原原生輸出');
      post('redoEdit'); await until(() => latest.liquifyRevision === revision, '重做'); await idle();
      check(latest.outputImage === warped, '全域重做重現相同原生輸出');
    }
    document.querySelector('[data-liquify-toggle]').click();
    // canvas 預設即有 300×150；先讓首個影格建立來源，避免在解碼開始前誤判可操作。
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    await until(() => {
      const canvas = document.querySelector('.liquify-overlay'), radius = document.getElementById('liquifyRadius');
      return canvas && canvas.width > 1 && radius && !radius.disabled && !document.querySelector('.liquify-status');
    }, 'WebView載入正式液化控制列與網格');
    check(!!document.querySelector('.liquify-panel'), '真實WebView開啟液化筆刷');
    const select = document.getElementById('liquifyMode'), style = getComputedStyle(select);
    check(select.classList.contains('compact-select') && parseFloat(style.height) === 28 &&
      parseFloat(style.paddingRight) >= 29 && style.backgroundImage !== 'none', '液化模式選單使用共用高度、間距與箭頭');
    brushWheel('.liquify-overlay', 'liquifyRadius', 'liquifyRadiusValue', '.liquify-cursor', '液化筆刷');
    document.querySelector('[data-liquify-action="done"]').click();
    check(!document.querySelector('.liquify-overlay'), '完成後返回正式照片預覽');
    document.querySelector('[data-repair-toggle]').click();
    await until(() => {
      const canvas = document.querySelector('.repair-overlay'), control = document.getElementById('repairBrushSize');
      return canvas && canvas.width > 1 && control && !control.disabled && !latest.isRepairingImage;
    }, '準備真實修復筆刷');
    // 模型準備回覆晚於狀態事件，等前端解除 preparing 再測試。
    await wait(200);
    brushWheel('.repair-overlay', 'repairBrushSize', 'repairBrushSizeValue', '.repair-cursor', '修復筆刷');
    document.querySelector('[data-repair-action="done"]').click();
    window.runtime.EventsEmit('filmdevelop:smoke-export');
    await until(() => exported, '全解析匯出');
    check(!latest.isSavingImage, '液化可經正式匯出流程完成');
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,completed,liquifyRevision:latest.liquifyRevision,sourceSize:latest.sourceImageSize,previewSize:latest.previewOutputSize});
  } catch (error) {
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),completed,latest:{generation:latest.photoGeneration,revision:latest.liquifyRevision,rendering:latest.isRenderingPreview},result});
  }
})();
