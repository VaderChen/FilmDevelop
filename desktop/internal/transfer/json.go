package transfer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

func readJSON(ctx context.Context, url string, target any) error {
	request, e := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if e != nil {
		return e
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "FilmDevelop")
	response, e := Client.Do(request)
	if e != nil {
		return e
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("遠端服務回應 HTTP %d", response.StatusCode)
	}
	data, e := io.ReadAll(io.LimitReader(response.Body, 8*1024*1024+1))
	if e != nil {
		return e
	}
	if len(data) > 8*1024*1024 {
		return errors.New("遠端 JSON 回應過大")
	}
	return json.Unmarshal(data, target)
}
