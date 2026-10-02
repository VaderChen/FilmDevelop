package updater

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// 子程序只存在於 Windows 測試執行檔，使用真正更新工具驗證程序交接與檔案鎖。
func TestMain(m *testing.M) {
	if os.Getenv("FILMDEVELOP_UPDATER_CHILD") == "1" {
		if err := portableChild(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func portableChild() error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	var info portableInfo
	if err = readUpdateJSON(filepath.Join(filepath.Dir(executable), "build-info.json"), &info); err != nil {
		return err
	}
	if len(os.Args) > 1 && os.Args[1] == "--finish-update" {
		if os.Getenv("FILMDEVELOP_TEST_NEW_FAILURE") == "1" {
			return fmt.Errorf("測試用新版啟動失敗")
		}
		return Confirm(os.Args, info.Version)
	}
	if len(os.Args) > 1 && os.Args[1] == "--update-rollback" {
		return os.WriteFile(os.Getenv("FILMDEVELOP_TEST_ROLLBACK"), []byte("restarted"), 0600)
	}
	version, err := Parse(os.Getenv("FILMDEVELOP_TEST_VERSION"))
	if err != nil {
		return err
	}
	prepared, err := Prepare(context.Background(), os.Getenv("FILMDEVELOP_TEST_ARCHIVE"), version)
	if err != nil {
		return err
	}
	if err = writeUpdateJSON(os.Getenv("FILMDEVELOP_TEST_JOB"), prepared.job); err != nil {
		return err
	}
	return prepared.Launch()
}

func TestWindowsPortableUpdateProcesses(t *testing.T) {
	helperPath := os.Getenv("FILMDEVELOP_TEST_UPDATER")
	if helperPath == "" {
		t.Skip("需指定此次建置的 FILMDEVELOP_TEST_UPDATER")
	}
	helper, err := os.ReadFile(helperPath)
	if err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	program, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	for _, failStartup := range []bool{false, true} {
		name := "success"
		if failStartup {
			name = "rollback"
		}
		t.Run(name, func(t *testing.T) {
			root := t.TempDir()
			target, source := filepath.Join(root, "免安裝 程式"), filepath.Join(root, "source")
			old, next := Version{"1.26.1002", "1323"}, Version{"1.26.1003", "1000"}
			binaries := map[string][]byte{"FilmDevelop.exe": program, "filmdevelop-update.exe": helper}
			portableFixture(t, target, old, binaries)
			portableFixture(t, source, next, binaries)
			private := filepath.Join(target, "保留照片.txt")
			if err := os.WriteFile(private, []byte("my photo"), 0600); err != nil {
				t.Fatal(err)
			}
			archive := filepath.Join(root, "portable.zip")
			fixtureZIP(t, source, archive)
			jobPath, rollback := filepath.Join(root, "child-job.json"), filepath.Join(root, "rollback.txt")
			failure := "0"
			if failStartup {
				failure = "1"
			}
			ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
			defer cancel()
			parent := exec.CommandContext(ctx, filepath.Join(target, "FilmDevelop.exe"))
			parent.Env = append(os.Environ(), "FILMDEVELOP_UPDATER_CHILD=1", "FILMDEVELOP_TEST_ARCHIVE="+archive,
				"FILMDEVELOP_TEST_VERSION="+next.Tag(), "FILMDEVELOP_TEST_JOB="+jobPath,
				"FILMDEVELOP_TEST_ROLLBACK="+rollback, "FILMDEVELOP_TEST_NEW_FAILURE="+failure)
			if output, err := parent.CombinedOutput(); err != nil {
				t.Fatalf("舊程序交接失敗：%v %s", err, output)
			}
			var job portableJob
			if err := readUpdateJSON(jobPath, &job); err != nil {
				t.Fatal(err)
			}
			var result struct {
				Passed bool   `json:"passed"`
				Error  string `json:"error"`
			}
			for {
				if err := readUpdateJSON(filepath.Join(job.Work, "result.json"), &result); err == nil {
					break
				}
				select {
				case <-ctx.Done():
					t.Fatal("更新程序未完成")
				case <-time.After(100 * time.Millisecond):
				}
			}
			if result.Passed == failStartup {
				t.Fatalf("更新結果不符：%+v", result)
			}
			want := next
			if failStartup {
				want = old
				for {
					if _, err := os.Stat(rollback); err == nil {
						break
					}
					select {
					case <-ctx.Done():
						t.Fatal("舊版未重新啟動")
					case <-time.After(100 * time.Millisecond):
					}
				}
			}
			if _, _, err := validatePortable(context.Background(), target, want, true); err != nil {
				t.Fatal(err)
			}
			if data, _ := os.ReadFile(private); string(data) != "my photo" {
				t.Fatal("使用者檔案未保留")
			}
			// Windows 執行檔鎖在程序結束時釋放；等待測試子程序離開後再清理。
			time.Sleep(200 * time.Millisecond)
		})
	}
}
