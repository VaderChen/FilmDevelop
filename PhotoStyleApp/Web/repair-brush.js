(function () {
  'use strict';
  window.PhotoRepairBrush = function (env) {
    var strokes = [], drawing = null, size = 32, pending = false, frame = null, canvas = null, cursor = null;
    var observer = null, generation = '', revision = '';
    var text = env.text, escape = env.escape;
    function state() { return env.state(); }
    function active() { return !!state().repairEditing; }
    function busy() { return pending || env.busy() || state().isRenderingPreview; }
    function button(label, action, disabled) {
      return '<button type="button" class="photo-directory-button" data-repair-action="' + action + '"' + (disabled ? ' disabled' : '') + '>' + escape(text(label)) + '</button>';
    }
    this.toolbar = function () {
      return '<button type="button" class="photo-directory-button repair-toggle" data-repair-toggle title="' + escape(text('修復筆刷：塗抹後移除物件並補齊背景；首次使用需下載本機模型。')) + '" aria-label="' + escape(text('修復筆刷')) + '" aria-pressed="' + active() + '"' + (!state().hasImage || env.busy() || state().isRenderingPreview ? ' disabled' : '') + '><svg viewBox="0 0 24 24" aria-hidden="true"><path d="m15 3 6 6-11 11H4l-2-2 13-15Zm-8 9 6 6M10 20h11"/></svg></button>';
    };
    this.panel = function () {
      if (!active()) return '';
      var waiting = pending || state().isRepairingImage;
      return '<section class="repair-panel" aria-label="' + escape(text('修復筆刷')) + '"><label for="repairBrushSize">' + escape(text('筆刷大小')) + '</label><input id="repairBrushSize" type="range" min="4" max="160" step="1" value="' + size + '"' + (waiting ? ' disabled' : '') + '><output id="repairBrushSizeValue">' + size + ' px</output>' +
        button(waiting ? '取消修復' : '完成', waiting ? 'cancel' : 'done', false) +
        (waiting ? '<span class="repair-status" role="status"><span class="preview-spinner"></span><span>' + escape(text(state().repairStep || '正在準備本機修復工具…')) + '</span></span>' : '') + '</section>';
    };
    this.overlay = function () { return active() ? '<canvas class="repair-overlay" aria-label="' + escape(text('塗抹要修復的區域')) + '"></canvas><span class="repair-cursor" hidden></span>' : ''; };
    function geometry() {
      var image = env.image();
      if (!image || !image.complete || !image.naturalWidth || !frame) return null;
      return { image: image.getBoundingClientRect(), frame: frame.getBoundingClientRect() };
    }
    function redraw() {
      if (!active() || !canvas || !canvas.isConnected) return;
      var g = geometry(); if (!g || !g.image.width) return;
      var dpr = Math.min(window.devicePixelRatio || 1, 2);
      canvas.width = Math.max(1, Math.round(g.frame.width*dpr)); canvas.height = Math.max(1, Math.round(g.frame.height*dpr));
      var ctx = canvas.getContext('2d'); ctx.scale(dpr,dpr);
      ctx.strokeStyle = 'rgba(220,70,45,0.48)'; ctx.fillStyle = ctx.strokeStyle; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
      var left = g.image.left-g.frame.left, top = g.image.top-g.frame.top;
      ctx.beginPath();ctx.rect(left,top,g.image.width,g.image.height);ctx.clip();
      strokes.forEach(function (stroke) {
        var radius = stroke.radius*g.image.width;
        ctx.lineWidth = radius*2; ctx.beginPath();
        stroke.points.forEach(function (p,i) { var x=left+p.x*g.image.width,y=top+p.y*g.image.height; if(i)ctx.lineTo(x,y);else ctx.moveTo(x,y); });
        if (stroke.points.length === 1) { var p=stroke.points[0];ctx.arc(left+p.x*g.image.width,top+p.y*g.image.height,radius,0,Math.PI*2);ctx.fill(); } else ctx.stroke();
      });
    }
    function point(event) {
      var g=geometry(); if(!g)return null;
      var x=(event.clientX-g.image.left)/g.image.width,y=(event.clientY-g.image.top)/g.image.height;
      if(x<0||x>1||y<0||y>1)return null;
      return {x:x,y:y};
    }
    this.bind = function () {
      drawing = null;
      if(observer)observer.disconnect(); observer=null;
      frame=env.root.querySelector('.preview-frame');canvas=env.root.querySelector('.repair-overlay');cursor=env.root.querySelector('.repair-cursor');
      var toggle=env.root.querySelector('[data-repair-toggle]');
      if(toggle)toggle.onclick=function(){
        if(toggle.disabled)return;
        env.prepare();state().repairEditing=!active();drawing=null;
        env.render();
      };
      env.root.querySelectorAll('[data-repair-action]').forEach(function(b){b.onclick=function(){
        if(b.disabled)return;
        var action=b.dataset.repairAction;
        if(action==='done'){state().repairEditing=false;drawing=null;}
        if(action==='cancel'){env.post('cancelRepairBrush');return;}
        env.render();
      };});
      var slider=env.root.querySelector('#repairBrushSize');
      if(slider)slider.oninput=function(){size=Number(slider.value);env.root.querySelector('#repairBrushSizeValue').textContent=size+' px';};
      if(!active()||!canvas||!frame)return;
      var image=env.image();if(image)image.addEventListener('load',redraw,{once:true});
      if(window.ResizeObserver){observer=new ResizeObserver(redraw);observer.observe(frame);}
      canvas.addEventListener('pointerdown',function(e){
        if(e.button!==0||busy())return;
        var p=point(e),g=geometry();if(!p||!g||strokes.length>=128)return;
        e.preventDefault();e.stopPropagation();env.cancelGesture();
        drawing={radius:size/2/g.image.width,points:[p]};
        drawing.radius=Math.min(drawing.radius,0.5);strokes.push(drawing);
        canvas.setPointerCapture(e.pointerId);redraw();
      });
      canvas.addEventListener('pointermove',function(e){
        var p=point(e),g=geometry();
        if(cursor&&g){cursor.hidden=!p||busy();cursor.style.width=size+'px';cursor.style.height=size+'px';cursor.style.left=(e.clientX-g.frame.left)+'px';cursor.style.top=(e.clientY-g.frame.top)+'px';}
        if(!drawing||!p||!g)return;
        e.preventDefault();e.stopPropagation();
        var last=drawing.points[drawing.points.length-1];
        if(Math.hypot((last.x-p.x)*g.image.width,(last.y-p.y)*g.image.height)<1)return;
        if(strokes.reduce(function(n,s){return n+s.points.length;},0)>=20000)return;
        drawing.points.push(p);redraw();
      });
      function end(e) {
        if(!drawing)return;
        e.preventDefault();e.stopPropagation();
        var completed = e.type === 'pointerup';
        if(!completed)strokes.pop();
        drawing=null;
        if(canvas.hasPointerCapture(e.pointerId))canvas.releasePointerCapture(e.pointerId);
        if(completed && !busy() && strokes.length) {
          pending=true;
          env.post('applyRepairBrush',{strokes:strokes,photoGeneration:state().photoGeneration,repairRevision:state().repairRevision||''});
          env.render();
        } else {redraw();}
      }
      canvas.addEventListener('pointerup',end);
      canvas.addEventListener('pointercancel',end);
      canvas.addEventListener('lostpointercapture',end);
      canvas.addEventListener('pointerleave',function(){if(cursor)cursor.hidden=true;});
      requestAnimationFrame(redraw);
    };
    this.redraw=redraw;
    this.receive=function(next){
      if(next.externalEdit){strokes=[];drawing=null;}
      if((generation&&next.photoGeneration!==generation)||(generation&&next.repairRevision!==revision)) {strokes=[];drawing=null;}
      if(generation&&next.photoGeneration!==generation){next.repairEditing=false;state().repairEditing=false;pending=false;}
      generation=next.photoGeneration;revision=next.repairRevision||'';
    };
    this.result=function(){pending=false;strokes=[];drawing=null;env.render();};
    this.escape=function(){if(!active()||state().isRepairingImage||pending)return false;state().repairEditing=false;drawing=null;env.render();return true;};
  };
})();
