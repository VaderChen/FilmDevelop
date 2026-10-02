package application

import (
	"encoding/json"
	"errors"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// 在使用者看到預覽前，驗證整份資料包；避免套用一半才發現另一份設定損壞。
func (a *App) validateArchiveStates(states map[string]json.RawMessage) error {
	for name, raw := range states {
		if !contains(portableStates, name) {
			return errors.New("資料包設定名稱不符")
		}
		if name == "custom-films.json" {
			var films []CustomFilm
			if json.Unmarshal(raw, &films) != nil {
				return errors.New("資料包底片庫格式錯誤")
			}
			seen := map[string]bool{}
			for _, f := range films {
				if len(f.ID) < 8 || f.ID[:7] != "custom-" || seen[f.ID] {
					return errors.New("資料包底片識別不符")
				}
				seen[f.ID] = true
				if _, err := validName(f.Name, 80); err != nil {
					return err
				}
				if _, err := a.services.NormalizeRecipe(filmRecipe(f)); err != nil {
					return err
				}
			}
			continue
		}
		var values object
		if json.Unmarshal(raw, &values) != nil || values == nil {
			return errors.New("資料包設定格式錯誤")
		}
		switch name {
		case "preferences.json":
			p := defaultPreferences()
			for key, value := range values {
				if err := preferenceField(&p, key, value); err != nil {
					return err
				}
			}
		case "prompts.json":
			var prompts map[string]map[string]string
			if json.Unmarshal(raw, &prompts) != nil {
				return errors.New("資料包提示詞格式錯誤")
			}
			for id, langs := range prompts {
				if _, ok := a.defaults[id]; !ok {
					return errors.New("資料包提示詞底片不存在")
				}
				for lang, text := range langs {
					if promptLanguage(lang) != lang || len(text) > 32768 {
						return errors.New("資料包提示詞語言或大小不符")
					}
				}
			}
		case "decorations.json":
			for id, value := range values {
				r, ok := a.defaults[id]
				if !ok {
					return errors.New("資料包装飾底片不存在")
				}
				fields, ok := value.(object)
				if !ok {
					return errors.New("資料包装飾格式錯誤")
				}
				adjustment := recipeFields(r)
				for key, value := range fields {
					if !contains(decorationKeys, key) {
						return errors.New("資料包装飾包含照片專屬欄位")
					}
					adjustment[key] = value
				}
				r.Adjustment, _ = json.Marshal(adjustment)
				if _, err := a.services.NormalizeRecipe(contract.Recipe{Version: 1, Style: id, Adjustment: r.Adjustment, RepairPatches: json.RawMessage(`[]`)}); err != nil {
					return err
				}
			}
		case "ui-preferences.json":
			if len(allowedUIPreferences(values)) != len(values) {
				return errors.New("資料包介面偏好不符")
			}
		}
	}
	return nil
}
