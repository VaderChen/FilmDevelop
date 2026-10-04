/** 液化 controller 函式前後比對；相同 Chromium、核心與 DOM，記錄配置與繪製次數。 */
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {fileURLToPath,pathToFileURL} from 'node:url';
import path from 'node:path';
import {createHash} from 'node:crypto';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const out=path.resolve(process.argv[2]||path.join(root,'build/liquify-optimization'));
const baseline=path.resolve(process.argv[3]||path.join(out,'baseline'));
await mkdir(out,{recursive:true});
const core=await readFile(path.join(baseline,'PhotoStyleApp/Web/liquify-core.js'),'utf8');
const before=await readFile(path.join(baseline,'PhotoStyleApp/Web/liquify-brush.js'),'utf8');
const after=await readFile(path.join(root,'PhotoStyleApp/Web/liquify-brush.js'),'utf8');
const brushSizeWheel=await readFile(path.join(root,'PhotoStyleApp/Web/brush-size-wheel.js'),'utf8');
const imported=await import(process.env.PLAYWRIGHT_MODULE?pathToFileURL(process.env.PLAYWRIGHT_MODULE).href:'playwright');
const browser=await (imported.default||imported).chromium.launch({headless:true});
async function run(source) {
  const page=await browser.newPage({viewport:{width:1000,height:900}}),errors=[];
  page.on('pageerror',e=>errors.push(String(e)));
  await page.setContent('<style>.preview-frame{position:relative;width:800px;height:640px}.preview-image{position:absolute;left:10px;top:20px;width:768px;height:576px;visibility:hidden}.liquify-overlay{position:absolute;inset:0;width:100%;height:100%}.liquify-cursor{position:absolute}</style><main id="app"></main>');
  await page.addScriptTag({content:core});await page.addScriptTag({content:brushSizeWheel});await page.addScriptTag({content:source});
  await page.evaluate(()=>{
    const NativeImage=Image, getPixels=CanvasRenderingContext2D.prototype.getImageData;
    const rect=Element.prototype.getBoundingClientRect, draw=CanvasRenderingContext2D.prototype.drawImage;
    const m=window.metrics={images:0,readbacks:0,readbackBytes:0,rects:0,draws:0};
    window.Image=new Proxy(NativeImage,{construct(target,args){m.images++;return Reflect.construct(target,args);}});
    CanvasRenderingContext2D.prototype.getImageData=function(...args){const v=getPixels.apply(this,args);m.readbacks++;m.readbackBytes+=v.data.byteLength;return v;};
    Element.prototype.getBoundingClientRect=function(){if(this.matches('.preview-frame,.preview-image'))m.rects++;return rect.call(this);};
    CanvasRenderingContext2D.prototype.drawImage=function(...args){m.draws++;return draw.apply(this,args);};
    const fixture=document.createElement('canvas');fixture.width=1024;fixture.height=768;
    const ctx=fixture.getContext('2d');ctx.fillStyle='#307a90';ctx.fillRect(0,0,1024,768);
    ctx.fillStyle='#eab370';ctx.fillRect(250,180,450,430);ctx.clearRect(340,230,110,140);
    ctx.strokeStyle='white';for(let x=0;x<1024;x+=32){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,768);ctx.stroke();}
    const s=window.fixtureState={supportsLiquify:true,hasImage:true,liquifyEditing:true,photoGeneration:'perf',previewRevision:1,liquifyRevision:'',liquifyMesh:null,liquifySourceImage:fixture.toDataURL()};
    const mesh=new PhotoLiquifyCore.LiquifyMesh(1024,768,{historyBytes:0});
    mesh.beginStroke({x:420,y:350},{radius:90,strength:.8});mesh.moveStroke({x:490,y:370});mesh.endStroke();
    window.meshA=mesh.toData();mesh.beginStroke({x:620,y:440},{radius:70,strength:.7});mesh.moveStroke({x:650,y:400});mesh.endStroke();window.meshB=mesh.toData();
    const app=document.getElementById('app');
    window.renderFixture=function(){app.innerHTML=controller.panel()+'<div class="preview-frame"><img class="preview-image" src="'+s.liquifySourceImage+'">'+controller.overlay()+'</div>';controller.bind();};
    window.controller=new PhotoLiquifyBrush({root:app,state:()=>s,text:v=>v,escape:v=>v,busy:()=>false,render:renderFixture,post:()=>{},
      image:()=>app.querySelector('.preview-image'),cancelGesture:()=>{},prepare:()=>{},toast:message=>{throw Error(message);}});
    window.paint=()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));
    window.ready=async()=>{for(let i=0;i<120;i++){await paint();if(!document.querySelector('.liquify-status')&&document.querySelector('#liquifyRadius')&&!document.querySelector('#liquifyRadius').disabled)return;}throw Error('預覽逾時');};
    window.clearMetrics=()=>Object.keys(m).forEach(k=>m[k]=0);
    window.canvasHash=()=>{const c=document.querySelector('.liquify-overlay'),d=getPixels.call(c.getContext('2d'),0,0,c.width,c.height).data;let h=2166136261;for(const v of d)h=Math.imul(h^v,16777619);return h>>>0;};
    controller.receive(s);renderFixture();
  });
  await page.evaluate(()=>ready());
  const revision=await page.evaluate(async()=>{
    clearMetrics();const milliseconds=[],hashes=[];
    for(let i=0;i<20;i++){
      const start=performance.now();fixtureState.liquifyMesh=i%2?meshB:meshA;fixtureState.liquifyRevision='revision-'+i;
      controller.receive(fixtureState);renderFixture();await ready();milliseconds.push(performance.now()-start);hashes.push(canvasHash());
    }
    return {metrics:{...metrics},milliseconds,hashes};
  });
  const idle=await page.evaluate(async()=>{
    clearMetrics();const expected=canvasHash();for(let i=0;i<20;i++){controller.redraw();await paint();}
    return {metrics:{...metrics},unchanged:canvasHash()===expected};
  });
  await page.locator('#liquifyStrength').evaluate(e=>{e.value=0;e.dispatchEvent(new Event('input'));});
  await page.mouse.move(380,330);await page.mouse.down();
  const pointer=await page.evaluate(()=>{
    const c=document.querySelector('.liquify-overlay');clearMetrics();const start=performance.now();
    for(let j=0;j<40;j++){
      const samples=Array.from({length:32},(_,i)=>({clientX:380+i/2,clientY:330+j/2}));
      const event=new PointerEvent('pointermove',{pointerId:1,clientX:396,clientY:350,bubbles:true});
      Object.defineProperty(event,'getCoalescedEvents',{value:()=>samples});c.dispatchEvent(event);
    }
    return {metrics:{...metrics},milliseconds:performance.now()-start,events:40,samplesPerEvent:32};
  });
  await page.mouse.up();await page.evaluate(()=>paint());
  const resized=await page.evaluate(async()=>{
    clearMetrics();const m=new PhotoLiquifyCore.LiquifyMesh(256,192,{historyBytes:0});
    m.beginStroke({x:100,y:90},{radius:32,strength:.8});m.moveStroke({x:130,y:95});m.endStroke();
    fixtureState.liquifyMesh=m.toData();fixtureState.liquifyRevision='resized';controller.receive(fixtureState);renderFixture();await ready();
    return {metrics:{...metrics},hash:canvasHash()};
  });
  const transitions=await page.evaluate(async()=>{
    const results=[];
    async function update(name,change){clearMetrics();change();controller.receive(fixtureState);renderFixture();await ready();results.push({name,metrics:{...metrics},hash:canvasHash()});}
    await update('不同尺寸網格回到原圖預設尺寸',()=>{fixtureState.liquifyMesh=null;fixtureState.liquifyRevision='';});
    await update('同尺寸identity到已保存網格',()=>{fixtureState.liquifyMesh=meshA;fixtureState.liquifyRevision='A';});
    await update('繪製前快速undo再redo回原revision',()=>{
      fixtureState.liquifyMesh=meshB;fixtureState.liquifyRevision='B';controller.receive(fixtureState);
      fixtureState.liquifyMesh=meshA;fixtureState.liquifyRevision='A';
    });
    await update('同尺寸網格回到identity',()=>{fixtureState.liquifyMesh=null;fixtureState.liquifyRevision='';});
    await update('相同照片切換來源',()=>{
      const c=document.createElement('canvas');c.width=1024;c.height=768;
      const ctx=c.getContext('2d');ctx.fillStyle='#602070';ctx.fillRect(0,0,1024,768);
      fixtureState.liquifySourceImage=c.toDataURL();
    });
    await update('關閉再開啟釋放並重建像素',()=>{controller.close();fixtureState.liquifyEditing=true;});
    return results;
  });
  assert.deepEqual(errors,[]);assert(idle.unchanged);assert.equal(resized.metrics.readbacks,1);
  await page.close();return {revision,idle,pointer,resized,transitions};
}
try {
 const old=await run(before),next=process.env.LIQUIFY_PERF_BASELINE_ONLY==='1'?null:await run(after);
 if(next){
   assert.deepEqual(next.revision.hashes,old.revision.hashes);assert.equal(next.resized.hash,old.resized.hash);
   assert.deepEqual(next.transitions.map(v=>v.hash),old.transitions.map(v=>v.hash));
   assert.deepEqual(next.transitions.map(v=>v.metrics.readbacks),[1,0,0,0,1,1]);
   assert.equal(next.revision.metrics.readbacks,0);assert.equal(next.idle.metrics.draws,0);
   assert.equal(next.pointer.metrics.rects,80);
 }
 const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
 const report={suite:'液化controller函式量測',passed:true,browser:await browser.version(),before:old,after:next,
  revisionMedianMs:{before:median(old.revision.milliseconds),after:next?median(next.revision.milliseconds):null},
  sourceSHA256:{before:createHash('sha256').update(before).digest('hex'),after:createHash('sha256').update(after).digest('hex')},
  method:'同一Chromium依序使用相同基線核心、1024×768透明格線；20次同來源換網格、20次無變化redraw、40事件×32個coalesced sample；計數只涵蓋controller明確解碼、像素readback、矩形讀取和drawImage。此測試宿主狀態為模擬，不是整張App延遲或程序RSS。'};
 await writeFile(path.join(out,next?'controller-report.json':'controller-baseline.json'),JSON.stringify(report,null,2)+'\n');
 console.log(JSON.stringify({passed:true,revisionMedianMs:report.revisionMedianMs,before:old.revision.metrics,after:next?.revision.metrics,pointerRects:{before:old.pointer.metrics.rects,after:next?.pointer.metrics.rects}},null,2));
}finally{await browser.close();}
