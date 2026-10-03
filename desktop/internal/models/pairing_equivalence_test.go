package models

import (
	"errors"
	"fmt"
	"math/rand"
	"reflect"
	"sort"
	"testing"
)

// 固定保留 8bdd679 的排序決策，驗證單次掃描的最高分及同分拒絕規則。
func originalPaired(model string, candidates []string) (string, error) {
	if len(candidates) == 1 {
		return candidates[0], nil
	}
	sorted := append([]string{}, candidates...)
	sort.Slice(sorted, func(i, j int) bool {
		a, b := PairingScore(model, sorted[i]), PairingScore(model, sorted[j])
		if a != b {
			return a > b
		}
		return sorted[i] < sorted[j]
	})
	if len(sorted) == 0 {
		return "", errors.New("缺少對應的 mmproj 視覺編碼器")
	}
	if PairingScore(model, sorted[0]) == 0 || len(sorted) > 1 && PairingScore(model, sorted[0]) == PairingScore(model, sorted[1]) {
		return "", errors.New("同資料夾有多個 mmproj，無法確定配對")
	}
	return sorted[0], nil
}

func TestPairingMatchesOriginalAcrossCandidateOrders(t *testing.T) {
	pool := []string{"", "mmproj-F16.gguf", "mmproj-Q8_0.gguf", "mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf", "Qwen3VL-2B-Instruct.mmproj-F16.gguf", "mmproj-SmolVLM-500M-Instruct-Q8_0.gguf", "mmproj-Qwen3VL-2B.gguf", "mmproj-SmolVLM-256M-Instruct.gguf", "mmproj-Qwen3VL-4B-Instruct.gguf"}
	random := rand.New(rand.NewSource(73))
	for _, model := range []string{"Qwen3VL-2B-Instruct-Q4_K_M.gguf", "SmolVLM-500M-Instruct-Q8_0.gguf", "unknown.gguf", ""} {
		for count := 0; count <= 12; count++ {
			for trial := 0; trial < 20; trial++ {
				candidates := make([]string, count)
				for i := range candidates {
					candidates[i] = pool[random.Intn(len(pool))]
				}
				before := append([]string{}, candidates...)
				want, wantErr := originalPaired(model, candidates)
				got, err := Paired(model, candidates)
				if got != want || fmt.Sprint(err) != fmt.Sprint(wantErr) || !reflect.DeepEqual(candidates, before) {
					t.Fatalf("%q / %v：%q %v，預期 %q %v", model, candidates, got, err, want, wantErr)
				}
			}
		}
	}
}
