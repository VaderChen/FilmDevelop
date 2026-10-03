package storage

import (
	"encoding/binary"
	"fmt"
	"math"
	"testing"
)

func maskFixture(side int) []byte {
	data := make([]byte, 16+side*side*16)
	copy(data, "FYPMASK1")
	binary.LittleEndian.PutUint32(data[8:12], uint32(side))
	binary.LittleEndian.PutUint32(data[12:16], uint32(side))
	for i := 16; i < len(data); i += 4 {
		binary.LittleEndian.PutUint32(data[i:i+4], math.Float32bits(float32(i%2047)/1024-0.5))
	}
	return data
}

func BenchmarkMaskFunctions(b *testing.B) {
	for _, side := range []int{1, 256, 1024} {
		b.Run(fmt.Sprint(side), func(b *testing.B) {
			b.Setenv("FILMDEVELOP_DATA_DIR", b.TempDir())
			s, err := New()
			if err != nil {
				b.Fatal(err)
			}
			data := maskFixture(side)
			mask, err := s.ImportMask(data, "照片", "修復")
			if err != nil {
				b.Fatal(err)
			}
			for _, name := range []string{"ValidateMask", "ValidateMaskAsset", "ImportExistingMask"} {
				b.Run(name, func(b *testing.B) {
					b.SetBytes(int64(len(data)))
					b.ReportAllocs()
					b.ResetTimer()
					for i := 0; i < b.N; i++ {
						var err error
						switch name {
						case "ValidateMask":
							_, _, err = ValidateMask(data)
						case "ValidateMaskAsset":
							err = s.ValidateMaskAsset(mask)
						case "ImportExistingMask":
							_, err = s.ImportMask(data, "照片", "修復")
						}
						if err != nil {
							b.Fatal(err)
						}
					}
				})
			}
		})
	}
}
