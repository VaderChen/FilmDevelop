package application

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/photos"
)

// 以相同底片目錄及影像資料量測宿主成本，不啟動原生引擎或讀取使用者資料。
func efficiencyApp(b *testing.B) *App {
	b.Helper()
	b.Setenv("FILMDEVELOP_DATA_DIR", b.TempDir())
	a, err := New("unused-engine")
	if err != nil {
		b.Fatal(err)
	}
	a.ctx = context.Background()
	if err = a.loadCatalog(); err != nil {
		b.Fatal(err)
	}
	if err = a.loadUserLibrary(); err != nil {
		b.Fatal(err)
	}
	if err = a.loadOrganization(); err != nil {
		b.Fatal(err)
	}
	a.emit = func(_ string, payload any) {
		if _, err := json.Marshal(payload); err != nil {
			b.Fatal(err)
		}
	}
	return a
}

func BenchmarkStatePublication(b *testing.B) {
	for _, full := range []bool{false, true} {
		name := "影像未變更"
		if full {
			name = "完整影像"
		}
		b.Run(name, func(b *testing.B) {
			a := efficiencyApp(b)
			a.sourcePreview = "data:image/jpeg;base64," + strings.Repeat("A", 1<<20)
			a.cropPreview = "data:image/jpeg;base64," + strings.Repeat("B", 1<<20)
			a.outputPreview = "data:image/jpeg;base64," + strings.Repeat("C", 1<<20)
			for i := 0; i < 48; i++ {
				id := strings.Repeat("x", i+1)
				a.directory.Entries = append(a.directory.Entries, photos.Entry{ID: id, Name: id + ".jpg"})
				a.thumbnails[id] = "data:image/jpeg;base64," + strings.Repeat("T", 4096)
			}
			a.sendState(true)
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				a.sendState(full)
			}
		})
	}
}

func BenchmarkRepairRevision(b *testing.B) {
	a := efficiencyApp(b)
	r := a.recipes[a.selected]
	r.RepairPatches = json.RawMessage(`[{"id":"修復甲","imageData":"` + strings.Repeat("A", 1<<20) + `","maskData":"` + strings.Repeat("B", 1<<20) + `"}]`)
	a.recipes[a.selected] = r
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if a.repairRevision() != "修復甲" {
			b.Fatal("修復版本不符")
		}
	}
}
