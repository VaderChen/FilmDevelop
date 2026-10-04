package application

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/recipes"
)

const liquifyHistoryBytes = 32 * 1024 * 1024

func liquifyDigest(raw *json.RawMessage) string {
	if raw == nil {
		return ""
	}
	digest := sha256.Sum256(*raw)
	return hex.EncodeToString(digest[:])
}

// 呼叫端持有 App.mu。App 的配方網格只整份替換，不修改其中位元組；
// 僅保留目前一份修訂鍵，切換、復原或清除時依新指標重新計算／釋放。
func (a *App) liquifyRevision() string {
	raw := a.recipes[a.selected].Liquify
	if raw != a.liquifyRevisionMesh {
		a.liquifyRevisionMesh, a.liquifyRevisionKey = raw, liquifyDigest(raw)
	}
	return a.liquifyRevisionKey
}

func (a *App) liquifySource() string {
	if a.liquifyPreview != "" {
		return a.liquifyPreview
	}
	return a.cropPreview
}

// 已驗證的 JSON 以新值整份取代；相同照片底片與歷史共用不可變的網格。
func shareLiquifyMeshes(values map[string]contract.Recipe) {
	var first *json.RawMessage
	var shared map[[32]byte]*json.RawMessage
	for id, recipe := range values {
		if recipe.Liquify == nil {
			continue
		}
		if first == nil {
			first = recipe.Liquify
			continue
		}
		// 同照片通常只有一種網格；既有別名或相同內容直接共用，毋須逐款 SHA。
		if recipe.Liquify == first || bytes.Equal(*recipe.Liquify, *first) {
			recipe.Liquify = first
			values[id] = recipe
			continue
		}
		if shared == nil {
			shared = map[[32]byte]*json.RawMessage{}
		}
		key := sha256.Sum256(*recipe.Liquify)
		if existing := shared[key]; existing != nil {
			recipe.Liquify = existing
			values[id] = recipe
		} else {
			shared[key] = recipe.Liquify
		}
	}
}

// 液化歷史另外限制位元組，不把各底片重複參照的同一網格重複計費。
func liquifyHistorySize(undo, redo []editSnapshot) int {
	seen := map[*json.RawMessage]bool{}
	total := 0
	count := func(recipe contract.Recipe) {
		if raw := recipe.Liquify; raw != nil && !seen[raw] {
			seen[raw] = true
			total += len(*raw)
		}
	}
	for _, history := range [][]editSnapshot{undo, redo} {
		for _, snapshot := range history {
			for _, recipe := range snapshot.Recipes {
				count(recipe)
			}
			if snapshot.CustomBase != nil {
				count(*snapshot.CustomBase)
			}
		}
	}
	return total
}

func (a *App) trimLiquifyHistory() {
	// 先計一次引用數；逐筆移除時只扣除該筆引用，避免每刪一筆重掃全部歷史。
	refs := map[*json.RawMessage]int{}
	total := 0
	visit := func(snapshot editSnapshot, delta int) {
		change := func(raw *json.RawMessage) {
			if raw == nil {
				return
			}
			if refs[raw] == 0 {
				total += len(*raw)
			}
			refs[raw] += delta
			if refs[raw] == 0 {
				total -= len(*raw)
			}
		}
		for _, recipe := range snapshot.Recipes {
			change(recipe.Liquify)
		}
		if snapshot.CustomBase != nil {
			change(snapshot.CustomBase.Liquify)
		}
	}
	for _, history := range [][]editSnapshot{a.undo, a.redo} {
		for _, snapshot := range history {
			visit(snapshot, 1)
		}
	}
	for _, history := range []*[]editSnapshot{&a.undo, &a.redo} {
		removed := 0
		for total > liquifyHistoryBytes && removed < len(*history) {
			visit((*history)[removed], -1)
			removed++
		}
		*history = slices.Delete(*history, 0, removed)
	}
}

func (a *App) liquifyBrush(message object) (err error) {
	result := object{"success": false, "requestID": message["requestID"], "photoGeneration": message["photoGeneration"]}
	defer func() {
		if err != nil {
			result["message"] = err.Error()
		}
		a.reply("handleLiquifyResult", result)
	}()
	a.mu.Lock()
	if a.initError != nil || a.source == "" || a.previewBusy() || a.saving || a.computing || a.repairing || a.mcpMutating || a.updating || a.switchingComputeBackend() || a.rawSwitch != nil || message["photoGeneration"] != a.generation || message["previewRevision"] != float64(a.revision) || message["liquifyRevision"] != a.liquifyRevision() {
		a.mu.Unlock()
		a.state()
		return nil
	}
	requestID := stringValue(message, "requestID")
	if requestID == "" || len(requestID) > 80 {
		a.mu.Unlock()
		return errors.New("液化筆畫識別格式不符")
	}
	if _, present := message["mesh"]; !present {
		a.mu.Unlock()
		return errors.New("液化筆畫缺少網格；清除時請明確傳入 null")
	}
	raw, marshalErr := json.Marshal(message["mesh"])
	if marshalErr != nil {
		a.mu.Unlock()
		return errors.New("液化筆刷資料格式不符")
	}
	data := json.RawMessage(raw)
	next, normalizeErr := recipes.NormalizeLiquify(&data)
	if normalizeErr != nil {
		a.mu.Unlock()
		return normalizeErr
	}
	current := a.recipes[a.selected].Liquify
	if current == nil && next == nil || current != nil && next != nil && bytes.Equal(*current, *next) {
		result["success"], result["liquifyRevision"] = true, a.liquifyRevision()
		a.mu.Unlock()
		a.state()
		return nil
	}
	a.pushHistory()
	a.historyGroup = ""
	for id, recipe := range a.recipes {
		recipe.Liquify = next
		a.recipes[id] = recipe
	}
	if a.customBase != nil {
		a.customBase.Liquify = next
	}
	a.invalidatePreview()
	a.editVersion++
	result["liquifyRevision"] = a.liquifyRevision()
	a.mu.Unlock()
	result["success"] = true
	if err = a.persist(); err != nil {
		// 已提交的可復原筆畫仍應顯示；儲存與組織索引不是同一個磁碟交易。
		// 不能只回失敗讓前端顯示舊網格，亦不能盲目回滾已寫入磁碟的紀錄。
		result["saved"] = false
		err = fmt.Errorf("液化已套用，但無法保存：%w", err)
		a.preview()
		return err
	}
	result["saved"] = true
	a.preview()
	return nil
}
