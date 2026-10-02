package updater

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

type Prepared struct {
	Path string
	job  *portableJob
}

func InstalledIdentifier(context.Context) (string, error) { return "", nil }

func Prepare(ctx context.Context, path string, version Version) (*Prepared, error) {
	if strings.EqualFold(filepath.Ext(path), ".exe") {
		return &Prepared{Path: path}, ctx.Err()
	}
	if !strings.EqualFold(filepath.Ext(path), ".zip") {
		return nil, errors.New("Windows 更新套件格式不支援")
	}
	executable, err := os.Executable()
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(filepath.Base(executable), "FilmDevelop.exe") {
		return nil, errors.New("請從 FilmDevelop.exe 執行更新")
	}
	job, err := preparePortableAt(ctx, filepath.Dir(executable), path, version, os.Getpid())
	if err != nil {
		return nil, err
	}
	return &Prepared{Path: filepath.Join(job.Work, "update.exe"), job: job}, nil
}
func (p *Prepared) Discard() {
	if p.job != nil {
		if _, err := os.Stat(filepath.Join(p.job.Work, "previous")); os.IsNotExist(err) {
			_ = os.RemoveAll(p.job.Work)
		}
	}
}
func (p *Prepared) Launch() error {
	cmd := exec.Command(p.Path)
	if p.job != nil {
		cmd.Args = append(cmd.Args, "--apply", filepath.Join(p.job.Work, "job.json"))
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		cmd.Dir = p.job.Work
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	if p.job != nil {
		for attempt := 0; attempt < 300; attempt++ {
			if _, err := os.Stat(filepath.Join(p.job.Work, "ready.json")); err == nil {
				return cmd.Process.Release()
			}
			var failure struct {
				Error string `json:"error"`
			}
			if readUpdateJSON(filepath.Join(p.job.Work, "result.json"), &failure) == nil && failure.Error != "" {
				_ = cmd.Wait()
				return errors.New(failure.Error)
			}
			time.Sleep(100 * time.Millisecond)
		}
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		return errors.New("更新工具未就緒，原程式仍保留")
	}
	return cmd.Process.Release()
}

func Confirm(args []string, version Version) error {
	for index, arg := range args {
		if arg != "--finish-update" || index+1 >= len(args) {
			continue
		}
		job, err := loadPortableJob(args[index+1])
		if err != nil {
			return err
		}
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		if !strings.EqualFold(filepath.Clean(executable), filepath.Join(job.Target, "FilmDevelop.exe")) || job.Version != version {
			return errors.New("更新啟動確認不符")
		}
		return writeUpdateJSON(filepath.Join(job.Work, "confirmed.json"), version)
	}
	return nil
}

// RunWindowsUpdate 只由套件內獨立的 Go 更新工具呼叫。
func RunWindowsUpdate(jobPath string) (result error) {
	job, err := loadPortableJob(jobPath)
	if err != nil {
		return err
	}
	defer func() {
		message := ""
		if result != nil {
			message = result.Error()
		}
		_ = writeUpdateJSON(filepath.Join(job.Work, "result.json"), map[string]any{"passed": result == nil, "error": message})
	}()
	parent, err := windows.OpenProcess(windows.SYNCHRONIZE|windows.PROCESS_QUERY_LIMITED_INFORMATION, false, uint32(job.ParentPID))
	if err != nil {
		return err
	}
	defer windows.CloseHandle(parent)
	name := make([]uint16, 32768)
	size := uint32(len(name))
	if err = windows.QueryFullProcessImageName(parent, 0, &name[0], &size); err != nil {
		return err
	}
	if !strings.EqualFold(windows.UTF16ToString(name[:size]), filepath.Join(job.Target, "FilmDevelop.exe")) {
		return errors.New("更新來源程序不符")
	}
	if err = writeUpdateJSON(filepath.Join(job.Work, "ready.json"), map[string]bool{"ready": true}); err != nil {
		return err
	}
	status, err := windows.WaitForSingleObject(parent, 180000)
	if err != nil || status != windows.WAIT_OBJECT_0 {
		return errors.New("等待 FilmDevelop 結束逾時，原程式尚未替換")
	}
	launch := func(arguments ...string) (*exec.Cmd, error) {
		cmd := exec.Command(filepath.Join(job.Target, "FilmDevelop.exe"), arguments...)
		cmd.Dir = job.Target
		return cmd, cmd.Start()
	}
	if err = swapPortable(job); err != nil {
		var current portableInfo
		if readUpdateJSON(filepath.Join(job.Target, "build-info.json"), &current) == nil && current.Version == job.Previous {
			if old, launchErr := launch("--update-rollback"); launchErr == nil {
				_ = old.Process.Release()
			}
		}
		return err
	}
	app, startErr := launch("--finish-update", jobPath)
	if startErr == nil {
		exited := make(chan error, 1)
		go func() { exited <- app.Wait() }()
	waitForStartup:
		for attempt := 0; attempt < 900; attempt++ {
			var confirmed Version
			if readUpdateJSON(filepath.Join(job.Work, "confirmed.json"), &confirmed) == nil && confirmed == job.Version {
				_ = os.RemoveAll(filepath.Join(job.Work, "previous"))
				return nil
			}
			select {
			case <-exited:
				// 新版可能在確認後立即由使用者關閉，仍應視為更新完成。
				if readUpdateJSON(filepath.Join(job.Work, "confirmed.json"), &confirmed) == nil && confirmed == job.Version {
					_ = os.RemoveAll(filepath.Join(job.Work, "previous"))
					return nil
				}
				startErr = errors.New("新版在完成啟動確認前已結束")
				break waitForStartup
			case <-time.After(100 * time.Millisecond):
			}
		}
		if startErr == nil {
			_ = app.Process.Kill()
			<-exited
			startErr = errors.New("新版未完成啟動確認")
		}
	}
	if err = restorePortable(job); err != nil {
		return fmt.Errorf("%w；還原失敗，舊版保留於 %s：%v", startErr, filepath.Join(job.Work, "previous"), err)
	}
	if old, err := launch("--update-rollback"); err == nil {
		_ = old.Process.Release()
	}
	return fmt.Errorf("%w；已還原舊版程式", startErr)
}

func VerifyWindowsArchive(ctx context.Context, archive string, version Version) error {
	work, err := os.MkdirTemp("", "FilmDevelop-verify-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	folder, err := extractPortable(ctx, archive, work)
	if err != nil {
		return err
	}
	_, _, err = validatePortable(ctx, folder, version, false)
	return err
}
