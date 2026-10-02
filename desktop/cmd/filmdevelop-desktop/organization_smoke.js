(async function () {
  'use strict';
  const fixture=window.organizationSmokeFixture, completed=[];
  let latest={}, directory={}, failure=null;
  const originalState=window.handleNativeState, originalDirectory=window.handlePhotoDirectoryState;
  window.handleNativeState=function(payload) {
    latest=Object.assign({},latest,payload);
    if(payload.photoDirectory)directory=payload.photoDirectory;
    originalState(payload);
  };
  window.handlePhotoDirectoryState=function(payload) {directory=payload;originalDirectory(payload);};
  window.handleNativeToast=function(payload) {failure=payload.message;};
  const frame=()=>new Promise(resolve=>requestAnimationFrame(resolve));
  async function until(test,label) {
    const start=performance.now();
    while(!test()) {
      if(failure)throw new Error(failure);
      if(performance.now()-start>45000)throw new Error('等待逾時：'+label);
      await frame();
    }
  }
  function mode(value) {
    const select=document.querySelector('#photoDisplayMode');
    select.value=value;select.dispatchEvent(new Event('change',{bubbles:true}));
  }
  function rows() {return Array.from(document.querySelectorAll('[data-directory-photo]'));}
  function item(label) {return Array.from(document.querySelectorAll('.host-menu-item')).find(b=>b.dataset.label===label);}
  function closeMenu() {document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));}
  async function openMenu(id,label) {
    const photo=document.querySelector('[data-directory-photo="'+id+'"]');
    photo.dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true,clientX:500,clientY:500}));
    await until(()=>item(label),'照片右鍵選單');item(label).click();
    await until(()=>document.querySelector('.host-menu[data-level="1"]'),'子選單');
  }
  try {
    window.PhotoNativeBridge.post({action:'getState'});
    await until(()=>fixture.photos.every(p=>directory.items?.some(i=>i.id===p.id))&&latest.hasImage&&!latest.isRenderingPreview,'載入本機照片');
    mode('standard');
    for(const expected of fixture.photos) {
      const actual=directory.items.find(i=>i.id===expected.id);
      if(actual.rating!==expected.rating||JSON.stringify(actual.tags.slice().sort())!==JSON.stringify(expected.tags.slice().sort()))throw new Error('照片分級／分類與 Swift 不符：'+expected.name);
      const row=document.querySelector('[data-directory-photo="'+expected.id+'"]');
      const stars='★'.repeat(expected.rating)+'☆'.repeat(5-expected.rating);
      if(row.querySelector('.photo-thumbnail-rating').textContent!==stars)throw new Error('星級未顯示：'+expected.name);
      for(const tag of expected.tags)if(!row.textContent.includes(tag))throw new Error('分類未顯示：'+expected.name);
      await openMenu(expected.id,'分級');
      if(document.querySelector('[data-command="rating:'+expected.rating+'"]').getAttribute('aria-checked')!=='true')throw new Error('分級選單未勾選');
      closeMenu();await openMenu(expected.id,'分類');
      for(const tag of fixture.tags) {
        const entry=item(tag);
        if(!entry||entry.getAttribute('aria-checked')!==String(expected.tags.includes(tag)))throw new Error('分類選單狀態不符：'+tag);
      }
      closeMenu();completed.push(expected.name+'：列表、星級、分類與右鍵勾選一致');
    }
    for(const tag of fixture.tags) {
      mode('tag:'+tag);
      const expected=directory.items.filter(p=>p.tags.includes(tag)).map(p=>p.id).sort();
      if(JSON.stringify(rows().map(p=>p.dataset.directoryPhoto).sort())!==JSON.stringify(expected))throw new Error('分類篩選不符：'+tag);
    }
    completed.push('既有分類篩選結果正確');
    mode('rating');
    const ratings=rows().map(row=>directory.items.find(p=>p.id===row.dataset.directoryPhoto).rating);
    if(ratings.some((rating,index)=>index>0&&rating>ratings[index-1]))throw new Error('分級排序不符');
    completed.push('依分級排序正確');
    mode('standard');
    if(fixture.mutate) {
      const target=fixture.photos[0];
      await openMenu(target.id,'分級');document.querySelector('[data-command="rating:0"]').click();
      await until(()=>directory.items.find(p=>p.id===target.id).rating===0,'清除分級保存');
      await openMenu(target.id,'分類');item('清除照片分類').click();
      await until(()=>directory.items.find(p=>p.id===target.id).tags.length===0,'清除分類保存');
      completed.push('沿用後仍可調整分類與分級（僅隔離副本）');
    } else completed.push('重新啟動保留變更，未重新匯入已清除的 Swift 標記');
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:true,completed,photos:fixture.photos.map(p=>directory.items.find(i=>i.id===p.id))});
  } catch(error) {
    window.runtime.EventsEmit('filmdevelop:smoke-result',{passed:false,error:String(error),completed,dom:document.body.innerText.slice(0,2500)});
  }
})();
