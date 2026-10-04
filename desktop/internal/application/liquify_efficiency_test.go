package application

import (
	"bytes"
	"encoding/json"
	"math/rand/v2"
	"reflect"
	"slices"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func TestLiquifyHistoryTrimMatchesPreviousOrder(t *testing.T) {
	random := rand.New(rand.NewPCG(21, 49))
	backing := make([]byte, 8<<20)
	raws := make([]*json.RawMessage, 80)
	for i := range raws {
		raw := json.RawMessage(backing[:(1+random.IntN(8))<<20])
		raws[i] = &raw
	}
	for scenario := 0; scenario < 40; scenario++ {
		a := &App{}
		for _, history := range []*[]editSnapshot{&a.undo, &a.redo} {
			for i := 0; i < random.IntN(70); i++ {
				values := map[string]contract.Recipe{}
				for _, id := range []string{"original", "styleA", "styleB"} {
					values[id] = contract.Recipe{Liquify: raws[random.IntN(len(raws))]}
				}
				*history = append(*history, editSnapshot{Selected: "original", Recipes: values})
			}
		}
		wantUndo, wantRedo := slices.Clone(a.undo), slices.Clone(a.redo)
		for liquifyHistorySize(wantUndo, wantRedo) > liquifyHistoryBytes {
			if len(wantUndo) > 0 {
				wantUndo = slices.Delete(wantUndo, 0, 1)
			} else {
				wantRedo = slices.Delete(wantRedo, 0, 1)
			}
		}
		a.trimLiquifyHistory()
		if !reflect.DeepEqual(a.undo, wantUndo) || !reflect.DeepEqual(a.redo, wantRedo) {
			t.Fatal("裁剪後保留順序與原演算法不同", scenario)
		}
	}
}

func TestLiquifyRevisionSwitchUndoAndClear(t *testing.T) {
	first, second := liquifyTestMesh(), liquifyTestMesh()
	other := bytes.Replace(*second, []byte("-0.05"), []byte("-0.04"), 1)
	*second = other
	a := &App{selected: "original", recipes: map[string]contract.Recipe{}}
	for _, raw := range []*json.RawMessage{first, first, second, first, nil, second, nil} {
		a.recipes["original"] = contract.Recipe{Liquify: raw}
		if got, want := a.liquifyRevision(), liquifyDigest(raw); got != want {
			t.Fatal("切換／復原／清除後修訂鍵錯誤")
		}
	}
	if a.liquifyRevisionMesh != nil {
		t.Fatal("清除仍保留先前大型網格")
	}
}

func TestLiquifySharedMeshContentAndInputIsolation(t *testing.T) {
	a, b := liquifyTestMesh(), liquifyTestMesh()
	other := bytes.Replace(*b, []byte("-0.05"), []byte("-0.04"), 1)
	*b = other
	acopy, bcopy := json.RawMessage(bytes.Clone(*a)), json.RawMessage(bytes.Clone(*b))
	values := map[string]contract.Recipe{"a": {Liquify: a}, "aa": {Liquify: a}, "aaa": {Liquify: &acopy}, "b": {Liquify: b}, "bb": {Liquify: &bcopy}, "none": {}}
	before := map[string]string{}
	for id, r := range values {
		before[id] = liquifyDigest(r.Liquify)
	}
	shareLiquifyMeshes(values)
	for id, r := range values {
		if liquifyDigest(r.Liquify) != before[id] {
			t.Fatal("共用化改變資料內容")
		}
	}
	if values["a"].Liquify != values["aaa"].Liquify || values["b"].Liquify != values["bb"].Liquify || values["a"].Liquify == values["b"].Liquify {
		t.Fatal("共用化未保持相等與不同網格")
	}
	if !bytes.Equal(*a, acopy) || !bytes.Equal(*b, bcopy) {
		t.Fatal("共用化改寫原始JSON")
	}
}
