(async function () {
  'use strict';
  let latest={}, failure=null, measure=null;
  const results=[], original=window.handleNativeState;
  window.handleNativeState=function(payload) {
    latest=Object.assign({},latest,payload);original(payload);
    if(measure && payload.outputImage && payload.outputImage!==measure.lastImage) {
      measure.lastImage=payload.outputImage;
      measure.frames.push({milliseconds:performance.now()-measure.start,dragging:measure.dragging});
    }
  };
  window.handleNativeToast=payload=>{ failure=payload.message; };
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  async function until(test,label) {
    const started=performance.now();
    while(!test()) {
      if(failure)throw new Error(failure);
      if(performance.now()-started>30000)throw new Error('等待逾時：'+label);
      await wait(16);
    }
  }
  const post=(action,fields)=>window.PhotoNativeBridge.post(Object.assign({action},fields));
  async function settled() {
    await until(()=>!latest.isRenderingPreview && !!latest.outputImage,'完整預覽');
    await until(()=>{
      const image=document.querySelector('.preview-image');
      return image && image.getAttribute('src')===latest.outputImage && !image._pendingPreviewDecode && !image._previewReveal;
    },'影像顯示');
  }
  try {
    post('getState');
    await until(()=>latest.styles?.length===37,'底片目錄');
    const initial={computeBackend:latest.computeBackend,rawDecoderBackend:latest.rawDecoderBackend};
    if(window.editingSmokeMode==='restore') {
      if(initial.computeBackend!=='vulkan'||initial.rawDecoderBackend!=='software')throw new Error('重新啟動未保留加速選項');
      window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,initial,results:['重新啟動保留兩個加速選項']});return;
    }
    if(initial.computeBackend!=='system'||initial.rawDecoderBackend!=='system')throw new Error('新設定未預設系統加速');
    if(window.editingSmokeMode==='preferences') {
      post('setComputeBackend',{backend:'vulkan',requestID:'設定保存'});
      await until(()=>latest.computeBackend==='vulkan'&&!latest.isSwitchingComputeBackend,'計算加速保存');
      post('setRAWDecoderBackend',{backend:'software'});
      await until(()=>latest.rawDecoderBackend==='software','RAW 加速保存');
      window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,initial,results:['系統原生預設','兩個選項保存']});return;
    }
    document.querySelector('[data-action="browsePhotoDirectory"]').click();
    await until(()=>latest.hasImage,'照片');await settled();
    post('setStyle',{style:'filmPortra400'});
    await until(()=>latest.selectedStyle==='filmPortra400','底片');await settled();
    let previousImage='';
    for(const [index,startValue] of [20,65,35].entries()) {
      const slider=document.querySelector('[data-adjustment="intensity"]');
      if(!slider||slider.disabled)throw new Error('滑桿不可用');
      measure={start:performance.now(),dragging:true,lastImage:latest.outputImage,frames:[]};
      for(let i=0;i<20;i++) {
        slider.value=startValue+i;
        slider.dispatchEvent(new Event('input',{bubbles:true}));
        await wait(75);
      }
      measure.dragging=false;
      const released=performance.now(), oldRevision=latest.previewRevision;
      slider.dispatchEvent(new Event('change',{bubbles:true}));
      await until(()=>latest.previewRevision!==oldRevision && latest.adjustments[latest.selectedStyle].intensity===startValue+19,'最後參數');
      await settled();
      const frames=measure.frames, firstAfter=frames.find(frame=>!frame.dragging);
      const displayed=document.querySelector('.preview-image');
      if(Math.max(displayed.naturalWidth,displayed.naturalHeight)!==2048)throw new Error('放開後沒有恢復完整預覽尺寸');
      if(window.editingSmokeMode==='verify'&&!frames.some(frame=>frame.dragging))throw new Error('持續拖曳沒有產生預覽');
      results.push({case:'拖曳 '+(index+1),duringDragFrames:frames.filter(frame=>frame.dragging).length,
        firstFrameMilliseconds:frames[0]?.milliseconds??null,
        releaseToFirstFrameMilliseconds:firstAfter ? firstAfter.milliseconds-(released-measure.start) : null,
        releaseToSettledVisibleMilliseconds:performance.now()-released,finalValue:latest.adjustments[latest.selectedStyle].intensity});
      measure=null;
      if(index===1)previousImage=latest.outputImage;
    }
    // 一次手勢是一筆復原；清晰成品也必須與之前的同參數結果完全相同。
    post('undoEdit');
    await until(()=>latest.adjustments[latest.selectedStyle].intensity===84,'整個手勢復原');await settled();
    if(latest.outputImage!==previousImage)throw new Error('復原後成品與相同參數不一致');
    const interaction={style:latest.selectedStyle,photoGeneration:latest.photoGeneration,interactionID:'快速指令順序'};
    post('beginAdjustmentPreview',interaction);
    for(let value=10;value<=30;value++)post('updateAdjustment',Object.assign({},interaction,{key:'intensity',value}));
    post('endAdjustmentPreview',interaction);
    await until(()=>latest.adjustments[latest.selectedStyle].intensity===30,'快速連續指令的最後參數');await settled();
    post('undoEdit');
    await until(()=>latest.adjustments[latest.selectedStyle].intensity===84,'快速指令仍只產生一筆復原');await settled();
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,initial,results,measurement:'真實 Wails 滑桿，每 75 毫秒 input、20 次後 change；非 race 建置；完整預覽含影像解碼與淡入。'});
  } catch(error) {
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),results,latest:{style:latest.selectedStyle,rendering:latest.isRenderingPreview}});
  }
})();
