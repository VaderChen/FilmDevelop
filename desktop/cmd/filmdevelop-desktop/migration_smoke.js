(async function () {
  'use strict';
  const completed=[];
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  async function until(test,label){const start=Date.now();while(!test()){if(Date.now()-start>30000)throw new Error(label);await wait(25);}}
  try {
    let nativeState=null;const originalState=window.handleNativeState;
    window.handleNativeState=function(payload){nativeState=payload;originalState(payload);};
    await until(()=>document.querySelector('[data-page=settings]')&&!document.getElementById('hostStartupDialog'),'設定頁未就緒');
    let reply=null;const previous=window.handleUIPreferences;
    window.handleUIPreferences=function(payload){reply=payload;previous(payload);};
    window.PhotoNativeBridge.post({action:'syncUIPreferences',initial:true});
    await until(()=>reply,'重新啟動後偏好未還原');
    const restoredUIPreferences=Object.assign({},reply);
    window.handleDesktopCommand('films');
    const restoredCustomFilms=Array.from(document.querySelectorAll('[data-toggle-film]')).filter(input=>input.dataset.toggleFilm.startsWith('custom-')).map(input=>({id:input.dataset.toggleFilm,checked:input.checked}));
    document.querySelector('[data-page=settings]').click();
    let buttonStyle=null;
    for(const action of ['showMigrationReport','exportLibraryArchive','importLibraryArchive']){
      const button=document.querySelector('[data-action="'+action+'"]');
      if(!button)throw new Error('缺少移轉入口：'+action);
      const rect=button.getBoundingClientRect(),style=getComputedStyle(button);
      const signature=[rect.width,rect.height,rect.right,style.borderRadius,style.fontWeight,style.backgroundColor].join('|');
      if(buttonStyle&&signature!==buttonStyle)throw new Error('設定頁按鈕寬度／視覺不一致');
      buttonStyle=signature;
    }
    completed.push('設定頁移轉操作按鈕寬度、高度、視覺及右側對齊一致');
    document.querySelector('[data-action=showMigrationReport]').click();
    await until(()=>document.querySelector('dialog[open]'),'移轉紀錄未顯示');
    if(!document.querySelector('dialog').textContent.includes('新版已保存的值優先'))throw new Error('移轉報告內容不完整');
    const close=document.querySelector('dialog [data-role=primary]'),cancel=document.querySelector('dialog [data-role=secondary]');
    if(!close||cancel||document.querySelectorAll('dialog button').length!==1)throw new Error('移轉報告出現重複取消');
    close.click();
    completed.push('移轉報告只有一個關閉按鈕');
    reply=null;
    window.PhotoNativeBridge.post({action:'syncUIPreferences',key:'photoStyle.thumbnailSize',value:'large'});
    window.PhotoNativeBridge.post({action:'getState'});
    await until(()=>reply && reply['photoStyle.thumbnailSize']==='large','Go 介面偏好未保存');
    if(localStorage.getItem('photoStyle.thumbnailSize')!=='large')throw new Error('介面偏好未回填');
    completed.push('介面偏好由 Go 持久化並還原至 WebView');
    await until(()=>nativeState&&nativeState.mcp,'MCP 狀態未就緒');
    document.querySelector('[data-settings-section=mcp]').click();
    const connectionFile=nativeState.mcp.connectionFile||'',path=document.querySelector('.mcp-path');
    if(connectionFile ? !path||path.textContent!==connectionFile : path!==null)throw new Error('MCP 設定檔列與實際檔案狀態不符');
    completed.push('MCP 設定檔存在才顯示，沒有時整列隱藏');
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,completed,restoredUIPreferences,restoredCustomFilms,connectionFile});
  } catch(error){window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),completed});}
})();
