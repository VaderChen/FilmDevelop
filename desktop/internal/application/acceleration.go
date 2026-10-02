package application

import "errors"

func (a *App) supportsBackend(key, backend string) bool {
	values, _ := a.capabilities[key].([]any)
	for _, value := range values {
		if value == backend {
			return true
		}
	}
	return false
}

// 每次啟動以當下能力核對持久化設定；不提供的選項回到系統預設。
// RAW 選單可為空，但一般 JPEG／PNG 仍沿用 system 解碼路徑。
func (a *App) reconcileAcceleration() error {
	a.mu.Lock()
	changed := false
	for _, field := range []struct {
		key     string
		current *string
	}{
		{"computeBackends", &a.computeBackend}, {"rawDecoders", &a.rawDecoder},
	} {
		if a.supportsBackend(field.key, *field.current) {
			continue
		}
		next := "system"
		if values, ok := a.capabilities[field.key].([]any); ok && len(values) > 0 && !a.supportsBackend(field.key, next) {
			next, _ = values[0].(string)
		}
		if *field.current != next {
			*field.current = next
			changed = true
		}
	}
	a.mu.Unlock()
	if changed {
		return a.savePreferences()
	}
	return nil
}

// 呼叫端持有 a.mu；只追蹤切換要求啟動的預覽，避免普通顯影或過期回覆開啟對話框。
func (a *App) switchingComputeBackend() bool {
	return a.computeSwitchPreparing || (a.rendering && a.computeSwitchRevision != 0 && a.computeSwitchRevision == a.revision)
}

func (a *App) setComputeBackend(backend string) error {
	if backend != "system" && backend != "vulkan" {
		return errors.New("不支援此運算或解析後端")
	}
	a.mu.Lock()
	if !a.supportsBackend("computeBackends", backend) {
		a.mu.Unlock()
		return errors.New("此電腦無法使用選取的運算後端")
	}
	previous := a.computeBackend
	if previous == backend {
		a.mu.Unlock()
		return a.savePreferences()
	}
	a.computeBackend = backend
	a.computeSwitchPreparing = true
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		a.computeSwitchPreparing = false
		a.mu.Unlock()
	}()
	a.state()
	if err := a.savePreferences(); err != nil {
		a.mu.Lock()
		a.computeBackend = previous
		a.mu.Unlock()
		return err
	}
	a.startPreview(true)
	return nil
}

func (a *App) setRAWDecoderBackend(backend string) error {
	if backend != "system" && backend != "software" {
		return errors.New("不支援此 RAW 解析後端")
	}
	a.mu.Lock()
	if !a.supportsBackend("rawDecoders", backend) {
		a.mu.Unlock()
		return errors.New("系統未提供選取的 RAW 解析器")
	}
	previous := a.rawDecoder
	a.rawDecoder = backend
	a.mu.Unlock()
	if err := a.savePreferences(); err != nil {
		a.mu.Lock()
		a.rawDecoder = previous
		a.mu.Unlock()
		return err
	}
	if previous != backend {
		a.mu.Lock()
		a.sourcePreview = ""
		a.mu.Unlock()
		a.preview()
	} else {
		a.state()
	}
	return nil
}
