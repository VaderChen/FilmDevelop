(async function () {
  'use strict';
  const completed=[], toasts=[];
  let latest={}, dialog=null, menu=null, images=0, cancelUI=false;
  const command=(action,fields)=>window.PhotoNativeBridge.post(Object.assign({action},fields));
  const fire=action=>window.runtime.EventsEmit('filmdevelop:smoke-parity',action);
  const require=(ok,message)=>{if(!ok)throw new Error(message);completed.push(message);};
  async function until(test,message,timeout=30000){const start=Date.now();while(!test()){if(Date.now()-start>timeout)throw new Error('逾時：'+message);await new Promise(resolve=>setTimeout(resolve,25));}}
  async function idle(test){await until(()=>!latest.isRenderingPreview&&(!test||test()),'完成預覽與狀態更新');}
  async function resolve(value){const current=dialog||menu;dialog=menu=null;command('resolveDialog',{id:current.id,value});}
  const nativeState=window.handleNativeState;
  window.handleNativeState=function(payload){nativeState(payload);if(payload.isCancellingRepair)cancelUI=document.getElementById('busyCancel').disabled&&document.getElementById('busyCancel').textContent.includes('取消');};
  window.runtime.EventsOn('filmdevelop:reply',reply=>{
    if(reply.function==='handleNativeState'){latest=Object.assign(latest,reply.payload);if(reply.payload.outputImage)images++;}
    if(reply.function==='handleHostDialog')dialog=reply.payload;
    if(reply.function==='handleHostMenu')menu=reply.payload;
    if(reply.function==='handleNativeToast')toasts.push(reply.payload.message);
  });
  try{
    command('getState');await until(()=>latest.styles&&latest.styles.length,'宿主就緒');
    command('setLanguage',{preference:'zh-Hant'});await until(()=>latest.language==='zh-Hant','測試語言');
    require(latest.exportSettings.pngDepth===8,'首次安裝 PNG 為 8 位元');
    document.querySelector('[data-page="ai"]').click();
    await until(()=>document.getElementById('repositoryFormat'),'AI 下載頁');
    const format=document.getElementById('repositoryFormat');
    require(latest.ai.mlxAvailable!==false || (format.value==='gguf'&&!format.querySelector('[value="mlx"]')),'Windows 下載頁使用 GGUF 並隱藏 MLX 選項');
    document.querySelector('[data-page="home"]').click();
    window.runtime.EventsEmit('filmdevelop:smoke-reopen');await idle(()=>latest.hasImage&&latest.outputImage);
    command('setStyle',{style:'filmPortra400'});await idle(()=>latest.selectedStyle==='filmPortra400');
    const contrast=latest.adjustments.filmPortra400.contrast;
    command('updateAdjustment',{style:'filmPortra400',key:'contrast',value:71});await idle(()=>latest.adjustments.filmPortra400.contrast===71);
    command('setStyle',{style:'filmPortra400'});await idle(()=>latest.adjustments.filmPortra400.contrast===contrast);
    require(true,'無 AI 重選底片恢復顯影預設');
    command('updateAdjustment',{style:'filmPortra400',key:'exposure',value:12});await idle(()=>latest.adjustments.filmPortra400.exposure===12);
    command('saveCustomFilm');await until(()=>dialog,'儲存底片命名');await resolve('第二輪底片');
    await until(()=>latest.selectedCustomFilmID&&latest.styles.some(s=>s.title==='第二輪底片'),'儲存後選取');
    const id=latest.selectedCustomFilmID;
    require(latest.canUndo&&latest.adjustments.filmPortra400.exposure===12,'儲存自訂底片後選取並保留調整與復原');
    command('showCustomFilmMenu',{id});await until(()=>menu,'底片選單');await resolve('duplicate');
    await idle(()=>latest.selectedCustomFilmID!==id&&latest.styles.some(s=>s.title==='第二輪底片 副本'));
    const copyID=latest.selectedCustomFilmID;
    require(!dialog&&!!copyID,'拷貝底片直接產生唯一名稱並套用，不增加命名步驟');
    command('deleteCustomFilm',{id:copyID});await until(()=>dialog,'刪除副本');await resolve('delete');
    await until(()=>!latest.selectedCustomFilmID&&!latest.styles.some(s=>s.id===copyID),'解除已刪除身分');
    require(latest.adjustments.filmPortra400.exposure===12,'刪除自訂底片保留照片參數');
    command('undoEdit');await idle(()=>latest.selectedCustomFilmID===id);
    command('redoEdit');await idle(()=>!latest.selectedCustomFilmID);
    require(!latest.styles.some(s=>s.id===copyID),'復原及重做不恢復已刪除的底片身分');
    command('resetAdjustments',{style:latest.selectedStyle});await idle(()=>latest.selectedStyle==='original'&&!latest.canUndo&&!latest.canRedo);
    require(true,'恢復預設清除復原與重做紀錄');
    const beforeImages=images,revision=latest.previewRevision;
    command('retryPreview');await idle(()=>latest.previewRevision>revision&&images>beforeImages);
    require(true,'重試預覽重新傳送影像');
    fire('portrait');await idle(()=>latest.sourceFileName==='portrait.jpg');
    const titles=Object.fromEntries(latest.cropAspectRatios.map(r=>[r.id,r.title]));
    require(titles.threeTwo==='2:3'&&titles.fourThree==='3:4'&&titles.sixteenNine==='9:16','直式照片裁切比例標籤為 2:3、3:4、9:16');
    fire('repair');await until(()=>latest.isRepairingImage,'修復下載等待');
    document.getElementById('busyCancel').click();await until(()=>!latest.isRepairingImage,'修復取消完成');
    require(cancelUI&&document.getElementById('busyDialog').hidden&&!document.getElementById('app').inert,'修復取消按鈕顯示等待、停用重複取消並正常關閉');
    if(latest.ai.mlxAvailable===false){
      fire('models');await until(()=>latest.ai.ready,'Windows 實際 GGUF 模型就緒');
      document.querySelector('[data-page="ai"]').click();
      const selected=document.querySelector('#localModelPicker option:checked');
      require(!!selected&&!selected.disabled&&!selected.textContent.includes('無法使用')&&latest.ai.format==='gguf','Windows GGUF 主模型與 mmproj 正確配對並可選用');
    }
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,completed,toasts});
  }catch(error){window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),completed,toasts,state:{selected:latest.selectedStyle,custom:latest.selectedCustomFilmID,rendering:latest.isRenderingPreview},dom:document.body.innerText.slice(-2500)});}
})();
