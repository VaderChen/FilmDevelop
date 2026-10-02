(async function () {
  'use strict';
  let latest={}, measuring=null;
  const results=[], images=new Map(), imageKeys=['sourceImage','cropSourceImage','repairSourceImage','outputImage','loadingPreviewImage'];
  const original=window.handleNativeState;
  window.handleNativeState=function(payload) {
    const began=performance.now();
    latest=Object.assign({},latest,payload);
    original(payload);
    if(measuring) {
      measuring.stateUpdates++;
      measuring.stateHandlerMilliseconds+=performance.now()-began;
      measuring.imagePayloadBytes+=imageKeys.reduce((sum,key)=>sum+(payload[key]||'').length,0);
      if(payload.photoDirectory)measuring.thumbnailPayloadBytes+=JSON.stringify(payload.photoDirectory).length;
    }
  };
  let failure=null;
  window.handleNativeToast=function(payload) { failure=payload.message; };
  const frame=()=>new Promise(resolve=>requestAnimationFrame(resolve));
  async function until(test,label) {
    const started=performance.now();
    while(!test()) {
      if(failure)throw new Error(failure);
      if(performance.now()-started>30000)throw new Error('等待逾時：'+label);
      await frame();
    }
  }
  function post(action,fields) { window.PhotoNativeBridge.post(Object.assign({action},fields)); }
  async function measure(name,action,expected) {
    const began=performance.now(), revision=latest.previewRevision, generation=latest.photoGeneration;
    measuring={case:name,stateUpdates:0,stateHandlerMilliseconds:0,imagePayloadBytes:0,thumbnailPayloadBytes:0};
    action();
    await until(()=>latest.previewRevision!==revision&&expected()&&!latest.isRenderingPreview&&!!latest.outputImage,name);
    measuring.resultReceivedMilliseconds=performance.now()-began;
    await until(()=>{
      const image=document.querySelector('.preview-image');
      return image&&image.complete&&image.naturalWidth&&image.getAttribute('src')===latest.outputImage&&!image._pendingPreviewDecode;
    },'照片解碼顯示');
    measuring.imageReadyMilliseconds=performance.now()-began;
    const reveal=document.querySelector('.preview-image')._previewReveal;
    measuring.animationMilliseconds=reveal?reveal.animation.effect.getTiming().duration:0;
    if(generation===latest.photoGeneration&&measuring.animationMilliseconds>250)throw new Error('同張照片切換底片仍使用過長的開圖動畫');
    const key=latest.sourceFileName+':'+latest.selectedStyle;
    if(images.has(key)&&images.get(key)!==latest.outputImage)throw new Error('切回照片或底片後的成品不一致');
    measuring.reusedImageMatches=images.has(key);images.set(key,latest.outputImage);
    await until(()=>!document.querySelector('.preview-image')._previewReveal,'顯影動畫完成');
    measuring.visibleMilliseconds=performance.now()-began;
    measuring.source=latest.sourceFileName;measuring.style=latest.selectedStyle;
    results.push(measuring);measuring=null;
  }
  try {
    post('getState');
    await until(()=>latest.styles&&latest.styles.length===37,'宿主就緒');
    await measure('首次照片',()=>document.querySelector('[data-action="browsePhotoDirectory"]').click(),()=>latest.hasImage);
    const items=latest.photoDirectory.items;
    if(items.length!==2)throw new Error('量測目錄必須有兩張照片');
    const switchStyle=async(style,name)=>measure(name,()=>post('setStyle',{style}),()=>latest.selectedStyle===style);
    await switchStyle('filmEktar100','首次 Ektar');
    await switchStyle('filmPortra400','首次 Portra');
    await switchStyle('filmEktar100','切回 Ektar');
    await switchStyle('filmPortra400','切回 Portra');
    for(const index of [1,0,1,0]) {
      const item=items[index];
      await measure('切換照片 '+(index+1),()=>post('selectDirectoryPhoto',{id:item.id}),()=>latest.sourceFileName===item.name);
    }
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,results,settings:{fullResolution:latest.originalResolutionEditing,backend:latest.computeBackend},measurement:'指令送出至結果抵達、影像解碼及動畫完成；真實 Wails 視窗，未啟用 race 插樁。'});
  } catch(error) {
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),results,measuring});
  }
})();
