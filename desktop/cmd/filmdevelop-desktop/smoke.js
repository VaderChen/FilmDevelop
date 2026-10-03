(function () {
  'use strict';
  let stage = -10;
  let firstID = '', secondID = '', thumbnailCheck = false;
  let loadingThumbnailCheck = false, inlinePreviewCheck = false, inlineSubjectCheck = false;
  let switchInFlight = false, rejectNextComputeSwitch = false, lastComputeRequestID = '', expectedToast = null;
  let switchingRenders = 0;
  let holdCropCommand = false, heldCropCommand = null;
  const completed = [];
  const timings = {};

  const recentCommands = [];
  const originalPost = window.PhotoNativeBridge.post;
  window.PhotoNativeBridge.post = function (message) {
    if(holdCropCommand && message.action==='updateAdjustment' && message.cropValues) {heldCropCommand=message;return;}
    if(stage===12 && message.action==="previewFilmHover" && message.requestID!=="hover-smoke") return;
    if(message.action==='setComputeBackend') {
      lastComputeRequestID=message.requestID;
      if(rejectNextComputeSwitch) { message=Object.assign({},message,{backend:'invalid-smoke'});rejectNextComputeSwitch=false; }
    }
    recentCommands.push(message.action);if(recentCommands.length>12)recentCommands.shift();originalPost(message);
  };
  const fail = message => window.runtime.EventsEmit('filmdevelop:smoke-result', {passed:false, message, stage, completed, recentCommands, dom:document.body.innerText.slice(0,4000), html:document.querySelector('#app')?.innerHTML.slice(0,1200)});
  window.addEventListener('error', event => fail(event.message));
  window.addEventListener('unhandledrejection', event => fail(String(event.reason)));
  function command(action, fields) { window.PhotoNativeBridge.post(Object.assign({action},fields)); }
  function onReply(reply) {
    observe(reply);
    if (reply.function === 'handleNativeToast') {
      if(expectedToast && reply.payload.message===expectedToast) { expectedToast=null;observe({});return; }
      if(stage===-6 && reply.payload.message.startsWith('已匯出：')) return; // 定影結束後重播的提示。
      if (stage === 5 && reply.payload.message.startsWith('已匯出：')) {
        completed.push('原尺寸匯出');
        // 舊版顯影動畫在寫入完成後仍須定影；等畫面解鎖才模擬下一步操作。
        stage=-6;
        const revealDeadline=Date.now()+15000;
        const waitForReveal=()=>{
          if(document.getElementById('exportDevelopment').hidden&&!document.getElementById('app').inert){
            stage=6;window.runtime.EventsEmit('filmdevelop:smoke-reopen');
          }else if(Date.now()>revealDeadline){fail('匯出顯影對話框未完成收尾');}
          else {setTimeout(waitForReveal,25);}
        };
        waitForReveal();
      } else { fail(reply.payload.message); }
      return;
    }
    if (reply.function === 'handlePhotoDirectoryState') {
      const items = reply.payload.items || [];
      if (items.length===3 && items.filter(item=>item.thumbnail).length===2 && items.find(item=>item.name==='zz-invalid.jpg').failed) {
        if (!thumbnailCheck) completed.push('可視照片縮圖與損壞檔案處理');
        thumbnailCheck=true;
      }
      return;
    }
    if (reply.function !== 'handleNativeState') return;
    const s = latest;
    if(s.isSwitchingComputeBackend) {
      try { verifyComputeSwitchDialog(); } catch(error) { return fail(String(error)); }
      if(s.isRenderingPreview)switchingRenders++;
    }
    if (s.isRenderingPreview && !s.isSwitchingComputeBackend && !switchInFlight && !s.isComputing && !s.isSavingImage && !s.isRepairingImage && !s.isMCPMutating) {
      if (!document.getElementById('busyDialog').hidden || document.getElementById('app').inert) {
        return fail('一般預覽出現浮動對話框或鎖住介面');
      }
      const frame = document.querySelector('.preview-frame');
      if (frame) {
        try { verifyInlineFeedback(); } catch(error) { return fail(String(error)); }
        inlinePreviewCheck = true;
        if (s.previewPhase === 'subject') {
          const feedback = document.querySelector('[data-preview-feedback]');
          if (feedback.querySelector('[data-action="cancelSubjectMaskDetection"]').hidden || !feedback.textContent.includes('正在偵測主體遮罩')) return fail('下方狀態列缺少偵測提示或取消操作');
          inlineSubjectCheck = true;
        }
      }
      if (s.loadingPreviewImage && !s.outputImage) {
        const selected = s.photoDirectory.items.find(item=>item.selected);
        const preview = document.querySelector('.preview-image');
        if (!selected || selected.thumbnail !== s.loadingPreviewImage || preview?.getAttribute('src') !== s.loadingPreviewImage) return fail('主預覽底圖未沿用列表縮圖 '+JSON.stringify({phase:s.previewPhase,selected:!!selected,listMatches:selected?.thumbnail===s.loadingPreviewImage,imageMatches:preview?.getAttribute('src')===s.loadingPreviewImage,preview:!!preview}));
        loadingThumbnailCheck = true;
      }
    }
    if (stage === -10) {
      const button = document.querySelector('[data-action="browsePhotoDirectory"]');
      if (!button || !document.querySelector('.photo-directory')) return fail('缺少目錄按鈕或下方列表空狀態 '+JSON.stringify({styles:s.styles?.length,directory:s.photoDirectory,keys:Object.keys(s)}));
      completed.push('下方列表空狀態與選目錄按鈕');stage=-11;emptyComputeSwitches();return;
    }
    if (stage === 10 && !s.hasImage && s.photoDirectory.items.length===0 && !s.photoDirectory.isScanning) {
      if (!document.querySelector('.photo-directory-empty')) return fail('空目錄提示未顯示');
      completed.push('切換空目錄清除舊照片與列表');stage=13;
      window.runtime.EventsEmit('filmdevelop:smoke-native-open');return;
    }
    if (!s.hasImage || s.isRenderingPreview || !s.outputImage) return;
    const adjustment = s.adjustments[s.selectedStyle];
    if (stage === 13) {
      completed.push('原生開檔事件等待畫面並恢復照片');
      const slider=document.querySelector('[data-adjustment="intensity"]');
      if(!slider||slider.disabled)return fail('關閉保存測試找不到可用滑桿');
      stage=14;slider.value=42;slider.dispatchEvent(new Event('input',{bubbles:true}));
      // 不觸發 change，交由真實關閉流程提交尚在前端等待的編輯。
      window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,completed,timings,closeSaved:{style:s.selectedStyle,intensity:42}});return;
    }
    if (stage === 0) {
      const image = new Image();
      stage = -1;
      image.onerror = () => fail('預覽影像無法解碼');
      image.onload = async function () {
        try {
        if (image.naturalWidth !== 97 || image.naturalHeight !== 65 || s.styles.length !== 38) return fail('原圖尺寸或底片目錄不符');
        if (!loadingThumbnailCheck || !inlinePreviewCheck) return fail('未觀察到先顯示縮圖及下方進度提示的流程');
        completed.push('列表與主預覽共用縮圖，等待文字與轉圈位於照片下方');
        await verifyPreviewReveal();
        await verifyRAWDecoderSetup();
        completed.push('開啟原圖與 38 個底片／相容配方目錄');
        const items = s.photoDirectory.items;
        if (items.length!==3 || items[0].name!=='photo2.bmp' || items[1].name!=='photo10.bmp' || !items[0].selected) return fail('目錄自然排序、選取或檔案過濾不符');
        firstID=items[0].id;secondID=items[1].id;
        if (document.querySelectorAll('[data-directory-photo]').length!==3) return fail('下方照片列表未顯示');
        completed.push('目錄掃描、自然排序及下方列表');
        const button = document.querySelector('[data-select-style="filmPortra400"]');
        if (!button) return fail('既有前端未顯示底片選項');
        stage = 1; button.click();
        } catch (error) { fail(String(error)); }
      };
      image.src=s.outputImage;
    } else if (stage === 1 && s.selectedStyle === 'filmPortra400') {
      completed.push('既有前端按鈕切換底片'); stage=2;
      command('updateAdjustment',{key:'exposure',value:12,photoGeneration:s.photoGeneration});
    } else if (stage === 2 && adjustment.exposure === 12) {
      completed.push('Go 配方修改與原生預覽'); stage=3; command('undoEdit');
    } else if (stage === 3 && adjustment.exposure !== 12) {
      completed.push('復原'); stage=4; command('redoEdit');
    } else if (stage === 4 && adjustment.exposure === 12) {
      completed.push('重做'); stage=5; window.runtime.EventsEmit('filmdevelop:smoke-export');
    } else if (stage === 6 && s.selectedStyle === 'filmPortra400' && adjustment.exposure === 12 && !s.canUndo) {
      completed.push('重新開圖保留原生配方'); stage=7;
      const button=Array.from(document.querySelectorAll('[data-directory-photo]')).find(node=>node.dataset.directoryPhoto===secondID);
      if (!button) return fail('找不到第二張縮圖按鈕');button.click();
    } else if (stage === 7 && s.sourceFileName === 'photo10.bmp' && s.selectedStyle === 'original') {
      if (adjustment.exposure!==0) return fail('其他照片繼承了前一張的調整');
      completed.push('縮圖按鈕切換照片與配方隔離');stage=8;
      const button=Array.from(document.querySelectorAll('[data-directory-photo]')).find(node=>node.dataset.directoryPhoto===firstID);button.click();
    } else if (stage === 8 && s.sourceFileName === 'photo2.bmp' && adjustment.exposure === 12 && s.selectedStyle === 'filmPortra400') {
      if (!thumbnailCheck) return setTimeout(()=>command('getState'),100);
      completed.push('切回照片恢復調整');advanced();
    }
  }
  ['handleUIPreferences','handleNativeState','handleNativeToast','handlePhotoDirectoryState','handleHostDialog','handleHostMenu','handleFilmHoverPreview','handlePhotoEXIF','handleRepairPreparation','handleRepairResult','handleDesktopCommand'].forEach(function(name){
    const original=window[name];window[name]=function(payload){try{original(payload);onReply({function:name,payload})}catch(error){fail('前端回覆處理失敗：'+error.stack)}};
  });
  let latest={}, directory={}, hover, hostDialog, hostMenu, exif, repairPrepared, repairResult, uiPreferences, mcpDone=false;
 window.runtime.EventsOn("filmdevelop:smoke-mcp-done",function(){mcpDone=true;observe({})});
  const waiters=[];
  function observe(reply) {
    if(reply.function==='handleUIPreferences')uiPreferences=reply.payload;
    if(reply.function==='handleNativeState') latest=Object.assign({},latest,reply.payload);
    if(reply.function==='handlePhotoDirectoryState') directory=reply.payload;
    if(reply.function==='handleFilmHoverPreview') hover=reply.payload;
    if(reply.function==='handleHostDialog') hostDialog=reply.payload;
    if(reply.function==='handleHostMenu') hostMenu=reply.payload;
    if(reply.function==='handlePhotoEXIF') exif=reply.payload;
    if(reply.function==='handleRepairPreparation')repairPrepared=reply.payload;
    if(reply.function==='handleRepairResult')repairResult=reply.payload;
    for(const item of [...waiters]) if(item.test()) {clearTimeout(item.timer);waiters.splice(waiters.indexOf(item),1);item.resolve()}
  }
  function until(test,label,timeout=20000) {if(test())return Promise.resolve();return new Promise((resolve,reject)=>{const item={test,resolve};item.timer=setTimeout(()=>{waiters.splice(waiters.indexOf(item),1);reject(new Error('等待逾時：'+label))},timeout);waiters.push(item)})}
  function idle(test) {return until(()=>latest.hasImage&&!latest.isRenderingPreview&&test(latest),'編輯結果')}
  function nextFrame() {return new Promise(resolve=>requestAnimationFrame(resolve))}
  function verifyHostDialogButtons(role) {
    const dialog=document.querySelector('dialog[open]');
    const action=dialog.querySelector('[data-role="'+role+'"]'),cancel=dialog.querySelector('[data-role="secondary"]');
    if(!action||!cancel||action===cancel)throw new Error('對話框按鈕缺少操作語意');
    const a=action.getBoundingClientRect(),c=cancel.getBoundingClientRect();
    if(Math.abs(a.top-c.top)>1||c.right>a.left||getComputedStyle(action).whiteSpace!=='nowrap')throw new Error('對話框按鈕未同列排列');
    if(getComputedStyle(action).backgroundColor===getComputedStyle(cancel).backgroundColor)throw new Error('確定／刪除與取消未區分顏色');
    return getComputedStyle(action).backgroundColor;
  }
  async function readUIPreferences() {
    uiPreferences=null;command('syncUIPreferences',{initial:true});
    await until(()=>uiPreferences,'重新讀取 Go 介面偏好');return uiPreferences;
  }
  function verifyComputeSwitchDialog() {
    const dialog=document.getElementById('busyDialog'), spinner=dialog.querySelector('.spinner');
    const style=getComputedStyle(spinner);
    if(dialog.hidden||!document.getElementById('app').inert||document.getElementById('busyTitle').textContent!=='正在切換計算加速')throw new Error('切換加速時沒有顯示等待對話框');
    if(style.animationName!=='spin'||style.animationPlayState!=='running'||parseFloat(style.animationDuration)<=0)throw new Error('切換對話框缺少轉圈動畫');
    if(!document.getElementById('busyCancel').hidden)throw new Error('切換加速出現不適用的取消按鈕');
  }
  async function switchComputeBackend(backend,reject=false) {
    const select=document.getElementById('computeBackendSelect'), stale=Object.assign({},latest);
    const rendersBefore=switchingRenders, hadImage=latest.hasImage;
    if(!select||select.disabled)throw new Error('計算加速選單無法操作');
    switchInFlight=true;rejectNextComputeSwitch=reject;
    if(reject)expectedToast='不支援此運算或解析後端';
    select.value=backend;select.dispatchEvent(new Event('change',{bubbles:true}));
    const requestID=lastComputeRequestID;
    if(!requestID)throw new Error('切換要求缺少識別');
    verifyComputeSwitchDialog();
    window.handleNativeState(stale);
    verifyComputeSwitchDialog();
    await until(()=>latest.computeBackendSwitchRequestID===requestID&&!latest.isSwitchingComputeBackend&&!latest.isRenderingPreview&&!expectedToast,'切換加速完成');
    switchInFlight=false;
    if(!document.getElementById('busyDialog').hidden||document.getElementById('app').inert||document.getElementById('computeBackendSelect').disabled)throw new Error('切換結束後對話框或鎖定未解除');
    if(document.activeElement.id!=='computeBackendSelect')throw new Error('切換結束後焦點未回到加速選單');
    if(latest.computeBackend!==(reject?stale.computeBackend:backend))throw new Error('切換後的運算設定不符');
    if(hadImage&&!reject&&switchingRenders===rendersBefore)throw new Error('切換對話框沒有涵蓋實際預覽');
    if(latest.photoGeneration!==stale.photoGeneration||JSON.stringify(latest.adjustments)!==JSON.stringify(stale.adjustments))throw new Error('切換加速更動了照片或調整');
  }
  async function emptyComputeSwitches() {
    try {
      window.handleDesktopCommand('settings');document.querySelector('[data-settings-section="acceleration"]').click();
      await switchComputeBackend('vulkan');await switchComputeBackend('system');
      completed.push('無照片切換加速：立即顯示動畫、過期回覆隔離及完成解鎖');
      await switchComputeBackend('vulkan',true);
      completed.push('切換加速失敗：關閉動畫對話框、恢復焦點與原設定');
      window.handleDesktopCommand('home');stage=0;document.querySelector('[data-action="browsePhotoDirectory"]').click();
    } catch(error) { fail(String(error)+'\n'+(error.stack||'')); }
  }
  function verifyInlineFeedback() {
    const frame=document.querySelector('.preview-frame'), feedback=document.querySelector('[data-preview-feedback]');
    const spinner=feedback?.querySelector('.preview-spinner');
    if(!feedback||feedback.hidden||!spinner||spinner.hidden||!feedback.querySelector('[data-preview-feedback-title]').textContent)throw new Error('預覽處理中未顯示等待文字與轉圈');
    if(frame.contains(feedback)||!feedback.closest('.canvas-footer')||feedback.getBoundingClientRect().top<frame.getBoundingClientRect().bottom-1)throw new Error('進度提示覆蓋照片，未位於顯示區下方');
  }
  async function verifyRAWDecoderSetup() {
    const originalImage=document.querySelector('.preview-image').getAttribute('src');
    window.handleNativeState({rawDecoderRequired:true,previewFailed:true});
    const feedback=document.querySelector('[data-preview-feedback]');
    if(feedback.hidden||feedback.querySelector('[data-action="setupRAWDecoder"]').hidden||!feedback.querySelector('.preview-spinner').hidden||document.querySelector('dialog[open]'))throw new Error('缺少解碼器時未在照片下方提供安裝入口');
    if(document.querySelector('.preview-image').getAttribute('src')!==originalImage)throw new Error('缺少解碼器時移除了現有照片');
    feedback.querySelector('[data-action="setupRAWDecoder"]').click();
    await until(()=>document.querySelector('dialog[open]'),'RAW 解碼器安裝說明');
    const labels=Array.from(document.querySelectorAll('dialog[open] button')).map(b=>b.textContent);
    if(!labels.includes('Adobe 官方下載')||!labels.includes('重新偵測')||!labels.includes('取消'))throw new Error('解碼器安裝缺少官方下載或重新偵測操作');
    await choose('重新偵測');
    await idle(s=>!s.previewFailed&&!s.rawDecoderRequired);
    if(!document.querySelector('[data-action="setupRAWDecoder"]').hidden)throw new Error('重新偵測完成仍顯示安裝提示');
    completed.push('缺少 RAW 解碼器：照片下方安裝入口、官方下載說明、重新偵測及保留畫面');
  }
  async function verifyPreviewReveal() {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      completed.push('減少動態效果設定下直接顯示完成影像');return;
    }
    let image=document.querySelector('.preview-image');
    for(let i=0;i<60&&!image._previewReveal;i++) await nextFrame();
    const reveal=image._previewReveal;
    if(!reveal)throw new Error('完成影像沒有從縮圖逐步顯影');
    const frames=reveal.animation.effect.getKeyframes();
    if(Number(frames[0].opacity)!==0||Number(frames[frames.length-1].opacity)!==1||reveal.animation.effect.getTiming().duration<500)throw new Error('顯影未由 0% 漸增至 100%');
    reveal.animation.pause();reveal.animation.currentTime=reveal.animation.effect.getTiming().duration/2;
    await nextFrame();
    const opacity=Number(getComputedStyle(image).opacity), frame=image.parentElement;
    if(opacity<=0||opacity>=1||!reveal.base.isConnected)throw new Error('顯影中途未保留縮圖底層');
    function visibleRect(img) {
      const box=img.getBoundingClientRect(), scale=Math.min(box.width/img.naturalWidth,box.height/img.naturalHeight);
      const width=img.naturalWidth*scale,height=img.naturalHeight*scale;
      return {width,height,left:box.left+(box.width-width)/2,top:box.top+(box.height-height)/2};
    }
    function verifyGeometry() {
      const front=visibleRect(image),base=visibleRect(reveal.base);
      if(Object.keys(front).some(key=>Math.abs(front[key]-base[key])>1))throw new Error('縮圖與編輯預覽的顯示範圍不一致：'+JSON.stringify({front,base,style:reveal.base.getAttribute('style')}));
    }
    verifyGeometry();
    verifyInlineFeedback();
    command('getState');
    for(let i=0;i<60&&image.parentElement===frame;i++) await nextFrame();
    if(document.querySelector('.preview-image')!==image||image._previewReveal!==reveal||!reveal.base.isConnected)throw new Error('狀態更新中斷顯影動畫');
    verifyGeometry();
    document.querySelector('.preview-pane').style.paddingBottom='53px';
    await nextFrame();await nextFrame();
    verifyGeometry();
    document.querySelector('.preview-pane').style.paddingBottom='';
    await nextFrame();await nextFrame();
    verifyGeometry();
    document.querySelector('.preview-pane').style.width='70%';
    await nextFrame();await nextFrame();
    verifyGeometry();
    document.querySelector('[data-zoom="zoomIn"]').click();
    verifyGeometry();
    document.querySelector('[data-zoom="zoomFit"]').click();
    document.querySelector('.preview-pane').style.width='';
    await nextFrame();await nextFrame();
    verifyGeometry();
    reveal.animation.play();await reveal.animation.finished;await nextFrame();
    if(reveal.base.isConnected||Number(getComputedStyle(image).opacity)!==1)throw new Error('顯影完成後未釋放縮圖底層');
    if(!document.querySelector('[data-preview-feedback]').hidden||document.querySelector('.preview-status').hidden)throw new Error('完成顯影後進度提示未結束');
    completed.push('完成影像 0→100% 淡入、狀態更新延續動畫及底圖釋放');
    completed.push('縮圖與編輯圖共用顯示範圍：淡入中改變寬高、放大及符合視窗均同步');
  }
  async function setting(action,field,value) {command(action,{enabled:value});await idle(s=>s[field]===value)}
  async function verifyCropEditing() {
    const cropDefaults={cropAspectRatio:'original',cropRotation:0,cropScale:100,cropWidth:100,cropHeight:100,cropHorizontalPosition:0,cropVerticalPosition:0};
    const current=()=>latest.adjustments[latest.selectedStyle];
    const geometry=()=>Object.fromEntries(Object.keys(cropDefaults).map(key=>[key,current()[key]]));
    const selectCrop=value=>{const select=document.querySelector('#previewCropAspectRatio');select.value=value;select.dispatchEvent(new Event('change',{bubbles:true}));};
    await window.flushPhotoUI();
    const menu=document.querySelector('#previewCropAspectRatio');
    if(menu.lastElementChild.value!=='reset'||menu.lastElementChild.textContent!=='還原'||menu.lastElementChild.previousElementSibling.tagName!=='HR')throw new Error('裁切選單缺少末尾的還原與分隔線');
    const originalGeometry=geometry(), originalAdjustment=JSON.stringify(current());
    selectCrop('free');await window.flushPhotoUI();
    const box=document.querySelector('[data-crop-box]');
    // 用現有滑鼠／鍵盤入口縮小、位移並旋轉，驗證提交的是整筆幾何變更。
    let rect=box.getBoundingClientRect();
    box.querySelector('[data-crop-handle="se"]').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,button:0,clientX:rect.right,clientY:rect.bottom}));
    document.dispatchEvent(new MouseEvent('mousemove',{bubbles:true,clientX:rect.left+rect.width*.72,clientY:rect.top+rect.height*.76}));
    document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));
    box.querySelector('[data-crop-rotate]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',shiftKey:true,bubbles:true}));
    const editedSource=document.querySelector('.crop-source-image'), editedTransform=editedSource.style.transform;
    const editedBoxStyle=box.getAttribute('style'), source=editedSource.getAttribute('src');
    if(!editedTransform.includes('rotate(1deg)'))throw new Error('旋轉鍵盤入口未生效');
    const stale=Object.assign({},latest);
    holdCropCommand=true;heldCropCommand=null;
    document.querySelector('[data-crop-done]').click();
    function checkHeld() {
      const held=document.querySelector('.crop-preview-hold'),image=held?.querySelector('.crop-held-image');
      if(!held||!image||image.getAttribute('src')!==source||image.style.transform!==editedTransform||held.querySelector('.crop-frame-box')?.getAttribute('style')!==editedBoxStyle)throw new Error('等待顯影時裁切／旋轉畫面被原圖取代');
      if(held.querySelector('[data-crop-box],button,.preview-image')||!held.inert)throw new Error('等待畫面仍可操作或混入預覽座標');
      const frame=held.parentElement,style=getComputedStyle(held);
      if(style.backgroundColor==='rgba(0, 0, 0, 0)'||Math.abs(held.getBoundingClientRect().width-frame.clientWidth)>1)throw new Error('裁切等待圖層未覆蓋原圖');
      verifyInlineFeedback();
    }
    checkHeld();await nextFrame();checkHeld();
    window.handleNativeState(stale);checkHeld();
    if(!heldCropCommand||heldCropCommand.cropValues.cropWidth>=100||heldCropCommand.cropValues.cropRotation!==1)throw new Error('完成未送出完整裁切與旋轉');
    const originalDecode=HTMLImageElement.prototype.decode;
    let releaseDecode;const decodeGate=new Promise(resolve=>{releaseDecode=resolve});
    HTMLImageElement.prototype.decode=function(){const result=originalDecode.call(this);return this.src!==stale.outputImage&&this.src!==source?result.then(()=>decodeGate):result;};
    try {
      holdCropCommand=false;originalPost(heldCropCommand);
      await idle(s=>s.previewRevision>stale.previewRevision&&s.adjustments[s.selectedStyle].cropRotation===1);
      checkHeld();
    } finally {HTMLImageElement.prototype.decode=originalDecode;releaseDecode();holdCropCommand=false;}
    await window.flushPhotoUI();await nextFrame();
    if(document.querySelector('.crop-preview-hold')||document.querySelector('.preview-image').getAttribute('src')!==latest.outputImage)throw new Error('裁切成品解碼後未取代等待畫面');
    const editedGeometry=geometry();
    command('undoEdit');await idle(s=>s.previewRevision>stale.previewRevision&&JSON.stringify(geometry())===JSON.stringify(originalGeometry));
    command('redoEdit');await idle(()=>JSON.stringify(geometry())===JSON.stringify(editedGeometry));await window.flushPhotoUI();
    completed.push('裁切／旋轉保留現有畫面，隔離舊回覆，解碼完成才交接，整筆復原與重做');
    // 完成後重新進入編輯，還原也須保留現有畫面，且不能重設色彩配方。
    document.querySelector('[data-crop-edit]').click();await window.flushPhotoUI();
    const editedAdjustment=JSON.stringify(current());
    selectCrop('reset');
    if(!document.querySelector('.crop-preview-hold'))throw new Error('還原時未保留當前裁切畫面');
    await idle(()=>JSON.stringify(geometry())===JSON.stringify(cropDefaults));await window.flushPhotoUI();
    if(document.querySelector('.crop-preview-hold')||JSON.stringify(current())!==originalAdjustment)throw new Error('還原更動了裁切以外的參數或等待圖層未釋放');
    command('undoEdit');await idle(()=>JSON.stringify(current())===editedAdjustment);
    command('redoEdit');await idle(()=>JSON.stringify(current())===originalAdjustment);await window.flushPhotoUI();
    completed.push('裁切選單末尾分隔線與還原：原始尺寸、零旋轉、保留配方、復原與重做');
    // 再次還原命中相同圖像快取，也必須結束等待；取消不提交新歷程。
    const revision=latest.previewRevision;selectCrop('reset');await idle(s=>s.previewRevision>revision);await window.flushPhotoUI();
    if(document.querySelector('.crop-preview-hold'))throw new Error('相同結果的還原快取未釋放等待畫面');
    selectCrop('oneOne');document.querySelector('[data-crop-cancel]').click();
    if(document.querySelector('[data-crop-box],.crop-preview-hold')||JSON.stringify(current())!==originalAdjustment)throw new Error('取消裁切未恢復原狀');
    completed.push('重複還原、相同影像快取與取消裁切');
  }
  async function menu(action,fields,choice) {hostMenu=null;command(action,fields);await until(()=>hostMenu,'操作選單');if(document.querySelector('dialog[open]'))throw new Error('操作選單仍然使用對話框');if(choice)await choose(choice)}
  async function choose(label) {
    const buttons=Array.from(document.querySelectorAll('dialog[open] button, .host-menu-item'));
    const button=buttons.find(b=>b.dataset.label===label||b.textContent===label);
    if(!button)throw new Error('找不到選項：'+label);
    const input=document.querySelector('dialog[open] input');
    if(input)input.dispatchEvent(new Event('input',{bubbles:true}));
    hostDialog=null;button.click();
  }
  function menuKey(key) {document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));}
  async function verifyContextMenus(custom) {
    hostMenu=null;
    document.querySelector('.preview-frame').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:innerWidth-4,clientY:innerHeight-4}));
    await until(()=>hostMenu,'預覽右鍵選單');
    const root=document.querySelector('.host-menu'),r=root.getBoundingClientRect();
    if(document.querySelector('dialog[open]')||document.getElementById('app').inert||root.querySelector('h2')||r.right>innerWidth||r.bottom>innerHeight||r.height>570)throw new Error('選單仍為大型對話框或超出視窗');
    if(root.querySelectorAll('[role=separator]').length<3||root.querySelector('.host-menu-item').getBoundingClientRect().height>32)throw new Error('選單缺少分組或仍是大按鈕');
    const apply=root.querySelector('[data-command="apply"]');
    if(apply.getAttribute('aria-disabled')!=='true')throw new Error('未複製參數卻可套用');
    apply.click();if(!root.isConnected)throw new Error('停用項目仍可執行');
    await choose('分級');
    const sub=document.querySelector('.host-menu[data-level="1"]'),sr=sub.getBoundingClientRect();
    if(!sub||sr.right>innerWidth||sr.bottom>innerHeight||sr.left<0)throw new Error('子選單超出視窗');
    menuKey('ArrowLeft');if(document.querySelector('.host-menu[data-level="1"]')||document.activeElement.dataset.label!=='分級')throw new Error('左鍵未回上層');
    menuKey('ArrowRight');menuKey('End');menuKey('Enter');
    await until(()=>directory.items?.find(i=>i.id===firstID)?.rating===5,'鍵盤分級保存');
    completed.push('緊湊右鍵選單、分隔線、邊緣避讓、停用狀態及方向鍵子選單');
    await menu('showPreviewMenu',{id:firstID,ids:[firstID,secondID]},'分級');
    if(document.querySelector('[data-command="rating:5"]').getAttribute('aria-checked')!=='mixed')throw new Error('多選缺少混合分級');
    await choose('★★★');await until(()=>[firstID,secondID].every(id=>directory.items.find(i=>i.id===id).rating===3),'多選分級');
    await menu('showPreviewMenu',{id:firstID,ids:[firstID]},'分類');await choose('新增分類…');
    await until(()=>document.querySelector('dialog[open] input'),'新增分類輸入');
    document.querySelector('dialog[open] input').value='Smoke 分類';await choose('確定');
    await until(()=>directory.items.find(i=>i.id===firstID).tags.includes('Smoke 分類'),'新增分類保存');
    await menu('showPreviewMenu',{id:firstID,ids:[firstID]},'分類');
    const tag=Array.from(document.querySelectorAll('.host-menu-item')).find(i=>i.dataset.label==='Smoke 分類');
    if(tag.getAttribute('aria-checked')!=='true')throw new Error('分類沒有勾選');
    await choose('移除未使用的分類…');
    if(document.querySelector('.host-menu[data-level="2"] .host-menu-item').getAttribute('aria-disabled')!=='true')throw new Error('使用中的分類可移除');
    menuKey('Escape');
    await menu('showPreviewMenu',{id:firstID,ids:[firstID]},'分類');await choose('清除照片分類');
    await until(()=>!directory.items.find(i=>i.id===firstID).tags.length,'清除分類');
    completed.push('多選混合勾選、分類子選單及命名對話框保存');
    hostMenu=null;
    const film=document.querySelector('[data-select-style="'+custom.id+'"], [data-film-stock="'+custom.id+'"]');
    if(!film)throw new Error('找不到自訂底片右鍵入口');
    film.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:20,clientY:120}));await until(()=>hostMenu,'自訂底片選單');
    await choose('重新命名');await until(()=>document.querySelector('dialog[open] input'),'重新命名輸入');
    document.querySelector('dialog[open] input').value='Smoke 底片更名';await choose('確定');
    await until(()=>latest.styles.some(i=>i.title==='Smoke 底片更名'),'底片更名保存');
    await menu('showPreviewMenu',{id:firstID,ids:[firstID]});
    document.body.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));if(document.querySelector('.host-menu'))throw new Error('點擊外部未關閉選單');
    const thumb=document.querySelector('[data-directory-photo="'+firstID+'"]');thumb.focus();hostMenu=null;
    thumb.dispatchEvent(new KeyboardEvent('keydown',{key:'F10',shiftKey:true,bubbles:true,cancelable:true}));await until(()=>hostMenu,'Shift F10 選單');menuKey('Escape');
    if(document.activeElement.dataset.directoryPhoto!==firstID)throw new Error('關閉選單未回到觸發照片');
    completed.push('自訂底片選單、外部取消及 Shift F10 鍵盤入口');
  }
  async function advanced() {
    try {
      stage=12;
      command('updateAdjustment',{key:'skinSmoothing',value:40});await idle(s=>s.adjustments[s.selectedStyle].skinSmoothing===40);
      if(!inlineSubjectCheck||!document.getElementById('busyDialog').hidden||document.getElementById('app').inert)throw new Error('主體偵測缺少下方提示或鎖住介面');
      completed.push('主體遮罩偵測在下方顯示進度，保持介面可用');
      command('updateAdjustment',{key:'skinSmoothing',value:41});await until(()=>latest.isRenderingPreview&&latest.previewPhase==='subject','主體偵測階段');
      document.querySelector('[data-preview-feedback] [data-action="cancelSubjectMaskDetection"]').click();
      await idle(s=>s.adjustments[s.selectedStyle].skinSmoothing===41);
      completed.push('下方取消偵測按鈕中止遮罩工作並完成預覽');
      command('undoEdit');await idle(s=>s.adjustments[s.selectedStyle].skinSmoothing===40);
      command('undoEdit');await idle(s=>s.adjustments[s.selectedStyle].skinSmoothing===0);
      command('setLanguage',{preference:'english'});await idle(s=>s.language==='english');
      if(document.documentElement.lang!=='en')throw new Error('英文介面未切換');
      command('setLanguage',{preference:'traditionalChinese'});await idle(s=>s.language==='traditionalChinese');
      if(document.documentElement.lang!=='zh-Hant')throw new Error('繁體中文介面未還原');
      completed.push('語言偏好、英文與繁體中文介面切換');
      window.runtime.EventsEmit('filmdevelop:smoke-menu','設定…');await until(()=>document.querySelector('[data-page="settings"][aria-current="page"]'),'系統設定選單');
      document.querySelector('[data-settings-section="acceleration"]').click();
      await switchComputeBackend('vulkan');await switchComputeBackend('system');
      completed.push('系統原生與 Vulkan 雙向切換：動畫涵蓋預覽，保留照片與配方');
      window.runtime.EventsEmit('filmdevelop:smoke-menu','工作台');await until(()=>document.querySelector('[data-page="home"][aria-current="page"]'),'系統工作台選單');
      completed.push('Go 系統選單與共用畫面命令');
      await setting('setShowAllFilms','showAllFilms',true);
      await setting('setExposureExpansionEnabled','exposureExpansionEnabled',true);
      await setting('setModernFilmExposureEnabled','modernFilmExposureEnabled',true);
      await setting('setHighlightProtectionEnabled','highlightProtectionEnabled',false);
      await setting('setLensCorrectionEnabled','lensCorrectionEnabled',false);
      await setting('setHDRFeatureEnabled','hdrFeatureEnabled',false);
      await setting('setOriginalResolutionEditing','originalResolutionEditing',true);
      completed.push('七項共用設定、原尺寸預覽與原生渲染契約');
      window.handleDesktopCommand('settings');document.querySelector('[data-settings-section="export"]').click();
      let exifToggle=document.querySelector('#export-writeExif');
      if(!latest.exportSettings.writeExif||exifToggle?.getAttribute('aria-checked')!=='true'||!exifToggle.closest('.settings-row').previousElementSibling.classList.contains('export-directory-row'))throw new Error('寫入 EXIF 未預設開啟或位置不符');
      exifToggle.click();await until(()=>latest.exportSettings.writeExif===false,'關閉 EXIF');
      if(document.querySelector('#export-writeExif').getAttribute('aria-checked')!=='false')throw new Error('EXIF 開關狀態未更新');
      document.querySelector('#export-writeExif').click();await until(()=>latest.exportSettings.writeExif===true,'開啟 EXIF');
      for(const format of ['jpeg','webp','tiff','png']) {
        const select=document.querySelector('#export-format');select.value=format;select.dispatchEvent(new Event('change',{bubbles:true}));
        await until(()=>latest.exportSettings.format===format,'輸出格式');
        if(document.querySelector('.export-format-heading')||!document.querySelector('[data-export-setting="'+({jpeg:'jpegQuality',png:'pngDepth',webp:'webpQuality',tiff:'tiffDepth'}[format])+'"]'))throw new Error('輸出格式標題重複或格式設定遺失');
      }
      window.handleDesktopCommand('home');completed.push('EXIF 預設開啟、開關儲存、指定位置及四種格式不重複標題');
      command('sampleWhiteBalance',{rgb:[0.65,0.5,0.35],style:latest.selectedStyle,customFilmID:null,photoGeneration:latest.photoGeneration,previewRevision:latest.previewRevision});
      await idle(s=>s.adjustments[s.selectedStyle].whiteBalanceWarmth!==0||s.adjustments[s.selectedStyle].whiteBalanceTint!==0);
      completed.push('白平衡取樣與 Swift 色彩運算');
      command('undoEdit');await idle(s=>s.adjustments[s.selectedStyle].whiteBalanceWarmth===0&&s.adjustments[s.selectedStyle].whiteBalanceTint===0);
      command('updateAdjustment',{adjustments:[{key:'cropAspectRatio',value:'free'},{key:'cropWidth',value:70}]});
      await idle(s=>s.adjustments[s.selectedStyle].cropWidth===70);
      if(!latest.cropSourceImage||latest.cropSourceImage===latest.outputImage)throw new Error('缺少完整座標的裁切預覽');
      command('setStyle',{style:'filmEktar100'});await idle(s=>s.selectedStyle==='filmEktar100');
      if(latest.adjustments.filmEktar100.cropWidth!==70)throw new Error('底片切換遺失裁切');
      command('undoEdit');await idle(s=>s.selectedStyle==='filmPortra400');
      command('undoEdit');await idle(s=>s.adjustments.filmPortra400.cropWidth===100);
      completed.push('裁切座標、底片切換與整次交易復原');
      await verifyCropEditing();
      const revision=latest.previewRevision;
      hover=null;command('previewFilmHover',{style:'filmEktar100',requestID:'hover-smoke',photoGeneration:latest.photoGeneration,previewRevision:revision});
      await until(()=>hover&&hover.requestID==='hover-smoke','底片懸停預覽');
      if(!hover.image||latest.selectedStyle!=='filmPortra400'||latest.previewRevision!==revision)throw new Error('懸停預覽更動了編輯狀態');
      command('cancelFilmHover');completed.push('底片懸停预覽保留編輯狀態');
      for(const node of document.querySelectorAll('.sidebar-style, .sidebar-film-divider, [data-directory-photo], .preview-file h1')){
        if(node.hasAttribute('title')||node.hasAttribute('data-tooltip'))throw new Error('照片／底片名稱仍有重複提示');
      }
      if(!document.querySelector('[data-action="browsePhotoDirectory"]').dataset.tooltip.includes('⇧⌘O'))throw new Error('誤移除快捷鍵提示');
      if(!document.querySelector('[data-white-balance-picker]').dataset.tooltip.includes('灰色或白色'))throw new Error('誤移除操作說明');
      completed.push('移除照片與底片重複名稱提示，保留快捷鍵及操作說明');
      const sizes=Array.from(document.querySelector('#photoThumbnailSize').options).map(option=>option.value);
      for(const size of sizes){
        const select=document.querySelector('#photoThumbnailSize');select.value=size;select.dispatchEvent(new Event('change',{bubbles:true}));
        const prefs=await readUIPreferences();
        if(prefs['photoStyle.thumbnailSize']!==size||document.querySelector('#photoThumbnailSize').value!==size||document.querySelector('.photo-directory').dataset.thumbnailSize!==size)throw new Error('縮圖尺寸保存／還原失敗：'+size);
      }
      completed.push('全部縮圖尺寸含超大可選取、保存並由 Go 還原');
      localStorage.setItem('photoStyle.enabledFilms.v2',JSON.stringify(['original',latest.selectedStyle]));
      hostDialog=null;command('saveCustomFilm');await until(()=>hostDialog,'儲存底片對話框');
      const confirmColor=verifyHostDialogButtons('primary');
      document.querySelector('dialog[open] input').value='Smoke 自訂底片';await choose('確定');await until(()=>latest.styles.some(s=>s.title==='Smoke 自訂底片'),'自訂底片保存');
      const custom=latest.styles.find(s=>s.title==='Smoke 自訂底片');
      const savedUI=await readUIPreferences(),enabled=JSON.parse(savedUI['photoStyle.enabledFilms.v2']);
      if(!enabled.includes(custom.id)||enabled.includes('filmGold200'))throw new Error('儲存底片未自動勾選，或更改其他底片選擇');
      window.handleDesktopCommand('films');
      if(!document.querySelector('[data-toggle-film="'+custom.id+'"]').checked)throw new Error('底片庫勾選未更新');
      window.handleDesktopCommand('home');
      hostDialog=null;command('deleteCustomFilm',{id:custom.id});await until(()=>hostDialog,'刪除底片確認');
      if(verifyHostDialogButtons('destructive')===confirmColor)throw new Error('刪除與確定未區分顏色');
      await choose('取消');
      completed.push('儲存底片自動勾選且保存；確定、取消、刪除同列並區分顏色');
      await idle(s=>s.selectedCustomFilmID===custom.id);
      command('undoEdit');await idle(s=>!s.selectedCustomFilmID);
      command('setStyle',{style:custom.id});await idle(s=>s.selectedCustomFilmID===custom.id);
      if(latest.adjustments.filmPortra400.exposure!==12)throw new Error('自訂底片未保留調整');
      command('undoEdit');await idle(s=>!s.selectedCustomFilmID);completed.push('自訂底片命名、套用與復原');
      command('updateStylePrompt',{style:'filmPortra400',language:'english',prompt:'Preserve neutral color and current crop.'});await until(()=>latest.styles.find(s=>s.id==='filmPortra400').prompts.english==='Preserve neutral color and current crop.','提示詞保存');
      command('resetStylePrompt',{style:'filmPortra400',language:'english'});await until(()=>latest.styles.find(s=>s.id==='filmPortra400').prompts.english!=='Preserve neutral color and current crop.','提示詞還原');completed.push('分語言底片提示詞保存與還原');
      await verifyContextMenus(custom);
      await menu('showPreviewMenu',{id:firstID,ids:[firstID]},'分級');await choose('★★★★');await until(()=>directory.items?.find(i=>i.id===firstID)?.rating===4,'照片分級');completed.push('照片右鍵選單與星級保存');
      exif=null;await menu('showPreviewMenu',{id:firstID,ids:[firstID]},'顯示 EXIF');await until(()=>exif,'EXIF');
      if(!exif.groups.some(g=>g.rows.some(r=>r.label==='影像尺寸')))throw new Error('EXIF 缺少影像尺寸');
      document.querySelector('#exifDialog [data-exif-close]').click();completed.push('原生影像中繼資料與 Go EXIF 分組');
      hostMenu=null;document.querySelector('[data-action="browsePhotoDirectory"]').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,clientX:100,clientY:80}));await until(()=>hostMenu,'最近目錄');if(!hostMenu.items.length)throw new Error('最近目錄遺失');menuKey('Escape');if(document.querySelector('.host-menu'))throw new Error('Esc 未關閉最近目錄選單');completed.push('最近開啟目錄選單');
      // 原生模型工作與引擎 Smoke 同樣最多等待兩分鐘；一般編輯仍維持 20 秒。
      let repairStarted=performance.now();
      repairPrepared=null;command('prepareRepairBrush',{photoGeneration:latest.photoGeneration});await until(()=>repairPrepared,'修復模型準備',120000);timings.repairPreparationMs=performance.now()-repairStarted;if(!repairPrepared.success)throw new Error('修復模型準備失敗');
      const oldRepair=latest.repairRevision||'';repairStarted=performance.now();repairResult=null;command('applyRepairBrush',{photoGeneration:latest.photoGeneration,repairRevision:oldRepair,strokes:[{radius:0.06,points:[{x:0.5,y:0.5}]}]});await until(()=>repairResult,'原生模型修復',120000);timings.repairInferenceMs=performance.now()-repairStarted;if(!repairResult.success)throw new Error('修復失敗');await idle(s=>(s.repairRevision||'')!==oldRepair);command('undoEdit');await idle(s=>(s.repairRevision||'')===oldRepair);completed.push('修復筆刷準備、原生模型推論與復原');
      window.runtime.EventsEmit('filmdevelop:smoke-mcp');await until(()=>mcpDone,'真實 MCP HTTP 與介面同步');completed.push('MCP 初始化、12 工具、切換底片、調整、預覽與匯出');
      const deadline=Date.now()+15000;
      while(!document.getElementById('exportDevelopment').hidden||document.getElementById('app').inert){
        if(Date.now()>deadline)throw new Error('MCP 匯出顯影對話框未完成收尾');
        await new Promise(resolve=>setTimeout(resolve,25));
      }
      stage=10;window.runtime.EventsEmit('filmdevelop:smoke-empty');
    } catch(error){fail(String(error)+"\n"+(error.stack||""))}
  }

  command('getState');
})();
