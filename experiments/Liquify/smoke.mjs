import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { LiquifyMesh, renderWarp } from './liquify.mjs';

// 獨立原型的功能 Smoke；不載入正式 App，也不改寫使用者照片。
const WIDTH = 128;
const HEIGHT = 96;
const SPACING = 4;
const HISTORY_BYTES = 256 * 1024;
const results = [];

function mesh(width = WIDTH, height = HEIGHT, historyBytes = HISTORY_BYTES) {
  return new LiquifyMesh(width, height, { spacing: SPACING, historyBytes });
}

function stroke(target, points, options = {}) {
  assert.ok(points.length >= 2);
  target.beginStroke(points[0], { radius: 28, strength: 0.8, mode: 'push', ...options });
  for (const point of points.slice(1)) target.moveStroke(point);
  target.endStroke();
}

function field(target, width = WIDTH, height = HEIGHT) {
  const values = [];
  for (let y = 0; y < height; y += 2) {
    for (let x = 0; x < width; x += 2) values.push(...target.sample(x, y));
  }
  return values;
}

function close(actual, expected, tolerance = 1e-6) {
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < actual.length; index++) {
    assert.ok(Number.isFinite(actual[index]), `第 ${index} 項必須為有限數值`);
    assert.ok(Math.abs(actual[index] - expected[index]) <= tolerance,
      `第 ${index} 項差異 ${actual[index] - expected[index]} 超過 ${tolerance}`);
  }
}

function fixture(width = WIDTH, height = HEIGHT) {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const index = (y * width + x) * 4;
      data[index] = (x * 29 + y * 3) & 255;
      data[index + 1] = (x * 5 + y * 31) & 255;
      data[index + 2] = (x * 7 + y * 11) & 255;
      data[index + 3] = (x * 13 + y * 17) & 255;
    }
  }
  return data;
}

function energy(target) {
  let sum = 0;
  for (let y = 0; y < HEIGHT; y += 2) {
    for (let x = 0; x < WIDTH; x += 2) {
      const [sx, sy] = target.sample(x, y);
      sum += (sx - x) ** 2 + (sy - y) ** 2;
    }
  }
  return sum;
}

function test(name, operation) {
  const start = performance.now();
  try {
    const evidence = operation();
    results.push({ name, status: 'passed', durationMs: +(performance.now() - start).toFixed(2), ...evidence });
  } catch (error) {
    results.push({ name, status: 'failed', durationMs: +(performance.now() - start).toFixed(2), error: error.stack });
  }
}

test('初始映射逐位元組保留原圖，包括透明像素的 RGB', () => {
  const target = mesh();
  const source = fixture();
  const original = source.slice();
  const output = renderWarp(source, WIDTH, HEIGHT, target);
  assert.deepEqual(output, source);
  assert.deepEqual(source, original);
  const reusable = new Uint8ClampedArray(source.length);
  assert.equal(renderWarp(source, WIDTH, HEIGHT, target, reusable), reusable);
  assert.deepEqual(reusable, source);
  assert.equal(target.canUndo, false);
  assert.equal(target.canRedo, false);
});

test('局部向右推移，筆刷支援範圍以外保持原樣', () => {
  const target = mesh();
  stroke(target, [{ x: 48, y: 48 }, { x: 74, y: 48 }]);
  const centre = target.sample(62, 48);
  assert.ok(centre[0] < 61.9, `反向映射應往左取樣，實際為 ${centre[0]}`);
  for (const [x, y] of [[4, 4], [120, 4], [4, 88], [120, 88], [8, 48], [118, 48]]) {
    close(target.sample(x, y), [x, y]);
  }
  assert.ok(target.canUndo);
  assert.ok(Number.isFinite(target.renderRevision));
  return { centreSource: centre };
});

test('同一直線的密集與稀疏指標事件產生相同結果', () => {
  const sparse = mesh();
  const dense = mesh();
  const start = { x: 30, y: 35 };
  const end = { x: 98, y: 61 };
  stroke(sparse, [start, end]);
  stroke(dense, Array.from({ length: 81 }, (_, index) => ({
    x: start.x + (end.x - start.x) * index / 80,
    y: start.y + (end.y - start.y) * index / 80,
  })));
  close(field(dense), field(sparse), 2e-5);
});

test('復原、重做、取消與重設都能完整還原映射', () => {
  const target = mesh();
  const initial = field(target);
  stroke(target, [{ x: 44, y: 46 }, { x: 75, y: 52 }]);
  const edited = field(target);
  target.undo();
  close(field(target), initial, 0);
  assert.equal(target.canUndo, false);
  assert.equal(target.canRedo, true);
  target.redo();
  close(field(target), edited, 0);
  target.beginStroke({ x: 52, y: 50 }, { radius: 24, strength: 1, mode: 'push' });
  target.moveStroke({ x: 66, y: 30 });
  target.cancelStroke();
  close(field(target), edited, 0);
  target.undo();
  close(field(target), initial, 0);
  target.redo();
  target.reset();
  close(field(target), initial, 0);
  assert.deepEqual(renderWarp(fixture(), WIDTH, HEIGHT, target), fixture());
});

test('復原後的新筆畫會清除舊的重做分支', () => {
  const target = mesh();
  stroke(target, [{ x: 48, y: 48 }, { x: 68, y: 48 }]);
  target.undo();
  assert.ok(target.canRedo);
  stroke(target, [{ x: 48, y: 48 }, { x: 48, y: 68 }]);
  assert.equal(target.canRedo, false);
});

test('局部恢復筆刷降低既有扭曲', () => {
  const target = mesh();
  stroke(target, [{ x: 48, y: 48 }, { x: 74, y: 48 }]);
  const before = energy(target);
  stroke(target, [{ x: 44, y: 48 }, { x: 82, y: 48 }], { radius: 36, strength: 1, mode: 'restore' });
  const after = energy(target);
  assert.ok(before > 1);
  assert.ok(after < before, `恢復前 ${before}，恢復後 ${after}`);
  return { beforeEnergy: before, afterEnergy: after };
});

test('透明像素的隱藏 RGB 不滲入可見顏色，插值保留 Alpha', () => {
  const source = new Uint8ClampedArray(WIDTH * HEIGHT * 4);
  for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
      const index = (y * WIDTH + x) * 4;
      source.set(x < WIDTH / 2 ? [255, 0, 0, 255] : [0, 0, 255, 0], index);
    }
  }
  const original = source.slice();
  const target = mesh();
  stroke(target, [{ x: 58, y: 48 }, { x: 76, y: 48 }]);
  const output = renderWarp(source, WIDTH, HEIGHT, target);
  let partialPixels = 0;
  for (let y = 1; y < HEIGHT - 1; y++) {
    for (let x = 1; x < WIDTH - 1; x++) {
      const [sx] = target.sample(x, y);
      if (sx <= WIDTH / 2 - 1 || sx >= WIDTH / 2) continue;
      const index = (y * WIDTH + x) * 4;
      const alpha = Math.round((WIDTH / 2 - sx) * 255);
      assert.ok(Math.abs(output[index + 3] - alpha) <= 1);
      if (output[index + 3] > 0 && output[index + 3] < 255) {
        assert.ok(output[index] >= 254);
        assert.equal(output[index + 1], 0);
        assert.equal(output[index + 2], 0);
        partialPixels++;
      }
    }
  }
  assert.ok(partialPixels > 0, '必須實際覆蓋透明邊界的次像素插值');
  assert.deepEqual(source, original);
  return { partialPixels };
});

test('不透明黑白邊界使用線性光插值', () => {
  const source = new Uint8ClampedArray(WIDTH * HEIGHT * 4);
  for (let y = 0; y < HEIGHT; y++) {
    for (let x = 0; x < WIDTH; x++) {
      const value = x < WIDTH / 2 ? 0 : 255;
      source.set([value, value, value, 255], (y * WIDTH + x) * 4);
    }
  }
  const target = mesh();
  stroke(target, [{ x: 58, y: 48 }, { x: 76, y: 48 }]);
  const output = renderWarp(source, WIDTH, HEIGHT, target);
  let checked = 0;
  for (let y = 1; y < HEIGHT - 1; y++) {
    for (let x = 1; x < WIDTH - 1; x++) {
      const [sx] = target.sample(x, y);
      const linear = sx - (WIDTH / 2 - 1);
      if (linear <= 0.05 || linear >= 0.95) continue;
      const encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * linear ** (1 / 2.4) - 0.055;
      const expected = Math.round(encoded * 255);
      const index = (y * WIDTH + x) * 4;
      close([...output.subarray(index, index + 3)], [expected, expected, expected], 1);
      assert.equal(output[index + 3], 255);
      checked++;
    }
  }
  assert.ok(checked > 0);
  return { checkedPixels: checked };
});

test('強烈重複筆畫保持座標有效且不造成網格翻折', () => {
  const target = mesh();
  for (let index = 0; index < 12; index++) {
    const direction = index % 2 ? -1 : 1;
    stroke(target, [{ x: 64 - 42 * direction, y: 20 + index * 5 },
      { x: 64 + 42 * direction, y: 72 - index * 4 }], { radius: 18, strength: 1 });
  }
  // 額外覆蓋畫布邊缘；只檢查公開反向映射，不依賴內部網格儲存方式。
  stroke(target, [{ x: 2, y: 2 }, { x: 124, y: 92 }], { radius: 32, strength: 1 });
  let minimumJacobian = Infinity;
  const h = 0.01;
  for (let y = 0; y < HEIGHT; y += 2) {
    for (let x = 0; x < WIDTH; x += 2) {
      const point = target.sample(x, y);
      assert.ok(point[0] >= -1e-6 && point[0] <= WIDTH - 1 + 1e-6);
      assert.ok(point[1] >= -1e-6 && point[1] <= HEIGHT - 1 + 1e-6);
      const px = target.sample(x + h, y);
      const py = target.sample(x, y + h);
      const determinant = ((px[0] - point[0]) * (py[1] - point[1])
        - (px[1] - point[1]) * (py[0] - point[0])) / (h * h);
      minimumJacobian = Math.min(minimumJacobian, determinant);
      assert.ok(determinant >= 0.049, `(${x}, ${y}) Jacobian ${determinant} 低於保護下限`);
    }
  }
  for (const point of [[0, 0], [WIDTH - 1, 0], [0, HEIGHT - 1], [WIDTH - 1, HEIGHT - 1]]) {
    close(target.sample(...point), point);
  }
  return { minimumJacobian };
});

test('長筆畫與多筆歷史的記憶體使用維持上限', () => {
  const target = mesh();
  const baseline = target.memoryBytes;
  assert.ok(Number.isFinite(baseline) && baseline > 0);
  let maximum = baseline;
  target.beginStroke({ x: 36, y: 48 }, { radius: 16, strength: 0.4, mode: 'push' });
  for (let index = 1; index <= 400; index++) {
    target.moveStroke({ x: 64 + Math.cos(index * 0.13) * 28, y: 48 + Math.sin(index * 0.13) * 20 });
    maximum = Math.max(maximum, target.memoryBytes);
  }
  target.endStroke();
  for (let index = 0; index < 80; index++) {
    const x = 40 + index % 40;
    target.beginStroke({ x, y: 42 }, { radius: 16, strength: 0.2, mode: 'push' });
    target.moveStroke({ x: x + 8, y: 50 });
    maximum = Math.max(maximum, target.memoryBytes);
    target.endStroke();
    maximum = Math.max(maximum, target.memoryBytes);
  }
  // 取消快照是獨立工作空間，避免開始新筆畫時破壞既有復原與重做歷史。
  const snapshotBytes = baseline / 2;
  const limit = baseline + Math.floor(HISTORY_BYTES / snapshotBytes) * snapshotBytes + snapshotBytes;
  assert.ok(maximum <= limit, `${maximum} 位元組超過 ${limit} 位元組`);
  return { baselineBytes: baseline, maximumBytes: maximum, historyBudgetBytes: HISTORY_BYTES, limitBytes: limit };
});

test('歷史預算滿額時取消新筆畫仍完整保留復原與重做', () => {
  const snapshotBytes = mesh().memoryBytes / 2;
  const target = mesh(WIDTH, HEIGHT, snapshotBytes);
  const baseline = target.memoryBytes;
  const initial = field(target);
  stroke(target, [{ x: 48, y: 48 }, { x: 74, y: 48 }]);
  const edited = field(target);
  assert.equal(target.canUndo, true);
  assert.equal(target.canRedo, false);
  target.beginStroke({ x: 58, y: 40 }, { radius: 24, strength: 0.7, mode: 'push' });
  target.moveStroke({ x: 58, y: 66 });
  assert.notDeepEqual(field(target), edited);
  assert.ok(target.memoryBytes <= baseline + snapshotBytes * 2);
  target.cancelStroke();
  close(field(target), edited, 0);
  assert.equal(target.canUndo, true, '取消不得丟失既有復原歷史');
  assert.equal(target.canRedo, false);
  target.undo();
  close(field(target), initial, 0);
  assert.equal(target.canRedo, true);
  target.beginStroke({ x: 58, y: 40 }, { radius: 24, strength: 0.7, mode: 'push' });
  target.moveStroke({ x: 58, y: 66 });
  assert.notDeepEqual(field(target), initial);
  assert.ok(target.memoryBytes <= baseline + snapshotBytes * 2);
  target.cancelStroke();
  close(field(target), initial, 0);
  assert.equal(target.canRedo, true, '取消不得丟失既有重做歷史');
  assert.equal(target.canUndo, false);
  target.redo();
  close(field(target), edited, 0);
  assert.equal(target.canUndo, true);
  assert.equal(target.canRedo, false);
});

test('歷史預算不足一份快照時仍能取消筆畫，提交後不超額保留歷史', () => {
  for (const budget of [0, 1, mesh().memoryBytes / 2 - 1]) {
    const target = mesh(WIDTH, HEIGHT, budget);
    const initial = field(target);
    const baseline = target.memoryBytes;
    target.beginStroke({ x: 48, y: 48 }, { radius: 28, strength: 0.8, mode: 'push' });
    target.moveStroke({ x: 74, y: 48 });
    assert.ok(energy(target) > 1);
    assert.ok(target.memoryBytes <= baseline * 1.5);
    target.cancelStroke();
    close(field(target), initial, 0);
    assert.equal(target.memoryBytes, baseline);
    stroke(target, [{ x: 48, y: 48 }, { x: 74, y: 48 }]);
    assert.equal(target.canUndo, false);
    assert.equal(target.memoryBytes, baseline);
  }
});

test('狹長、小尺寸及末端不足一格的影像仍有有效映射', () => {
  for (const [width, height] of [[2, 2], [2, 17], [17, 2], [5, 7], [31, 23], [130, 99]]) {
    const target = mesh(width, height);
    stroke(target, [{ x: 0, y: 0 }, { x: width - 1, y: height - 1 }], { radius: 16, strength: 1 });
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const [sx, sy] = target.sample(x, y);
        assert.ok(Number.isFinite(sx) && Number.isFinite(sy));
        assert.ok(sx >= -1e-6 && sx <= width - 1 + 1e-6);
        assert.ok(sy >= -1e-6 && sy <= height - 1 + 1e-6);
        if (x === 0 || x === width - 1 || y === 0 || y === height - 1) close([sx, sy], [x, y]);
      }
    }
    assert.equal(renderWarp(fixture(width, height), width, height, target).length, width * height * 4);
  }
});

test('零強度不改圖、不新增歷史', () => {
  const target = mesh();
  const initial = field(target);
  stroke(target, [{ x: 32, y: 48 }, { x: 96, y: 48 }], { strength: 0 });
  close(field(target), initial, 0);
  assert.equal(target.canUndo, false);
  assert.equal(target.canRedo, false);
});

test('拒絕非有限數值、無效尺寸與錯誤影像緩衝', () => {
  for (const dimensions of [[0, 96], [1, 96], [128, 1], [128, -1], [NaN, 96], [128, Infinity], [128.5, 96]]) {
    assert.throws(() => mesh(...dimensions), `尺寸 ${dimensions} 必須被拒絕`);
  }
  const target = mesh();
  for (const [point, options] of [
    [{ x: NaN, y: 48 }, { radius: 24, strength: 1, mode: 'push' }],
    [{ x: 48, y: Infinity }, { radius: 24, strength: 1, mode: 'push' }],
    [{ x: 48, y: 48 }, { radius: NaN, strength: 1, mode: 'push' }],
    [{ x: 48, y: 48 }, { radius: 24, strength: NaN, mode: 'push' }],
  ]) {
    assert.throws(() => target.beginStroke(point, options));
    target.cancelStroke();
  }
  assert.throws(() => target.sample(NaN, 0));
  assert.throws(() => renderWarp(new Uint8ClampedArray(4), WIDTH, HEIGHT, target));
  assert.throws(() => renderWarp(fixture(), WIDTH - 1, HEIGHT, target));
  assert.throws(() => renderWarp(fixture(), WIDTH, HEIGHT, target, new Uint8ClampedArray(4)));
  const aliased = fixture();
  assert.throws(() => renderWarp(aliased, WIDTH, HEIGHT, target, aliased));
  assert.throws(() => renderWarp(null, WIDTH, HEIGHT, target));
});

test('768×512 單次渲染診斷，不設硬體速度門檻', () => {
  const width = 768;
  const height = 512;
  const target = mesh(width, height, 32 * 1024 * 1024);
  stroke(target, [{ x: 310, y: 256 }, { x: 400, y: 280 }], { radius: 96, strength: 0.7 });
  const source = fixture(width, height);
  const output = new Uint8ClampedArray(source.length);
  const start = performance.now();
  renderWarp(source, width, height, target, output);
  const renderMs = performance.now() - start;
  assert.equal(output.length, source.length);
  assert.notDeepEqual(output, source);
  return { width, height, renderMs: +renderMs.toFixed(2), meshMemoryBytes: target.memoryBytes,
    inputAndOutputBytes: source.byteLength + output.byteLength };
});

const failed = results.filter(result => result.status === 'failed').length;
console.log(JSON.stringify({ suite: '獨立筆刷液化 Smoke', node: process.version,
  passed: results.length - failed, failed, results }, null, 2));
process.exitCode = failed ? 1 : 0;
