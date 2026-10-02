package updater

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type Prepared struct {
	Work, Target, Staged, Backup string
	Version                      Version
}

func Bundle() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	target := filepath.Dir(filepath.Dir(filepath.Dir(exe)))
	if filepath.Ext(target) != ".app" {
		return "", errors.New("請從已安裝的 FilmDevelop App 執行更新")
	}
	target, err = filepath.EvalSymlinks(target)
	return target, err
}
func run(ctx context.Context, name string, args ...string) ([]byte, error) {
	data, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("更新驗證失敗：%s：%w", strings.TrimSpace(string(data)), err)
	}
	return data, nil
}
func metadata(ctx context.Context, path string) (map[string]any, error) {
	data, err := run(ctx, "/usr/bin/plutil", "-convert", "json", "-o", "-", filepath.Join(path, "Contents", "Info.plist"))
	if err != nil {
		return nil, err
	}
	var result map[string]any
	err = json.Unmarshal(data, &result)
	return result, err
}
func ValidateBundle(ctx context.Context, path, identifier string, version Version) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("App 格式不正確")
	}
	// macOS 暫存目錄的 /var 可能指向 /private/var；比較相同的實際根目錄。
	resolvedRoot, err := filepath.EvalSymlinks(path)
	if err != nil {
		return err
	}
	m, err := metadata(ctx, path)
	if err != nil {
		return err
	}
	if m["CFBundleIdentifier"] != identifier || m["CFBundleExecutable"] != "FilmDevelopGo" || m["CFBundleShortVersionString"] != version.Version || m["CFBundleVersion"] != version.Build {
		return errors.New("安裝包識別、混合宿主或版本不符")
	}
	minimum, ok := m["LSMinimumSystemVersion"].(string)
	if !ok {
		return errors.New("安裝包缺少最低 macOS 版本")
	}
	currentOS, err := run(ctx, "/usr/bin/sw_vers", "-productVersion")
	if err != nil {
		return err
	}
	if !supportsOS(strings.TrimSpace(string(currentOS)), minimum) {
		return fmt.Errorf("新版需要 macOS %s 或更新版本", minimum)
	}
	for _, file := range []string{"Contents/MacOS/FilmDevelopGo", "Contents/Resources/Engine/FilmDevelopEngine.app/Contents/MacOS/filmdevelop-engine"} {
		binary := filepath.Join(path, file)
		resolved, err := filepath.EvalSymlinks(binary)
		if err != nil || !strings.HasPrefix(resolved, resolvedRoot+string(os.PathSeparator)) {
			return errors.New("安裝包引擎路徑不符")
		}
		data, err := run(ctx, "/usr/bin/lipo", "-archs", binary)
		if err != nil || strings.TrimSpace(string(data)) != "arm64" {
			return errors.New("安裝包不支援 Apple Silicon")
		}
	}
	_, err = run(ctx, "/usr/bin/codesign", "--verify", "--deep", "--strict", path)
	return err
}
func signingTeam(ctx context.Context, path string) (string, error) {
	data, err := run(ctx, "/usr/bin/codesign", "-dv", "--verbose=4", path)
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "TeamIdentifier=") {
			value := strings.TrimPrefix(line, "TeamIdentifier=")
			if value != "not set" {
				return value, nil
			}
		}
	}
	return "", nil
}
func Prepare(ctx context.Context, assetPath string, version Version) (*Prepared, error) {
	target, err := Bundle()
	if err != nil {
		return nil, err
	}
	return prepareBundle(ctx, target, assetPath, version)
}

func supportsOS(current, minimum string) bool {
	parse := func(value string) ([]uint64, error) {
		parts := strings.Split(value, ".")
		if len(parts) < 2 || len(parts) > 3 {
			return nil, errors.New("macOS 版本格式不符")
		}
		result := make([]uint64, 3)
		for i, part := range parts {
			n, err := strconv.ParseUint(part, 10, 32)
			if err != nil {
				return nil, err
			}
			result[i] = n
		}
		return result, nil
	}
	c, err := parse(current)
	m, e := parse(minimum)
	if err != nil || e != nil {
		return false
	}
	for i := range c {
		if c[i] != m[i] {
			return c[i] > m[i]
		}
	}
	return true
}

func prepareBundle(ctx context.Context, target, assetPath string, version Version) (*Prepared, error) {
	if strings.Contains(target, "/AppTranslocation/") {
		return nil, errors.New("請先將 App 移入可寫入的應用程式資料夾")
	}
	m, err := metadata(ctx, target)
	if err != nil {
		return nil, err
	}
	id, ok := m["CFBundleIdentifier"].(string)
	if !ok {
		return nil, errors.New("無法辨識目前 App")
	}
	work, err := os.MkdirTemp("", "FilmYourPhoto-update-")
	if err != nil {
		return nil, err
	}
	p := &Prepared{Work: work, Target: target, Version: version}
	success := false
	defer func() {
		if !success {
			p.Discard()
		}
	}()
	mount := filepath.Join(work, "mount")
	if err = os.Mkdir(mount, 0700); err != nil {
		return nil, err
	}
	if _, err = run(ctx, "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, assetPath); err != nil {
		return nil, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, _ = run(cleanup, "/usr/bin/hdiutil", "detach", mount)
	}()
	entries, err := os.ReadDir(mount)
	if err != nil {
		return nil, err
	}
	candidate := ""
	for _, entry := range entries {
		if entry.IsDir() && filepath.Ext(entry.Name()) == ".app" {
			path := filepath.Join(mount, entry.Name())
			data, e := metadata(ctx, path)
			if e == nil && data["CFBundleIdentifier"] == id {
				if candidate != "" {
					return nil, errors.New("安裝包包含多個相同 App")
				}
				candidate = path
			}
		}
	}
	if candidate == "" {
		return nil, errors.New("找不到相符的 Go 混合 App")
	}
	if err = ValidateBundle(ctx, candidate, id, version); err != nil {
		return nil, err
	}
	team, err := signingTeam(ctx, target)
	if err != nil {
		return nil, err
	}
	newTeam, err := signingTeam(ctx, candidate)
	if err != nil {
		return nil, err
	}
	if team != "" && team != newTeam {
		return nil, errors.New("新版開發者簽章與已安裝版本不符")
	}
	staged, err := os.MkdirTemp(filepath.Dir(target), ".FilmYourPhoto-*.app")
	if err != nil {
		return nil, err
	}
	p.Staged = staged
	p.Backup = staged + ".bak"
	if _, err = run(ctx, "/usr/bin/ditto", "--norsrc", candidate, staged); err != nil {
		return nil, err
	}
	if err = ValidateBundle(ctx, staged, id, version); err != nil {
		return nil, err
	}
	helper, err := os.ReadFile(filepath.Join(target, "Contents", "Resources", "Updater", "install.sh"))
	if err != nil {
		return nil, err
	}
	if err = os.WriteFile(filepath.Join(work, "install.sh"), helper, 0700); err != nil {
		return nil, err
	}
	receipt, _ := json.Marshal(map[string]string{"target": target, "staged": p.Staged, "backup": p.Backup, "tag": version.Tag(), "identifier": id})
	if err = os.WriteFile(filepath.Join(work, "receipt.json"), receipt, 0600); err != nil {
		return nil, err
	}
	success = true
	return p, nil
}
func (p *Prepared) Discard() {
	if p.Staged != "" {
		_ = os.RemoveAll(p.Staged)
	}
	if p.Work != "" {
		_ = os.RemoveAll(p.Work)
	}
}
func (p *Prepared) Launch() error {
	cmd := exec.Command("/bin/bash", filepath.Join(p.Work, "install.sh"), fmt.Sprint(os.Getpid()), p.Target, p.Staged, p.Backup, p.Work)
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return err
	}
	return cmd.Process.Release()
}
func Confirm(arguments []string, current Version) error {
	for i, arg := range arguments {
		if arg != "--finish-update" || i+1 >= len(arguments) {
			continue
		}
		work := filepath.Clean(arguments[i+1])
		temp, err := filepath.EvalSymlinks(os.TempDir())
		if err != nil {
			return err
		}
		resolved, err := filepath.EvalSymlinks(work)
		if err != nil {
			return err
		}
		if filepath.Dir(resolved) != temp || !strings.HasPrefix(filepath.Base(resolved), "FilmYourPhoto-update-") {
			return errors.New("更新收據路徑不符")
		}
		info, err := os.Lstat(work)
		if err != nil || info.Mode()&os.ModeSymlink != 0 {
			return errors.New("更新收據目錄無效")
		}
		data, err := os.ReadFile(filepath.Join(work, "receipt.json"))
		if err != nil {
			return err
		}
		var receipt map[string]string
		if json.Unmarshal(data, &receipt) != nil {
			return errors.New("更新收據格式不符")
		}
		target, err := Bundle()
		if err != nil {
			return err
		}
		if receipt["target"] != target || receipt["tag"] != current.Tag() || filepath.Dir(receipt["backup"]) != filepath.Dir(target) || !strings.HasPrefix(filepath.Base(receipt["backup"]), ".FilmYourPhoto-") {
			return errors.New("更新收據與目前 App 不符")
		}
		if err = ValidateBundle(context.Background(), target, receipt["identifier"], current); err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(work, "confirmed"), []byte(current.Tag()), 0600)
	}
	return nil
}
