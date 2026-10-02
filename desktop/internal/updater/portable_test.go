package updater

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 最小 PE64 結構只用於檔案驗證測試；實際 Windows 啟動另以封裝成品 Smoke 驗證。
func fixturePE() []byte {
	b := make([]byte, 512)
	copy(b, "MZ")
	binary.LittleEndian.PutUint32(b[60:], 128)
	copy(b[128:], "PE\x00\x00")
	binary.LittleEndian.PutUint16(b[132:], 0x8664)
	binary.LittleEndian.PutUint16(b[148:], 240)
	binary.LittleEndian.PutUint16(b[152:], 0x20b)
	binary.LittleEndian.PutUint32(b[260:], 16)
	return b
}

func portableFixture(t *testing.T, root string, version Version, additional map[string][]byte) {
	t.Helper()
	info, _ := json.Marshal(portableInfo{Version: version, Product: portableProduct, Distribution: "portable", Architecture: "x64", FullRenderer: true})
	files := map[string][]byte{"FilmDevelop.exe": fixturePE(), "filmdevelop-update.exe": fixturePE(), "engine/filmdevelop-engine.exe": fixturePE(), "engine/libPhotoCompute.dll": fixturePE(), "build-info.json": info}
	for name, data := range additional {
		files[name] = data
	}
	manifest := portableManifest{Schema: 1, Algorithm: "SHA-256"}
	for name, data := range files {
		full := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(full), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, data, 0600); err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		manifest.Files = append(manifest.Files, portableFile{name, int64(len(data)), hex.EncodeToString(digest[:])})
	}
	if err := writeUpdateJSON(filepath.Join(root, "files.json"), manifest); err != nil {
		t.Fatal(err)
	}
}

func fixtureZIP(t *testing.T, root, archive string) {
	t.Helper()
	file, err := os.Create(archive)
	if err != nil {
		t.Fatal(err)
	}
	z := zip.NewWriter(file)
	err = filepath.WalkDir(root, func(name string, item os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if item.IsDir() {
			return nil
		}
		rel, _ := filepath.Rel(root, name)
		w, err := z.Create("FilmDevelop/" + filepath.ToSlash(rel))
		if err != nil {
			return err
		}
		data, err := os.ReadFile(name)
		if err != nil {
			return err
		}
		_, err = w.Write(data)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = z.Close(); err != nil {
		t.Fatal(err)
	}
	if err = file.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPortableArchiveValidation(t *testing.T) {
	version := Version{"1.26.1003", "1000"}
	source := filepath.Join(t.TempDir(), "source")
	portableFixture(t, source, version, nil)
	archive := filepath.Join(t.TempDir(), "portable.zip")
	fixtureZIP(t, source, archive)
	extracted, err := extractPortable(context.Background(), archive, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = validatePortable(context.Background(), extracted, version, false); err != nil {
		t.Fatal(err)
	}
	if _, _, err = validatePortable(context.Background(), extracted, Version{"1.26.1004", "1000"}, false); err == nil {
		t.Fatal("接受錯誤版本")
	}
	if err = os.WriteFile(filepath.Join(extracted, "engine", "filmdevelop-engine.exe"), []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, _, err = validatePortable(context.Background(), extracted, version, false); err == nil {
		t.Fatal("接受被更動的引擎")
	}
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = extractPortable(cancelled, archive, t.TempDir()); err == nil {
		t.Fatal("忽略取消")
	}
}

func TestPortableZIPRejectsUnsafeEntries(t *testing.T) {
	cases := map[string][]zip.FileHeader{
		"traversal": {{Name: "FilmDevelop/../../outside"}},
		"absolute":  {{Name: "/FilmDevelop/test"}},
		"drive":     {{Name: "FilmDevelop/C:/test"}},
		"backslash": {{Name: `FilmDevelop/..\outside`}},
		"reserved":  {{Name: "FilmDevelop/CON.txt"}},
		"tail":      {{Name: "FilmDevelop/test. "}},
		"case":      {{Name: "FilmDevelop/a"}, {Name: "FilmDevelop/A"}},
		"root":      {{Name: "Other/app.exe"}},
		"large":     {{Name: "FilmDevelop/large", UncompressedSize64: uint64(maxPortableBytes) + 1}},
	}
	symlink := zip.FileHeader{Name: "FilmDevelop/link"}
	symlink.SetMode(os.ModeSymlink | 0777)
	cases["link"] = []zip.FileHeader{symlink}
	for name, entries := range cases {
		t.Run(name, func(t *testing.T) {
			archive := filepath.Join(t.TempDir(), "unsafe.zip")
			file, err := os.Create(archive)
			if err != nil {
				t.Fatal(err)
			}
			z := zip.NewWriter(file)
			for _, entry := range entries {
				if _, err = z.CreateRaw(&entry); err != nil {
					t.Fatal(err)
				}
			}
			if err = z.Close(); err != nil {
				t.Fatal(err)
			}
			file.Close()
			if _, err = extractPortable(context.Background(), archive, t.TempDir()); err == nil {
				t.Fatal("接受危險 ZIP")
			}
		})
	}
}

func TestPortableSwapPreservesUserFilesAndRestores(t *testing.T) {
	parent := t.TempDir()
	target := filepath.Join(parent, "照片 程式")
	source := filepath.Join(t.TempDir(), "new")
	old, next := Version{"1.26.1002", "1323"}, Version{"1.26.1003", "1000"}
	portableFixture(t, target, old, map[string][]byte{"obsolete.txt": []byte("old component")})
	if err := os.WriteFile(filepath.Join(target, "my-photo.txt"), []byte("user photo"), 0600); err != nil {
		t.Fatal(err)
	}
	portableFixture(t, source, next, map[string][]byte{"new-component.txt": []byte("new")})
	archive := filepath.Join(t.TempDir(), "new.zip")
	fixtureZIP(t, source, archive)
	job, err := preparePortableAt(context.Background(), target, archive, next, os.Getpid())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = loadPortableJob(filepath.Join(job.Work, "job.json")); err != nil {
		t.Fatal(err)
	}
	if err = swapPortable(job); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(target, "my-photo.txt")); err != nil || string(data) != "user photo" {
		t.Fatal("使用者檔案遺失", err)
	}
	if _, err := os.Stat(filepath.Join(target, "obsolete.txt")); !os.IsNotExist(err) {
		t.Fatal("過期元件未移除")
	}
	if _, _, err = validatePortable(context.Background(), target, next, true); err != nil {
		t.Fatal(err)
	}
	if err = restorePortable(job); err != nil {
		t.Fatal(err)
	}
	if _, _, err = validatePortable(context.Background(), target, old, true); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(filepath.Join(target, "my-photo.txt")); string(data) != "user photo" {
		t.Fatal("還原破壞使用者檔案")
	}
}

func TestPortableConflictAndTamperLeaveOldVersion(t *testing.T) {
	for _, tamper := range []bool{false, true} {
		t.Run(map[bool]string{false: "user-conflict", true: "staged-tamper"}[tamper], func(t *testing.T) {
			target := filepath.Join(t.TempDir(), "FilmDevelop")
			source := filepath.Join(t.TempDir(), "new")
			old, next := Version{"1.26.1002", "1323"}, Version{"1.26.1003", "1000"}
			portableFixture(t, target, old, nil)
			os.WriteFile(filepath.Join(target, "new-component.txt"), []byte("private"), 0600)
			portableFixture(t, source, next, map[string][]byte{"new-component.txt": []byte("product")})
			archive := filepath.Join(t.TempDir(), "new.zip")
			fixtureZIP(t, source, archive)
			job, err := preparePortableAt(context.Background(), target, archive, next, os.Getpid())
			if err != nil {
				t.Fatal(err)
			}
			if tamper {
				os.WriteFile(filepath.Join(job.Work, "FilmDevelop", "new-component.txt"), []byte("tampered"), 0600)
			}
			if err = swapPortable(job); err == nil {
				t.Fatal("未拒絕衝突／竄改")
			}
			if _, _, err = validatePortable(context.Background(), target, old, true); err != nil {
				t.Fatal(err)
			}
			data, _ := os.ReadFile(filepath.Join(target, "new-component.txt"))
			if string(data) != "private" {
				t.Fatal("覆蓋使用者檔案")
			}
		})
	}
}

func TestPortablePathRules(t *testing.T) {
	for _, name := range []string{"../file", "a/../file", "a//file", "a/COM1.dll", "aux", "a/test:", "x\x00y", "C:/test", "file."} {
		if portablePath(name) {
			t.Fatalf("接受 %q", name)
		}
	}
	if !portablePath("engine/中文 檔案.dll") || !portablePath("Licenses/Go/module@v1/LICENSE") {
		t.Fatal("拒絕正常路徑")
	}
	if portablePath(strings.Repeat("../", 10) + "photo") {
		t.Fatal("接受上層目錄")
	}
}
