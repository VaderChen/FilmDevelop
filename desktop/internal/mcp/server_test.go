package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"testing"
)

func TestLoopbackMCPAuthorizationAndContracts(t *testing.T) {
	called := 0
	definitions := []Object{{"name": "echo", "inputSchema": Object{"type": "object", "properties": Object{"text": Object{"type": "string"}}, "required": []string{"text"}}}}
	s, err := Start(t.TempDir(), "127.0.0.1:0", definitions, func(ctx context.Context, name string, args Object) (Object, error) { called++; return Text(args), nil })
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	body := []byte(`{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"text":"測試"}}}`)
	request := func(token, origin string, data []byte) (int, Object) {
		r, _ := http.NewRequest("POST", s.Endpoint, bytes.NewReader(data))
		r.Header.Set("Content-Type", "application/json")
		r.Header.Set("Authorization", token)
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		response, err := http.DefaultClient.Do(r)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		bytes, _ := io.ReadAll(response.Body)
		var value Object
		_ = json.Unmarshal(bytes, &value)
		return response.StatusCode, value
	}
	if status, _ := request("", "", body); status != 401 {
		t.Fatal(status)
	}
	if status, _ := request("Bearer "+s.token, "https://untrusted.invalid", body); status != 403 {
		t.Fatal(status)
	}
	status, result := request("Bearer "+s.token, "", body)
	if status != 200 || result["error"] != nil || called != 1 {
		t.Fatal(status, result)
	}
	_, result = request("Bearer "+s.token, "", []byte(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"unknown":1}}}`))
	if result["error"] == nil || called != 1 {
		t.Fatal("未驗證參數")
	}
	info, err := os.Stat(s.ConnectionFile)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("權杖檔案權限不符")
	}
}
