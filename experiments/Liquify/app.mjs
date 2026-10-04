import { LiquifyMesh, renderWarp } from './liquify.mjs';

const $ = (id) => document.getElementById(id);
const canvas = $('canvas');
const context = canvas.getContext('2d', { willReadFrequently: true });
const wrap = $('canvasWrap');
const brush = $('brush');
const controls = ['mode', 'radius', 'strength', 'undo', 'redo', 'reset', 'compare', 'download', 'testImage'];
let mesh;
let source;
let output;
let outputImage;
let frame = 0;
let renderedRevision = -1;
let renderTime = 0;
let pointer = null;
let comparison = false;
let comparePointer = null;
let lastPoint = null;
let loading = false;
let loadGeneration = 0;
let imageName = '格線測試圖';

function clearError() { $('error').hidden = true; $('error').textContent = ''; }
function showError(message) { $('error').textContent = message; $('error').hidden = false; }

function updateControls() {
  for (const id of controls) $(id).disabled = loading;
  $('undo').disabled = loading || !mesh?.canUndo;
  $('redo').disabled = loading || !mesh?.canRedo;
  $('radiusValue').value = `${$('radius').value} px`;
  $('strengthValue').value = `${$('strength').value}%`;
  $('compare').setAttribute('aria-pressed', String(comparison));
  $('compareBadge').hidden = !comparison;
  brush.classList.toggle('restore', $('mode').value === 'restore');
}

function updateStatus() {
  if (loading) { $('status').textContent = '正在載入照片…'; return; }
  const memory = (mesh.memoryBytes + source.byteLength + output.byteLength) / (1024 * 1024);
  $('status').textContent = `${canvas.width} × ${canvas.height} 像素\n最近更新 ${renderTime.toFixed(1)} ms · 編輯資料 ${memory.toFixed(1)} MB`;
}

function draw() {
  frame = 0;
  if (!mesh || !source) return;
  if (comparison) {
    context.putImageData(new ImageData(source, canvas.width, canvas.height), 0, 0);
  } else {
    if (renderedRevision !== mesh.renderRevision) {
      const start = performance.now();
      renderWarp(source, canvas.width, canvas.height, mesh, output);
      renderTime = performance.now() - start;
      renderedRevision = mesh.renderRevision;
    }
    context.putImageData(outputImage, 0, 0);
  }
  updateStatus();
  updateControls();
}

function scheduleDraw() { if (!frame) frame = requestAnimationFrame(draw); }
function flushDraw() { if (frame) cancelAnimationFrame(frame); frame = 0; draw(); }

function finishStroke(cancel = false) {
  if (pointer === null) return;
  const ended = pointer;
  pointer = null;
  if (cancel) mesh.cancelStroke(); else mesh.endStroke();
  if (canvas.hasPointerCapture(ended)) canvas.releasePointerCapture(ended);
  scheduleDraw();
  updateControls();
}

function compareOriginal(value) {
  if (loading || !mesh) return;
  finishStroke();
  comparison = value;
  brush.hidden = value || !lastPoint;
  scheduleDraw();
  updateControls();
}

function position(event) {
  const rect = canvas.getBoundingClientRect();
  return { x: (event.clientX - rect.left) * canvas.width / rect.width,
    y: (event.clientY - rect.top) * canvas.height / rect.height };
}

function updateBrush(point) {
  if (point) lastPoint = point;
  if (!lastPoint || comparison || loading) { brush.hidden = true; return; }
  const rect = canvas.getBoundingClientRect();
  const scale = rect.width / canvas.width;
  const diameter = Number($('radius').value) * 2 * scale;
  brush.style.width = `${diameter}px`;
  brush.style.height = `${diameter}px`;
  brush.style.left = `${lastPoint.x * scale}px`;
  brush.style.top = `${lastPoint.y * scale}px`;
  brush.hidden = false;
}

canvas.addEventListener('pointerdown', (event) => {
  if (event.button !== 0 || loading || comparison || pointer !== null) return;
  event.preventDefault();
  clearError();
  canvas.focus({ preventScroll: true });
  const point = position(event);
  mesh.beginStroke(point, { radius: Number($('radius').value), strength: Number($('strength').value) / 100, mode: $('mode').value });
  pointer = event.pointerId;
  canvas.setPointerCapture(pointer);
  updateBrush(point);
  scheduleDraw();
});

canvas.addEventListener('pointermove', (event) => {
  const point = position(event);
  updateBrush(point);
  if (pointer !== event.pointerId) return;
  // 保留裝置提供的軌跡；整張照片只在下一個畫面更新一次。
  const samples = typeof event.getCoalescedEvents === 'function' ? event.getCoalescedEvents() : [];
  for (const sample of samples.length ? samples : [event]) mesh.moveStroke(position(sample));
  scheduleDraw();
});
canvas.addEventListener('pointerup', (event) => {
  if (pointer === event.pointerId) { mesh.moveStroke(position(event)); finishStroke(); }
});
canvas.addEventListener('pointercancel', (event) => { if (pointer === event.pointerId) finishStroke(true); });
canvas.addEventListener('lostpointercapture', (event) => { if (pointer === event.pointerId) finishStroke(true); });
canvas.addEventListener('pointerleave', () => { if (pointer === null) { lastPoint = null; brush.hidden = true; } });

for (const id of ['radius', 'strength', 'mode']) $(id).addEventListener('input', () => {
  finishStroke(); updateControls(); updateBrush();
});

function edit(action) {
  finishStroke();
  comparison = false;
  action();
  scheduleDraw();
  updateControls();
}
$('undo').addEventListener('click', () => edit(() => mesh.undo()));
$('redo').addEventListener('click', () => edit(() => mesh.redo()));
$('reset').addEventListener('click', () => edit(() => mesh.reset()));

$('compare').addEventListener('pointerdown', (event) => {
  if (event.button !== 0 || loading) return;
  event.preventDefault();
  comparePointer = event.pointerId;
  $('compare').setPointerCapture(comparePointer);
  compareOriginal(true);
});
function stopComparison(event) {
  if (event && comparePointer !== event.pointerId) return;
  comparePointer = null;
  compareOriginal(false);
}
for (const name of ['pointerup', 'pointercancel', 'lostpointercapture']) $('compare').addEventListener(name, stopComparison);

function isTextControl(element) { return element instanceof Element && element.matches('input, select, textarea, [contenteditable="true"]'); }
document.addEventListener('keydown', (event) => {
  if (loading || isTextControl(event.target)) return;
  if (event.key === 'Escape') { finishStroke(true); compareOriginal(false); return; }
  const comparisonTarget = event.target === canvas || event.target === document.body || event.target === $('compare');
  if ((event.code === 'Space' && comparisonTarget) || (event.key === 'Enter' && event.target === $('compare'))) {
    event.preventDefault(); if (!event.repeat) compareOriginal(true); return;
  }
  if ((event.ctrlKey || event.metaKey) && !event.altKey && event.key.toLowerCase() === 'z') {
    event.preventDefault(); edit(() => event.shiftKey ? mesh.redo() : mesh.undo());
  }
});
document.addEventListener('keyup', (event) => {
  if (event.code === 'Space' || (event.key === 'Enter' && event.target === $('compare'))) compareOriginal(false);
});
function cancelInteraction() {
  finishStroke(true);
  comparePointer = null;
  comparison = false;
  lastPoint = null;
  brush.hidden = true;
  scheduleDraw();
}
window.addEventListener('blur', cancelInteraction);
document.addEventListener('visibilitychange', () => { if (document.hidden) cancelInteraction(); });
window.addEventListener('resize', () => updateBrush());

function setImage(imageData, name) {
  // 先完成驗證與配置，載圖失敗時保留上一張影像及其編輯紀錄。
  const nextMesh = new LiquifyMesh(imageData.width, imageData.height, { spacing: 4, historyBytes: 32 * 1024 * 1024 });
  const nextOutput = new Uint8ClampedArray(imageData.data.length);
  const nextOutputImage = new ImageData(nextOutput, imageData.width, imageData.height);
  finishStroke(true);
  comparison = false;
  pointer = null;
  lastPoint = null;
  brush.hidden = true;
  canvas.width = imageData.width;
  canvas.height = imageData.height;
  // 直幅照片同樣限制預覽高度，畫布與筆刷共用一致的座標比例。
  wrap.style.maxWidth = `${Math.min(imageData.width, imageData.width / imageData.height * 640)}px`;
  source = imageData.data;
  output = nextOutput;
  outputImage = nextOutputImage;
  mesh = nextMesh;
  renderedRevision = -1;
  imageName = name;
  $('imageName').textContent = name;
  scheduleDraw();
  updateControls();
}

function testImage() {
  ++loadGeneration;
  loading = false;
  clearError();
  const temporary = document.createElement('canvas');
  temporary.width = 768; temporary.height = 512;
  const ctx = temporary.getContext('2d', { willReadFrequently: true });
  const gradient = ctx.createLinearGradient(0, 0, 768, 512);
  gradient.addColorStop(0, '#b7ced4'); gradient.addColorStop(.48, '#b5bb9d'); gradient.addColorStop(1, '#d49d88');
  ctx.fillStyle = gradient; ctx.fillRect(0, 0, 768, 512);
  ctx.fillStyle = '#7a9692'; ctx.beginPath(); ctx.ellipse(245, 261, 136, 155, -.22, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = '#eed1a3'; ctx.beginPath(); ctx.ellipse(445, 242, 103, 119, .3, 0, Math.PI * 2); ctx.fill();
  ctx.fillStyle = '#ad685c'; ctx.beginPath(); ctx.arc(571, 327, 67, 0, Math.PI * 2); ctx.fill();
  ctx.strokeStyle = '#fff7'; ctx.lineWidth = 1;
  for (let x = 0; x <= 768; x += 32) { ctx.beginPath(); ctx.moveTo(x + .5, 0); ctx.lineTo(x + .5, 512); ctx.stroke(); }
  for (let y = 0; y <= 512; y += 32) { ctx.beginPath(); ctx.moveTo(0, y + .5); ctx.lineTo(768, y + .5); ctx.stroke(); }
  ctx.strokeStyle = '#243a3988'; ctx.lineWidth = 2; ctx.strokeRect(64, 64, 640, 384);
  ctx.fillStyle = '#243a39'; ctx.font = '500 15px sans-serif'; ctx.fillText('拖曳格線，觀察自然的局部變形', 86, 95);
  setImage(ctx.getImageData(0, 0, 768, 512), '格線測試圖');
  $('openFile').value = '';
  temporary.width = temporary.height = 1;
}
$('testImage').addEventListener('click', testImage);

$('openFile').addEventListener('change', async () => {
  const file = $('openFile').files?.[0];
  if (!file) return;
  const generation = ++loadGeneration;
  clearError();
  loading = false;
  updateControls(); updateStatus();
  if (!file.type.startsWith('image/')) { showError('請選擇瀏覽器支援的圖片檔案。'); return; }
  if (file.size > 40 * 1024 * 1024) { showError('此原型支援 40 MB 以內的照片，請先縮小檔案。'); return; }
  finishStroke(true);
  loading = true;
  comparison = false;
  brush.hidden = true;
  updateControls(); updateStatus();
  let url;
  let bitmap;
  const image = new Image();
  try {
    url = URL.createObjectURL(file);
    image.src = url;
    await image.decode();
    if (generation !== loadGeneration) return;
    if (image.naturalWidth < 2 || image.naturalHeight < 2 || image.naturalWidth * image.naturalHeight > 100_000_000) throw new Error('圖片尺寸過大或無法判讀，請選擇寬高至少 2 像素、一億像素以內的圖片。');
    const scale = Math.min(1, 1024 / Math.max(image.naturalWidth, image.naturalHeight));
    const width = Math.max(2, Math.round(image.naturalWidth * scale));
    const height = Math.max(2, Math.round(image.naturalHeight * scale));
    bitmap = await createImageBitmap(image, { resizeWidth: width, resizeHeight: height, resizeQuality: 'high' });
    if (generation !== loadGeneration) return;
    const temporary = document.createElement('canvas');
    temporary.width = width; temporary.height = height;
    const ctx = temporary.getContext('2d', { willReadFrequently: true });
    ctx.drawImage(bitmap, 0, 0, width, height);
    setImage(ctx.getImageData(0, 0, width, height), file.name);
    temporary.width = temporary.height = 1;
  } catch (error) {
    if (generation === loadGeneration) showError(error instanceof Error && error.message.startsWith('圖片尺寸') ? error.message : '無法載入這張照片，請改用 PNG、JPEG 或 WebP 格式。');
  } finally {
    bitmap?.close();
    image.src = '';
    if (url) URL.revokeObjectURL(url);
    if (generation === loadGeneration) { loading = false; scheduleDraw(); updateControls(); }
  }
});

$('download').addEventListener('click', async () => {
  if (loading) return;
  clearError();
  finishStroke();
  comparison = false;
  flushDraw();
  const filename = imageName.replace(/\.[^.]+$/, '').replace(/[\\/:*?"<>|]/g, '_') + '-液化.png';
  try {
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
    if (!blob) throw new Error('PNG 編碼失敗');
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement('a');
    anchor.href = url; anchor.download = filename;
    document.body.append(anchor); anchor.click(); anchor.remove();
    // 下載啟動後釋放暫存 URL，不保留整張照片的第二份副本。
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch { showError('下載失敗，請稍後再試。'); }
});

testImage();
