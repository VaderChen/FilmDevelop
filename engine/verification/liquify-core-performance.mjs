/** 液化核心差分與函式基準：原始備份和目前核心在同一程序交錯量測。 */
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const baselinePath = path.resolve(process.argv[2] || path.join(root, 'build/liquify-optimization/baseline/PhotoStyleApp/Web/liquify-core.js'));
const currentPath = path.join(root, 'PhotoStyleApp/Web/liquify-core.js');
const reportPath = path.resolve(process.argv[3] || path.join(root, 'build/liquify-optimization/core-report.json'));
const codes = await Promise.all([readFile(baselinePath, 'utf8'), readFile(currentPath, 'utf8')]);
function load(code) {
  // 使用同一 V8 realm，避免 vm context 全域代理查找成本蓋過真正熱區。
  const namespace = {}; new Function('globalThis', code)(namespace); return namespace.PhotoLiquifyCore;
}
const baseline = load(codes[0]), current = load(codes[1]);
const hash = value => createHash('sha256').update(value).digest('hex');
const bytes = array => Buffer.from(array.buffer, array.byteOffset, array.byteLength);
let randomState = 0x2468ace;
function random() { randomState = (Math.imul(randomState, 1664525) + 1013904223) >>> 0; return randomState / 4294967296; }
function source(w, h) {
  const out = new Uint8ClampedArray(w * h * 4);
  for (let i = 0; i < out.length; i++) out[i] = (i * 71 + (i >>> 5) * 13) & 255;
  return out;
}
function mesh(core, w = 1024, h = 683, spacing = 4) {
  const result = new core.LiquifyMesh(w, h, { spacing, historyBytes: 32 * 1024 * 1024 });
  result.beginStroke({ x: w * .43, y: h * .47 }, { radius: 64, strength: .65 });
  result.moveStroke({ x: w * .52, y: h * .5 }); result.endStroke(); return result;
}
const coverage = { dimensions: [], operations: 0, maps: 0, rgbaComparisons: 0, serializedComparisons: 0, validationCases: 0, limitedSteps: 0, rejectedSteps: 0 };
function equalMesh(a, b, label) {
  assert(bytes(a.dx).equals(bytes(b.dx)), label + ': dx'); assert(bytes(a.dy).equals(bytes(b.dy)), label + ': dy');
  assert.equal(a.canUndo, b.canUndo, label + ': undo'); assert.equal(a.canRedo, b.canRedo, label + ': redo');
  assert.equal(a.renderRevision, b.renderRevision, label + ': revision');
  assert.equal(JSON.stringify(a.stats), JSON.stringify(b.stats), label + ': stats'); coverage.maps++;
}
for (const [w, h, spacing] of [[2,2,2],[17,13,3],[65,49,16],[257,193,4],[768,512,4],[1024,683,8],[1024,1024,2]]) {
  coverage.dimensions.push({ width: w, height: h, spacing });
  const a = new baseline.LiquifyMesh(w,h,{spacing,historyBytes:3*1024*1024});
  const b = new current.LiquifyMesh(w,h,{spacing,historyBytes:3*1024*1024});
  const rgba = source(w,h), outA = new Uint8ClampedArray(rgba.length), outB = new Uint8ClampedArray(rgba.length);
  for (let stroke = 0; stroke < 18; stroke++) {
    const start = { x: (random() * 1.4 - .2) * w, y: (random() * 1.4 - .2) * h };
    const options = { radius: [12,32,64,180][stroke%4], strength: [0,.01,.65,1][stroke%4], mode: stroke%3===2 ? 'restore' : 'push' };
    a.beginStroke(start, options); b.beginStroke(start, options); coverage.operations += 2;
    for (let point = 0; point < 5; point++) {
      const p = { x: start.x + (random()-.5)*96, y: start.y + (random()-.5)*96 };
      a.moveStroke(p); b.moveStroke(p); equalMesh(a,b,'筆畫中'); coverage.operations += 2;
    }
    const action = stroke%7===6 ? 'cancelStroke' : 'endStroke'; a[action](); b[action](); coverage.operations += 2;
    equalMesh(a,b,'筆畫結束');
    if (stroke%4===3) { a.undo(); b.undo(); equalMesh(a,b,'復原'); a.redo(); b.redo(); equalMesh(a,b,'重做'); coverage.operations += 4; }
    const dataA=a.toData(), dataB=b.toData(); assert.equal(JSON.stringify(dataA),JSON.stringify(dataB),'持久JSON'); coverage.serializedComparisons++;
    baseline.renderWarp(rgba,w,h,a,outA);current.renderWarp(rgba,w,h,b,outB);assert(bytes(outA).equals(bytes(outB)),'RGBA位元組');coverage.rgbaComparisons++;
    if (dataA && stroke%3===0) {
      const reloadA=baseline.LiquifyMesh.fromData(dataA),reloadB=current.LiquifyMesh.fromData(dataB);
      assert(bytes(reloadA.dx).equals(bytes(reloadB.dx)));assert(bytes(reloadA.dy).equals(bytes(reloadB.dy)));
      baseline.renderWarp(rgba,w,h,reloadA,outA);current.renderWarp(rgba,w,h,reloadB,outB);assert(bytes(outA).equals(bytes(outB)),'重載RGBA位元組');coverage.rgbaComparisons++;
    }
  }
  coverage.limitedSteps+=a.stats.limitedSteps;coverage.rejectedSteps+=a.stats.rejectedSteps;
  a.reset();b.reset();equalMesh(a,b,'reset');
}
// 集中交錯的強筆畫實際進入減半重試與拒絕分支，不只比較容易通過的候選。
{
  const a=new baseline.LiquifyMesh(128,96),b=new current.LiquifyMesh(128,96),rgba=source(128,96);
  for(let i=0;i<12;i++){
    const direction=i%2?-1:1,start={x:64-42*direction,y:20+i*5},end={x:64+42*direction,y:72-i*4};
    for(const m of [a,b]){m.beginStroke(start,{radius:18,strength:1});m.moveStroke(end);m.endStroke();}
    equalMesh(a,b,'接近翻折門檻');coverage.operations+=6;
    assert(bytes(baseline.renderWarp(rgba,128,96,a)).equals(bytes(current.renderWarp(rgba,128,96,b))));coverage.rgbaComparisons++;
  }
  assert(a.stats.limitedSteps>0&&a.stats.rejectedSteps>0);
  coverage.limitedSteps+=a.stats.limitedSteps;coverage.rejectedSteps+=a.stats.rejectedSteps;
}
const validData=mesh(baseline).toData();
for(const mutate of [d=>{d.version=2;},d=>{d.referenceWidth=1025;},d=>{d.dx.pop();},d=>{d.dx[0]=.1;},d=>{d.dy[17]=NaN;},d=>{d.dx[2000]=.99;}]) {
  const d=structuredClone(validData);mutate(d);
  function error(core){try{core.LiquifyMesh.fromData(d);return null;}catch(e){return e.name+':'+e.message;}}
  assert.equal(error(baseline),error(current));coverage.validationCases++;
}

// 先暖機，再交錯 baseline/current；每項回報單次函式的中位數，排除備料。
const median=values=>values.slice().sort((a,b)=>a-b)[Math.floor(values.length/2)];
const benches=[];
function bench(name, setup, run, iterations=30) {
  const contexts=[setup(baseline),setup(current)];
  for(let side=0;side<2;side++)for(let i=0;i<4;i++)run(contexts[side]);
  const samples=[[],[]];
  for(let trial=0;trial<9;trial++)for(const side of (trial%2 ? [1,0]:[0,1])) {
    const start=performance.now();for(let i=0;i<iterations;i++)run(contexts[side]);
    samples[side].push((performance.now()-start)/iterations);
  }
  const before=median(samples[0]),after=median(samples[1]);
  benches.push({function:name,baselineMedianMs:before,currentMedianMs:after,ratio:after/before,iterations,trials:9});
}
bench('read：10000次取樣',c=>mesh(c),m=>{for(let i=0;i<10000;i++)m.read((i*17.31)%1024,(i*7.13)%683);},8);
bench('validCandidate：局部33×33節點',c=>{const m=mesh(c);m.nextX.set(m.dx);m.nextY.set(m.dy);return m;},m=>m.validCandidate(90,60,122,92),100);
bench('validCandidate：全圖',c=>{const m=mesh(c);m.nextX.set(m.dx);m.nextY.set(m.dy);return m;},m=>m.validCandidate(0,0,m.columns-1,m.rows-1),20);
bench('fromData：局部筆畫重載',c=>({c,data:validData}),x=>x.c.LiquifyMesh.fromData(x.data,{historyBytes:0}),20);
bench('toData：局部筆畫序列化',c=>mesh(c),m=>m.toData(),30);
bench('toData：未編輯影像',c=>new c.LiquifyMesh(1024,683),m=>m.toData(),50);
bench('renderWarp：局部筆畫',c=>{const m=mesh(c);return {c,m,rgba:source(m.width,m.height),out:new Uint8ClampedArray(m.width*m.height*4)};},x=>x.c.renderWarp(x.rgba,x.m.width,x.m.height,x.m,x.out),20);
bench('renderWarp：重載局部筆畫',c=>{const m=c.LiquifyMesh.fromData(validData);return {c,m,rgba:source(m.width,m.height),out:new Uint8ClampedArray(m.width*m.height*4)};},x=>x.c.renderWarp(x.rgba,x.m.width,x.m.height,x.m,x.out),20);
bench('capture：網格快照',c=>mesh(c),m=>m.capture(),100);
for(const mode of ['push','restore']) bench('dab：'+mode,c=>{const m=mesh(c);return {m,s:{radius:64,strength:.65,mode,before:m.capture()},before:m.capture()};},x=>{
  x.m.dx.set(x.before.x);x.m.dy.set(x.before.y);x.m.dab({x:470,y:320},{x:475,y:322},x.s);
},80);
bench('一次70px完整筆畫',c=>({c}),x=>{const m=new x.c.LiquifyMesh(1024,683,{historyBytes:0});m.beginStroke({x:450,y:300},{radius:64,strength:.65});m.moveStroke({x:520,y:315});m.endStroke();},15);

// 函式累計時間含其下層呼叫，僅用於找熱區，不作效能改善的百分比。
function profile(core) {
  const m=new core.LiquifyMesh(1024,683,{historyBytes:0}), measured={};
  for(const name of ['read','validCandidate','dab','capture','point','moveStroke','endStroke','toData']) {
    const original=m[name];measured[name]={calls:0,totalMilliseconds:0};
    m[name]=function(...args){const start=performance.now();try{return original.apply(this,args);}finally{measured[name].calls++;measured[name].totalMilliseconds+=performance.now()-start;}};
  }
  for(let i=0;i<12;i++){m.beginStroke({x:400+i*3,y:280+i*2},{radius:64,strength:.65});m.moveStroke({x:470+i*3,y:310+i*2});m.endStroke();m.toData();}
  return measured;
}
const memoryMesh=mesh(current);
function retainedSerialization(core) {
  if(typeof global.gc!=='function')return null;
  const m=mesh(core), samples=[];
  for(let trial=0;trial<5;trial++){
    global.gc();const start=process.memoryUsage().heapUsed;
    let retained=Array.from({length:24},()=>m.toData());global.gc();
    samples.push((process.memoryUsage().heapUsed-start)/retained.length);
    // 保留到量測完成，避免 V8 判斷未使用的結果可以提前回收。
    assert.equal(retained[23].dx.length,m.dx.length);retained=null;
  }
  global.gc();return median(samples);
}
function isolatedCapture() {
  if(typeof global.gc!=='function')return null;
  const meshes=[mesh(baseline),mesh(current)],samples=[[],[]];
  for(const m of meshes)for(let i=0;i<500;i++)m.capture();
  for(let trial=0;trial<21;trial++)for(const side of (trial%2?[1,0]:[0,1])) {
    global.gc();const start=performance.now();let checksum=0;
    for(let i=0;i<200;i++)checksum+=meshes[side].capture().x[0];
    samples[side].push((performance.now()-start)/200);assert.equal(checksum,0);
  }
  return {sameFunction:baseline.LiquifyMesh.prototype.capture.toString()===current.LiquifyMesh.prototype.capture.toString(),
    baselineMedianMs:median(samples[0]),currentMedianMs:median(samples[1]),trials:21,iterations:200,
    description:'單獨交錯量測，組前GC。capture未修改，不把混合基準的短配置／GC噪音解讀成加速或退步。'};
}
const report={passed:true,baselineSHA:hash(codes[0]),currentSHA:hash(codes[1]),runtime:process.version,platform:process.platform,
  coverage,benchmarks:benches,isolatedCapture:isolatedCapture(),
  measurementNotes:['read、capture實作未變，不宣稱加速；capture的極短配置量測受GC時點影響，另附隔離複測。',
    'dab與完整筆畫的改善來自validCandidate；直接修改的函式為validCandidate、fromData、toData及renderWarp。'],
  profile:{baseline:profile(baseline),current:profile(current)},
  buffers:{mesh1024x683WithOneHistoryBytes:memoryMesh.memoryBytes,
    mesh1024x683HistoryZeroBytes:new current.LiquifyMesh(1024,683,{historyBytes:0}).memoryBytes,
    rgbaInputBytes:1024*683*4,rgbaOutputBytes:1024*683*4,
    serializedRetainedHeapBytes:{baseline:retainedSerialization(baseline),current:retainedSerialization(current)},
    notes:['未新增任何常駐typed-array或RGBA buffer；網格、scratch與歷史預算不變。',
      'toData配置兩個最終長度的Array，取代兩個Array.from iterator/callback及陣列擴充；空網格不配置輸出陣列。',
      'validCandidate取消每次驗證的displacement closure，四個角各只判斷一次candidate來源。',
      'renderWarp垂直網格權重按列計算，不配置新的逐畫素物件或快取。',
      'fromData重載的bounds僅含非零節點與相鄰一格；輸出仍先完整複製原圖，透明像素與未變形區完全一致。']},
  methodology:'9組交錯量測中位數；同一Node程序、固定種子、typed array位元組與RGBA逐byte差分。dab項含恢復兩個既有網格buffer，不含配置。函式profile含下層時間。'};
await mkdir(path.dirname(reportPath),{recursive:true});await writeFile(reportPath,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({passed:report.passed,coverage,benchmarks:benches,report:reportPath},null,2));
