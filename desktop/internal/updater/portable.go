package updater

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"debug/pe"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

const portableProduct = "person.vader.FilmDevelop.Windows"
const maxPortableBytes int64 = 8 * 1024 * 1024 * 1024

type portableFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type portableManifest struct {
	Schema    int            `json:"schema"`
	Algorithm string         `json:"algorithm"`
	Files     []portableFile `json:"files"`
}

type portableInfo struct {
	Version
	Product      string `json:"product"`
	Distribution string `json:"distribution"`
	Architecture string `json:"architecture"`
	FullRenderer bool   `json:"fullWindowsRendererAvailable"`
}

var reservedWindowsName = regexp.MustCompile(`(?i)^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)`)

func portablePath(name string) bool {
	if name == "" || name != path.Clean(name) || strings.HasPrefix(name, "/") || strings.ContainsAny(name, `\:<>"|?*`) {
		return false
	}
	for _, part := range strings.Split(name, "/") {
		if part == "." || part == ".." || strings.TrimRight(part, ". ") != part || reservedWindowsName.MatchString(part) {
			return false
		}
		for _, r := range part {
			if r < 32 || r == 127 {
				return false
			}
		}
	}
	return true
}

type updateReader struct {
	ctx    context.Context
	reader io.Reader
}

func (r updateReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

func readUpdateJSON(name string, value any) error {
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 2*1024*1024+1))
	if err != nil {
		return err
	}
	if len(data) > 2*1024*1024 {
		return errors.New("更新清單過大")
	}
	return json.Unmarshal(data, value)
}

func updateHash(ctx context.Context, name string) (string, int64, error) {
	f, err := os.Open(name)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, updateReader{ctx, f})
	return hex.EncodeToString(h.Sum(nil)), n, err
}

// ZIP 只能含 FilmDevelop 根目錄，逐筆驗證名稱再寫入新建的私有目錄。
func extractPortable(ctx context.Context, archive, work string) (string, error) {
	z, err := zip.OpenReader(archive)
	if err != nil {
		return "", err
	}
	defer z.Close()
	if len(z.File) == 0 || len(z.File) > 10000 {
		return "", errors.New("免安裝 ZIP 檔案數不符")
	}
	seen := map[string]bool{}
	var total uint64
	for _, file := range z.File {
		name := strings.TrimSuffix(file.Name, "/")
		if !portablePath(name) || (name != "FilmDevelop" && !strings.HasPrefix(name, "FilmDevelop/")) || file.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("免安裝 ZIP 路徑無效：%s", file.Name)
		}
		key := strings.ToLower(name)
		if seen[key] {
			return "", errors.New("免安裝 ZIP 含重複檔名")
		}
		seen[key] = true
		if file.FileInfo().IsDir() {
			continue
		}
		if !file.Mode().IsRegular() || file.Flags&1 != 0 || file.UncompressedSize64 > uint64(maxPortableBytes)-total {
			return "", errors.New("免安裝 ZIP 內容或大小無效")
		}
		total += file.UncompressedSize64
		if err := ctx.Err(); err != nil {
			return "", err
		}
		target := filepath.Join(work, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return "", err
		}
		input, err := file.Open()
		if err != nil {
			return "", err
		}
		output, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			input.Close()
			return "", err
		}
		n, copyErr := io.Copy(output, io.LimitReader(updateReader{ctx, input}, int64(file.UncompressedSize64)+1))
		closeErr := output.Close()
		input.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		if n != int64(file.UncompressedSize64) {
			return "", errors.New("免安裝 ZIP 解壓大小不符")
		}
	}
	return filepath.Join(work, "FilmDevelop"), ctx.Err()
}

// allowExtra 僅用於目前程式目錄：清單以外的使用者檔案必須保留。
func validatePortable(ctx context.Context, root string, version Version, allowExtra bool) (portableInfo, []portableFile, error) {
	var info portableInfo
	var manifest portableManifest
	if err := readUpdateJSON(filepath.Join(root, "build-info.json"), &info); err != nil {
		return info, nil, err
	}
	legacy := false
	if allowExtra && (info.Product == "" || info.Product == portableProduct) && info.Distribution != "portable" {
		marker, _ := os.ReadFile(filepath.Join(root, ".filmdevelop-installed.ini"))
		legacy = strings.Contains(string(marker), "Product="+portableProduct+"\r\n")
	}
	if (!legacy && (info.Product != portableProduct || info.Distribution != "portable")) || info.Architecture != "x64" || !info.FullRenderer || (version != (Version{}) && info.Version != version) {
		return info, nil, errors.New("免安裝套件的產品、版本或平台不符")
	}
	if _, err := Parse(info.Version.Tag()); err != nil {
		return info, nil, err
	}
	if err := readUpdateJSON(filepath.Join(root, "files.json"), &manifest); err != nil {
		return info, nil, err
	}
	if manifest.Schema != 1 || manifest.Algorithm != "SHA-256" || len(manifest.Files) == 0 || len(manifest.Files) > 10000 {
		return info, nil, errors.New("免安裝套件清單格式不符")
	}
	expected := map[string]portableFile{}
	for _, entry := range manifest.Files {
		key := strings.ToLower(entry.Path)
		_, duplicate := expected[key]
		if !portablePath(entry.Path) || key == "files.json" || duplicate || entry.Size < 0 || entry.Size > maxPortableBytes || !digestPattern.MatchString("sha256:"+entry.SHA256) {
			return info, nil, errors.New("免安裝套件清單含無效路徑、大小或摘要")
		}
		expected[key] = entry
	}
	seen := map[string]bool{}
	err := filepath.WalkDir(root, func(name string, item os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if item.Type()&os.ModeSymlink != 0 {
			return errors.New("更新目錄不可包含符號連結或接合點")
		}
		if item.IsDir() {
			return nil
		}
		relative, err := filepath.Rel(root, name)
		if err != nil {
			return err
		}
		key := strings.ToLower(filepath.ToSlash(relative))
		if seen[key] {
			return errors.New("免安裝目錄含大小寫衝突")
		}
		seen[key] = true
		if key == "files.json" {
			return nil
		}
		entry, exists := expected[key]
		if !exists {
			if allowExtra {
				return nil
			}
			return fmt.Errorf("免安裝目錄含未列入清單的檔案：%s", relative)
		}
		stat, err := item.Info()
		if err != nil {
			return err
		}
		if !stat.Mode().IsRegular() {
			return errors.New("免安裝套件包含非一般檔案")
		}
		hash, size, err := updateHash(ctx, name)
		if err != nil {
			return err
		}
		if hash != strings.ToLower(entry.SHA256) || size != entry.Size {
			return fmt.Errorf("更新檔案驗證失敗：%s", relative)
		}
		if strings.HasSuffix(key, ".exe") || strings.HasSuffix(key, ".dll") {
			binary, err := pe.Open(name)
			if err != nil {
				return err
			}
			defer binary.Close()
			if binary.Machine != pe.IMAGE_FILE_MACHINE_AMD64 {
				return fmt.Errorf("更新檔案不是 Windows x64：%s", relative)
			}
		}
		return nil
	})
	if err != nil {
		return info, nil, err
	}
	for name := range expected {
		if !seen[name] {
			return info, nil, fmt.Errorf("更新套件缺少檔案：%s", name)
		}
	}
	for _, required := range []string{"filmdevelop.exe", "engine/filmdevelop-engine.exe", "engine/libphotocompute.dll", "build-info.json"} {
		if _, exists := expected[required]; !exists {
			return info, nil, fmt.Errorf("更新套件缺少必要元件：%s", required)
		}
	}
	if !allowExtra {
		if _, exists := expected["filmdevelop-update.exe"]; !exists {
			return info, nil, errors.New("更新套件缺少更新工具")
		}
	}
	hash, size, err := updateHash(ctx, filepath.Join(root, "files.json"))
	if err != nil {
		return info, nil, err
	}
	return info, append(manifest.Files, portableFile{"files.json", size, hash}), nil
}

// 由更新工具在舊程序退出後執行；只搬移整個程式目錄，保留可完整還原的舊目錄。
func preservePortableExtras(previous, staged string, managed []portableFile) error {
	owned := map[string]bool{}
	for _, entry := range managed {
		owned[strings.ToLower(entry.Path)] = true
	}
	return filepath.WalkDir(previous, func(name string, item os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if item.Type()&os.ModeSymlink != 0 {
			return errors.New("使用者檔案含連結，請手動解壓新版到其他目錄")
		}
		relative, err := filepath.Rel(previous, name)
		if err != nil || relative == "." {
			return err
		}
		target := filepath.Join(staged, relative)
		if item.IsDir() {
			return os.MkdirAll(target, 0700)
		}
		if owned[strings.ToLower(filepath.ToSlash(relative))] {
			return nil
		}
		if _, err := os.Lstat(target); !os.IsNotExist(err) {
			return fmt.Errorf("新版檔案與使用者檔案衝突：%s", relative)
		}
		// 同磁碟硬連結保留大型私人檔案而不重複占用空間；不支援時改為複製。
		if err := os.Link(name, target); err == nil {
			return nil
		}
		input, err := os.Open(name)
		if err != nil {
			return err
		}
		defer input.Close()
		output, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(output, input)
		closeErr := output.Close()
		return errors.Join(copyErr, closeErr)
	})
}
