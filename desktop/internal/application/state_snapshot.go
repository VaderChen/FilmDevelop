package application

// 狀態快照隔離所有可變容器；字串不可變，可共用預覽及縮圖而不重複配置。
// 常用 JSON 容器直接遞迴複製，其他型別仍經既有 JSON 路徑，保留 struct
// 標籤、omitempty、RawMessage、自訂 Marshaler 及數值轉換的傳輸語意。
func snapshotJSON(value any) any {
	switch value := value.(type) {
	case nil, bool, string, float64:
		return value
	case object:
		return snapshotMap(value)
	case map[string]object:
		return snapshotMap(value)
	case map[string]string:
		return snapshotMap(value)
	case []any:
		return snapshotSlice(value)
	case []object:
		return snapshotSlice(value)
	case []string:
		return snapshotSlice(value)
	default:
		return clone[any](value)
	}
}

func snapshotMap[T any](source map[string]T) any {
	if source == nil {
		return nil
	}
	result := make(object, len(source))
	for key, value := range source {
		result[key] = snapshotJSON(value)
	}
	return result
}

func snapshotSlice[T any](source []T) any {
	if source == nil {
		return nil
	}
	result := make([]any, len(source))
	for i, value := range source {
		result[i] = snapshotJSON(value)
	}
	return result
}
