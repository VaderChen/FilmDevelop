// Package mcp 提供兩平台共用、只接受本機連線與權杖驗證的 MCP HTTP 服務。
package mcp

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Object = map[string]any
type Handler func(context.Context, string, Object) (Object, error)
type Server struct {
	server                   *http.Server
	listener                 net.Listener
	token                    string
	Endpoint, ConnectionFile string
	Definitions              []Object
	Handle                   Handler
	mu                       sync.Mutex
	active                   map[string]map[string]context.CancelFunc
}

var Versions = []string{"2025-11-25", "2025-06-18", "2025-03-26"}

func Start(directory, address string, definitions []Object, handler Handler) (*Server, error) {
	listener, err := net.Listen("tcp4", address)
	if err != nil {
		return nil, err
	}
	s := &Server{listener: listener, Endpoint: "http://" + listener.Addr().String() + "/mcp", ConnectionFile: filepath.Join(directory, "connection.json"), Definitions: definitions, Handle: handler, active: map[string]map[string]context.CancelFunc{}}
	success := false
	defer func() {
		if !success {
			listener.Close()
		}
	}()
	if err = os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	if err = os.Chmod(directory, 0700); err != nil {
		return nil, err
	}
	if data, e := os.ReadFile(s.ConnectionFile); e == nil {
		var value struct {
			Servers map[string]struct {
				Headers map[string]string `json:"headers"`
			} `json:"mcpServers"`
		}
		if json.Unmarshal(data, &value) == nil {
			s.token = strings.TrimPrefix(value.Servers["FilmYourPhoto"].Headers["Authorization"], "Bearer ")
		}
	}
	if len(s.token) < 32 {
		var token [32]byte
		if _, err = rand.Read(token[:]); err != nil {
			return nil, err
		}
		s.token = hex.EncodeToString(token[:])
	}
	configuration := Object{"mcpServers": Object{"FilmYourPhoto": Object{"url": s.Endpoint, "headers": Object{"Authorization": "Bearer " + s.token}}}}
	data, _ := json.MarshalIndent(configuration, "", "  ")
	file, err := os.CreateTemp(directory, ".connection-")
	if err != nil {
		return nil, err
	}
	name := file.Name()
	defer os.Remove(name)
	if _, err = file.Write(data); err != nil {
		file.Close()
		return nil, err
	}
	if err = file.Close(); err != nil {
		return nil, err
	}
	if err = os.Rename(name, s.ConnectionFile); err != nil {
		return nil, err
	}
	s.server = &http.Server{Handler: s, ReadHeaderTimeout: 15 * time.Second, ReadTimeout: 20 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 16 * 1024}
	success = true
	go s.server.Serve(listener)
	return s, nil
}
func (s *Server) Close() {
	s.mu.Lock()
	for _, requests := range s.active {
		for _, cancel := range requests {
			cancel()
		}
	}
	s.mu.Unlock()
	_ = s.server.Close()
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	_, port, _ := net.SplitHostPort(s.listener.Addr().String())
	host := strings.ToLower(r.Host)
	if host != "127.0.0.1:"+port && host != "localhost:"+port {
		http.Error(w, "Host 無效", 403)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		u, err := url.Parse(origin)
		if err != nil || u.Scheme != "http" || u.User != nil || (u.Host != "127.0.0.1:"+port && u.Host != "localhost:"+port) || u.Path != "" || u.RawQuery != "" || u.Fragment != "" {
			http.Error(w, "Origin 無效", 403)
			return
		}
	}
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.token)) != 1 {
		http.Error(w, "需要權杖", 401)
		return
	}
	if r.URL.Path != "/mcp" {
		http.NotFound(w, r)
		return
	}
	if r.Method != "POST" {
		w.WriteHeader(405)
		return
	}
	media, _, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if media != "application/json" {
		w.WriteHeader(415)
		return
	}
	if v := r.Header.Get("MCP-Protocol-Version"); v != "" && !contains(Versions, v) {
		w.WriteHeader(400)
		return
	}
	var request struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  Object          `json:"params"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 2*1024*1024))
	if err := decoder.Decode(&request); err != nil || decoder.Decode(new(any)) != io.EOF || request.JSONRPC != "2.0" || request.Method == "" {
		write(w, Object{"jsonrpc": "2.0", "id": nil, "error": Object{"code": -32600, "message": "JSON-RPC 請求格式錯誤"}})
		return
	}
	id := string(request.ID)
	if id == "" {
		if request.Method == "notifications/cancelled" {
			raw, _ := json.Marshal(request.Params["requestId"])
			s.mu.Lock()
			requests := s.active[string(raw)]
			if len(requests) == 1 {
				for _, cancel := range requests {
					cancel()
				}
			}
			s.mu.Unlock()
		}
		w.WriteHeader(202)
		return
	}
	var idValue any
	if json.Unmarshal(request.ID, &idValue) != nil {
		w.WriteHeader(400)
		return
	}
	switch idValue.(type) {
	case string, float64:
	default:
		w.WriteHeader(400)
		return
	}
	result := func(value any) { write(w, Object{"jsonrpc": "2.0", "id": idValue, "result": value}) }
	failure := func(code int, msg string) {
		write(w, Object{"jsonrpc": "2.0", "id": idValue, "error": Object{"code": code, "message": msg}})
	}
	switch request.Method {
	case "initialize":
		v, _ := request.Params["protocolVersion"].(string)
		if v == "" {
			failure(-32602, "缺少協定版本")
			return
		}
		if !contains(Versions, v) {
			v = Versions[0]
		}
		result(Object{"protocolVersion": v, "capabilities": Object{"tools": Object{"listChanged": false}}, "serverInfo": Object{"name": "FilmYourPhoto", "version": "1.0.0"}, "instructions": "操作同步更新 FilmDevelop。匯出預設拒絕覆寫；使用 get_state 查詢 AI 進度。"})
	case "ping":
		result(Object{})
	case "tools/list":
		result(Object{"tools": s.Definitions})
	case "tools/call":
		name, _ := request.Params["name"].(string)
		args, ok := request.Params["arguments"].(map[string]any)
		if request.Params["arguments"] == nil {
			args = Object{}
			ok = true
		}
		var definition Object
		for _, d := range s.Definitions {
			if d["name"] == name {
				definition = d
			}
		}
		if definition == nil || !ok {
			failure(-32602, "工具或參數無效")
			return
		}
		if err := Validate(args, definition["inputSchema"].(Object)); err != nil {
			failure(-32602, err.Error())
			return
		}
		ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 2*time.Minute)
		defer cancel()
		key := strconv.FormatInt(time.Now().UnixNano(), 10)
		s.mu.Lock()
		count := 0
		for _, requests := range s.active {
			count += len(requests)
		}
		if count >= 32 {
			s.mu.Unlock()
			w.WriteHeader(503)
			return
		}
		if s.active[id] == nil {
			s.active[id] = map[string]context.CancelFunc{}
		}
		s.active[id][key] = cancel
		s.mu.Unlock()
		defer func() {
			s.mu.Lock()
			delete(s.active[id], key)
			if len(s.active[id]) == 0 {
				delete(s.active, id)
			}
			s.mu.Unlock()
		}()
		value, err := s.Handle(ctx, name, args)
		if err != nil {
			value = Object{"isError": true, "content": []Object{{"type": "text", "text": err.Error()}}}
		}
		result(value)
	default:
		failure(-32601, "工具方法不存在")
	}
}
func write(w http.ResponseWriter, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(value)
}
func contains(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}
func Text(value any) Object {
	data, _ := json.Marshal(value)
	return Object{"content": []Object{{"type": "text", "text": string(data)}}, "isError": false}
}
func Validate(value any, schema Object) error {
	switch schema["type"] {
	case "object":
		obj, ok := value.(map[string]any)
		if !ok {
			return errors.New("參數必須是物件")
		}
		properties, _ := schema["properties"].(Object)
		required, _ := schema["required"].([]string)
		for _, k := range required {
			if _, ok := obj[k]; !ok {
				return fmt.Errorf("缺少參數：%s", k)
			}
		}
		if schema["minProperties"] == 1 && len(obj) == 0 {
			return errors.New("調整不可為空")
		}
		for k, v := range obj {
			p, ok := properties[k].(Object)
			if !ok {
				return fmt.Errorf("未知參數：%s", k)
			}
			if err := Validate(v, p); err != nil {
				return fmt.Errorf("%s：%w", k, err)
			}
		}
	case "string":
		text, ok := value.(string)
		if !ok || strings.ContainsRune(text, 0) {
			return errors.New("字串格式錯誤")
		}
		length := len([]rune(strings.TrimSpace(text)))
		if n, ok := schema["minLength"].(int); ok && length < n {
			return errors.New("字串不可為空")
		}
		if n, ok := schema["maxLength"].(int); ok && length > n {
			return errors.New("字串過長")
		}
	case "boolean":
		if _, ok := value.(bool); !ok {
			return errors.New("必須是布林值")
		}
	case "number", "integer":
		v, ok := value.(float64)
		if !ok {
			return errors.New("必須是數值")
		}
		if schema["type"] == "integer" && v != float64(int64(v)) {
			return errors.New("必須是整數")
		}
		if n, ok := schema["minimum"].(float64); ok && v < n {
			return errors.New("數值低於範圍")
		}
		if n, ok := schema["maximum"].(float64); ok && v > n {
			return errors.New("數值超出範圍")
		}
	}
	if choices, ok := schema["enum"].([]any); ok {
		for _, v := range choices {
			if v == value {
				return nil
			}
		}
		return errors.New("不支援此選項")
	}
	return nil
}
