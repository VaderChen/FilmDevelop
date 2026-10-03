package recipes

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// 每項基準只計目標函式；目錄載入與固定輸入在計時前完成。
func BenchmarkRecipeFunctions(b *testing.B) {
	l, err := New()
	if err != nil {
		b.Fatal(err)
	}
	r, err := l.Default("filmPortra400")
	if err != nil {
		b.Fatal(err)
	}
	for _, name := range []string{"Validate", "Project", "Edit", "Normalize", "EditWithRepair"} {
		b.Run(name, func(b *testing.B) {
			input := r
			if name == "EditWithRepair" {
				input.RepairPatches = json.RawMessage(`[{"id":"修復","imageData":"` + strings.Repeat("A", 1<<20) + `","maskData":"` + strings.Repeat("B", 1<<20) + `"}]`)
			}
			request := contract.EditorRequest{Recipe: input, Changes: json.RawMessage(`[{"key":"contrast","value":12}]`)}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				var err error
				switch name {
				case "Validate":
					err = l.Validate(input)
				case "Project":
					_, err = l.Project(input)
				case "Edit", "EditWithRepair":
					_, err = l.Edit(request)
				case "Normalize":
					_, err = l.Normalize(input)
				}
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
