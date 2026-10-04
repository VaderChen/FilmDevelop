package application

import (
	"bytes"
	"encoding/json"
	"fmt"
	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/recipes"
	"math"
	"testing"
)

func liquifyBenchMesh() *json.RawMessage {
	const width, height, spacing = 1024, 768, 4
	columns, rows := (width-2+spacing)/spacing+1, (height-2+spacing)/spacing+1
	mesh := recipes.LiquifyMesh{Version: 1, ReferenceWidth: width, ReferenceHeight: height, Spacing: spacing, Columns: columns, Rows: rows, DX: make([]float64, columns*rows), DY: make([]float64, columns*rows)}
	for y := 1; y < rows-1; y++ {
		for x := 1; x < columns-1; x++ {
			v := math.Sin(math.Pi*float64(x*spacing)/float64(width-1)) * math.Sin(math.Pi*float64(y*spacing)/float64(height-1))
			mesh.DX[y*columns+x] = .012 * v
			mesh.DY[y*columns+x] = -.008 * v
		}
	}
	data, _ := json.Marshal(mesh)
	raw := json.RawMessage(data)
	return &raw
}

// 場景包含大網格、38款底片共用及100筆歷史超過32MiB預算。
func BenchmarkLiquifyHost(b *testing.B) {
	raw := liquifyBenchMesh()
	b.Run("RevisionLarge", func(b *testing.B) {
		a := &App{selected: "original", recipes: map[string]contract.Recipe{"original": {Liquify: raw}}}
		b.ReportAllocs()
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			if a.liquifyRevision() == "" {
				b.Fatal("修訂鍵遺失")
			}
		}
	})
	for _, same := range []bool{true, false} {
		name := "Share38Copies"
		if same {
			name = "Share38Aliases"
		}
		b.Run(name, func(b *testing.B) {
			values := map[string]contract.Recipe{}
			for i := 0; i < 38; i++ {
				r := raw
				if !same {
					copy := json.RawMessage(bytes.Clone(*raw))
					r = &copy
				}
				values[fmt.Sprint(i)] = contract.Recipe{Liquify: r}
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				copy := copyRecipes(values)
				shareLiquifyMeshes(copy)
			}
		})
	}
	b.Run("TrimHistory100x38", func(b *testing.B) {
		history := make([]editSnapshot, 100)
		for i := range history {
			data := json.RawMessage(make([]byte, 1<<20))
			values := map[string]contract.Recipe{}
			for j := 0; j < 38; j++ {
				values[fmt.Sprint(j)] = contract.Recipe{Liquify: &data}
			}
			history[i] = editSnapshot{Recipes: values}
		}
		b.ReportAllocs()
		b.ResetTimer()
		for i := 0; i < b.N; i++ {
			a := &App{undo: append([]editSnapshot(nil), history...)}
			a.trimLiquifyHistory()
			if len(a.undo) != 32 {
				b.Fatal("歷史裁剪不同")
			}
		}
	})
}
