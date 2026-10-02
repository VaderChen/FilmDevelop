package updater

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type portableJob struct {
	Schema         int     `json:"schema"`
	ParentPID      int     `json:"parentPID"`
	Target         string  `json:"target"`
	Work           string  `json:"work"`
	Version        Version `json:"version"`
	Previous       Version `json:"previous"`
	SourceManifest string  `json:"sourceManifest"`
}

func writeUpdateJSON(name string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(name), ".state-")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	if _, err = temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err = temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), name)
}

func preparePortableAt(ctx context.Context, target, archive string, version Version, pid int) (*portableJob, error) {
	target, err := filepath.EvalSymlinks(target)
	if err != nil {
		return nil, err
	}
	target, err = filepath.Abs(target)
	if err != nil || target == filepath.Dir(target) {
		return nil, errors.New("目前程式目錄無效")
	}
	previous, _, err := validatePortable(ctx, target, Version{}, true)
	if err != nil {
		return nil, fmt.Errorf("目前程式檔案驗證失敗：%w", err)
	}
	if !version.After(previous.Version) {
		return nil, errors.New("更新套件必須比目前版本新")
	}
	manifest, _, err := updateHash(ctx, filepath.Join(target, "files.json"))
	if err != nil {
		return nil, err
	}
	work, err := os.MkdirTemp(filepath.Dir(target), ".filmdevelop-update-")
	if err != nil {
		return nil, fmt.Errorf("程式目錄需要寫入權限才能更新：%w", err)
	}
	success := false
	defer func() {
		if !success {
			os.RemoveAll(work)
		}
	}()
	staged, err := extractPortable(ctx, archive, work)
	if err != nil {
		return nil, err
	}
	if _, _, err = validatePortable(ctx, staged, version, false); err != nil {
		return nil, err
	}
	// 工具位於程式目錄之外，關閉 GUI 後才能在 Windows 重新命名整個程式目錄。
	input, err := os.Open(filepath.Join(staged, "filmdevelop-update.exe"))
	if err != nil {
		return nil, err
	}
	defer input.Close()
	output, err := os.OpenFile(filepath.Join(work, "update.exe"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0700)
	if err != nil {
		return nil, err
	}
	_, copyErr := io.Copy(output, updateReader{ctx, input})
	err = errors.Join(copyErr, output.Close())
	if err != nil {
		return nil, err
	}
	job := &portableJob{1, pid, target, work, version, previous.Version, manifest}
	if err = writeUpdateJSON(filepath.Join(work, "job.json"), job); err != nil {
		return nil, err
	}
	success = true
	return job, nil
}

func loadPortableJob(name string) (*portableJob, error) {
	var job portableJob
	if err := readUpdateJSON(name, &job); err != nil {
		return nil, err
	}
	actual, err := filepath.EvalSymlinks(filepath.Dir(name))
	if err != nil {
		return nil, err
	}
	actual, err = filepath.Abs(actual)
	if err != nil {
		return nil, err
	}
	if job.Schema != 1 || job.ParentPID <= 0 || filepath.Base(name) != "job.json" || !filepath.IsAbs(job.Target) || filepath.Clean(job.Target) != job.Target || job.Work != actual || filepath.Dir(job.Target) != filepath.Dir(actual) || !strings.HasPrefix(filepath.Base(actual), ".filmdevelop-update-") || job.Target == actual || !job.Version.After(job.Previous) || !digestPattern.MatchString("sha256:"+job.SourceManifest) {
		return nil, errors.New("更新交接資料無效")
	}
	return &job, nil
}

func retryUpdateRename(from, to string) error {
	var err error
	for attempt := 0; attempt < 60; attempt++ {
		if err = os.Rename(from, to); err == nil {
			return nil
		}
		// 等待剛結束的原生工作程序釋放 DLL；不強制關閉使用者其他程序。
		if _, statErr := os.Lstat(from); statErr != nil {
			return err
		}
		if _, statErr := os.Lstat(to); !os.IsNotExist(statErr) {
			return err
		}
		time.Sleep(250 * time.Millisecond)
	}
	return err
}

func swapPortable(job *portableJob) error {
	ctx := context.Background()
	if _, _, err := validatePortable(ctx, filepath.Join(job.Work, "FilmDevelop"), job.Version, false); err != nil {
		return err
	}
	_, managed, err := validatePortable(ctx, job.Target, job.Previous, true)
	if err != nil {
		return err
	}
	hash, _, err := updateHash(ctx, filepath.Join(job.Target, "files.json"))
	if err != nil || hash != job.SourceManifest {
		return errors.New("目前程式已被其他更新變更")
	}
	previous, staged := filepath.Join(job.Work, "previous"), filepath.Join(job.Work, "FilmDevelop")
	if err = retryUpdateRename(job.Target, previous); err != nil {
		return err
	}
	if err = preservePortableExtras(previous, staged, managed); err == nil {
		err = retryUpdateRename(staged, job.Target)
	}
	if err != nil {
		restoreErr := retryUpdateRename(previous, job.Target)
		return errors.Join(err, restoreErr)
	}
	return nil
}

func restorePortable(job *portableJob) error {
	previous := filepath.Join(job.Work, "previous")
	if _, err := os.Stat(previous); err != nil {
		return err
	}
	if err := retryUpdateRename(job.Target, filepath.Join(job.Work, "failed")); err != nil {
		return err
	}
	return retryUpdateRename(previous, job.Target)
}
