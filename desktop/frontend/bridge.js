(function () {
  "use strict";
  var allowed = new Set(["handleUIPreferences", "handleNativeState", "handleNativeToast", "handleDesktopCommand", "handleNativeFileOpen", "handlePhotoDirectoryState", "handleFilmHoverPreview", "handleHostDialog", "handleHostMenu", "handleRepairPreparation", "handleNativeMenu", "handlePreviewMenu", "handlePhotoEXIF", "handleBatchExportProgress", "handleRepairResult", "handleUpdateComplete", "handleMCPFlush", "handleMCPPage", "handleHostProgress", "handleHostClose", "handleHostStartup", "handleExportDevelopment", "handleFocusDirectoryPhoto"]);
  // Wails 的事件回呼可並行；等宿主確認入列後才送下一筆，保持手勢與換圖順序。
  var pending = [], sequence = 0, hostConnected = false;
  function sendNext() {
    if (hostConnected && pending.length) window.runtime.EventsEmit("filmdevelop:ordered-command", pending[0]);
  }
  window.runtime.EventsOn("filmdevelop:host-connected", function () {
    if (!hostConnected) { hostConnected=true;sendNext(); }
  });
  window.runtime.EventsOn("filmdevelop:command-accepted", function (id) {
    if (!pending.length || pending[0].id !== id) return;
    pending.shift();
    sendNext();
  });
  var initialUI = {};
  for (var i=0;i<localStorage.length;i++) { var key=localStorage.key(i); if(key.indexOf("photoStyle.")===0) initialUI[key]=localStorage.getItem(key); }
  window.PhotoNativeBridge = {
    post: function (payload) {
      if (payload.action === "getState") window.PhotoNativeBridge.post({action:"syncUIPreferences",initial:true,values:initialUI});
      pending.push({ id: ++sequence, payload: Object.assign({}, payload) });
      if (pending.length === 1) sendNext();
    }
  };
  // Windows 由 WebView2 解析拖入路徑，macOS 由原生事件交給同一 Go 入口。
  window.runtime.OnFileDrop(function () { document.body.classList.remove("file-drag-over"); }, false);
  window.addEventListener("dragover", function (event) {
    if (event.dataTransfer && Array.from(event.dataTransfer.types).includes("Files") && !document.getElementById("app").inert) document.body.classList.add("file-drag-over");
  });
  ["drop", "dragend"].forEach(function (name) { window.addEventListener(name, function () { document.body.classList.remove("file-drag-over"); }); });
  window.addEventListener("dragleave", function (event) { if (!event.relatedTarget) document.body.classList.remove("file-drag-over"); });
  var writingUI = false, uiConnected = false;
  var nativeSet = Storage.prototype.setItem, nativeRemove = Storage.prototype.removeItem;
  var portableKeys = new Set("photoStyle.activeAdjustmentPanel photoStyle.adjustmentMode photoStyle.sidebarGroup.custom photoStyle.sidebarGroup.builtin photoStyle.sidebarCollapsed photoStyle.showHelp photoStyle.appearance photoStyle.thumbnailSize photoStyle.photoDisplayMode photoStyle.styleOrder photoStyle.enabledFilms.v2 photoStyle.enabledStyles photoStyle.enabledExpandedFilms.v1 photoStyle.thumbnailViewport.v1".split(" "));
  Storage.prototype.setItem = function(key,value) { var changed=this.getItem(key)!==String(value); nativeSet.call(this,key,value); if(this===localStorage && uiConnected && changed && !writingUI && portableKeys.has(key)) window.PhotoNativeBridge.post({action:"syncUIPreferences",key:key,value:String(value)}); };
  Storage.prototype.removeItem = function(key) { var changed=this.getItem(key)!==null; nativeRemove.call(this,key); if(this===localStorage && uiConnected && changed && !writingUI && portableKeys.has(key)) window.PhotoNativeBridge.post({action:"syncUIPreferences",key:key,remove:true}); };
  window.runtime.EventsOn("filmdevelop:reply", function (reply) {
    if(reply && reply.function === "handleUIPreferences") {
      writingUI=true;
      portableKeys.forEach(function(key){ if(Object.prototype.hasOwnProperty.call(reply.payload,key)) nativeSet.call(localStorage,key,reply.payload[key]); else nativeRemove.call(localStorage,key); });
      writingUI=false; uiConnected=true;
    }
    if (reply && allowed.has(reply.function) && typeof window[reply.function] === "function") {
      window[reply.function](reply.payload);
    }
  });
})();

// 啟動與首次移轉使用獨立模態視窗，不能排在尚未開始接收的一般指令佇列後面。
(function () {
  "use strict";
  var dialog, timer, started=performance.now(), revision=-1;
  function text(value) { return window.PhotoL10n.text(value); }
  window.handleHostStartup = function (payload) {
    if (payload.revision < revision) return;
    revision=payload.revision;
    if (!payload.active) {
      clearInterval(timer);
      if (dialog) { dialog.close();dialog.remove();dialog=null; }
      return;
    }
    if (payload.language) window.PhotoL10n.setLanguage(payload.language);
    if (!dialog) {
      dialog=document.createElement("dialog");dialog.id="hostStartupDialog";dialog.className="host-dialog host-startup-dialog";
      dialog.innerHTML='<h2 id="hostStartupTitle"></h2><p data-startup-description></p><p class="host-startup-status"><span class="preview-spinner" aria-hidden="true"></span><strong data-startup-stage></strong></p><p data-startup-item></p><progress class="host-dialog-progress" max="1"></progress><p data-startup-count role="status" aria-live="polite"></p><p data-startup-time></p>';
      dialog.setAttribute("aria-labelledby","hostStartupTitle");
      dialog.addEventListener("cancel",function(e){e.preventDefault()});
      ["keydown","keyup"].forEach(function(name){dialog.addEventListener(name,function(e){e.stopPropagation()})});
      document.body.appendChild(dialog);dialog.showModal();
      function elapsed(){if(dialog)dialog.querySelector("[data-startup-time]").textContent=text("已經過 {0} 秒".replace("{0}",String(Math.floor((performance.now()-started)/1000))))}
      elapsed();timer=setInterval(elapsed,1000);
    }
    dialog.querySelector("h2").textContent=text(payload.migration ? "正在移轉舊版資料" : "正在準備 FilmDevelop");
    dialog.querySelector("[data-startup-description]").textContent=text(payload.migration ? "正在匯入 FilmYourPhoto 的設定與照片紀錄。原始照片與舊版資料會保留，完成後即可操作。" : "正在載入設定與照片，完成後即可操作。");
    dialog.querySelector("[data-startup-stage]").textContent=text(payload.stage);
    dialog.querySelector("[data-startup-item]").textContent=payload.item || "";
    var progress=dialog.querySelector("progress"),count=dialog.querySelector("[data-startup-count]");
    if (payload.total>0) {
      progress.value=Math.min(1,Math.max(0,payload.completed/payload.total));
      count.textContent=text("此階段已處理 {0} / {1} 項".replace("{0}",String(payload.completed)).replace("{1}",String(payload.total)));
      progress.hidden=false;
    } else { progress.removeAttribute("value");progress.hidden=true;count.textContent=""; }
  };
  // 先畫等待畫面；握手取得最新快照，即使移轉先開始或已完成也不遺失狀態。
  window.handleHostStartup({active:true,stage:"載入底片與分類",revision:-1});
  function connect(){window.runtime.EventsEmit("filmdevelop:frontend-ready")}
  window.runtime.EventsOn("filmdevelop:host-ready",connect);connect();
})();

// 對話框由 Go 提供資料與一次性識別，使用 textContent 避免檔名／提示詞成為 HTML。
(function () {
  "use strict";
  var current;
  function text(value) { return window.PhotoL10n ? window.PhotoL10n.text(value) : value || ""; }
  function detailText(payload) {
    var value = payload.detail || "";
    if (payload.literalDetail) return value;
    var translated = text(value);
    return translated !== value ? translated : value.split("\n").map(text).join("\n");
  }
  function close(dialog) {
    if (current !== dialog) return;
    current=null;dialog.close();dialog.remove();
    var focus=dialog.previousFocus;
    if (focus && focus.isConnected && !focus.closest("[inert]")) focus.focus({preventScroll:true});
  }
  function updateProgress(dialog, payload) {
    if (typeof payload.progress !== "number" || !Number.isFinite(payload.progress)) return;
    var progress = dialog.querySelector("[data-host-progress]");
    progress.value = Math.max(0, Math.min(1, payload.progress));
    progress.hidden = false;
  }
  window.handleHostProgress = function (payload) {
    if (!current || current.dataset.hostID !== payload.id) return;
    if (payload.close) { close(current);return; }
    if (Object.prototype.hasOwnProperty.call(payload, "detail")) current.querySelector("[data-host-detail]").textContent=detailText(payload);
    updateProgress(current, payload);
  };
  window.handleHostDialog = function (payload) {
    if (window.dismissHostMenu) window.dismissHostMenu(false);
    var previousFocus=current ? current.previousFocus : document.activeElement;
    if (current) close(current);
    var dialog = document.createElement("dialog"); current = dialog; dialog.dataset.hostID = payload.id;
    dialog.previousFocus=previousFocus;
    dialog.className = "host-dialog";
    dialog.setAttribute("aria-label", text(payload.title));
    var title = document.createElement("h2"); title.textContent = text(payload.title); title.style.marginTop = "0"; dialog.appendChild(title);
    var detail = document.createElement("p"); detail.dataset.hostDetail = "true"; detail.textContent = detailText(payload); detail.style.whiteSpace="pre-wrap"; dialog.appendChild(detail);
    var progress = document.createElement("progress"); progress.dataset.hostProgress = "true"; progress.className = "host-dialog-progress";
    progress.max = 1; progress.value = 0; progress.hidden = true; progress.setAttribute("aria-label", text(payload.title)); dialog.appendChild(progress);
    updateProgress(dialog, payload);
    var form=document.createElement("form");form.method="dialog";dialog.appendChild(form);
    var actions=document.createElement("div");actions.className="host-dialog-actions";form.appendChild(actions);
    var input;
    function finish(value,cancelled) {
      if (current !== dialog) return;
      close(dialog);
      window.PhotoNativeBridge.post({action:"resolveDialog",id:payload.id,value:value || "",cancelled:!!cancelled});
    }
    function button(label,value,role) {
      var b=document.createElement("button");b.type="button";b.textContent=text(label);
      b.className="host-dialog-button";
      b.dataset.role=role==="destructive"?"destructive":role==="secondary"?"secondary":"primary";
      b.onclick=function(){finish(value,false)};actions.appendChild(b);return b;
    }
    if (payload.choices && payload.choices.length) {
      payload.choices.forEach(function(c){button(c.label,c.id,c.role || (c.id==="cancel"?"secondary":"primary")).disabled=!!c.disabled});
    } else {
      input=document.createElement("input");input.type="text";input.value=payload.value || "";input.maxLength=2048;
      input.setAttribute("aria-label",text(payload.title));input.style.cssText="box-sizing:border-box;width:100%;padding:10px;";form.insertBefore(input,actions);
      var save=button("確定","");save.onclick=function(){if(!save.disabled)finish(input.value,false)};
      function validateInput(){save.disabled=!input.value.trim()}
      input.addEventListener("input",validateInput);validateInput();
    }
    // 取消／關閉由穩定的操作識別判斷，不依賴畫面語言或個別對話框標題。
    var hasDismiss=(payload.choices || []).some(function(c){return c.id==="cancel" || c.id==="close"});
    if(!hasDismiss){var cancel=button("取消","","secondary");cancel.onclick=function(){finish("",true)};actions.prepend(cancel)}
    form.onsubmit=function(e){e.preventDefault();if(input && !save.disabled)finish(input.value,false)};
    dialog.addEventListener("keydown",function(e){e.stopPropagation()});
    dialog.addEventListener("keyup",function(e){e.stopPropagation()});
    dialog.addEventListener("cancel",function(e){e.preventDefault();finish("",true)});
    document.body.appendChild(dialog);dialog.showModal();if(input){input.focus();input.select()}
  };
})();

window.handleMCPFlush = async function (value) {
  if (window.flushPhotoUI) await window.flushPhotoUI();
  window.PhotoNativeBridge.post({action:"mcpUIReady",id:value.id});
};

window.handleMCPPage = function(value) { window.handleDesktopCommand(value.page); };
window.handleHostClose = function () {
  // 與換圖相同，最後一批參數和關閉要求必須是同一筆指令。
  if (window.commitPhotoEdits) window.commitPhotoEdits("confirmClose");
  else window.PhotoNativeBridge.post({action:"confirmClose"});
};

// Go 共用選單模型：緊湊浮動列、真正的階層、鍵盤導覽與一次性命令。
(function () {
  'use strict';
  var current = null, origin = null;
  var selector = '[data-directory-photo], [data-select-style], [data-film-stock], [data-action="browsePhotoDirectory"], .preview-frame';
  function liveOrigin(element) {
    if (!element || element.isConnected) return element;
    if (element.id) return document.getElementById(element.id);
    for (var name of ['data-directory-photo','data-select-style','data-film-stock','data-action']) {
      if (element.hasAttribute(name)) return document.querySelector('['+name+'="'+CSS.escape(element.getAttribute(name))+'"]');
    }
    return element.classList.contains('preview-frame') ? document.querySelector('.preview-frame') : null;
  }
  document.addEventListener('contextmenu', function (event) {
    origin = event.target.closest(selector) || document.activeElement;
  }, true);
  document.addEventListener('keydown', function (event) {
    if (event.key !== 'ContextMenu' && !(event.shiftKey && event.key === 'F10')) return;
    var target = event.target.closest(selector);
    if (!target || current) return;
    var rect = target.getBoundingClientRect();
    event.preventDefault(); event.stopImmediatePropagation();
    target.dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, cancelable:true, clientX:rect.left+12, clientY:rect.top+12}));
  }, true);
  function close(notify, restoreFocus) {
    var menu = current;
    if (!menu) return;
    current = null;
    clearTimeout(menu.timer);
    menu.abort.abort();
    menu.panels.forEach(function (panel) { panel.remove(); });
    var previous = liveOrigin(menu.focus);
    if (restoreFocus && previous) previous.focus({preventScroll:true});
    if (notify) window.PhotoNativeBridge.post({action:'resolveDialog', id:menu.payload.id, cancelled:true});
  }
  window.dismissHostMenu = function (notify) { close(notify, true); };
  window.handleHostMenu = function (payload) {
    close(false, false);
    var menu = {payload:payload, panels:[], parents:[], focus:origin || document.activeElement, abort:new AbortController(), timer:null};
    origin = null;
    current = menu;
    var L = window.PhotoL10n, options = {capture:true, signal:menu.abort.signal};
    function text(item) { return item.literal || !L ? item.label : L.text(item.label); }
    function removeAfter(level) {
      while (menu.panels.length > level+1) {
        menu.panels.pop().remove();
        var parent=menu.parents.pop(); if(parent)parent.setAttribute('aria-expanded','false');
      }
    }
    function rows(panel) { return Array.from(panel.querySelectorAll('[role^="menuitem"]')).filter(function(row){return row.getAttribute('aria-disabled') !== 'true';}); }
    function focus(row) { if (row) { row.focus({preventScroll:true}); row.scrollIntoView({block:'nearest',inline:'nearest'}); } }
    function position(panel, x, y, parent) {
      var gap=6, rect=panel.getBoundingClientRect(), width=window.innerWidth, height=window.innerHeight;
      if (parent && x+rect.width>width-gap) x=parent.getBoundingClientRect().left-rect.width+3;
      x=Math.max(gap,Math.min(x,width-rect.width-gap));
      y=Math.max(gap,Math.min(y,height-rect.height-gap));
      panel.style.left=x+'px';panel.style.top=y+'px';panel.style.visibility='visible';
    }
    function build(items, level, parent) {
      var panel=document.createElement('div');panel.className='host-menu';panel.setAttribute('role','menu');
      panel.setAttribute('aria-label',parent ? parent.dataset.label : (payload.title || ''));
      panel.dataset.hostMenu=payload.id;panel.dataset.level=level;panel.style.visibility='hidden';
      panel.addEventListener('contextmenu',function(event){event.preventDefault();event.stopPropagation();});
      items.forEach(function(item) {
        if(item.separator){var line=document.createElement('div');line.className='host-menu-separator';line.setAttribute('role','separator');panel.appendChild(line);return;}
        var row=document.createElement('button');row.type='button';row.tabIndex=-1;row.className='host-menu-item';
        row.dataset.label=text(item);row.dataset.command=item.id || '';
        row.setAttribute('role',item.checked ? 'menuitemcheckbox' : 'menuitem');
        row.setAttribute('aria-disabled',String(!!item.disabled));
        if(item.checked)row.setAttribute('aria-checked',item.checked);
        var check=document.createElement('span');check.className='host-menu-check';check.setAttribute('aria-hidden','true');
        check.textContent=item.checked==='true' ? '✓' : item.checked==='mixed' ? '−' : '';
        var label=document.createElement('span');label.className='host-menu-label';label.textContent=text(item);
        var trail=document.createElement('span');trail.className='host-menu-trail';trail.setAttribute('aria-hidden','true');
        var children=item.items && item.items.length;
        if(children){row.setAttribute('aria-haspopup','menu');row.setAttribute('aria-expanded','false');trail.textContent='›';}
        else trail.textContent=item.shortcut || '';
        row.append(check,label,trail);panel.appendChild(row);
        function open(keyboard) {
          if(item.disabled || !children)return;
          clearTimeout(menu.timer);
          if(menu.parents[level+1]!==row) {
            removeAfter(level);var child=build(item.items,level+1,row),rect=row.getBoundingClientRect();
            row.setAttribute('aria-expanded','true');position(child,rect.right-3,rect.top-5,row);
          }
          if(keyboard)focus(rows(menu.panels[level+1])[0]);
        }
        row._openSubmenu=open;
        row.addEventListener('pointerenter',function() {
          clearTimeout(menu.timer);
          if(item.disabled){removeAfter(level);return;}
          focus(row);
          // 保留短暫移動時間，游標可斜向進入右側子選單。
          menu.timer=setTimeout(function(){if(current!==menu)return;if(children)open(false);else removeAfter(level);},160);
        });
        row.addEventListener('click',function(event) {
          event.preventDefault();event.stopPropagation();
          if(item.disabled)return;
          if(children){open(true);return;}
          close(false,true);
          window.PhotoNativeBridge.post({action:'resolveDialog',id:payload.id,value:item.id});
        });
      });
      panel.addEventListener('pointerenter',function(){clearTimeout(menu.timer);});
      panel.addEventListener('scroll',function(){removeAfter(level);});
      document.body.appendChild(panel);menu.panels[level]=panel;menu.parents[level]=parent;
      return panel;
    }
    var root=build(payload.items || [],0,null), anchor=payload.anchor || {};
    var rect=menu.focus && menu.focus.getBoundingClientRect ? menu.focus.getBoundingClientRect() : {left:20,top:20};
    position(root,Number.isFinite(anchor.x)?anchor.x:rect.left+12,Number.isFinite(anchor.y)?anchor.y:rect.top+12);
    focus(rows(root)[0]);
    document.addEventListener('pointerdown',function(event) {
      if(!menu.panels.some(function(panel){return panel.contains(event.target);}))close(true,false);
    },options);
    document.addEventListener('keydown',function(event) {
      if(current!==menu)return;
      var panel=event.target.closest('.host-menu') || menu.panels[menu.panels.length-1];
      var level=Number(panel.dataset.level), entries=rows(panel), index=entries.indexOf(document.activeElement);
      event.stopImmediatePropagation();
      if(event.key==='Escape'){event.preventDefault();close(true,true);return;}
      if(event.key==='Tab'){event.preventDefault();close(true,true);return;}
      if(event.key==='ArrowDown'||event.key==='ArrowUp') {
        event.preventDefault();focus(entries[(index+(event.key==='ArrowDown'?1:-1)+entries.length)%entries.length]);return;
      }
      if(event.key==='Home'||event.key==='End'){event.preventDefault();focus(entries[event.key==='Home'?0:entries.length-1]);return;}
      if(event.key==='ArrowRight'){event.preventDefault();if(entries[index])entries[index]._openSubmenu(true);return;}
      if(event.key==='ArrowLeft'){event.preventDefault();if(level){var parent=menu.parents[level];removeAfter(level-1);focus(parent);}return;}
      if(event.key==='Enter'||event.key===' '){event.preventDefault();if(entries[index])entries[index].click();return;}
      if(event.key.length===1&&!event.ctrlKey&&!event.metaKey) {
        event.preventDefault();var key=event.key.toLocaleLowerCase();
        var ordered=entries.slice(index+1).concat(entries.slice(0,index+1));
        focus(ordered.find(function(row){return row.dataset.label.toLocaleLowerCase().startsWith(key);}));
      }
    },options);
    window.addEventListener('resize',function(){close(true,false);},{signal:menu.abort.signal});
    window.addEventListener('blur',function(){close(true,false);},{signal:menu.abort.signal});
    document.addEventListener('scroll',function(event){if(!event.target.closest || !event.target.closest('.host-menu'))close(true,false);},options);
  };
  window.runtime.EventsOn('filmdevelop:reply',function(reply) {
    if(current && reply.function==='handleDesktopCommand') close(true,false);
    if(current && reply.function==='handleNativeState' && reply.payload.photoGeneration && reply.payload.photoGeneration!==current.payload.photoGeneration) close(true,false);
  });
})();
