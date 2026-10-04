(function () {
"use strict";
/** 獨立液化幾何原型。所有座標均為影像像素中心，強度為 0..1。 */
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const smooth = v => v * v * (3 - 2 * v);
const finite = v => typeof v === 'number' && Number.isFinite(v);
const MAX_PIXELS = 4 * 1024 * 1024;
function dimensions(w, h) {
  if (!Number.isInteger(w) || !Number.isInteger(h) || w < 2 || h < 2 || w * h > MAX_PIXELS) {
    throw new RangeError('影像寬高至少 2 像素，總像素不得超過 4,194,304。');
  }
}
function weight(t) { return t >= 1 ? 0 : (1 - t) ** 4 * (1 + 4 * t); }

class LiquifyMesh {
  // 持久資料採標準化逆向位移，可在原始解析度重播；照片像素不經過 Web 回傳。
  static fromData(data, options = {}) {
    if (!data || data.version !== 1 || !Number.isInteger(data.referenceWidth) || !Number.isInteger(data.referenceHeight) ||
        data.referenceWidth < 2 || data.referenceHeight < 2 || data.referenceWidth > 1024 || data.referenceHeight > 1024 || !Number.isInteger(data.spacing))
      throw new RangeError('液化網格尺寸或版本無效。');
    const mesh = new LiquifyMesh(data.referenceWidth, data.referenceHeight, {...options, spacing:data.spacing});
    if (data.columns !== mesh.columns || data.rows !== mesh.rows || !Array.isArray(data.dx) || !Array.isArray(data.dy) ||
        data.dx.length !== mesh.dx.length || data.dy.length !== mesh.dy.length)
      throw new RangeError('液化網格資料不完整。');
    let minX=mesh.columns,minY=mesh.rows,maxX=-1,maxY=-1;
    for (let y=0; y<mesh.rows; y++) for(let x=0; x<mesh.columns; x++) {
      const i=y*mesh.columns+x, dx=data.dx[i], dy=data.dy[i];
      const px=Math.min(x*mesh.spacing,mesh.width-1)/(mesh.width-1)+dx;
      const py=Math.min(y*mesh.spacing,mesh.height-1)/(mesh.height-1)+dy;
      if (!finite(dx) || !finite(dy) || px < -1e-6 || px > 1+1e-6 || py < -1e-6 || py > 1+1e-6 ||
          ((x===0 || y===0 || x===mesh.columns-1 || y===mesh.rows-1) && (Math.abs(dx)>1e-6 || Math.abs(dy)>1e-6)))
        throw new RangeError('液化網格座標無效。');
      mesh.dx[i]=dx*(mesh.width-1);mesh.dy[i]=dy*(mesh.height-1);
      if (mesh.dx[i]!==0 || mesh.dy[i]!==0) {
        minX=Math.min(minX,x);minY=Math.min(minY,y);maxX=Math.max(maxX,x);maxY=Math.max(maxY,y);
      }
    }
    mesh.nextX.set(mesh.dx);mesh.nextY.set(mesh.dy);
    // JSON 浮點與 Float32 的轉換可在門檻附近產生極小誤差。
    if (!mesh.validCandidate(0,0,mesh.columns-1,mesh.rows-1,.049)) throw new RangeError('液化網格有翻折或過度壓縮。');
    // 重載也保留局部範圍；相鄰一格涵蓋非零節點的雙線性影響區。
    if (maxX>=0) mesh.bounds={left:Math.max(0,(minX-1)*mesh.spacing),top:Math.max(0,(minY-1)*mesh.spacing),
      right:Math.min(mesh.width-1,(maxX+1)*mesh.spacing),bottom:Math.min(mesh.height-1,(maxY+1)*mesh.spacing)};
    return mesh;
  }
  toData() {
    const count=this.dx.length,maxX=this.width-1,maxY=this.height-1;
    let first=0;
    while(first<count && this.dx[first]===0 && this.dy[first]===0) first++;
    if(first===count)return null;
    // 直接配置最終長度，避免 Array.from 的 iterator、callback 與陣列擴充。
    const dx=new Array(count),dy=new Array(count);
    for(let i=0;i<count;i++){dx[i]=this.dx[i]/maxX;dy[i]=this.dy[i]/maxY;}
    return {version:1,referenceWidth:this.width,referenceHeight:this.height,spacing:this.spacing,columns:this.columns,rows:this.rows,
      dx:dx,dy:dy};
  }
  constructor(width, height, {spacing = 4, historyBytes = 32 * 1024 * 1024} = {}) {
    dimensions(width, height);
    if (!Number.isInteger(spacing) || spacing < 2 || spacing > 16) throw new RangeError('網格間距須為 2..16 整數。');
    if (!Number.isSafeInteger(historyBytes) || historyBytes < 0) throw new RangeError('歷史記憶體預算無效。');
    this.width = width; this.height = height; this.spacing = spacing;
    this.columns = Math.ceil((width - 1) / spacing) + 1;
    this.rows = Math.ceil((height - 1) / spacing) + 1;
    const count = this.columns * this.rows;
    this.dx = new Float32Array(count); this.dy = new Float32Array(count);
    this.nextX = new Float32Array(count); this.nextY = new Float32Array(count);
    this.historyBytes = historyBytes; this.past = []; this.future = []; this.stroke = null;
    this.renderRevision = 0; this.bounds = null;
    this.stats = {appliedSteps:0, limitedSteps:0, rejectedSteps:0, evaluatedNodes:0};
  }
  get snapshotBytes() { return this.dx.byteLength + this.dy.byteLength; }
  get memoryBytes() {
    return this.snapshotBytes * (2 + this.past.length + this.future.length + (this.stroke?.before ? 1 : 0));
  }
  get canUndo() { return !this.stroke && this.past.length > 0; }
  get canRedo() { return !this.stroke && this.future.length > 0; }
  point(p) {
    if (!p || !finite(p.x) || !finite(p.y)) throw new TypeError('筆畫座標須為有限數值。');
    return {x:clamp(p.x, 0, this.width-1), y:clamp(p.y, 0, this.height-1)};
  }
  // 位移網格採雙線性內插；末端不足 spacing 的 cell 使用實際寬高。
  read(x, y) {
    x = clamp(x, 0, this.width-1); y = clamp(y, 0, this.height-1);
    const ix = Math.min(this.columns-2, Math.floor(x / this.spacing));
    const iy = Math.min(this.rows-2, Math.floor(y / this.spacing));
    const x0 = ix*this.spacing, y0 = iy*this.spacing;
    const u = (x-x0)/(Math.min(x0+this.spacing, this.width-1)-x0);
    const v = (y-y0)/(Math.min(y0+this.spacing, this.height-1)-y0);
    const a = iy*this.columns+ix, b = a+1, c = a+this.columns, d = c+1;
    this.sampleDX = (this.dx[a]*(1-u)+this.dx[b]*u)*(1-v)+(this.dx[c]*(1-u)+this.dx[d]*u)*v;
    this.sampleDY = (this.dy[a]*(1-u)+this.dy[b]*u)*(1-v)+(this.dy[c]*(1-u)+this.dy[d]*u)*v;
  }
  sample(x, y) {
    if (!finite(x) || !finite(y)) throw new TypeError('取樣座標須為有限數值。');
    x = clamp(x, 0, this.width-1); y = clamp(y, 0, this.height-1);
    this.read(x,y); return [x+this.sampleDX,y+this.sampleDY];
  }
  capture() { return {x:this.dx.slice(), y:this.dy.slice(), bounds:this.bounds && {...this.bounds}}; }
  load(state) {
    this.dx.set(state.x); this.dy.set(state.y); this.bounds = state.bounds && {...state.bounds}; this.renderRevision++;
  }
  trimHistory() {
    // 歷史只在提交／復原／重做後裁剪；進行中另用至多一份快照，取消不刪既有歷史。
    while ((this.past.length + this.future.length)*this.snapshotBytes > this.historyBytes) {
      if (this.past.length) this.past.shift();
      else if (this.future.length) this.future.shift();
      else break;
    }
  }
  beginStroke(point, {radius = 60, strength = .5, mode = 'push'} = {}) {
    if (this.stroke) throw new Error('請先結束目前筆畫。');
    const p = this.point(point);
    if (!finite(radius) || radius < 12 || radius > 1024) throw new RangeError('筆刷半徑須為 12..1024 像素。');
    if (!finite(strength) || strength < 0 || strength > 1) throw new RangeError('筆刷強度須為 0..1。');
    if (!['push','restore'].includes(mode)) throw new RangeError('不支援此筆刷模式。');
    this.stroke = {radius, strength, mode, input:p, stamp:p, remaining:radius*.08, before:null};
  }
  moveStroke(point) {
    const target = this.point(point), s = this.stroke;
    if (!s) return false;
    let x = s.input.x, y = s.input.y;
    let length = Math.hypot(target.x-x, target.y-y);
    if (length === 0) return false;
    const vx = (target.x-x)/length, vy = (target.y-y)/length;
    while (length + 1e-9 >= s.remaining) {
      const advance = Math.min(length,s.remaining);
      x += vx*advance; y += vy*advance; length -= advance;
      this.dab(s.stamp, {x,y}, s);
      s.stamp = {x,y}; s.remaining = s.radius*.08;
    }
    s.remaining -= length; s.input = target;
    return true;
  }
  endStroke() {
    const s = this.stroke;
    if (!s) return false;
    const length = Math.hypot(s.input.x-s.stamp.x,s.input.y-s.stamp.y);
    if (length > 1e-7 || (s.mode === 'restore' && !s.before)) this.dab(s.stamp,s.input,s);
    this.stroke = null;
    if (!s.before) return false;
    this.future.length = 0;
    this.past.push(s.before); this.trimHistory(); return true;
  }
  cancelStroke() {
    const s = this.stroke; this.stroke = null;
    if (s?.before) this.load(s.before);
  }
  undo() {
    if (!this.canUndo) return false;
    this.future.push(this.capture()); this.load(this.past.pop()); this.trimHistory(); return true;
  }
  redo() {
    if (!this.canRedo) return false;
    this.past.push(this.capture()); this.load(this.future.pop()); this.trimHistory(); return true;
  }
  reset() {
    this.cancelStroke(); this.dx.fill(0); this.dy.fill(0);
    this.past.length = 0; this.future.length = 0; this.bounds = null; this.renderRevision++;
  }
  dab(from, to, s) {
    const vx = to.x-from.x, vy = to.y-from.y, length = Math.hypot(vx,vy);
    if (s.strength === 0 || (s.mode === 'push' && length < 1e-7)) return;
    const cx = (from.x+to.x)*.5, cy = (from.y+to.y)*.5, r=s.radius, step=this.spacing;
    const left = Math.max(0,Math.floor((cx-r)/step)), top=Math.max(0,Math.floor((cy-r)/step));
    const right = Math.min(this.columns-1,Math.ceil((cx+r)/step)), bottom=Math.min(this.rows-1,Math.ceil((cy+r)/step));
    let accepted=false, changed=false;
    for (let attempt=0; attempt<10; attempt++) {
      const strength=s.strength*2**(-attempt); changed=false;
      for (let iy=top; iy<=bottom; iy++) for (let ix=left; ix<=right; ix++) {
        const index=iy*this.columns+ix, x=Math.min(ix*step,this.width-1), y=Math.min(iy*step,this.height-1);
        const edge=Math.min(x,y,this.width-1-x,this.height-1-y);
        const influence=weight(Math.hypot(x-cx,y-cy)/r)*smooth(clamp(edge/r,0,1));
        let dx=this.dx[index], dy=this.dy[index];
        if (influence>0) {
          if (s.mode==='restore') {
            const a=clamp((length || r*.08)/r*1.5*strength*influence,0,1); dx*=1-a;dy*=1-a;
          } else {
            const ux=-vx*strength*influence, uy=-vy*strength*influence;
            // 合成逆向映射：M_new(p)=M_old(p−wΔ)，不直接累加位移。
            this.read(x+ux,y+uy); dx=ux+this.sampleDX;dy=uy+this.sampleDY;
          }
        }
        this.nextX[index]=dx;this.nextY[index]=dy;
        if (this.nextX[index]!==this.dx[index] || this.nextY[index]!==this.dy[index]) changed=true;
      }
      this.stats.evaluatedNodes+=(right-left+1)*(bottom-top+1);
      if (!changed) return;
      if (this.validCandidate(left,top,right,bottom)) {
        accepted=true; if(attempt) this.stats.limitedSteps++;break;
      }
    }
    if (!accepted) {this.stats.rejectedSteps++;return;}
    if (!s.before) s.before=this.capture();
    for (let iy=top;iy<=bottom;iy++) {
      const first=iy*this.columns+left,last=iy*this.columns+right+1;
      this.dx.set(this.nextX.subarray(first,last),first);this.dy.set(this.nextY.subarray(first,last),first);
    }
    const bounds={left:Math.max(0,(left-1)*step),top:Math.max(0,(top-1)*step),right:Math.min(this.width-1,(right+1)*step),bottom:Math.min(this.height-1,(bottom+1)*step)};
    if(this.bounds) {bounds.left=Math.min(bounds.left,this.bounds.left);bounds.top=Math.min(bounds.top,this.bounds.top);bounds.right=Math.max(bounds.right,this.bounds.right);bounds.bottom=Math.max(bounds.bottom,this.bounds.bottom);}
    this.bounds=bounds;this.renderRevision++;this.stats.appliedSteps++;
  }
  validCandidate(left,top,right,bottom,minimum=.05) {
    const step=this.spacing, cols=this.columns, endX=Math.min(cols-2,right),endY=Math.min(this.rows-2,bottom);
    // 每角只判斷一次資料來源，X/Y 共用；不建立每次呼叫的 closure。
    for(let iy=Math.max(0,top-1);iy<=endY;iy++) {
      const upper=iy>=top&&iy<=bottom,lower=iy+1>=top&&iy+1<=bottom,row=iy*cols;
      for(let ix=Math.max(0,left-1);ix<=endX;ix++) {
        const x=ix*step,y=iy*step,hx=Math.min(x+step,this.width-1)-x,hy=Math.min(y+step,this.height-1)-y;
        const insideLeft=ix>=left&&ix<=right,insideRight=ix+1>=left&&ix+1<=right;
        const a=row+ix,b=a+1,c=a+cols,d=c+1;
        const ac=upper&&insideLeft,bc=upper&&insideRight,cc=lower&&insideLeft,dc=lower&&insideRight;
        const ax=x+(ac?this.nextX[a]:this.dx[a]),ay=y+(ac?this.nextY[a]:this.dy[a]);
        const bx=x+hx+(bc?this.nextX[b]:this.dx[b]),by=y+(bc?this.nextY[b]:this.dy[b]);
        const cx=x+(cc?this.nextX[c]:this.dx[c]),cy=y+hy+(cc?this.nextY[c]:this.dy[c]);
        const dx=x+hx+(dc?this.nextX[d]:this.dx[d]),dy=y+hy+(dc?this.nextY[d]:this.dy[d]);
        // 雙線性 cell 的 Jacobian determinant 是仿射，四角正即可保護整個 cell。
        const threshold=minimum*hx*hy;
        if ((bx-ax)*(cy-ay)-(by-ay)*(cx-ax)<threshold ||
            (bx-ax)*(dy-by)-(by-ay)*(dx-bx)<threshold ||
            (dx-cx)*(cy-ay)-(dy-cy)*(cx-ax)<threshold ||
            (dx-cx)*(dy-by)-(dy-cy)*(dx-bx)<threshold) return false;
      }
    }
    return true;
  }
}

const toLinear=Float32Array.from({length:256},(_,i)=>{
  const v=i/255;return v<=.04045?v/12.92:((v+.055)/1.055)**2.4;
});
function toByte(v) {return Math.round(255*clamp(v<=.0031308?v*12.92:1.055*v**(1/2.4)-.055,0,1));}
function renderWarp(source,width,height,mesh,output) {
  dimensions(width,height);
  if (!(mesh instanceof LiquifyMesh) || mesh.width!==width || mesh.height!==height) throw new RangeError('影像與網格尺寸不符。');
  if (!(source instanceof Uint8ClampedArray) || source.length!==width*height*4) throw new TypeError('來源須為完整 RGBA Uint8ClampedArray。');
  if (output===undefined) output=new Uint8ClampedArray(source.length);
  if (!(output instanceof Uint8ClampedArray) || output.length!==source.length) throw new TypeError('輸出 RGBA 長度不符。');
  if (source.buffer===output.buffer && source.byteOffset<output.byteOffset+output.byteLength && output.byteOffset<source.byteOffset+source.byteLength) throw new TypeError('輸出不得覆寫不可變原圖。');
  output.set(source);
  if(!mesh.bounds)return output;
  const {left,top,right,bottom}=mesh.bounds;
  // 遠距的小筆畫可能形成很大的包圍盒；先以網格節點排除沒有位移的 tile。
  // 節點範圍包含雙線性內插所需的右／下鄰點，不另持有全圖 dirty buffer。
  const tileSize=32,step=mesh.spacing,cols=mesh.columns;
  for(let tileY=top;tileY<=bottom;tileY+=tileSize)for(let tileX=left;tileX<=right;tileX+=tileSize) {
    const endX=Math.min(right,tileX+tileSize-1),endY=Math.min(bottom,tileY+tileSize-1);
    const firstX=Math.min(cols-2,Math.floor(tileX/step)),firstY=Math.min(mesh.rows-2,Math.floor(tileY/step));
    const lastX=Math.min(cols-1,Math.floor(endX/step)+1),lastY=Math.min(mesh.rows-1,Math.floor(endY/step)+1);
    let deformed=false;
    for(let iy=firstY;iy<=lastY&&!deformed;iy++)for(let ix=firstX;ix<=lastX;ix++) {
      const index=iy*cols+ix;
      if(mesh.dx[index]!==0||mesh.dy[index]!==0) {deformed=true;break;}
    }
    if(!deformed)continue;
    for(let y=tileY;y<=endY;y++) {
      // 畫素座標已在影像內，同一列共用網格列與垂直權重；算式次序維持 read。
      const iy=Math.min(mesh.rows-2,Math.floor(y/step)),gridY=iy*step;
      const gridV=(y-gridY)/(Math.min(gridY+step,height-1)-gridY),row=iy*cols;
      for(let x=tileX;x<=endX;x++) {
        const ix=Math.min(cols-2,Math.floor(x/step)),gridX=ix*step;
        const gridU=(x-gridX)/(Math.min(gridX+step,width-1)-gridX),ga=row+ix,gb=ga+1,gc=ga+cols,gd=gc+1;
        mesh.sampleDX=(mesh.dx[ga]*(1-gridU)+mesh.dx[gb]*gridU)*(1-gridV)+(mesh.dx[gc]*(1-gridU)+mesh.dx[gd]*gridU)*gridV;
        mesh.sampleDY=(mesh.dy[ga]*(1-gridU)+mesh.dy[gb]*gridU)*(1-gridV)+(mesh.dy[gc]*(1-gridU)+mesh.dy[gd]*gridU)*gridV;
        if(mesh.sampleDX===0&&mesh.sampleDY===0)continue;
        const sx=clamp(x+mesh.sampleDX,0,width-1),sy=clamp(y+mesh.sampleDY,0,height-1);
        const x0=Math.floor(sx),y0=Math.floor(sy),x1=Math.min(width-1,x0+1),y1=Math.min(height-1,y0+1);
        const u=sx-x0,v=sy-y0,a=(y0*width+x0)*4,b=(y0*width+x1)*4,c=(y1*width+x0)*4,d=(y1*width+x1)*4;
        const wa=(1-u)*(1-v)*source[a+3]/255,wb=u*(1-v)*source[b+3]/255,wc=(1-u)*v*source[c+3]/255,wd=u*v*source[d+3]/255;
        const alpha=wa+wb+wc+wd,index=(y*width+x)*4;
        output[index+3]=Math.round(alpha*255);
        if(!output[index+3]) {output[index]=output[index+1]=output[index+2]=0;continue;}
        for(let channel=0;channel<3;channel++) {
          output[index+channel]=toByte((toLinear[source[a+channel]]*wa+toLinear[source[b+channel]]*wb+toLinear[source[c+channel]]*wc+toLinear[source[d+channel]]*wd)/alpha);
        }
      }
    }
  }
  return output;
}

globalThis.PhotoLiquifyCore = {LiquifyMesh, renderWarp};
})();
