/** 對正式 Web 核心執行原型回歸與網格保存 Smoke，不開啟 App 或使用者照片。 */
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import '../../PhotoStyleApp/Web/liquify-core.js';
const {LiquifyMesh,renderWarp}=globalThis.PhotoLiquifyCore;
const coreURL=new URL('../../PhotoStyleApp/Web/liquify-core.js',import.meta.url).href;
const suite=readFileSync(new URL('../../experiments/Liquify/smoke.mjs',import.meta.url),'utf8')
  .replace("import { LiquifyMesh, renderWarp } from './liquify.mjs';",'const {LiquifyMesh,renderWarp}=globalThis.PhotoLiquifyCore;');
const baseline=JSON.parse(execFileSync(process.execPath,['--input-type=module','-'],{
  input:'import '+JSON.stringify(coreURL)+';\n'+suite,encoding:'utf8',maxBuffer:4*1024*1024
}));
assert.equal(baseline.failed,0);
const completed=[];
function check(name,fn){fn();completed.push(name);}
const mesh=new LiquifyMesh(257,193,{historyBytes:0});
mesh.beginStroke({x:95,y:96},{radius:48,strength:.85});
mesh.moveStroke({x:143,y:102});mesh.endStroke();
const data=JSON.parse(JSON.stringify(mesh.toData()));
check('JSON往返保留Float32位移與逐像素輸出',()=>{
  const loaded=LiquifyMesh.fromData(data,{historyBytes:0});
  assert.deepEqual(loaded.dx,mesh.dx);assert.deepEqual(loaded.dy,mesh.dy);
  const source=Uint8ClampedArray.from({length:257*193*4},(_,i)=>i%251);
  assert.deepEqual(renderWarp(source,257,193,loaded),renderWarp(source,257,193,mesh));
});
check('identity省略網格，還原清除持久變形',()=>{
  const empty=new LiquifyMesh(100,80);assert.equal(empty.toData(),null);
  const loaded=LiquifyMesh.fromData(data);loaded.reset();assert.equal(loaded.toData(),null);
});
check('拒絕超大、不完整、非有限與越界網格',()=>{
  for(const modify of [v=>v.version=2,v=>v.referenceWidth=1025,v=>delete v.spacing,
    v=>v.columns++,v=>v.dx.pop(),v=>v.dx[0]=Infinity,v=>v.dy[0]=.1,
    v=>v.dx[100]=2,v=>v.spacing=1]){
    const bad=structuredClone(data);modify(bad);assert.throws(()=>LiquifyMesh.fromData(bad));
  }
});
check('拒絕在影像內部翻折的網格',()=>{
  const bad=structuredClone(data),i=24*bad.columns+24;
  bad.dx[i]=.25;assert.throws(()=>LiquifyMesh.fromData(bad));
});
check('保存後繼續筆畫與原網格一致，不重複套用舊位移',()=>{
  const loaded=LiquifyMesh.fromData(data,{historyBytes:0});
  for(const target of [mesh,loaded]){
    target.beginStroke({x:160,y:100},{radius:40,strength:.7});
    target.moveStroke({x:170,y:130});target.endStroke();
  }
  assert.deepEqual(loaded.dx,mesh.dx);assert.deepEqual(loaded.dy,mesh.dy);
});
check('非完整末格的保存與取消仍能完全還原',()=>{
  const target=new LiquifyMesh(131,117,{spacing:4,historyBytes:0});
  target.beginStroke({x:95,y:79},{radius:26,strength:1});target.moveStroke({x:112,y:90});target.endStroke();
  const saved=target.toData(),loaded=LiquifyMesh.fromData(saved,{historyBytes:0});
  assert.deepEqual(loaded.toData(),saved);
  loaded.beginStroke({x:40,y:50},{radius:26,strength:1});loaded.moveStroke({x:75,y:70});loaded.cancelStroke();
  assert.deepEqual(loaded.toData(),saved);
});
console.log(JSON.stringify({suite:'正式液化核心與保存Smoke',passed:baseline.passed+completed.length,failed:0,
  baseline:baseline.results,persistence:completed},null,2));
