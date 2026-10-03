package photos

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkDirectoryScan(b *testing.B) {
	for _, count := range []int{0, 1, 256, 4096} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			folder := b.TempDir()
			for i := 0; i < count; i++ {
				name := fmt.Sprintf("相簿%d-é_%d.JPG", i%13, (i*7919)%count)
				if err := os.WriteFile(filepath.Join(folder, name), []byte{1}, 0600); err != nil {
					b.Fatal(err)
				}
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				d, err := Scan(context.Background(), folder)
				if err != nil || len(d.Entries) != count {
					b.Fatal(len(d.Entries), err)
				}
			}
		})
	}
}
