package recipes

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestRecipeCopyMatchesJSONRoundTrip(t *testing.T) {
	values := []json.RawMessage{nil, {}, json.RawMessage(`null`), json.RawMessage(` { "x": "<&>\u2028", "a": [1, null, true] } `), json.RawMessage(`"` + string([]byte{0xff, 0xfe}) + `"`), json.RawMessage(`[{"imageData":"` + strings.Repeat("A", 2<<20) + `"}]`), json.RawMessage(`{`)}
	for _, adjustment := range values {
		for _, patches := range values {
			for _, style := range []string{"filmPortra400", "<&>\u2028", string([]byte{0xff, 0xfe})} {
				input := contract.Recipe{Version: 1, Style: style, Adjustment: adjustment, RepairPatches: patches, DetectSubject: true}
				want, got := clone(input), cloneRecipe(input)
				if !reflect.DeepEqual(got, want) {
					t.Fatal("配方複製與原 JSON 往返語意不符")
				}
				if len(got.Adjustment) > 0 {
					before := bytes.Clone(input.Adjustment)
					got.Adjustment[0] ^= 1
					if !bytes.Equal(input.Adjustment, before) {
						t.Fatal("調整參數共用可變記憶體")
					}
				}
				if len(got.RepairPatches) > 0 {
					before := bytes.Clone(input.RepairPatches)
					got.RepairPatches[0] ^= 1
					if !bytes.Equal(input.RepairPatches, before) {
						t.Fatal("修復貼片共用可變記憶體")
					}
				}
			}
		}
	}
}
