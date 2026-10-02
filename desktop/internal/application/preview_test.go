package application

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/host"
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

type previewBackend struct {
	thumbnail func(context.Context, string) ([]byte, error)
	render    func(context.Context, contract.RenderJob) (json.RawMessage, error)
}

func TestLivePreviewPreservesSettledAndExportResolution(t *testing.T) {
	a := testApp(t)
	a.preferences.OriginalResolution = true
	a.interaction = "拖曳中"
	live := a.job("", a.defaults["original"], true)
	if live.Policy.FullResolution || live.PreviewMaxPixel != 1024 || live.Output.Format != "jpeg" {
		t.Fatal("拖曳時沒有沿用 Swift 編輯縮圖流程")
	}
	if !a.job("", a.defaults["original"], false).Policy.FullResolution {
		t.Fatal("拖曳狀態影響匯出精度")
	}
	a.interaction = ""
	settled := a.job("", a.defaults["original"], true)
	if !settled.Policy.FullResolution || settled.PreviewMaxPixel != 2048 {
		t.Fatal("拖曳結束未恢復原尺寸設定")
	}
}

func (b previewBackend) Call(ctx context.Context, method string, input any, _ func(float64)) (json.RawMessage, error) {
	request := input.(contract.ThumbnailRequest)
	data, err := b.thumbnail(ctx, request.Path)
	if err != nil {
		return nil, err
	}
	return json.Marshal(contract.ThumbnailResult{ImageData: base64.StdEncoding.EncodeToString(data), Width: 4, Height: 3})
}
func (b previewBackend) Render(ctx context.Context, job contract.RenderJob, _ func(float64)) (json.RawMessage, error) {
	return b.render(ctx, job)
}

func TestPreviewUsesDirectoryThumbnailBeforeRendering(t *testing.T) {
	for _, warm := range []bool{false, true} {
		t.Run(map[bool]string{false: "冷快取", true: "列表已有縮圖"}[warm], func(t *testing.T) {
			a := testApp(t)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			a.ctx = ctx
			t.Cleanup(func() { cancel(); a.workers.Wait() })
			bitmap := image.NewRGBA(image.Rect(0, 0, 4, 3))
			bitmap.Set(0, 0, color.RGBA{R: 255, A: 255})
			var thumb, output bytes.Buffer
			_ = jpeg.Encode(&thumb, bitmap, nil)
			_ = png.Encode(&output, bitmap)
			path := filepath.Join(t.TempDir(), "照片.jpg")
			if err := os.WriteFile(path, thumb.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			path, _ = photos.Canonical(path)
			directory, err := photos.Scan(ctx, filepath.Dir(path))
			if err != nil {
				t.Fatal(err)
			}
			a.installDirectory(directory)
			id := photos.Identity(path)
			thumbnailURL := "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(thumb.Bytes())
			if warm {
				a.thumbnails[id] = thumbnailURL
			}
			recipe := a.defaults["filmEktar100"]
			fields := recipeFields(recipe)
			fields["skinSmoothing"] = float64(40)
			recipe = withFields(recipe, fields)
			fingerprint, _ := storage.Fingerprint(ctx, path)
			if err = a.store.Save(storage.PhotoKey(path, fingerprint), storage.Document{Version: 1, Selected: recipe.Style, Recipes: map[string]contract.Recipe{recipe.Style: recipe}}); err != nil {
				t.Fatal(err)
			}
			var mu sync.Mutex
			shown, thumbnailCalls, renderCalls, subjectRender := false, 0, 0, false
			phase := ""
			subjectShown := false
			var failures []string
			state := object{}
			a.emit = func(name string, payload any) {
				if name != "handleNativeState" {
					return
				}
				mu.Lock()
				defer mu.Unlock()
				for key, value := range payload.(object) {
					state[key] = value
				}
				if state["subjectMask"].(object)["detecting"] == true {
					failures = append(failures, "一般預覽誤報成獨立遮罩偵測")
				}
				phase, _ = state["previewPhase"].(string)
				if phase == "subject" {
					subjectShown = true
				}
				if state["loadingPreviewImage"] == thumbnailURL && state["outputImage"] == "" {
					shown = true
				}
			}
			backend := previewBackend{
				thumbnail: func(context.Context, string) ([]byte, error) {
					mu.Lock()
					thumbnailCalls++
					mu.Unlock()
					return thumb.Bytes(), nil
				},
				render: func(_ context.Context, job contract.RenderJob) (json.RawMessage, error) {
					// 列表的可視範圍更新，不得在初次顯影完成前丟棄目前底圖。
					_ = a.requestThumbnails(nil)
					a.mu.Lock()
					retained := a.thumbnails[id] == thumbnailURL
					a.mu.Unlock()
					mu.Lock()
					if !retained {
						failures = append(failures, "初次顯影途中丟棄了列表底圖")
					}
					if !shown {
						failures = append(failures, "縮圖顯示前就開始完整渲染")
					}
					renderCalls++
					if job.Recipe.Style == recipe.Style && job.Recipe.DetectSubject {
						subjectRender = true
						if phase != "subject" {
							failures = append(failures, "主體偵測沒有進度提示")
						}
					} else if phase != "render" {
						failures = append(failures, "預覽顯影沒有進度提示")
					}
					mu.Unlock()
					result, _ := json.Marshal(object{"sourceWidth": 4, "sourceHeight": 3, "sourceImage": thumbnailURL, "cropImage": thumbnailURL})
					return result, os.WriteFile(job.Output.Path, output.Bytes(), 0600)
				},
			}
			a.services, _ = host.New(backend)
			a.thumbnailServices, _ = host.New(backend)
			if err = a.OpenImage(path); err != nil {
				t.Fatal(err)
			}
			a.workers.Wait()
			mu.Lock()
			defer mu.Unlock()
			if len(failures) > 0 {
				t.Fatal(failures)
			}
			if !shown || renderCalls != 1 || !subjectRender || !subjectShown || phase != "" || a.previewError != nil || a.outputPreview == "" || a.sourcePreview != thumbnailURL || a.cropPreview != thumbnailURL || a.loadingPreview != a.thumbnails[id] {
				t.Fatal("縮圖、已調整預覽或背景遮罩流程不符", shown, renderCalls, subjectRender, a.previewError)
			}
			if (warm && thumbnailCalls != 0) || (!warm && thumbnailCalls != 1) {
				t.Fatal("重複解碼列表縮圖", thumbnailCalls)
			}
		})
	}
}

func TestLateThumbnailCannotReplaceCurrentPhoto(t *testing.T) {
	a := testApp(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	a.ctx = ctx
	t.Cleanup(func() { cancel(); a.workers.Wait() })
	var thumbnail bytes.Buffer
	_ = jpeg.Encode(&thumbnail, image.NewRGBA(image.Rect(0, 0, 4, 3)), nil)
	path := filepath.Join(t.TempDir(), "上一張.jpg")
	if err := os.WriteFile(path, thumbnail.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	directory, err := photos.Scan(ctx, filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	a.installDirectory(directory)
	entry := directory.Entries[0]
	started, release := make(chan struct{}), make(chan struct{})
	a.thumbnailServices, _ = host.New(previewBackend{thumbnail: func(ctx context.Context, _ string) ([]byte, error) {
		close(started)
		select {
		case <-release:
			return thumbnail.Bytes(), nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}})
	a.mu.Lock()
	a.source = entry.Path
	work := a.startThumbnail(entry)
	a.mu.Unlock()
	<-started
	a.mu.Lock()
	a.source = "另一張.jpg"
	a.loadingPreview = "另一張的縮圖"
	a.mu.Unlock()
	close(release)
	<-work.done
	if a.loadingPreview != "另一張的縮圖" {
		t.Fatal("過期縮圖覆蓋了目前照片")
	}
}
