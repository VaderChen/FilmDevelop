package engine

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

const rawConversionLimit = 512 * 1024 * 1024

type rawProbe struct {
	Recognized, Supported, DNG, Mosaic bool
	Width, Height                      uint32
}

type rawConversion struct {
	key, extension, backend, path, directory, digest string
	converterID                                      string
	size                                             int64
}

// 由 Client 的 gate 保護。快取僅保存本次工作階段的衍生 RAW，最多 8 張／512 MiB。
// 原始路徑、照片識別、配方及 EXIF 都由原有流程持有，不改寫為快取路徑。
type rawConversionCache struct {
	root          string
	entries       []rawConversion
	converterPath string
	converterInfo os.FileInfo
	converterID   string
}

func (r *rawConversionCache) converter(ctx context.Context) (string, string, error) {
	path, err := dngConverter()
	if err != nil {
		return "", "", err
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", "", err
	}
	if r.converterInfo == nil || path != r.converterPath || !os.SameFile(info, r.converterInfo) ||
		info.Size() != r.converterInfo.Size() || !info.ModTime().Equal(r.converterInfo.ModTime()) {
		fingerprint, err := rawDigest(ctx, path)
		if err != nil {
			return "", "", err
		}
		r.converterPath, r.converterInfo = path, info
		// 固定選項也是快取識別的一部分；更換轉檔器時不沿用舊輸出。
		r.converterID = fingerprint + ":lossless-dng1.4-p0-v1"
	}
	return path, r.converterID, nil
}

func (r *rawConversionCache) close() {
	if r.root != "" {
		_ = os.RemoveAll(r.root)
	}
	r.root, r.entries = "", nil
}

func rawDigest(ctx context.Context, path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 1024*1024*1024 {
		return "", errors.New("RAW 來源無法讀取或過大")
	}
	hash := sha256.New()
	buffer := make([]byte, 1024*1024)
	for {
		if err := ctx.Err(); err != nil {
			return "", err
		}
		n, err := file.Read(buffer)
		_, _ = hash.Write(buffer[:n])
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", err
		}
	}
	after, err := file.Stat()
	if err != nil || info.Size() != after.Size() || !info.ModTime().Equal(after.ModTime()) {
		return "", errors.New("RAW 來源在讀取時已變更，請重試")
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func dngConverter() (string, error) {
	var candidates []string
	if configured := os.Getenv("FILMDEVELOP_DNG_CONVERTER"); configured != "" {
		// 測試或自訂安裝位置只接受明確路徑，不從目前目錄或 PATH 搜尋。
		if !filepath.IsAbs(configured) {
			return "", errors.New("DNG Converter 路徑必須是完整路徑")
		}
		candidates = append(candidates, configured)
	} else if runtime.GOOS == "darwin" {
		if home, err := os.UserHomeDir(); err == nil {
			candidates = append(candidates, filepath.Join(home, "Applications", "Adobe DNG Converter.app", "Contents", "MacOS", "Adobe DNG Converter"))
		}
		candidates = append(candidates, "/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter")
	} else if runtime.GOOS == "windows" {
		for _, name := range []string{"ProgramW6432", "ProgramFiles"} {
			if base := os.Getenv(name); base != "" && filepath.IsAbs(base) {
				for _, suffix := range []string{"Adobe/Adobe DNG Converter/Adobe DNG Converter.exe", "Adobe/Adobe DNG Converter.exe", "Adobe DNG Converter.exe"} {
					candidates = append(candidates, filepath.Join(base, filepath.FromSlash(suffix)))
				}
			}
		}
	}
	for _, path := range candidates {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() &&
			(runtime.GOOS == "windows" || info.Mode()&0111 != 0) {
			return path, nil
		}
	}
	return "", &NativeError{Code: "rawDecoderUnavailable", Message: "此 RAW 需要補充解碼器。請從 Adobe 官方下載並安裝 DNG Converter，再按「重試」。"}
}

func (r *rawConversionCache) lookup(ctx context.Context, input contract.ImageInput) (rawConversion, bool, error) {
	extension := strings.ToLower(filepath.Ext(input.Path))
	possible := false
	for _, entry := range r.entries {
		possible = possible || entry.extension == extension && entry.backend == input.RawDecoder
	}
	if !possible {
		return rawConversion{}, false, nil
	}
	_, converterID, err := r.converter(ctx)
	if err != nil {
		return rawConversion{}, false, ctx.Err()
	}
	digest, err := rawDigest(ctx, input.Path)
	if err != nil {
		return rawConversion{}, false, err
	}
	for i, entry := range r.entries {
		if entry.key != digest || entry.extension != extension || entry.backend != input.RawDecoder || entry.converterID != converterID {
			continue
		}
		actual, err := rawDigest(ctx, entry.path)
		if err != nil || actual != entry.digest {
			r.entries = append(r.entries[:i], r.entries[i+1:]...)
			_ = os.RemoveAll(entry.directory)
			return rawConversion{}, false, ctx.Err()
		}
		r.entries = append(append(r.entries[:i], r.entries[i+1:]...), entry)
		return entry, true, nil
	}
	return rawConversion{}, false, nil
}

func (r *rawConversionCache) remember(entry rawConversion) {
	r.entries = append(r.entries, entry)
	var total int64
	for _, existing := range r.entries {
		total += existing.size
	}
	for len(r.entries) > 8 || total > rawConversionLimit {
		oldest := r.entries[0]
		r.entries = r.entries[1:]
		total -= oldest.size
		_ = os.RemoveAll(oldest.directory)
	}
}

func (c *Client) probeRAW(ctx context.Context, path string) (rawProbe, error) {
	data, err := c.callNativeLocked(ctx, "rawProbe", contract.FileRequest{Path: path}, nil)
	if err != nil {
		return rawProbe{}, err
	}
	var result rawProbe
	err = json.Unmarshal(data, &result)
	return result, err
}

func (c *Client) convertRAW(ctx context.Context, input contract.ImageInput) (entry rawConversion, err error) {
	if c.rawConversions == nil {
		c.rawConversions = &rawConversionCache{}
	}
	cache := c.rawConversions
	converter, converterID, err := cache.converter(ctx)
	if err != nil {
		return entry, err
	}
	entry.converterID = converterID
	if cache.root == "" {
		cache.root, err = os.MkdirTemp("", "filmdevelop-raw-")
		if err != nil {
			return entry, err
		}
	}
	entry.directory, err = os.MkdirTemp(cache.root, "conversion-")
	if err != nil {
		return entry, err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(entry.directory)
		}
	}()
	entry.extension, entry.backend = strings.ToLower(filepath.Ext(input.Path)), input.RawDecoder
	snapshot := filepath.Join(entry.directory, "source"+entry.extension)
	digest := sha256.New()
	if err = copySnapshot(ctx, input.Path, snapshot, digest); err != nil {
		return entry, err
	}
	defer os.Remove(snapshot)
	entry.key = hex.EncodeToString(digest.Sum(nil))
	before, err := c.probeRAW(ctx, snapshot)
	if err != nil {
		return entry, err
	}
	// GPR／較新的 DNG 壓縮也可能缺少解碼器；依實際能力判斷，不以相機或副檔名排除。
	if !before.Recognized || before.Supported || before.Width == 0 || before.Height == 0 {
		return entry, errors.New("此來源不符合補充 RAW 解碼的條件")
	}
	conversionCtx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(conversionCtx, converter, "-c", "-dng1.4", "-p0", "-d", entry.directory, "-o", "image.dng", snapshot)
	configureCommand(cmd)
	cmd.WaitDelay = 5 * time.Second
	var log limitedLog
	cmd.Stdout, cmd.Stderr = &log, &log
	if err = cmd.Run(); err != nil {
		if conversionCtx.Err() != nil {
			return entry, conversionCtx.Err()
		}
		return entry, fmt.Errorf("補充 RAW 解碼失敗，請確認 Adobe DNG Converter 支援此相機：%w", err)
	}
	if err = ctx.Err(); err != nil {
		return entry, err
	}
	entry.path = filepath.Join(entry.directory, "image.dng")
	info, err := os.Lstat(entry.path)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > rawConversionLimit {
		return entry, errors.New("補充解碼未產生有效的 RAW 檔案")
	}
	after, err := c.probeRAW(ctx, entry.path)
	if err != nil {
		return entry, err
	}
	// 同時檢查 DNG、感光馬賽克與完整有效區域；相機 JPEG 或縮小代理圖不得進入編輯。
	if !after.Recognized || !after.Supported || !after.DNG || (before.Mosaic && !after.Mosaic) ||
		after.Width < before.Width || after.Height < before.Height {
		return entry, errors.New("補充解碼未保留完整 RAW 感光資料")
	}
	entry.size = info.Size()
	entry.digest, err = rawDigest(ctx, entry.path)
	return entry, err
}

// 所有接收 ImageInput 的原生工作共用同一個補充解碼入口。
func rawInput(value any) (contract.ImageInput, func(contract.ImageInput) any, bool) {
	switch request := value.(type) {
	case contract.RenderJob:
		return request.Input, func(input contract.ImageInput) any { request.Input = input; return request }, true
	case contract.AnalysisRequest:
		return request.Input, func(input contract.ImageInput) any { request.Input = input; return request }, true
	case contract.RepairRequest:
		return request.Input, func(input contract.ImageInput) any { request.Input = input; return request }, true
	case contract.ThumbnailRequest:
		return contract.ImageInput{Path: request.Path, RawDecoder: "system"}, func(input contract.ImageInput) any { request.Path = input.Path; return request }, true
	default:
		return contract.ImageInput{}, nil, false
	}
}

func (c *Client) callWithRAWConversion(ctx context.Context, method string, value any, progress func(float64)) (json.RawMessage, error) {
	input, replace, eligible := rawInput(value)
	if !eligible {
		return c.callNativeLocked(ctx, method, value, progress)
	}
	render := func(entry rawConversion) (json.RawMessage, error) {
		converted := input
		converted.Path, converted.RawDecoder = entry.path, "software"
		result, err := c.callNativeLocked(ctx, method, replace(converted), progress)
		if err != nil {
			return nil, err
		}
		// 縮圖契約只接受固定的三個欄位；原檔仍是列表快取與方向校正的識別。
		if method == "thumbnail" {
			return result, nil
		}
		var fields map[string]any
		if err = json.Unmarshal(result, &fields); err != nil || fields == nil {
			return nil, errors.New("補充解碼的引擎回覆格式不符")
		}
		fields["rawConversion"] = "adobe-dng"
		fields["systemRAWFallback"] = input.RawDecoder == "system"
		return json.Marshal(fields)
	}
	if c.rawConversions != nil {
		entry, found, err := c.rawConversions.lookup(ctx, input)
		if err != nil {
			return nil, err
		}
		if found {
			return render(entry)
		}
	}
	result, err := c.callNativeLocked(ctx, method, value, progress)
	var native *NativeError
	if !errors.As(err, &native) {
		return result, err
	}
	required := native.Code == "rawConversionRequired"
	if !required && method == "thumbnail" && native.Code == "decodeFailed" {
		// 系統也讀不到內嵌縮圖時，再探測 RAW；一般損壞圖片不交給 Converter。
		probe, probeErr := c.probeRAW(ctx, input.Path)
		required = probeErr == nil && probe.Recognized && !probe.Supported
	}
	if !required {
		return result, err
	}
	entry, err := c.convertRAW(ctx, input)
	if err != nil {
		return nil, err
	}
	result, err = render(entry)
	if err != nil {
		_ = os.RemoveAll(entry.directory)
		return nil, err
	}
	c.rawConversions.remember(entry)
	return result, nil
}
