package application

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/engine"
	"github.com/VaderChen/FilmDevelop/internal/host"
	"github.com/VaderChen/FilmDevelop/internal/models"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

func migrateValues(t *testing.T, a *App, values object) {
	t.Helper()
	a.legacySettings = values
	if err := a.migrateLegacyValues(); err != nil {
		t.Fatal(err)
	}
}
func TestMigrationPartialStateAndDeletionReceipts(t *testing.T) {
	a := testApp(t)
	for name, value := range map[string]any{"preferences.json": object{"version": 1, "language": "korean"}, "prompts.json": object{"original": object{"english": "新版提示"}}, "browser.json": browserState{Version: 1, Directory: "/new", Recent: []string{"/new"}}} {
		if err := a.store.SaveState(name, value); err != nil {
			t.Fatal(err)
		}
	}
	values := object{"showAllFilms.v1": true, "stylePrompts.v1": object{"filmGold200": object{"japanese": "舊提示"}, "original": object{"english": "舊內容"}}, "lastPhotoDirectoryPath.v1": "/old", "recentPhotoDirectories.v1": []any{object{"path": "/old"}}}
	migrateValues(t, a, values)
	if a.preferences.Language != "korean" || !a.preferences.ShowAllFilms || a.prompts["filmGold200"]["japanese"] != "舊提示" || a.prompts["original"]["english"] != "新版提示" {
		t.Fatal("逐項移轉或新版優先失敗", a.preferences, a.prompts)
	}
	delete(a.prompts, "filmGold200")
	if err := a.store.SaveState("prompts.json", a.prompts); err != nil {
		t.Fatal(err)
	}
	migrateValues(t, a, values)
	if _, exists := a.prompts["filmGold200"]; exists {
		t.Fatal("刪除後被回灌")
	}
	var browser browserState
	_, _ = a.store.LoadState("browser.json", &browser)
	if browser.Directory != "/new" || len(browser.Recent) != 1 {
		t.Fatal(browser)
	}
}
func TestMigrationSeparateLanguagesMCPAndPNG(t *testing.T) {
	a := testApp(t)
	migrateValues(t, a, object{"interfaceLanguage.v1": "automatic", "promptLanguage.v1": "japanese", "mcpEnabled.v1": true, "photoExportBitDepths.v1": object{"png": float64(16)}, "photoExportPNG8Default.v1": false})
	if a.preferences.Language != "automatic" || a.effectivePromptLanguage() != "japanese" || !a.preferences.MCPEnabled || a.exportSettings.PNGDepth != 8 {
		t.Fatal(a.preferences, a.exportSettings)
	}
}
func TestMigrationCustomFilmsIsolateBadAndPreserveDeletion(t *testing.T) {
	a := testApp(t)
	legacy := t.TempDir()
	a.legacyPhotoDirectory = filepath.Join(legacy, "PhotoEdits")
	good := CustomFilm{ID: "custom-good", Name: "有效底片", BaseStyle: "original", Adjustment: a.defaults["original"].Adjustment}
	bad := CustomFilm{ID: "custom-bad", Name: "壞底片", BaseStyle: "missing", Adjustment: json.RawMessage(`{}`)}
	writePhotoJSON(t, filepath.Join(legacy, "CustomFilms.json"), []CustomFilm{good, bad})
	if err := a.loadUserLibrary(); err != nil {
		t.Fatal(err)
	}
	if len(a.customFilms) != 1 || len(a.migrationIssues) != 1 {
		t.Fatal(a.customFilms, a.migrationIssues)
	}
	if err := a.store.SaveState("custom-films.json", []CustomFilm{}); err != nil {
		t.Fatal(err)
	}
	if err := a.loadUserLibrary(); err != nil {
		t.Fatal(err)
	}
	if len(a.customFilms) != 0 {
		t.Fatal("已刪除底片回灌")
	}
	// 壞來源修好後可重試，成功項目不重複。
	bad.BaseStyle = "original"
	bad.Adjustment = good.Adjustment
	writePhotoJSON(t, filepath.Join(legacy, "CustomFilms.json"), []CustomFilm{good, bad})
	if err := a.loadUserLibrary(); err != nil {
		t.Fatal(err)
	}
	if len(a.customFilms) != 1 || a.customFilms[0].ID != "custom-bad" {
		t.Fatal(a.customFilms)
	}
}
func TestMigrationDamagedNewFilmKeepsHealthyRecords(t *testing.T) {
	a := testApp(t)
	good := CustomFilm{ID: "custom-good", Name: "有效", BaseStyle: "original", Adjustment: a.defaults["original"].Adjustment}
	if err := a.store.SaveState("custom-films.json", []CustomFilm{good, {ID: "custom-bad", Name: "失敗", BaseStyle: "absent", Adjustment: json.RawMessage(`{}`)}}); err != nil {
		t.Fatal(err)
	}
	if err := a.loadUserLibrary(); err != nil {
		t.Fatal(err)
	}
	if len(a.customFilms) != 1 {
		t.Fatal(a.customFilms)
	}
	entries, _ := os.ReadDir(filepath.Join(a.store.Root(), "recovery"))
	if len(entries) == 0 {
		t.Fatal("缺少原始資料備份")
	}
}
func TestMigrationUnicodeNames(t *testing.T) {
	a := testApp(t)
	flag := strings.Repeat("🇹🇼", 21)
	if err := a.changeMetadata([]string{"/photo.jpg"}, "tag", flag); err != nil {
		t.Fatal(err)
	}
	name, err := validName("Cafe\u0301", 40)
	if err != nil || name != "Café" {
		t.Fatal(name, err)
	}
	if filmNameKey("Café") != filmNameKey("CAFE") {
		t.Fatal("重音與大小寫比較不相容")
	}
	if _, err := validName(strings.Repeat("🇹🇼", 41), 40); err == nil {
		t.Fatal("超長字素未拒絕")
	}
}
func TestMigrationDecorationsOnly(t *testing.T) {
	a := testApp(t)
	fields := recipeFields(a.defaults["original"])
	fields["frameEnabled"] = true
	fields["dateEnabled"] = true
	fields["exposure"] = 2.0
	fields["cropRotation"] = 20.0
	migrateValues(t, a, object{"styleAdjustments.v1": object{"original": fields}})
	if err := a.loadDecorations(); err != nil {
		t.Fatal(err)
	}
	r := a.newPhotoRecipes()["original"]
	f := recipeFields(r)
	if f["frameEnabled"] != true || f["dateEnabled"] != true || f["exposure"] != float64(0) || f["cropRotation"] != float64(0) {
		t.Fatal(f)
	}
}
func maskFixture() []byte {
	data := make([]byte, 16+2*2*16)
	copy(data, "FYPMASK1")
	binary.LittleEndian.PutUint32(data[8:], 2)
	binary.LittleEndian.PutUint32(data[12:], 2)
	for i := 16; i < len(data); i += 4 {
		binary.LittleEndian.PutUint32(data[i:], math.Float32bits(float32((i-16)%16)/16))
	}
	return data
}
func TestMigrationMaskIdentityAndInvalidation(t *testing.T) {
	a := testApp(t)
	path := filepath.Join(t.TempDir(), "photo.jpg")
	if err := os.WriteFile(path, []byte("原圖"), 0600); err != nil {
		t.Fatal(err)
	}
	fingerprint, _ := storage.Fingerprint(context.Background(), path)
	mask, err := a.store.ImportMask(maskFixture(), fingerprint, repairDigest(json.RawMessage(`[]`)))
	if err != nil {
		t.Fatal(err)
	}
	a.source = path
	a.sourceIdentity = &storage.PhotoSource{Path: path, Fingerprint: fingerprint}
	a.subjectMask = mask
	job := a.job("result.png", a.defaults["original"], true)
	if job.SubjectMask == nil {
		t.Fatal("舊遮罩未傳入契約")
	}
	r := a.defaults["original"]
	r.RepairPatches = json.RawMessage(`[{"changed":true}]`)
	if a.job("out.png", r, true).SubjectMask != nil {
		t.Fatal("修復變更仍用舊遮罩")
	}
	data := maskFixture()
	data[20] ^= 1
	if err := os.WriteFile(a.store.MaskPath(mask), data, 0600); err != nil {
		t.Fatal(err)
	}
	if a.store.ValidateMaskAsset(mask) == nil {
		t.Fatal("破損遮罩未拒絕")
	}
}
func TestMigrationArchiveRelocatesDistinctCopies(t *testing.T) {
	a := testApp(t)
	oldRoot := t.TempDir()
	newRoot := t.TempDir()
	for _, name := range []string{"a.jpg", "b.jpg"} {
		old := filepath.Join(oldRoot, name)
		dest := filepath.Join(newRoot, name)
		data := []byte("相同內容的不同副本")
		_ = os.WriteFile(old, data, 0600)
		_ = os.WriteFile(dest, data, 0600)
		fp, _ := storage.Fingerprint(a.ctx, old)
		r := a.defaults["original"]
		fields := recipeFields(r)
		if name == "b.jpg" {
			fields["exposure"] = 1.0
		}
		r.Adjustment, _ = json.Marshal(fields)
		doc := storage.Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{"original": r}, Source: &storage.PhotoSource{Path: old, Fingerprint: fp}}
		if name == "a.jpg" {
			doc.SubjectMask, _ = a.store.ImportMask(maskFixture(), fp, repairDigest(r.RepairPatches))
		}
		if err := a.store.Save(storage.PhotoKey(old, fp), doc); err != nil {
			t.Fatal(err)
		}
		a.organization.Photos[photos.Identity(old)] = photoMetadata{Rating: 5, Tags: []string{"分類"}}
		a.organization.Edited[photos.Identity(old)] = true
	}
	a.organization.Tags = []string{"分類"}
	archive := filepath.Join(t.TempDir(), "library.zip")
	if err := a.writeLibraryArchive(archive); err != nil {
		t.Fatal(err)
	}
	b := testApp(t)
	manifest, _, err := readLibraryArchive(archive)
	if err != nil {
		t.Fatal(err)
	}
	roots := map[string]string{}
	for id := range manifest.Roots {
		roots[id] = newRoot
	}
	plan, err := b.planLibraryImport(b.ctx, archive, roots)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Photos) != 2 {
		t.Fatal("不同路徑副本被合併")
	}
	if err = b.applyLibraryImport(plan); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a.jpg", "b.jpg"} {
		path := filepath.Join(newRoot, name)
		_, doc, err := b.photoDocument(b.ctx, path)
		if err != nil {
			t.Fatal(err)
		}
		expected := 0.0
		if name == "b.jpg" {
			expected = 1
		}
		if recipeFields(doc.Recipes["original"])["exposure"] != expected {
			t.Fatal("配方混用")
		}
		canonical, _ := photos.Canonical(path)
		if b.organization.Photos[photos.Identity(canonical)].Rating != 5 {
			t.Fatal("分級未搬移")
		}
	}
	plan, err = b.planLibraryImport(b.ctx, archive, roots)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Photos) != 0 || plan.Conflicts != 2 {
		t.Fatal("重複匯入未保護新版")
	}
}
func TestMigrationUISettingsAndExistingChoices(t *testing.T) {
	a := testApp(t)
	a.emit = func(string, any) {}
	migrateValues(t, a, object{"webPreferences": object{"photoStyle.thumbnailSize": "large", "photoStyle.showHelp": "false", "not-a-preference": "x"}})
	if err := a.syncUIPreferences(object{"initial": true, "values": object{"photoStyle.thumbnailSize": "small"}}); err != nil {
		t.Fatal(err)
	}
	var saved object
	_, _ = a.store.LoadState("ui-preferences.json", &saved)
	if saved["photoStyle.thumbnailSize"] != "small" || saved["photoStyle.showHelp"] != "false" || saved["not-a-preference"] != nil {
		t.Fatal(saved)
	}
	if err := a.syncUIPreferences(object{"key": "photoStyle.showHelp", "remove": true}); err != nil {
		t.Fatal(err)
	}
	migrateValues(t, a, object{"webPreferences": object{"photoStyle.showHelp": "false"}})
	_, _ = a.store.LoadState("ui-preferences.json", &saved)
	fresh := object{}
	_, _ = a.store.LoadState("ui-preferences.json", &fresh)
	if _, exists := fresh["photoStyle.showHelp"]; exists {
		t.Fatal("刪除偏好回灌")
	}
}
func TestMigrationModelBindingAndOfflineRoot(t *testing.T) {
	a := testApp(t)
	root := filepath.Join(a.store.Root(), "models")
	_ = os.MkdirAll(root, 0700)
	for _, name := range []string{"camera.gguf", "mmproj-one.gguf", "vision.gguf"} {
		data := make([]byte, 32)
		copy(data, "GGUF")
		binary.LittleEndian.PutUint32(data[4:], 3)
		_ = os.WriteFile(filepath.Join(root, name), data, 0600)
	}
	writePhotoJSON(t, filepath.Join(root, "active-model.json"), object{"mainFileName": "camera.gguf", "family": "custom", "auxiliaryFileName": "vision.gguf"})
	entries, err := models.Scan(a.ctx, root)
	if err != nil || len(entries) != 1 || !entries[0].Ready || filepath.Base(entries[0].Projector) != "vision.gguf" {
		t.Fatal(entries, err)
	}
	_ = a.store.SaveState("models.json", modelSettings{Version: 1, Directory: filepath.Join(root, "offline")})
	a.capabilities = object{}
	if err = a.loadModels(); err != nil {
		t.Fatal(err)
	}
	if len(a.modelEntries) != 1 || !strings.Contains(a.modelMessage, "offline") {
		t.Fatal(a.modelEntries, a.modelMessage)
	}
}
func TestMigrationPrivateSourceFallback(t *testing.T) {
	a := testApp(t)
	root := t.TempDir()
	a.legacyPhotoDirectory = filepath.Join(root, "PhotoEdits")
	_ = os.MkdirAll(a.legacyPhotoDirectory, 0700)
	private := filepath.Join(root, "last-opened-image.nef")
	_ = os.WriteFile(private, []byte("私有原圖"), 0600)
	hash, _ := storage.Fingerprint(a.ctx, private)
	migrateValues(t, a, object{"lastSourceImagePath.v1": private, "lastSourceImageIdentifier.v1": "sha256:" + hash, "lastImageImportFilePath.v1": filepath.Join(root, "missing.nef")})
	var saved object
	found, err := a.store.LoadState("private-source.json", &saved)
	if err != nil || !found {
		t.Fatal(found, err)
	}
	if _, err = os.Stat(saved["path"].(string)); err != nil {
		t.Fatal(err)
	}
}
func TestMigrationMCPTokenKeptPrivate(t *testing.T) {
	a := testApp(t)
	legacy := t.TempDir()
	a.legacyPhotoDirectory = filepath.Join(legacy, "PhotoEdits")
	token := strings.Repeat("x", 64)
	_ = os.MkdirAll(filepath.Join(legacy, "MCP"), 0700)
	writePhotoJSON(t, filepath.Join(legacy, "MCP", "connection.json"), object{"mcpServers": object{"FilmYourPhoto": object{"url": "http://127.0.0.1:8765/mcp", "headers": object{"Authorization": "Bearer " + token}}}})
	if err := a.migrateMCPConnection(); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(a.store.Root(), "MCP", "connection.json")
	data, err := os.ReadFile(file)
	if err != nil || !strings.Contains(string(data), token) {
		t.Fatal("本機連線未沿用", err)
	}
	info, _ := os.Stat(file)
	if runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
		t.Fatal("權杖權限太寬")
	}
	if strings.Contains(a.migrationSummary(), token) {
		t.Fatal("報告洩漏權杖")
	}
}

func TestLegacyCompleteLibraryArchiveSmoke(t *testing.T) {
	directory := os.Getenv("FILMDEVELOP_LEGACY_SMOKE_DIRECTORY")
	if directory == "" {
		t.Skip("需指定本機舊照片目錄")
	}
	a := testApp(t)
	root, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	original := filepath.Join(root, "PhotoStyleApp", "PhotoEdits")
	a.legacyPhotoDirectory = original
	if err = a.store.SaveState("browser.json", browserState{Version: 1, Directory: directory, Recent: []string{directory}}); err != nil {
		t.Fatal(err)
	}
	a.loadOrganizationSafely()
	if err = a.archiveLegacyPhotos(); err != nil {
		t.Fatal(err)
	}
	files, err := os.ReadDir(original)
	if err != nil {
		t.Fatal(err)
	}
	masks, documents := 0, 0
	for _, file := range files {
		if file.IsDir() {
			continue
		}
		if !strings.HasSuffix(file.Name(), ".json") && !strings.HasSuffix(file.Name(), ".mask.rgba") {
			continue
		}
		source, err := os.ReadFile(filepath.Join(original, file.Name()))
		if err != nil {
			t.Fatal(err)
		}
		copy, err := os.ReadFile(filepath.Join(a.store.Root(), "legacy", "PhotoEdits", file.Name()))
		if err != nil || sha256Bytes(copy) != sha256Bytes(source) {
			t.Fatal("整庫備份不完整", file.Name(), err)
		}
		if strings.HasSuffix(file.Name(), ".mask.rgba") {
			if _, _, err := storage.ValidateMask(source); err != nil {
				t.Fatal(file.Name(), err)
			}
			masks++
		} else if file.Name() != "edited-photos.json" {
			documents++
		}
	}
	if masks == 0 || documents == 0 {
		t.Fatal("缺少真實遮罩與文件樣本")
	}
	archived := a.legacyPhotoDirectory
	if archived == original {
		t.Fatal("仍依賴舊目錄")
	}
	// 第二次啟動使用自己的備份；無須重讀已建立來源索引的照片。
	if err = a.archiveLegacyPhotos(); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "library.zip")
	if err = a.writeLibraryArchive(out); err != nil {
		t.Fatal(err)
	}
	manifest, _, err := readLibraryArchive(out)
	if err != nil || len(manifest.Photos) == 0 {
		t.Fatal(err)
	}
	t.Logf("舊文件 %d 份、遮罩 %d 份逐位元保存；已定位照片 %d 張", documents, masks, len(manifest.Photos))
}

func TestMigrationDamagedPreferenceAndOrganizationIsolation(t *testing.T) {
	a := testApp(t)
	if err := a.store.SaveState("preferences.json", object{"version": 1, "language": "korean", "computeBackend": "broken", "showAllFilms": true, "exportSettings": object{"pngDepth": 32, "format": "jpeg"}}); err != nil {
		t.Fatal(err)
	}
	if err := a.loadPreferences(); err != nil {
		t.Fatal(err)
	}
	if a.preferences.Language != "korean" || !a.preferences.ShowAllFilms || a.computeBackend != "system" || a.exportSettings.Format != "jpeg" {
		t.Fatal(a.preferences)
	}
	if err := a.store.SaveState("organization.json", organization{Version: 1, Tags: []string{"好分類"}, Photos: map[string]photoMetadata{"healthy": {Rating: 5, Tags: []string{"好分類"}}, "bad": {Rating: 9, Tags: []string{"缺少"}}}}); err != nil {
		t.Fatal(err)
	}
	a.loadOrganizationSafely()
	if a.organization.Photos["healthy"].Rating != 5 || a.organization.Photos["bad"].Rating != 0 {
		t.Fatal(a.organization)
	}
	if len(a.migrationIssues) < 3 {
		t.Fatal("隔離問題未回報")
	}
}

func TestMigrationResolvedBookmarkKeepsRecipeAndRating(t *testing.T) {
	a, old, _, recipe := legacyPhotoFixture(t)
	fp, _ := storage.Fingerprint(a.ctx, old)
	// 模擬書籤把舊檔定位到新資料夾，原路徑不再存在。
	target := filepath.Join(t.TempDir(), filepath.Base(old))
	data, err := os.ReadFile(old)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(target, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.Remove(old); err != nil {
		t.Fatal(err)
	}
	canonical, _ := photos.Canonical(target)
	oldKey := photos.Identity(old)
	a.organization.Photos[oldKey] = photoMetadata{Rating: 4, Tags: []string{"搬移"}}
	a.organization.Tags = []string{"搬移"}
	aliases := object{"entry": object{"from": old, "to": canonical, "directory": false}}
	if err = a.store.SaveState("path-aliases.json", aliases); err != nil {
		t.Fatal(err)
	}
	doc, err := a.legacyPhotoDocument(fp, canonical)
	if err != nil || doc == nil {
		t.Fatal(err)
	}
	if doc.Selected != recipe.Style || a.organization.Photos[photos.Identity(canonical)].Rating != 4 {
		t.Fatal("重新定位遺失原配方或分級")
	}
}

func TestLegacySubjectMaskNativeSmoke(t *testing.T) {
	binary, directory := os.Getenv("FILMDEVELOP_NATIVE_SMOKE_ENGINE"), os.Getenv("FILMDEVELOP_LEGACY_SMOKE_DIRECTORY")
	if binary == "" || directory == "" {
		t.Skip("需指定原生引擎與本機照片目錄")
	}
	a := testApp(t)
	root, _ := os.UserConfigDir()
	a.legacyPhotoDirectory = filepath.Join(root, "PhotoStyleApp", "PhotoEdits")
	var err error
	a.services, err = host.New(engine.New(binary))
	if err != nil {
		t.Fatal(err)
	}
	defer a.services.Close()
	scan, err := photos.Scan(a.ctx, directory)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range scan.Entries {
		fp, err := storage.Fingerprint(a.ctx, entry.Path)
		if err != nil {
			continue
		}
		doc, err := a.legacyPhotoDocument(fp, entry.Path)
		if err != nil {
			t.Fatal(err)
		}
		if doc == nil || doc.SubjectMask == nil {
			continue
		}
		a.source = entry.Path
		a.sourceIdentity = doc.Source
		a.subjectMask = doc.SubjectMask
		r := a.defaults["original"]
		fields := recipeFields(r)
		fields["skinSmoothing"] = 20.0
		r.Adjustment, _ = json.Marshal(fields)
		r.RepairPatches = doc.Recipes[doc.Selected].RepairPatches
		r, err = a.services.NormalizeRecipe(r)
		if err != nil {
			t.Fatal(err)
		}
		folder := t.TempDir()
		job := a.job(filepath.Join(folder, "first.jpeg"), r, true)
		job.Output.MaxPixel = 256
		job.PreviewMaxPixel = 256
		if job.SubjectMask == nil {
			t.Fatal("未傳入主體遮罩")
		}
		first, err := a.services.Render(a.ctx, job, nil)
		if err != nil {
			t.Fatal(err)
		}
		job.Output.Path = filepath.Join(folder, "second.jpeg")
		second, err := a.services.Render(a.ctx, job, nil)
		if err != nil {
			t.Fatal(err)
		}
		var f, s object
		_ = json.Unmarshal(first, &f)
		_ = json.Unmarshal(second, &s)
		if s["timing"].(object)["maskCacheHit"] != true || f["cropImage"] != s["cropImage"] {
			t.Fatal("遮罩快取或輸出不同")
		}
		t.Logf("%s：沿用 Swift 遮罩，兩次預覽輸出一致，maskCacheHit=true", entry.Name)
		return
	}
	t.Fatal("目錄沒有可驗證的原始遮罩")
}

func TestMigrationArchiveRetryImportsMetadataIndependently(t *testing.T) {
	a := testApp(t)
	source := filepath.Join(t.TempDir(), "photo.jpg")
	_ = os.WriteFile(source, []byte("photo"), 0600)
	source, _ = photos.Canonical(source)
	fp, _ := storage.Fingerprint(a.ctx, source)
	doc := storage.Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{}, Source: &storage.PhotoSource{Path: source, Fingerprint: fp}}
	key := storage.PhotoKey(source, fp)
	if err := a.store.Save(key, doc); err != nil {
		t.Fatal(err)
	}
	a.organization.Tags = []string{"舊分類"}
	a.organization.Photos[photos.Identity(source)] = photoMetadata{Rating: 4, Tags: []string{"舊分類"}}
	path := filepath.Join(t.TempDir(), "retry.zip")
	if err := a.writeLibraryArchive(path); err != nil {
		t.Fatal(err)
	}
	b := testApp(t)
	if err := b.store.Save(key, doc); err != nil {
		t.Fatal(err)
	} // 模擬照片已提交，但分類提交前中斷。
	manifest, _, err := readLibraryArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	roots := map[string]string{}
	for id := range manifest.Roots {
		roots[id] = filepath.Dir(source)
	}
	plan, err := b.planLibraryImport(b.ctx, path, roots)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Photos) != 0 || plan.Conflicts != 1 {
		t.Fatal(plan)
	}
	if err = b.applyLibraryImport(plan); err != nil {
		t.Fatal(err)
	}
	if b.organization.Photos[photos.Identity(source)].Rating != 4 {
		t.Fatal("重試時未補齊分类")
	}
}

func TestMigrationDecorationsDoNotOverrideSavedReset(t *testing.T) {
	a := testApp(t)
	a.computing = true // 測試狀態恢復，不啟動原生工作。
	a.decorations = map[string]object{"original": {"frameEnabled": true, "frameStyle": "whitePaperThin", "dateEnabled": true, "dateStyle": "numeric"}}
	path := filepath.Join(t.TempDir(), "photo.jpg")
	_ = os.WriteFile(path, []byte("fixture"), 0600)
	if err := a.openImage(path); err != nil {
		t.Fatal(err)
	}
	if recipeFields(a.recipes["original"])["frameEnabled"] != true {
		t.Fatal("新照片未沿用裝飾")
	}
	fp, _ := storage.Fingerprint(a.ctx, path)
	if err := a.store.Save(storage.PhotoKey(path, fp), storage.Document{Version: 1, Selected: "original", Recipes: map[string]contract.Recipe{}, Manual: &storage.ManualAdjustments{HasCompleteHistory: true}}); err != nil {
		t.Fatal(err)
	}
	if err := a.openImage(path); err != nil {
		t.Fatal(err)
	}
	if recipeFields(a.recipes["original"])["frameEnabled"] != false {
		t.Fatal("新照片偏好覆蓋已保存的還原")
	}
}
