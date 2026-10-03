(async function () {
  'use strict';
  const completed=[], exports=[], batches=[], focuses=[], toasts=[];
  let latest={}, cancellingSeen=false;
  const command=(action,fields)=>window.PhotoNativeBridge.post(Object.assign({action},fields));
  const fire=action=>window.runtime.EventsEmit('filmdevelop:smoke-parity',action);
  const require=(ok,message)=>{if(!ok)throw new Error(message);completed.push(message);};
  async function until(test,message,timeout=30000){const start=Date.now();while(!test()){if(Date.now()-start>timeout)throw new Error('逾時：'+message);await new Promise(resolve=>setTimeout(resolve,25));}}
  const nativeDevelopment=window.handleExportDevelopment, nativeBatch=window.handleBatchExportProgress;
  window.handleExportDevelopment=function(payload){nativeDevelopment(payload);exports.push(Object.assign({},payload,{image:!!payload.image,visible:!document.getElementById('exportDevelopment').hidden,inert:document.getElementById('app').inert}));};
  window.handleBatchExportProgress=function(payload){nativeBatch(payload);batches.push(Object.assign({},payload,{visible:!document.getElementById('busyDialog').hidden,count:document.getElementById('batchExportCount').textContent,value:document.getElementById('batchExportProgress').value}));};
  window.runtime.EventsOn('filmdevelop:reply',reply=>{
    if(reply.function==='handleNativeState') {latest=Object.assign(latest,reply.payload);cancellingSeen=cancellingSeen||!!latest.isCancellingComputation;}
    if(reply.function==='handleFocusDirectoryPhoto') focuses.push(reply.payload);
    if(reply.function==='handleNativeToast') toasts.push(reply.payload.message);
  });
  try {
    command('getState');await until(()=>latest.styles&&latest.styles.length,'宿主就緒');
    require(window.wails.flags.enableWailsDragAndDrop===true,'Wails 已啟用檔案拖放');
    command('setExportSettings',{key:'format',value:'jpeg'});
    await until(()=>latest.exportSettings&&latest.exportSettings.format==='jpeg','JPEG 設定');
    window.runtime.EventsEmit('filmdevelop:smoke-reopen');
    await until(()=>latest.hasImage&&!latest.isRenderingPreview&&latest.outputImage,'載入照片');
    const sourceName=latest.sourceFileName;
    for(let round=0;round<2;round++){
      const start=exports.length;
      window.runtime.EventsEmit('filmdevelop:smoke-export');
      await until(()=>exports.slice(start).some(x=>x.phase==='complete'),'JPEG 匯出完成');
      const current=exports.slice(start), begin=current.find(x=>x.phase==='begin');
      require(!!begin&&begin.visible&&begin.inert&&begin.image,'單張 JPEG '+(round+1)+' 顯示原有顯影對話框與照片');
      require(['render','encode','write'].every(stage=>current.some(x=>x.phase==='progress'&&x.stage===stage)),'單張 JPEG '+(round+1)+' 回報渲染、編碼與寫入階段');
      await until(()=>!latest.isSavingImage&&document.getElementById('exportDevelopment').hidden,'顯影對話框定影並關閉');
      require(!document.getElementById('app').inert,'單張 JPEG '+(round+1)+' 完成後解除等待');
    }
    require(exports.filter(x=>x.phase==='complete').length===2,'同一 JPEG 目的檔案可確認取代');
    let start=exports.length;
    fire('export-failure');
    await until(()=>exports.slice(start).some(x=>x.phase==='cancel')&&!latest.isSavingImage,'失敗匯出收尾');
    require(document.getElementById('exportDevelopment').hidden&&!document.getElementById('app').inert,'單張匯出失敗後關閉顯影對話框');
    const batchStart=batches.length;
    fire('batch');
    await until(()=>batches.slice(batchStart).some(x=>x.progress===1&&x.succeeded+x.failed===3)&&!latest.isSavingImage,'複選匯出完成');
    const batch=batches.slice(batchStart), end=batch[batch.length-1];
    require(batch.every(x=>x.visible&&Number.isFinite(x.value)&&!x.count.includes('undefined')&&!x.count.includes('NaN')),'複選匯出對話框進度與張數有效');
    require([1,2,3].every(index=>batch.some(x=>x.current===index)),'複選匯出逐張更新目前張數');
    require(end.total===3&&end.succeeded===2&&end.failed===1&&end.progress===1,'複選匯出統計兩張成功與一張失敗');
    require(batch.some(x=>x.progress>0&&x.progress<1&&x.filename),'複選匯出顯示整批中間進度與檔名');
    require(['正在處理照片','正在編碼照片','正在儲存照片'].every(stage=>batch.some(x=>x.stage===stage)),'複選匯出顯示處理、編碼與儲存階段');
    require(batch.filter(x=>x.succeeded+x.failed<x.total).every(x=>x.progress<1),'複選匯出在寫入與統計完成前不提前顯示 100%');
    require(document.getElementById('busyDialog').hidden&&!document.getElementById('app').inert,'複選匯出完成後關閉對話框');
    const items=latest.photoDirectory.items.filter(x=>x.name.endsWith('.bmp'));
    const resetStart=batches.length;
    command('resetAdjustments',{style:latest.selectedStyle,ids:items.map(x=>x.id)});
    await until(()=>batches.slice(resetStart).some(x=>x.progress===1&&x.succeeded===2)&&!latest.isSavingImage&&!latest.isRenderingPreview,'多選恢復完成');
    require(latest.selectedStyle==='original','多選恢復完成並回到原片');
    fire('duplicate');
    await until(()=>focuses.length&&latest.sourceFileName.includes('copy')&&!latest.isRenderingPreview,'開啟並定位副本');
    require(focuses[focuses.length-1].name===latest.sourceFileName,'複製完成後開啟並定位新副本');
    fire('ai');await until(()=>latest.isComputing,'AI 等待狀態');
    require(!document.getElementById('busyCancel').hidden&&document.getElementById('busyItems').children.length===7,'AI 顯示取消按鈕與七個運算階段');
    document.getElementById('busyCancel').click();
    await until(()=>!latest.isComputing,'AI 取消收尾');
    require(cancellingSeen&&!document.getElementById('app').inert,'AI 取消顯示等待並正常收尾');
    fire('drop');await until(()=>latest.sourceFileName===sourceName&&!latest.isRenderingPreview,'拖入原生檔案事件');
    require(latest.sourceFileName===sourceName,'拖入照片經原生開檔握手載入');
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,completed,exports,batches,focuses,toasts});
  } catch(error) {
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),completed,exports,batches,focuses,toasts,dom:document.body.innerText.slice(0,2500)});
  }
})();
