package application

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"

	"github.com/VaderChen/FilmDevelop/internal/contract"
	"github.com/VaderChen/FilmDevelop/internal/storage"
)

const previewCacheEntries = 6
const previewCacheBytes = 32 * 1024 * 1024

// 僅保存顯示用成品，不持有原始浮點影像；呼叫端持有 App.mu。
type previewResultCache struct {
	entries []cachedPreview
	bytes   int
}
type cachedPreview struct {
	key, output string
	result      json.RawMessage
}

func (c *previewResultCache) get(key string) (cachedPreview, bool) {
	for i, entry := range c.entries {
		if entry.key == key {
			copy(c.entries[i:], c.entries[i+1:])
			c.entries[len(c.entries)-1] = entry
			return entry, true
		}
	}
	return cachedPreview{}, false
}
func (c *previewResultCache) put(entry cachedPreview) {
	size := len(entry.output) + len(entry.result)
	if entry.key == "" || size > previewCacheBytes {
		return
	}
	for i, current := range c.entries {
		if current.key == entry.key {
			c.bytes -= len(current.output) + len(current.result)
			c.entries = append(c.entries[:i], c.entries[i+1:]...)
			break
		}
	}
	for len(c.entries) >= previewCacheEntries || c.bytes+size > previewCacheBytes {
		c.bytes -= len(c.entries[0].output) + len(c.entries[0].result)
		c.entries[0] = cachedPreview{}
		c.entries = c.entries[1:]
	}
	c.entries = append(c.entries, entry)
	c.bytes += size
}

// 來源內容及整份運算契約共同識別成品；時間戳未變但檔案內容改變也會失效。
func previewResultKey(ctx context.Context, job contract.RenderJob) (string, error) {
	fingerprint, err := storage.Fingerprint(ctx, job.Input.Path)
	if err != nil {
		return "", err
	}
	job.Output.Path = ""
	data, err := json.Marshal(struct {
		Job         contract.RenderJob
		Fingerprint string
	}{job, fingerprint})
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}
