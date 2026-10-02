package application

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/text/unicode/norm"
)

func preferenceField(p *Preferences, key string, value any) error {
	if value == nil {
		return errors.New("設定不能是空值")
	}
	if key == "exportSettings" {
		fields, ok := value.(object)
		if !ok {
			return errors.New("匯出設定格式錯誤")
		}
		for key, value := range fields {
			if err := p.Export.update(key, value); err != nil {
				return err
			}
		}
		return nil
	}
	data, _ := json.Marshal(object{key: value})
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	next := *p
	if err := decoder.Decode(&next); err != nil {
		return err
	}
	switch key {
	case "language":
		if !contains(strings.Split("automatic|zh-Hant|zh-Hans|en|ja|ko|traditionalChinese|english|japanese|korean", "|"), next.Language) {
			return errors.New("介面語言不符")
		}
	case "promptLanguage":
		if !contains(strings.Split("|automatic|traditionalChinese|english|japanese|korean", "|"), next.PromptLanguage) {
			return errors.New("提示詞語言不符")
		}
	case "computeBackend":
		if next.ComputeBackend != "system" && next.ComputeBackend != "vulkan" {
			return errors.New("計算加速設定不符")
		}
	case "rawDecoderBackend":
		if next.RAWDecoder != "system" && next.RAWDecoder != "software" {
			return errors.New("RAW 解析設定不符")
		}
	case "version":
		if next.Version != 1 {
			return errors.New("設定版本不支援")
		}
	}
	*p = next
	return nil
}

func sanitizeOrganization(value organization) organization {
	result := organization{Version: 1, LegacyOrganizationImported: value.LegacyOrganizationImported, Tags: []string{}, Photos: map[string]photoMetadata{}, Edited: map[string]bool{}}
	for _, tag := range value.Tags {
		name, e := validName(tag, 40)
		if e == nil && !contains(result.Tags, name) {
			result.Tags = append(result.Tags, name)
		}
	}
	for id, metadata := range value.Photos {
		if metadata.Rating < 0 || metadata.Rating > 5 {
			metadata.Rating = 0
		}
		tags := []string{}
		for _, tag := range metadata.Tags {
			tag = norm.NFC.String(tag)
			if contains(result.Tags, tag) && !contains(tags, tag) {
				tags = append(tags, tag)
			}
		}
		metadata.Tags = tags
		result.Photos[id] = metadata
	}
	for id, edited := range value.Edited {
		result.Edited[id] = edited
	}
	return result
}

func (a *App) loadOrganizationSafely() {
	if err := a.loadOrganization(); err == nil {
		return
	}
	base := organization{Version: 1, Tags: []string{}, Photos: map[string]photoMetadata{}, Edited: map[string]bool{}}
	found, err := a.store.LoadState("organization.json", &base)
	if err != nil || base.Version != 1 {
		a.recoverState("organization.json", errors.Join(err, errors.New("分類文件格式或版本不符")))
		base = organization{Version: 1}
	}
	if e := validateOrganization(base); e != nil {
		// CommitStates 備份完整原檔，逐筆留下仍可用的分類與分級。
		a.migrationProblem("organization.json", e, filepath.Join(a.store.Root(), "recovery"))
		base = sanitizeOrganization(base)
		if found {
			if e := a.store.CommitStates(map[string]any{"organization.json": base}); e != nil {
				a.migrationProblem("organization.json", e, "")
			}
		}
	}
	base = sanitizeOrganization(base)
	if !base.LegacyOrganizationImported && a.legacyPhotoDirectory != "" {
		path := filepath.Join(filepath.Dir(a.legacyPhotoDirectory), "PhotoOrganization.json")
		data, e := readBounded(path, 16*1024*1024)
		if e == nil {
			var old organization
			if json.Unmarshal(data, &old) != nil || old.Version != 1 {
				a.migrationProblem(path, errors.New("舊分類文件格式或版本不符"), path)
			} else {
				if e := validateOrganization(old); e != nil {
					a.migrationProblem(path, e, path)
				}
				old = sanitizeOrganization(old)
				for _, tag := range old.Tags {
					if !contains(base.Tags, tag) {
						base.Tags = append(base.Tags, tag)
					}
				}
				for key, value := range old.Photos {
					if _, exists := base.Photos[key]; !exists {
						base.Photos[key] = value
					}
				}
			}
		} else if !errors.Is(e, os.ErrNotExist) {
			a.migrationProblem(path, e, path)
		}
	}
	if edited, e := a.legacyEditedPhotos(); e == nil {
		for key, value := range edited {
			if _, exists := base.Edited[key]; !exists {
				base.Edited[key] = value
			}
		}
	} else {
		a.migrationProblem("edited-photos.json", e, "")
	}
	if e := a.store.SaveState("organization.json", base); e != nil {
		a.migrationProblem("organization.json", fmt.Errorf("可用分類暫時未能保存：%w", e), "")
	}
	a.organization = base
}
