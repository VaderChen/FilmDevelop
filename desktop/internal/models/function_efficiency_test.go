package models

import (
	"fmt"
	"testing"
)

func BenchmarkPaired(b *testing.B) {
	for _, count := range []int{4, 32, 128} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			candidates := make([]string, count)
			for i := range candidates {
				candidates[i] = fmt.Sprintf("mmproj-VisionModel-%03d-Q8_0.gguf", i)
			}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				got, err := Paired("VisionModel-001-Q4_K_M.gguf", candidates)
				if err != nil || got != candidates[1] {
					b.Fatal(got, err)
				}
			}
		})
	}
}
