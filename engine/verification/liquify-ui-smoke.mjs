/** 共用正式 Web 介面 Smoke；宿主協定由測試模擬，真引擎另以原生 Smoke 驗證。 */
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const web = path.join(root, 'PhotoStyleApp/Web');
const out = path.resolve(process.argv[2] || path.join(root, 'build/liquify-integration-ui'));
await mkdir(out, { recursive: true });
const server = createServer(async (request, response) => {
  try {
    const name = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    const file = path.resolve(web, '.' + (name === '/' ? '/index.html' : name));
    if (!file.startsWith(web + path.sep)) { response.writeHead(403).end(); return; }
    const data = await readFile(file);
    const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png' };
    response.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' }).end(data);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${server.address().port}/`;
const modulePath = process.env.PLAYWRIGHT_MODULE;
const imported = await import(modulePath ? pathToFileURL(modulePath).href : 'playwright');
const playwright = imported.default || imported;
const browserName = process.env.LIQUIFY_BROWSER || 'chromium';
assert(['chromium', 'webkit'].includes(browserName));
const browser = await playwright[browserName].launch({ headless: true, ...(process.env.LIQUIFY_BROWSER_EXECUTABLE ? { executablePath: process.env.LIQUIFY_BROWSER_EXECUTABLE } : {}) });
const page = await browser.newPage({ viewport: { width: 1512, height: 982 }, deviceScaleFactor: 1, locale: 'zh-TW' });
const errors = [], completed = [];
page.on('pageerror', error => errors.push(String(error)));
page.on('request', request => {
  if (/^https?:/.test(request.url()) && new URL(request.url()).origin !== new URL(url).origin) errors.push('非本機請求：' + request.url());
});
const paint = () => page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
const pass = name => completed.push(name);
const send = payload => page.evaluate(value => window.__liquifyHost.update(value), payload);
const imageRect = () => page.locator('.preview-image').evaluate(image => { const r = image.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; });
const commandCount = () => page.evaluate(() => window.__liquifyHost.commands.filter(c => c.action === 'applyLiquifyBrush').length);
async function ready() {
  await page.waitForFunction(() => {
    const overlay = document.querySelector('.liquify-overlay'), slider = document.querySelector('#liquifyRadius');
    return overlay && overlay.width > 1 && slider && !slider.disabled && !document.querySelector('.liquify-status');
  });
  await paint();
}
async function hash() {
  return page.locator('.liquify-overlay').evaluate(canvas => {
    const rgba = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
    let h = 2166136261; for (const value of rgba) h = Math.imul(h ^ value, 16777619); return h >>> 0;
  });
}
async function stroke(from = [.43, .47], to = [.55, .50]) {
  const rect = await imageRect();
  await page.mouse.move(rect.x + rect.width * from[0], rect.y + rect.height * from[1]);
  await page.mouse.down();
  await page.mouse.move(rect.x + rect.width * to[0], rect.y + rect.height * to[1], { steps: 12 });
  await page.mouse.up(); await paint();
}
async function toggleOn() {
  await page.locator('[data-liquify-toggle]').click(); await ready();
}

// 真實鍵盤／滑鼠滾輪搭配合成 deltaMode 封包，覆蓋兩種筆刷的共同手勢。
async function brushWheelSmoke(kind) {
  const liquid=kind==='liquify', label=liquid?'液化':'修復';
  const input=liquid?'#liquifyRadius':'#repairBrushSize', output=input+'Value', overlay='.'+kind+'-overlay', cursor='.'+kind+'-cursor';
  const current=async()=>Number(await page.locator(input).inputValue());
  const change=async value=>page.locator(input).evaluate((e,v)=>{e.value=v;e.dispatchEvent(new Event('input',{bubbles:true}));},value);
  const count=()=>page.evaluate(()=>window.__liquifyHost.commands.filter(c=>c.action==='applyLiquifyBrush'||c.action==='applyRepairBrush').length);
  const initial=await current(), initialCount=await count(), rect=await imageRect();
  const position={x:rect.x+rect.width*.5,y:rect.y+rect.height*.5};
  await page.mouse.move(position.x,position.y);await page.keyboard.down('Shift');
  await page.mouse.wheel(0,-120);await page.waitForFunction(id=>Number(document.querySelector(id).value)>Number(document.querySelector(id).getAttribute('value')),input);
  assert.equal(await current(),initial+5);assert.equal(await page.locator(output).textContent(),(initial+5)+' px');
  const diameter=await page.locator(cursor).evaluate(e=>({value:parseFloat(e.style.width),visible:!e.hidden}));
  assert(diameter.visible);assert(Math.abs(diameter.value-(liquid?2*(initial+5)*rect.width/767:initial+5))<.01);
  await page.mouse.wheel(0,120);await page.waitForFunction(({id,v})=>Number(document.querySelector(id).value)===v,{id:input,v:initial});
  await page.keyboard.up('Shift');assert.equal((await imageRect()).width,rect.width);
  pass(label+'：Shift＋實際滾輪雙向調整，滑桿與游標同步且不縮放');
  async function packet(values) {
    await page.locator(overlay).evaluate((element,values)=>{
      const r=element.getBoundingClientRect();element.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,shiftKey:true,...values}));
    },values);
  }
  await packet({deltaX:-48});assert.equal(await current(),initial+2);
  await packet({deltaY:3,deltaMode:1});assert.equal(await current(),initial);
  await packet({deltaY:-1,deltaMode:2});assert.equal(await current(),initial+10);
  pass(label+'：支援 Shift 轉橫向滾動與行／頁單位');
  await change(initial);
  async function fine(delta) {
    await page.locator(overlay).evaluate((element,delta)=>{
      const r=element.getBoundingClientRect();for(let i=0;i<48;i++)element.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,clientX:r.x+r.width/2,clientY:r.y+r.height/2,shiftKey:true,deltaY:delta}));
    },delta);
  }
  await fine(-.5);assert.equal(await current(),initial+1);
  const limits=await page.locator(input).evaluate(e=>({min:Number(e.min),max:Number(e.max)}));
  await change(limits.max-1);await packet({deltaY:-1000000});assert.equal(await current(),limits.max);
  await packet({deltaY:-1000000});await fine(.5);assert.equal(await current(),limits.max-1);
  await change(limits.min+1);await packet({deltaY:1000000});assert.equal(await current(),limits.min);
  await packet({deltaY:1000000});await fine(-.5);assert.equal(await current(),limits.min+1);
  pass(label+'：觸控板小數增量、大小上下限與邊界反向正常');
  await change(initial);
  await page.mouse.move(position.x,position.y);await page.mouse.wheel(0,-72);
  await page.waitForFunction(width=>document.querySelector('.preview-image').getBoundingClientRect().width>width,rect.width);
  assert.equal(await current(),initial);const zoomed=await imageRect();
  await packet({deltaY:-24});assert.equal(await current(),initial+1);assert.equal((await imageRect()).width,zoomed.width);
  const zoomDiameter=await page.locator(cursor).evaluate(e=>parseFloat(e.style.width));
  assert(Math.abs(zoomDiameter-(liquid?2*(initial+1)*zoomed.width/767:initial+1))<.01);
  await packet({ctrlKey:true,deltaY:24});await paint();assert.equal(await current(),initial+1);
  assert((await imageRect()).width<zoomed.width);
  assert.equal(await count(),initialCount);
  pass(label+'：一般滾輪及Ctrl縮放保留，調整大小不送出修圖');
  await page.locator('[data-zoom="zoomFit"]').click();await paint();await change(initial);
  const restored=await imageRect();await page.mouse.move(restored.x+restored.width*.5,restored.y+restored.height*.5);await page.mouse.down();
  await packet({deltaY:-120});assert.equal(await current(),initial);assert.equal((await imageRect()).width,restored.width);
  await page.locator(overlay).dispatchEvent('pointercancel',{pointerId:1,bubbles:true});await page.mouse.up();await paint();
  assert.equal(await count(),initialCount);pass(label+'：筆畫中不改尺寸或觸發照片縮放');
  await packet({deltaY:-48});assert.equal(await current(),initial+2);
  await send({sourceFileName:'Shift滾輪測試.png'});if(liquid)await ready();else await paint();
  assert.equal(await current(),initial+2);pass(label+'：背景重繪保留調整後尺寸');
  await page.evaluate(liquid=>{window.__liquifyHost.autoReply=!liquid;window.__liquifyHost.autoRepairReply=liquid;},liquid);
  await page.keyboard.down('Shift');await stroke([.45,.46],[.51,.5]);await page.keyboard.up('Shift');
  assert.equal(await current(),initial+2);assert.equal(await count(),initialCount+1);
  const pendingWidth=(await imageRect()).width;await packet({deltaY:-120});assert.equal(await current(),initial+2);assert.equal((await imageRect()).width,pendingWidth);
  if(liquid){await page.evaluate(()=>{const h=window.__liquifyHost;h.autoReply=true;h.reply(h.commands.filter(c=>c.action==='applyLiquifyBrush').at(-1));});await ready();}
  else {
    const applied=await page.evaluate(()=>window.__liquifyHost.commands.filter(c=>c.action==='applyRepairBrush').at(-1));
    assert(Math.abs(applied.strokes[0].radius-(initial+2)/2/pendingWidth)<1e-8);
    await page.evaluate(()=>{window.__liquifyHost.autoRepairReply=true;window.handleRepairResult({success:true});});await paint();
  }
  pass(label+'：Shift拖曳仍正常塗抹，處理期間不接受尺寸變更');
  await change(initial);
}

try {
  await page.addInitScript(() => {
    const h = window.__liquifyHost = { commands: [], state: {}, past: [], future: [], autoReply: true, revision: 0, replyFirst: false };
    h.update = patch => { Object.assign(h.state, patch); window.handleNativeState(patch); };
    h.reply = (command, success = true, replyFirst = h.replyFirst) => {
      if (!success) { window.handleLiquifyResult({ success: false, requestID: command.requestID, photoGeneration: command.photoGeneration, liquifyRevision: command.liquifyRevision }); return; }
      h.past.push({ mesh: h.state.liquifyMesh, revision: h.state.liquifyRevision }); h.future = [];
      const revision = 'mesh-' + (++h.revision);
      const result = { success: true, requestID: command.requestID, photoGeneration: command.photoGeneration, liquifyRevision: revision };
      const patch = { liquifyMesh: command.mesh, liquifyRevision: revision, previewRevision: h.state.previewRevision + 1, canUndo: true, canRedo: false };
      if (replyFirst) window.handleLiquifyResult(result);
      h.update(patch);
      if (!replyFirst) window.handleLiquifyResult(result);
      h.lastResult = result;
    };
    window.PhotoNativeBridge = { post(command) {
      h.commands.push(structuredClone(command));
      if (command.action === 'applyLiquifyBrush' && h.autoReply) setTimeout(() => h.reply(command), 20);
      if (command.action === 'applyRepairBrush' && h.autoRepairReply !== false) setTimeout(() => window.handleRepairResult({success:true}),20);
      if (command.action === 'prepareRepairBrush') setTimeout(() => window.handleRepairPreparation({ success: true, photoGeneration: command.photoGeneration }), 0);
      if (command.action === 'undoEdit' || command.action === 'redoEdit') {
        const from = command.action === 'undoEdit' ? h.past : h.future;
        const to = command.action === 'undoEdit' ? h.future : h.past;
        if (from.length) {
          to.push({ mesh: h.state.liquifyMesh, revision: h.state.liquifyRevision }); const next = from.pop();
          setTimeout(() => h.update({ liquifyMesh: next.mesh, liquifyRevision: next.revision, previewRevision: h.state.previewRevision + 1, canUndo: h.past.length > 0, canRedo: h.future.length > 0, externalEdit: true }), 0);
        }
      }
    } };
  });
  await page.goto(url);
  await page.waitForFunction(() => typeof window.handleNativeState === 'function');
  await page.evaluate(() => {
    const c = document.createElement('canvas'); c.width = 768; c.height = 512;
    const g = c.getContext('2d'), gradient = g.createLinearGradient(0, 0, 768, 512);
    gradient.addColorStop(0, '#c0a080'); gradient.addColorStop(.5, '#408090'); gradient.addColorStop(1, '#c0d0a0');
    g.fillStyle = gradient; g.fillRect(0, 0, c.width, c.height); g.strokeStyle = '#fff';
    for (let x = 0; x < 768; x += 32) { g.beginPath(); g.moveTo(x, 0); g.lineTo(x, 512); g.stroke(); }
    for (let y = 0; y < 512; y += 32) { g.beginPath(); g.moveTo(0, y); g.lineTo(768, y); g.stroke(); }
    const source = c.toDataURL('image/png');
    const fixture = { supportsLiquify: true, hasImage: true, canSave: true, sourceFileName: '液化整合測試.png',
      photoGeneration: 'photo-A', previewRevision: 1, liquifyMesh: null, liquifyRevision: '',
      sourceImage: source, outputImage: source, cropSourceImage: source, repairSourceImage: source, liquifySourceImage: source,
      sourceImageSize: { width: 768, height: 512 }, cropSourceImageSize: { width: 768, height: 512 }, previewOutputSize: { width: 768, height: 512 },
      selectedStyle: 'original', styles: [{ id: 'original', title: '原片', isOriginal: true, palette: ['#888', '#aaa', '#ddd'] }], adjustments: {},
      isLoadingImage: false, isRenderingPreview: false, canUndo: false, canRedo: false };
    window.__liquifyHost.fixture = structuredClone(fixture); window.__liquifyHost.update(fixture);
  });
  await page.waitForFunction(() => document.querySelector('.preview-image')?.complete && document.querySelector('.preview-image')?.naturalWidth > 0);
  const placement = await page.evaluate(() => {
    const a = document.querySelector('[data-liquify-toggle]'), b = document.querySelector('[data-repair-toggle]');
    return a.parentElement === b.parentElement && a.nextElementSibling === b;
  });
  assert(placement); pass('液化按鈕位於修復按鈕左側');
  await send({ supportsLiquify: false }); assert.equal(await page.locator('[data-liquify-toggle]').count(), 0);
  await send({ supportsLiquify: true }); pass('無液化宿主能力時不顯示失效按鈕');
  await page.locator('[data-white-balance-picker]').click(); assert.equal(await page.locator('[data-white-balance-picker]').getAttribute('aria-pressed'), 'true');
  await toggleOn(); assert.equal(await page.locator('[data-white-balance-picker]').getAttribute('aria-pressed'), 'false');
  assert(await page.locator('[data-white-balance-picker]').isDisabled()); assert(await page.locator('#previewCropAspectRatio').isDisabled());
  const original = await hash(); assert.notEqual(original, 0); pass('液化與滴管互斥並停用裁切');
  await page.locator('[data-repair-toggle]').click();
  await page.waitForSelector('.repair-overlay'); assert.equal(await page.locator('.liquify-overlay').count(), 0);
  await toggleOn(); assert.equal(await page.locator('.repair-overlay').count(), 0); pass('修復與液化相互切換且無重疊畫布');
  await stroke(); await ready(); const first = await hash(); assert.notEqual(first, original);
  assert.equal(await commandCount(), 1); pass('第一筆真實指標拖曳提交並顯示權威網格');
  await page.evaluate(() => { window.__liquifyHost.replyFirst = true; });
  await stroke([.58, .58], [.65, .54]); await ready(); const second = await hash(); assert.notEqual(second, first);
  assert.equal(await commandCount(), 2); pass('第二筆累積前筆變形，result先於state仍可解鎖');
  await page.locator('[data-action="undoEdit"]').click(); await page.waitForFunction(() => window.__liquifyHost.state.liquifyRevision === 'mesh-1'); await ready(); assert.equal(await hash(), first);
  await page.locator('[data-action="redoEdit"]').click(); await page.waitForFunction(() => window.__liquifyHost.state.liquifyRevision === 'mesh-2'); await ready(); assert.equal(await hash(), second); pass('宿主復原／重做逐像素恢復');
  await page.locator('[data-liquify-action="done"]').click(); assert.equal(await page.locator('.liquify-overlay').count(), 0);
  await toggleOn(); assert.equal(await hash(), second); pass('退出再進入由保存網格重播而非重複變形');

  let beforeCancel = await commandCount();
  let rect = await imageRect();
  await page.mouse.move(rect.x + rect.width * .45, rect.y + rect.height * .46); await page.mouse.down();
  await page.mouse.move(rect.x + rect.width * .53, rect.y + rect.height * .47, { steps: 8 }); await paint();
  await page.locator('.liquify-overlay').dispatchEvent('pointercancel', { pointerId: 1, bubbles: true }); await page.mouse.up(); await paint();
  assert.equal(await commandCount(), beforeCancel); assert.equal(await hash(), second); pass('pointercancel捨棄當筆且保留已提交網格');
  await page.mouse.move(rect.x + rect.width * .45, rect.y + rect.height * .46); await page.mouse.down();
  await page.mouse.move(rect.x + rect.width * .53, rect.y + rect.height * .47, { steps: 8 }); await paint();
  await send({ sourceFileName: '同照片部分狀態更新.png' }); await page.mouse.up(); await ready();
  assert.equal(await commandCount(), beforeCancel + 1); assert.notEqual(await hash(), second);
  await page.locator('[data-action="undoEdit"]').click(); await page.waitForFunction(() => window.__liquifyHost.state.liquifyRevision === 'mesh-2'); await ready();
  assert.equal(await hash(), second); beforeCancel = await commandCount(); pass('部分背景狀態更新不打斷拖曳，仍只提交一筆');
  rect = await imageRect();
  await page.mouse.move(rect.x + rect.width * .45, rect.y + rect.height * .46); await page.mouse.down();
  await page.mouse.move(rect.x + rect.width * .53, rect.y + rect.height * .47, { steps: 8 }); await paint();
  await page.evaluate(() => window.dispatchEvent(new Event('blur'))); await page.mouse.up(); await paint();
  assert.equal(await commandCount(), beforeCancel); assert.equal(await hash(), second); pass('失焦取消未提交筆畫');

  await page.evaluate(() => { window.__liquifyHost.autoReply = false; });
  await stroke([.38, .56], [.45, .62]); await page.waitForSelector('.liquify-status');
  const pendingCount = await commandCount();
  await stroke([.45, .48], [.50, .50]); assert.equal(await commandCount(), pendingCount); pass('原生處理期間禁止提交第二筆');
  await page.evaluate(() => { const h = window.__liquifyHost; h.reply(h.commands.filter(c => c.action === 'applyLiquifyBrush').at(-1), false); });
  await ready(); assert.equal(await hash(), second); pass('原生失敗回復前筆，重新啟用編輯');

  await stroke([.4, .4], [.48, .43]); await page.waitForSelector('.liquify-status');
  await page.evaluate(() => window.handleLiquifyResult(window.__liquifyHost.lastResult));
  assert(await page.locator('#liquifyRadius').isDisabled()); pass('舊requestID成功回覆不會解除新筆畫pending');
  await page.evaluate(() => { const h = window.__liquifyHost; h.oldPending = h.commands.filter(c => c.action === 'applyLiquifyBrush').at(-1); h.update({ ...h.fixture, photoGeneration: 'photo-B', sourceFileName: '第二張.png' }); h.past = []; h.future = []; });
  assert.equal(await page.locator('.liquify-overlay').count(), 0); await toggleOn(); assert.equal(await hash(), original);
  await page.evaluate(() => { const p = window.__liquifyHost.oldPending; window.handleLiquifyResult({ success: true, requestID: p.requestID, photoGeneration: p.photoGeneration, liquifyRevision: 'stale-photo-A' }); });
  await paint(); assert.equal(await hash(), original); assert(await page.locator('#liquifyRadius').isEnabled()); pass('換圖清除網格／pending並忽略舊照片結果');

  await page.evaluate(() => { window.__liquifyHost.autoReply = true; });
  await page.locator('[data-zoom="zoomIn"]').click(); await page.locator('[data-zoom="zoomIn"]').click(); await paint();
  await stroke([.46, .47], [.50, .5]); await ready();
  const coordinate = await page.evaluate(() => {
    const m = window.__liquifyHost.state.liquifyMesh;
    let amount = 0, x = 0, y = 0;
    for (let iy = 0; iy < m.rows; iy++) for (let ix = 0; ix < m.columns; ix++) {
      const i = iy * m.columns + ix, weight = Math.hypot(m.dx[i], m.dy[i]);
      amount += weight; x += weight * Math.min(ix * m.spacing, m.referenceWidth - 1) / (m.referenceWidth - 1); y += weight * Math.min(iy * m.spacing, m.referenceHeight - 1) / (m.referenceHeight - 1);
    }
    return { x: x / amount, y: y / amount };
  });
  assert(Math.abs(coordinate.x - .48) < .08 && Math.abs(coordinate.y - .485) < .08, JSON.stringify(coordinate));
  pass('放大後按實際影像矩形映射筆畫座標');
  await page.evaluate(() => { const h = window.__liquifyHost; h.update({ ...h.fixture, photoGeneration: 'photo-C' }); h.past = []; h.future = []; });
  await page.locator('[data-zoom="zoomIn"]').click(); await page.locator('[data-zoom="zoomIn"]').click(); await paint();
  const panBefore = await imageRect(), frameBox = await page.locator('.preview-frame').boundingBox();
  await page.mouse.move(frameBox.x + frameBox.width * .5, frameBox.y + frameBox.height * .5); await page.mouse.down();
  await page.mouse.move(frameBox.x + frameBox.width * .5 + 65, frameBox.y + frameBox.height * .5 + 30, { steps: 8 }); await page.mouse.up(); await paint();
  const panAfter = await imageRect(); assert(Math.abs(panAfter.x - panBefore.x) > 20);
  await toggleOn(); await stroke([.46, .47], [.50, .50]); await ready();
  const panCoordinate = await page.evaluate(() => {
    const m = window.__liquifyHost.state.liquifyMesh; let amount = 0, x = 0, y = 0;
    for (let iy = 0; iy < m.rows; iy++) for (let ix = 0; ix < m.columns; ix++) {
      const i = iy * m.columns + ix, weight = Math.hypot(m.dx[i], m.dy[i]); amount += weight;
      x += weight * Math.min(ix * m.spacing, m.referenceWidth - 1) / (m.referenceWidth - 1); y += weight * Math.min(iy * m.spacing, m.referenceHeight - 1) / (m.referenceHeight - 1);
    }
    return { x: x / amount, y: y / amount };
  });
  assert(Math.abs(panCoordinate.x - .48) < .08 && Math.abs(panCoordinate.y - .485) < .08, JSON.stringify(panCoordinate));
  pass('實際平移與放大後筆畫仍落於正確影像座標');
  await page.locator('[data-liquify-action="done"]').click();
  await page.locator('#previewCropAspectRatio').selectOption('oneOne');
  await page.waitForSelector('[data-crop-box]'); await toggleOn(); assert.equal(await page.locator('[data-crop-box]').count(), 0);
  pass('裁切進入液化時取消裁切模式');
  await page.evaluate(() => {
    const h = window.__liquifyHost; h.positiveState = structuredClone(h.state);
    const c = document.createElement('canvas'); c.width = 768; c.height = 512;
    const g = c.getContext('2d'); g.fillStyle = '#90b4a0'; g.fillRect(0, 0, 768, 512); g.clearRect(230, 150, 260, 200);
    const source = c.toDataURL('image/png');
    h.update({ ...h.fixture, photoGeneration: 'photo-alpha', sourceFileName: '透明液化.png', sourceImage: source, outputImage: source,
      cropSourceImage: source, repairSourceImage: source, liquifySourceImage: source }); h.past = []; h.future = [];
  });
  await toggleOn(); await stroke([.31, .48], [.39, .5]); await ready();
  const alpha = await page.locator('.liquify-overlay').evaluate(canvas => {
    const image = document.querySelector('.preview-image'), r = image.getBoundingClientRect(), f = canvas.getBoundingClientRect();
    const data = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
    let zero = 0, opaque = 0, partial = 0;
    for (let y = Math.max(0, Math.ceil(r.top - f.top)); y < Math.min(canvas.height, Math.floor(r.bottom - f.top)); y++)
      for (let x = Math.max(0, Math.ceil(r.left - f.left)); x < Math.min(canvas.width, Math.floor(r.right - f.left)); x++) {
        const a = data[(y * canvas.width + x) * 4 + 3]; if (!a) zero++; else if (a === 255) opaque++; else partial++;
      }
    return { zero, opaque, partial, canonicalVisible: getComputedStyle(image).visibility !== 'hidden' };
  });
  assert(alpha.zero > 1000 && alpha.opaque > 1000 && alpha.partial > 0); assert.equal(alpha.canonicalVisible, false);
  pass('透明與半透明邊緣保留，透明區不透出未扭曲原圖');
  await page.evaluate(() => { const h = window.__liquifyHost; h.update({ ...h.positiveState, photoGeneration: 'photo-final' }); });
  await toggleOn();
  await brushWheelSmoke('liquify');
  await page.locator('[data-repair-toggle]').click();await page.waitForSelector('.repair-overlay');await paint();
  await brushWheelSmoke('repair');
  await toggleOn();
  await page.locator('.preview-frame').focus(); await page.mouse.move(5, 5);
  await page.waitForFunction(() => document.querySelector('#toast').hidden && document.querySelector('#instantTooltip').hidden);
  assert.deepEqual(errors, []); pass('無未處理JavaScript錯誤或外部網路請求');
  await page.screenshot({ path: path.join(out, 'integrated.png'), fullPage: true });
  const report = { passed: true, browser: browserName, browserVersion: browser.version(), platform: process.platform,
    completed, coordinate, panCoordinate, alpha, limitation: '此測試使用正式共用Web及真實瀏覽器，宿主回覆由測試模擬；不代替Go／Swift／C++真引擎及Windows實機驗證。' };
  await writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n'); console.log(JSON.stringify(report, null, 2));
} catch (error) {
  const report = { passed: false, error: String(error), stack: error.stack, completed, errors };
  await writeFile(path.join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  await page.screenshot({ path: path.join(out, 'failure.png'), fullPage: true }); throw error;
} finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
