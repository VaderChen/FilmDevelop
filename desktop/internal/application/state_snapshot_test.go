package application

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/photos"
)

func TestStateSnapshotPreservesJSONAndIsolation(t *testing.T) {
	type settings struct {
		Name   string   `json:"name"`
		Tags   []string `json:"tags"`
		Hidden string   `json:"-"`
		Empty  string   `json:"empty,omitempty"`
	}
	values := object{"items": []any{object{"value": "原值"}, []string{"原分類"}}}
	groups := map[string]object{"film": {"exposure": float64(6)}}
	entries := []object{{"id": "照片", "tags": []string{"風景"}}}
	prompts := map[string]string{"traditionalChinese": "原提示詞"}
	preferences := &settings{Name: "設定", Tags: []string{"分類"}, Hidden: "不傳送"}
	raw := json.RawMessage(`{"image":"原影像","value":1}`)
	payload := object{
		"values": values, "groups": groups, "entries": entries, "prompts": prompts,
		"preferences": preferences, "raw": raw, "bytes": []byte{1, 2, 3},
		"nil": nil, "nilObject": object(nil), "nilGroups": map[string]object(nil),
		"nilPrompts": map[string]string(nil), "nilArray": []any(nil),
		"nilEntries": []object(nil), "nilStrings": []string(nil), "nilPointer": (*settings)(nil),
		"emptyObject": object{}, "emptyArray": []any{}, "emptyStrings": []string{},
		"true": true, "float": float64(1.25), "float32": float32(1.23),
		"integer": 27, "largeInteger": int64(9007199254740993),
		"number": json.Number("2.5"), "text": "繁體中文 <>&\n\"\\",
		"image": "data:image/jpeg;base64," + strings.Repeat("A", 1<<20),
	}
	want := clone(payload)
	got := snapshotJSON(payload).(object)
	if !reflect.DeepEqual(got, want) {
		t.Fatal("狀態快照與既有 JSON 轉換結果不同")
	}
	wantJSON, _ := json.Marshal(want)
	assertUnchanged := func() {
		t.Helper()
		actual, err := json.Marshal(got)
		if err != nil || !bytes.Equal(actual, wantJSON) {
			t.Fatal("來源變動影響已發布的狀態", err)
		}
	}
	values["items"].([]any)[0].(object)["value"] = "新值"
	values["items"].([]any)[1].([]string)[0] = "新分類"
	groups["film"]["exposure"] = float64(12)
	entries[0]["tags"].([]string)[0] = "人像"
	prompts["traditionalChinese"] = "新提示詞"
	preferences.Tags[0] = "新設定"
	raw[10] = 'X'
	payload["bytes"].([]byte)[0] = 9
	assertUnchanged()
	got["groups"].(object)["film"].(object)["exposure"] = float64(18)
	if groups["film"]["exposure"] != float64(12) {
		t.Fatal("修改快照影響宿主狀態")
	}
}

func TestPublishedStateRemainsStable(t *testing.T) {
	a := testApp(t)
	a.organization.Tags = []string{"風景"}
	a.directory.Entries = []photos.Entry{{ID: "照片", Name: "照片.jpg"}}
	a.organization.Photos["照片"] = photoMetadata{Rating: 3, Tags: []string{"風景"}}
	a.sourcePreview, a.cropPreview, a.outputPreview = "原圖", "裁切圖", "成品"
	a.customFilms = []CustomFilm{{ID: "custom-smoke", BaseStyle: "original", Name: "自訂底片", Adjustment: a.defaults["original"].Adjustment}}
	a.prompts["original"] = map[string]string{"traditionalChinese": "自訂提示詞"}
	var first object
	a.emit = func(name string, payload any) {
		if name == "handleNativeState" && first == nil {
			first = payload.(object)
		}
	}
	a.sendState(true)
	before, err := json.Marshal(first)
	if err != nil {
		t.Fatal(err)
	}
	a.ui["original"]["exposure"] = float64(12)
	a.defaultUI["original"]["exposure"] = float64(18)
	a.catalog["styles"].([]any)[0].(object)["title"] = "已變更的名稱"
	a.organization.Tags[0] = "人像"
	a.organization.Photos["照片"].Tags[0] = "人像"
	a.customFilms[0].Name = "新的底片名稱"
	a.prompts["original"]["traditionalChinese"] = "新的提示詞"
	a.sourcePreview, a.cropPreview, a.outputPreview = "新原圖", "新裁切圖", "新成品"
	a.sendState(true)
	after, err := json.Marshal(first)
	if err != nil || !bytes.Equal(before, after) {
		t.Fatal("下一次狀態更新改寫了上次傳送的內容", err)
	}
}

func TestHistoryReleasesRemovedSnapshots(t *testing.T) {
	a := testApp(t)
	a.undo = make([]editSnapshot, 100, 128)
	for i := range a.undo {
		a.undo[i] = a.snapshot()
	}
	a.undo[0].CustomID = "應淘汰"
	a.undo[0].Recipes = map[string]contract.Recipe{"original": {RepairPatches: json.RawMessage(strings.Repeat("x", 1<<20))}}
	backing := a.undo[:cap(a.undo)]
	a.pushHistory()
	if len(a.undo) != 100 {
		t.Fatal("復原紀錄上限改變")
	}
	for _, entry := range backing {
		if entry.CustomID == "應淘汰" {
			t.Fatal("底層陣列仍持有已淘汰的大型修復資料")
		}
	}
	for _, action := range []string{"undoEdit", "redoEdit"} {
		from := a.undo
		if action == "redoEdit" {
			from = a.redo
		}
		last := len(from) - 1
		if err := a.handle(object{"action": action}); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(from[last], editSnapshot{}) {
			t.Fatal("復原／重做後仍持有已取出的快照", action)
		}
	}
	if len(a.undo) != 100 || len(a.redo) != 0 {
		t.Fatal("復原／重做改變了歷史順序或數量")
	}
}

func TestRepairRevisionPreservesIDs(t *testing.T) {
	a := testApp(t)
	for _, patches := range []string{
		`[]`, `null`,
		`[{"id":"甲","imageData":"影像","maskData":"遮罩"},{"id":"乙","linearGain":1.2}]`,
		`[{"id":"甲"},{"id":""},{"id":"丙"}]`,
	} {
		r := a.recipes[a.selected]
		r.RepairPatches = json.RawMessage(patches)
		a.recipes[a.selected] = r
		var previous []object
		if err := json.Unmarshal(r.RepairPatches, &previous); err != nil {
			t.Fatal(err)
		}
		ids := make([]string, len(previous))
		for i, patch := range previous {
			ids[i] = stringValue(patch, "id")
		}
		if got, want := a.repairRevision(), strings.Join(ids, ":"); got != want {
			t.Fatal("修復識別或順序改變", got, want)
		}
	}
}
