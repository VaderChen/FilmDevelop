package application

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/recipes"
)

func liquifyTestMesh() *json.RawMessage {
	mesh := recipes.LiquifyMesh{Version: 1, ReferenceWidth: 17, ReferenceHeight: 17, Spacing: 4, Columns: 5, Rows: 5, DX: make([]float64, 25), DY: make([]float64, 25)}
	mesh.DX[12] = -.05
	data, _ := json.Marshal(mesh)
	raw := json.RawMessage(data)
	return &raw
}

func liquifyMessage(a *App, mesh *json.RawMessage) object {
	var value any
	if mesh != nil {
		_ = json.Unmarshal(*mesh, &value)
	}
	return object{"action": "applyLiquifyBrush", "requestID": "smoke-stroke", "photoGeneration": a.generation, "previewRevision": float64(a.revision), "liquifyRevision": a.liquifyRevision(), "mesh": value}
}

func TestLiquifyCommitPersistenceHistoryAndStyle(t *testing.T) {
	a, path := restoredParityApp(t)
	callbacks := make(chan object, 8)
	a.emit = func(name string, value any) {
		if name == "handleLiquifyResult" {
			callbacks <- value.(object)
		}
	}
	if err := a.handle(liquifyMessage(a, liquifyTestMesh())); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	reply := <-callbacks
	if reply["success"] != true || reply["requestID"] != "smoke-stroke" || reply["liquifyRevision"] == "" || len(a.undo) != 1 {
		t.Fatal("筆畫未完成單一可復原交易", reply)
	}
	committed := a.recipes[a.selected].Liquify
	for id, recipe := range a.recipes {
		if recipe.Liquify != committed {
			t.Fatal("照片不同底片沒有共用同一液化網格", id)
		}
	}
	if !a.organization.Edited[a.directory.Entries[0].ID] {
		t.Fatal("只有液化的照片未標示已編輯")
	}
	saved, err := a.store.Load(a.imageKey)
	if err != nil || saved.Recipes[a.selected].Liquify == nil {
		t.Fatal("液化紀錄未保存", err)
	}
	if err = a.handle(object{"action": "undoEdit"}); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.recipes[a.selected].Liquify != nil {
		t.Fatal("復原沒有移除網格")
	}
	if err = a.handle(object{"action": "redoEdit"}); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if !bytes.Equal(*a.recipes[a.selected].Liquify, *committed) {
		t.Fatal("重做未還原完整網格")
	}
	if err = a.selectStyle("filmPortra400"); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(*a.recipes[a.selected].Liquify, *committed) {
		t.Fatal("切換底片遺失照片液化")
	}
	if err = a.saveFilm("液化共用測例", a.recipes[a.selected], ""); err != nil {
		t.Fatal(err)
	}
	if filmRecipe(a.customFilms[0]).Liquify != nil {
		t.Fatal("照片液化被保存到自訂底片")
	}
	if err = a.persist(); err != nil {
		t.Fatal(err)
	}
	if err = a.openImage(path); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.recipes[a.selected].Liquify == nil || !bytes.Equal(*a.recipes[a.selected].Liquify, *committed) {
		t.Fatal("重開照片未恢復液化")
	}
	if err = a.handle(liquifyMessage(a, nil)); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if reply = <-callbacks; reply["success"] != true || a.recipes[a.selected].Liquify != nil {
		t.Fatal("清除液化未成功", reply)
	}
	if err = a.handle(object{"action": "undoEdit"}); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	if a.recipes[a.selected].Liquify == nil {
		t.Fatal("清除液化無法復原")
	}
}

func TestLiquifyRejectsStaleBusyAndInvalidMessages(t *testing.T) {
	a, _ := restoredParityApp(t)
	callbacks := make(chan object, 16)
	a.emit = func(name string, value any) {
		if name == "handleLiquifyResult" {
			callbacks <- value.(object)
		}
	}
	for _, mutate := range []func(object){
		func(m object) { m["photoGeneration"] = "舊照片" },
		func(m object) { m["previewRevision"] = float64(a.revision + 1) },
		func(m object) { m["liquifyRevision"] = "舊網格" },
		func(m object) { m["mesh"] = object{} },
		func(m object) { delete(m, "mesh") },
		func(m object) { m["requestID"] = "" },
	} {
		message := liquifyMessage(a, liquifyTestMesh())
		mutate(message)
		_ = a.handle(message)
		reply := <-callbacks
		if reply["success"] != false || reply["requestID"] != message["requestID"] || a.recipes[a.selected].Liquify != nil || len(a.undo) != 0 {
			t.Fatal("失效或錯誤筆畫改寫了照片", reply)
		}
	}
	a.saving = true
	_ = a.handle(liquifyMessage(a, liquifyTestMesh()))
	a.saving = false
	if reply := <-callbacks; reply["success"] != false || len(a.undo) != 0 {
		t.Fatal("忙碌時未回覆明確失敗", reply)
	}
	if err := a.handle(liquifyMessage(a, nil)); err != nil {
		t.Fatal(err)
	}
	if reply := <-callbacks; reply["success"] != true || len(a.undo) != 0 {
		t.Fatal("identity 產生了多餘歷史", reply)
	}
}

func TestLiquifyPreviewSourcesStateAndCache(t *testing.T) {
	a, _ := restoredParityApp(t)
	recipe := a.recipes[a.selected]
	job := a.job("", recipe, true)
	before, err := previewResultKey(a.ctx, job)
	if err != nil {
		t.Fatal(err)
	}
	recipe.Liquify = liquifyTestMesh()
	a.recipes[a.selected] = recipe
	job.Recipe = recipe
	after, err := previewResultKey(a.ctx, job)
	if err != nil || before == after {
		t.Fatal("預覽快取未納入液化", err)
	}
	var state object
	a.emit = func(name string, value any) {
		if name == "handleNativeState" {
			state = value.(object)
		}
	}
	a.previewDone(a.revision, "output", json.RawMessage(`{"cropImage":"warped","liquifyImage":"canonical","sourceImage":"source","sourceWidth":17,"sourceHeight":17}`), nil)
	a.sendState(true)
	if state["supportsLiquify"] != true || state["liquifySourceImage"] != "canonical" || state["repairSourceImage"] != "canonical" || state["cropSourceImage"] != "warped" || state["liquifyMesh"] == nil || state["liquifyRevision"] == "" {
		t.Fatal("編輯來源或網格狀態錯誤", state)
	}
	if a.renderInfo["liquifyImage"] != nil {
		t.Fatal("原生回覆保留多餘大型影像副本")
	}
	a.previewDone(a.revision, "output", json.RawMessage(`{"cropImage":"compatibility","sourceWidth":17,"sourceHeight":17}`), nil)
	a.sendState(true)
	if state["liquifySourceImage"] != "compatibility" || state["repairSourceImage"] != "compatibility" {
		t.Fatal("缺少新來源時沿用了過期圖片")
	}
	a.state()
	if _, repeated := state["liquifyMesh"]; repeated || state["liquifyRevision"] == "" {
		t.Fatal("無關進度更新重複傳送大型網格或省略修訂鍵")
	}
	recipe.Liquify = nil
	a.recipes[a.selected] = recipe
	a.state()
	if cleared, present := state["liquifyMesh"]; !present || cleared != nil || state["liquifyRevision"] != "" {
		t.Fatal("切換為無液化照片時未明確傳送 null")
	}
	a.state()
	if _, repeated := state["liquifyMesh"]; repeated {
		t.Fatal("清除後仍反覆傳送未變的網格")
	}
}

func TestLiquifySaveFailureKeepsAppliedPreviewAndExplicitStatus(t *testing.T) {
	a, _ := restoredParityApp(t)
	a.imageKey = "無效紀錄路徑"
	callbacks := make(chan object, 1)
	a.emit = func(name string, value any) {
		if name == "handleLiquifyResult" {
			callbacks <- value.(object)
		}
	}
	err := a.handle(liquifyMessage(a, liquifyTestMesh()))
	a.workers.Wait()
	reply := <-callbacks
	if err == nil || reply["success"] != true || reply["saved"] != false || reply["message"] == "" || a.recipes[a.selected].Liquify == nil || len(a.undo) != 1 || a.outputPreview == "" || a.previewError != nil {
		t.Fatal("保存失敗後記憶體、預覽或回覆語意不一致", err, reply, a.previewError)
	}
}

func TestLiquifyHistoryBudgetCountsSharedMeshOnce(t *testing.T) {
	a := testApp(t)
	shared := json.RawMessage(strings.Repeat("A", 1024*1024))
	for id, recipe := range a.recipes {
		recipe.Liquify = &shared
		a.recipes[id] = recipe
	}
	for i := 0; i < 40; i++ {
		a.pushHistory()
	}
	if got := liquifyHistorySize(a.undo, a.redo); got != len(shared) {
		t.Fatal("同網格在底片與歷史被重複計費", got)
	}
	for i := 0; i < 36; i++ {
		data := json.RawMessage(strings.Repeat("B", 1024*1024))
		recipe := a.recipes[a.selected]
		recipe.Liquify = &data
		a.recipes = map[string]contract.Recipe{a.selected: recipe}
		a.pushHistory()
	}
	if got := liquifyHistorySize(a.undo, a.redo); got > liquifyHistoryBytes || len(a.undo) >= 76 {
		t.Fatal("液化歷史未受 32MiB 上限約束", got, len(a.undo))
	}
	if !reflect.DeepEqual(a.recipes[a.selected].Liquify, a.undo[len(a.undo)-1].Recipes[a.selected].Liquify) {
		t.Fatal("歷史裁剪丟失最新筆畫")
	}
}

func TestLiquifyBatchCopyPreservesTargetAndResetClears(t *testing.T) {
	a := testApp(t)
	folder := t.TempDir()
	first, second := filepath.Join(folder, "來源.png"), filepath.Join(folder, "目標.png")
	for _, path := range []string{first, second} {
		if err := os.WriteFile(path, []byte(path), 0600); err != nil {
			t.Fatal(err)
		}
	}
	firstKey, firstDoc, err := a.photoDocument(a.ctx, first)
	if err != nil {
		t.Fatal(err)
	}
	secondKey, secondDoc, err := a.photoDocument(a.ctx, second)
	if err != nil {
		t.Fatal(err)
	}
	firstRecipe := a.defaults["original"]
	firstRecipe.Liquify = liquifyTestMesh()
	firstDoc.Recipes["original"] = firstRecipe
	secondRecipe := firstRecipe
	var secondMesh recipes.LiquifyMesh
	_ = json.Unmarshal(*firstRecipe.Liquify, &secondMesh)
	secondMesh.DX[12] = .03
	data, _ := json.Marshal(secondMesh)
	raw := json.RawMessage(data)
	secondRecipe.Liquify = &raw
	secondDoc.Recipes["original"] = secondRecipe
	if err = a.store.Save(firstKey, *firstDoc); err != nil {
		t.Fatal(err)
	}
	if err = a.store.Save(secondKey, *secondDoc); err != nil {
		t.Fatal(err)
	}
	if err = a.batchPhotos([]string{first}, "copy", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	for _, recipe := range a.copiedRecipe.Recipes {
		if recipe.Liquify != nil {
			t.Fatal("複製參數包含來源照片液化")
		}
	}
	if err = a.batchPhotos([]string{second}, "apply", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	loaded, err := a.store.Load(secondKey)
	if err != nil {
		t.Fatal(err)
	}
	for _, recipe := range loaded.Recipes {
		if recipe.Liquify == nil {
			t.Fatal("批次套用丟失目標照片的液化")
		}
		var actual recipes.LiquifyMesh
		if err = json.Unmarshal(*recipe.Liquify, &actual); err != nil || !reflect.DeepEqual(actual, secondMesh) {
			t.Fatal("批次套用了來源照片的液化", err)
		}
	}
	if err = a.batchPhotos([]string{second}, "reset", ""); err != nil {
		t.Fatal(err)
	}
	a.workers.Wait()
	loaded, err = a.store.Load(secondKey)
	if err != nil || loaded.SharedLiquify != nil {
		t.Fatal("重設照片失敗", err)
	}
	for _, recipe := range loaded.Recipes {
		if recipe.Liquify != nil {
			t.Fatal("批次重設沒有清除液化")
		}
	}
}
