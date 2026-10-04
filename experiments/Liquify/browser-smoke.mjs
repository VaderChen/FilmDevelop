/** 實際 Chromium 介面 Smoke；需本機 serve.py 及 Playwright。 */
import assert from 'node:assert/strict';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
const here=path.dirname(fileURLToPath(import.meta.url));
const url=process.argv[2] || 'http://127.0.0.1:8766/';
assert(['127.0.0.1','localhost','[::1]'].includes(new URL(url).hostname),'僅對本機原型執行Smoke');
const out=path.resolve(process.argv[3] || path.join(here,'../../build/liquify-smoke-20261004'));
await mkdir(out,{recursive:true});
const playwright=await import(process.env.PLAYWRIGHT_MODULE ? pathToFileURL(process.env.PLAYWRIGHT_MODULE).href : 'playwright');
const {chromium}=playwright.default ?? playwright;
const browser=await chromium.launch({headless:true});
const page=await browser.newPage({viewport:{width:1380,height:970},deviceScaleFactor:1,acceptDownloads:true});
const errors=[],completed=[];
page.on('pageerror',e=>errors.push(String(e)));
page.on('request',r=>{if(/^https?:/.test(r.url()) && new URL(r.url()).origin!==new URL(url).origin)errors.push('非本機網路請求：'+r.url());});
const hash=()=>page.locator('#canvas').evaluate(c=>{
 const data=c.getContext('2d').getImageData(0,0,c.width,c.height).data;let h=2166136261;
 for(const v of data)h=Math.imul(h^v,16777619);return h>>>0;
});
async function untilHash(expected,equal=true) {
 for(let i=0;i<100;i++){const actual=await hash();if((actual===expected)===equal)return actual;await page.waitForTimeout(20);}
 throw new Error('畫布更新逾時');
}
async function setRange(id,value){await page.locator(id).evaluate((e,v)=>{e.value=String(v);e.dispatchEvent(new Event('input',{bubbles:true}));},value);}
async function stroke(from,to,steps=12) {
 const box=await page.locator('#canvas').boundingBox();
 await page.mouse.move(box.x+box.width*from[0],box.y+box.height*from[1]);await page.mouse.down();
 await page.mouse.move(box.x+box.width*to[0],box.y+box.height*to[1],{steps});await page.mouse.up();
 await nextPaint();
}
async function nextPaint(){await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));}
function pass(name){completed.push(name);}
try {
 await page.goto(url);await page.waitForFunction(()=>document.querySelector('#status')?.textContent.includes('768 × 512'));
 assert.equal(await page.title(),'FilmDevelop · 液化實驗室');
 const original=await hash();assert(original!==0);pass('獨立頁面載入與格線測試圖');
 await page.screenshot({path:path.join(out,'before.png'),fullPage:true});
 await stroke([.43,.48],[.53,.5]);const warped=await untilHash(original,false);
 assert(await page.locator('#undo').isEnabled());pass('真實滑鼠局部推移並建立復原紀錄');
 await page.screenshot({path:path.join(out,'after.png'),fullPage:true});
 await page.locator('#undo').click();await untilHash(original);
 await page.locator('#redo').click();await untilHash(warped);pass('復原與重做逐像素恢復');
 await page.locator('#compare').hover();await page.mouse.down();await untilHash(original);await page.mouse.up();await untilHash(warped);pass('按住比較原圖並恢復變形');
 await page.locator('#compare').focus();await page.keyboard.down('Space');await untilHash(original);await page.keyboard.up('Space');await untilHash(warped);pass('鍵盤原圖比較');
 const box=await page.locator('#canvas').boundingBox();
 await page.mouse.move(box.x+box.width*.42,box.y+box.height*.45);await page.mouse.down();await page.mouse.move(box.x+box.width*.48,box.y+box.height*.49,{steps:6});
 await untilHash(warped,false);await page.keyboard.press('Escape');await page.mouse.up();await untilHash(warped);assert(await page.locator('#undo').isEnabled());pass('Esc取消當筆且保留原有歷史');
 await setRange('#strength',0);await stroke([.45,.44],[.55,.45]);await nextPaint();assert.equal(await hash(),warped);pass('零強度不改變影像');
 await setRange('#strength',80);await page.locator('#mode').selectOption('restore');await stroke([.45,.47],[.53,.5]);await untilHash(warped,false);pass('局部還原筆刷可操作');
 await page.locator('#reset').click();await untilHash(original);assert(await page.locator('#undo').isDisabled());pass('全部還原清除編輯歷史');
 await page.locator('#mode').selectOption('push');await setRange('#strength',65);
 await page.setViewportSize({width:920,height:940});await nextPaint();
 const small=await page.locator('#canvas').boundingBox();assert(small.width<768);
 await stroke([.43,.48],[.53,.5]);const scaled=await untilHash(original,false);pass('縮放後畫布座標與筆刷仍可操作');
 // 載入失敗必須保留影像與上一筆歷史。
 await page.locator('#openFile').setInputFiles({name:'broken.png',mimeType:'image/png',buffer:Buffer.from('broken')});
 await page.waitForFunction(()=>!document.querySelector('#error').hidden);assert.equal(await hash(),scaled);assert(await page.locator('#undo').isEnabled());pass('損壞圖片不破壞現有編輯');
 const fixture=await page.evaluate(()=>{
  const c=document.createElement('canvas');c.width=1600;c.height=800;const g=c.getContext('2d');
  const gradient=g.createLinearGradient(200,0,1400,0);gradient.addColorStop(0,'#4080c0');gradient.addColorStop(1,'#f0b080');
  g.fillStyle=gradient;g.fillRect(200,100,1200,600);g.clearRect(500,200,200,200);return c.toDataURL('image/png').split(',')[1];
 });
 await page.locator('#openFile').setInputFiles({name:'透明照片.png',mimeType:'image/png',buffer:Buffer.from(fixture,'base64')});
 await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('1024 × 512') && document.querySelector('#error').hidden);
 assert(await page.locator('#undo').isDisabled());const imported=await hash();pass('本機透明PNG載入、長邊1024限制及換圖清空歷史');
 await setRange('#radius',100);await stroke([.33,.39],[.38,.43]);await untilHash(imported,false);
 const alpha=await page.locator('#canvas').evaluate(c=>{
  const d=c.getContext('2d').getImageData(0,0,c.width,c.height).data;let zero=0,opaque=0,partial=0;
  for(let i=3;i<d.length;i+=4){if(!d[i])zero++;else if(d[i]===255)opaque++;else partial++;}return {zero,opaque,partial};
 });assert(alpha.zero>0&&alpha.opaque>0&&alpha.partial>0);pass('透明與半透明邊緣保留');
 const downloadPromise=page.waitForEvent('download');await page.locator('#download').click();const download=await downloadPromise;
 assert.equal(download.suggestedFilename(),'透明照片-液化.png');const downloaded=path.join(out,'export.png');await download.saveAs(downloaded);
 const png=await readFile(downloaded);assert.equal(png.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
 assert.equal(png.readUInt32BE(16),1024);assert.equal(png.readUInt32BE(20),512);pass('實際下載PNG且尺寸正確');
 const exportHash=await hash();await page.locator('#openFile').setInputFiles(downloaded);
 await page.waitForFunction(()=>document.querySelector('#imageName').textContent==='export.png' && document.querySelector('#error').hidden);await nextPaint();assert.equal(await hash(),exportHash);pass('PNG重新載入逐像素一致');
 await page.locator('#testImage').click();await page.waitForFunction(()=>document.querySelector('#status').textContent.includes('768 × 512'));
 await untilHash(original);pass('回到格線圖且無殘留照片／歷史');
 assert.deepEqual(errors,[]);pass('無未處理JavaScript錯誤或外部網路請求');
 const result={passed:true,browser:await browser.version(),platform:process.platform,completed,alpha,diagnosticStatus:await page.locator('#status').innerText(),limitations:['實際GUI測試為macOS Chromium；未執行Windows或Safari實機。']};
 await writeFile(path.join(out,'browser-report.json'),JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result,null,2));
} catch(e) {
 const report={passed:false,error:String(e),stack:e.stack,completed,errors};await writeFile(path.join(out,'browser-report.json'),JSON.stringify(report,null,2)+'\n');await page.screenshot({path:path.join(out,'failure.png'),fullPage:true});throw e;
} finally {await browser.close();}
