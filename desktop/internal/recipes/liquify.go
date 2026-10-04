package recipes

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
)

const MaxLiquifyBytes = 8 * 1024 * 1024

// LiquifyMesh 保存參考預覽的反向位移；座標與位移以各軸長度減一正規化。
// 原生引擎在每個輸出尺寸重新取樣原圖，不能把預覽點陣圖當成全尺寸成品。
type LiquifyMesh struct {
	Version         int       `json:"version"`
	ReferenceWidth  int       `json:"referenceWidth"`
	ReferenceHeight int       `json:"referenceHeight"`
	Spacing         int       `json:"spacing"`
	Columns         int       `json:"columns"`
	Rows            int       `json:"rows"`
	DX              []float64 `json:"dx"`
	DY              []float64 `json:"dy"`
}

// NormalizeLiquify 驗證整份網格並把空網格化為 identity；有效資料保持不可變。
func NormalizeLiquify(raw *json.RawMessage) (*json.RawMessage, error) {
	if raw == nil {
		return nil, nil
	}
	if len(*raw) > MaxLiquifyBytes {
		return nil, errors.New("液化網格超過大小限制")
	}
	if bytes.Equal(bytes.TrimSpace(*raw), []byte("null")) {
		return nil, nil
	}
	var mesh LiquifyMesh
	// 合法格式只有數值陣列；逗號數估計容量可避免兩個大陣列反覆擴張。
	// 非法文字亦受最大節點數限制，最後仍使用相同嚴格 decoder 與完整驗證。
	capacity := min((bytes.Count(*raw, []byte{','})+1)/2, 513*513)
	mesh.DX, mesh.DY = make([]float64, 0, capacity), make([]float64, 0, capacity)
	decoder := json.NewDecoder(bytes.NewReader(*raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&mesh); err != nil {
		return nil, errors.New("液化網格資料格式不符")
	}
	if decoder.Decode(new(any)) != io.EOF || mesh.Version != 1 || mesh.ReferenceWidth < 2 || mesh.ReferenceWidth > 1024 || mesh.ReferenceHeight < 2 || mesh.ReferenceHeight > 1024 || mesh.Spacing < 2 || mesh.Spacing > 16 {
		return nil, errors.New("液化網格版本或參考尺寸不符")
	}
	w, h, spacing := mesh.ReferenceWidth-1, mesh.ReferenceHeight-1, mesh.Spacing
	if mesh.Columns != (w+spacing-1)/spacing+1 || mesh.Rows != (h+spacing-1)/spacing+1 || len(mesh.DX) != mesh.Columns*mesh.Rows || len(mesh.DY) != len(mesh.DX) {
		return nil, errors.New("液化網格節點數量不符")
	}
	changed := false
	for row := 0; row < mesh.Rows; row++ {
		for column := 0; column < mesh.Columns; column++ {
			i := row*mesh.Columns + column
			dx, dy := mesh.DX[i], mesh.DY[i]
			x, y := float64(min(column*spacing, w))/float64(w), float64(min(row*spacing, h))/float64(h)
			if math.IsNaN(dx) || math.IsInf(dx, 0) || math.IsNaN(dy) || math.IsInf(dy, 0) || x+dx < -1e-6 || x+dx > 1+1e-6 || y+dy < -1e-6 || y+dy > 1+1e-6 {
				return nil, errors.New("液化網格取樣座標超出影像")
			}
			if (column == 0 || row == 0 || column == mesh.Columns-1 || row == mesh.Rows-1) && (math.Abs(dx) > 1e-6 || math.Abs(dy) > 1e-6) {
				return nil, errors.New("液化網格邊界必須固定")
			}
			changed = changed || dx != 0 || dy != 0
			// 驗證暫存轉為像素座標，供相鄰四個 cell 重用，不更動輸入 JSON。
			mesh.DX[i] = float64(min(column*spacing, w)) + dx*float64(w)
			mesh.DY[i] = float64(min(row*spacing, h)) + dy*float64(h)
		}
	}
	if !changed {
		return nil, nil
	}
	point := func(column, row int) (float64, float64) {
		i := row*mesh.Columns + column
		return mesh.DX[i], mesh.DY[i]
	}
	for row := 0; row < mesh.Rows-1; row++ {
		for column := 0; column < mesh.Columns-1; column++ {
			ax, ay := point(column, row)
			bx, by := point(column+1, row)
			cx, cy := point(column, row+1)
			dx, dy := point(column+1, row+1)
			hx := min((column+1)*spacing, w) - column*spacing
			hy := min((row+1)*spacing, h) - row*spacing
			// Float32 網格跨 JSON 正規化的捨入誤差不得造成合法筆畫被拒絕。
			threshold := 0.049 * float64(hx*hy)
			if (bx-ax)*(cy-ay)-(by-ay)*(cx-ax) < threshold || (bx-ax)*(dy-by)-(by-ay)*(dx-bx) < threshold || (dx-cx)*(cy-ay)-(dy-cy)*(cx-ax) < threshold || (dx-cx)*(dy-by)-(dy-cy)*(dx-bx) < threshold {
				return nil, errors.New("液化網格會造成影像翻折")
			}
		}
	}
	return raw, nil
}

// Library 的呼叫者可以持有並修改 RawMessage，故快取以內容比較而非指標判斷。
// 僅保留最後一份通過驗證的私有副本與需要時才建立的標準 JSON；
// 每份至多 MaxLiquifyBytes，內容相同時共用儲存，不快取失敗。
func (l *Library) matchesLiquify(raw []byte) bool {
	return l.liquifyValidated != nil && (bytes.Equal(raw, l.liquifyValidated) || l.liquifyCanonical != nil && bytes.Equal(raw, l.liquifyCanonical))
}

func (l *Library) normalizeLiquify(raw *json.RawMessage) (*json.RawMessage, error) {
	if raw == nil {
		return nil, nil
	}
	l.liquifyMu.Lock()
	if l.matchesLiquify(*raw) {
		identity := l.liquifyIdentity
		l.liquifyMu.Unlock()
		if identity {
			return nil, nil
		}
		return raw, nil
	}
	l.liquifyMu.Unlock()
	result, err := NormalizeLiquify(raw)
	if err != nil {
		return nil, err
	}
	l.liquifyMu.Lock()
	l.liquifyValidated, l.liquifyIdentity = bytes.Clone(*raw), result == nil
	l.liquifyCanonical = nil
	l.liquifyMu.Unlock()
	return result, nil
}
