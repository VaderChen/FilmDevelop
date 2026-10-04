package recipes

import (
	"encoding/json"
	"github.com/VaderChen/FilmDevelop/internal/contract"
	"math"
	"testing"
)

func liquifyBenchMesh() *json.RawMessage {
	const width, height, spacing = 1024, 768, 4
	columns, rows := (width-2+spacing)/spacing+1, (height-2+spacing)/spacing+1
	mesh := LiquifyMesh{Version: 1, ReferenceWidth: width, ReferenceHeight: height, Spacing: spacing, Columns: columns, Rows: rows, DX: make([]float64, columns*rows), DY: make([]float64, columns*rows)}
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

func BenchmarkLiquifyRecipe(b *testing.B) {
	raw := liquifyBenchMesh()
	lib, err := New()
	if err != nil {
		b.Fatal(err)
	}
	r, _ := lib.Default("original")
	r.Liquify = raw
	for _, name := range []string{"ValidateCold", "NormalizeWarm", "EditWarm", "Project38"} {
		b.Run(name, func(b *testing.B) {
			values := map[string]contract.Recipe{}
			for i := range lib.styles {
				value, _ := lib.Default(i)
				value.Liquify = raw
				values[i] = value
				if len(values) == 38 {
					break
				}
			}
			if _, err := lib.Normalize(r); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				var err error
				switch name {
				case "ValidateCold":
					_, err = NormalizeLiquify(raw)
				case "NormalizeWarm":
					_, err = lib.Normalize(r)
				case "EditWarm":
					_, err = lib.Edit(contract.EditorRequest{Recipe: r, Changes: json.RawMessage(`[{"key":"exposure","value":12}]`)})
				case "Project38":
					_, err = lib.ProjectMany(values)
				}
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
