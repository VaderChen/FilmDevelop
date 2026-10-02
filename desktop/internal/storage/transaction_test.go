package storage

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestMigrationTransactionRecoversAfterInterruptedCommit(t *testing.T) {
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	s, err := New()
	if err != nil {
		t.Fatal(err)
	}
	if err = s.SaveState("preferences.json", map[string]any{"language": "old"}); err != nil {
		t.Fatal(err)
	}
	tx := stateTransaction{Version: 1, After: map[string]json.RawMessage{"preferences.json": json.RawMessage(`{"language":"new"}`), "migrations.json": json.RawMessage(`{"complete":true}`)}}
	data, _ := json.Marshal(tx)
	if err = os.WriteFile(filepath.Join(s.root, "state-transaction.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(s.root, "state", "preferences.json"), []byte(`{"language":"new"}`), 0600); err != nil {
		t.Fatal(err)
	}
	recovered, err := New()
	if err != nil {
		t.Fatal(err)
	}
	var p map[string]any
	_, err = recovered.LoadState("migrations.json", &p)
	if err != nil || p["complete"] != true {
		t.Fatal(p, err)
	}
	if _, err = os.Stat(filepath.Join(s.root, "state-transaction.json")); !os.IsNotExist(err) {
		t.Fatal("交易尚未結束")
	}
}
func TestMigrationBackupAndQuarantinePreserveBytes(t *testing.T) {
	t.Setenv("FILMDEVELOP_DATA_DIR", t.TempDir())
	s, _ := New()
	_ = s.SaveState("preferences.json", map[string]string{"language": "old"})
	if err := s.CommitStates(map[string]any{"preferences.json": map[string]string{"language": "new"}, "migrations.json": map[string]bool{"done": true}}); err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(filepath.Join(s.root, "recovery", "migration-*.json"))
	if len(files) != 1 {
		t.Fatal(files)
	}
	data, _ := os.ReadFile(files[0])
	var before map[string]map[string]string
	if err := json.Unmarshal(data, &before); err != nil || before["preferences.json"]["language"] != "old" {
		t.Fatal(string(data), err)
	}
	broken := []byte("{broken\x00")
	_ = os.WriteFile(filepath.Join(s.root, "state", "bad.json"), broken, 0600)
	backup, err := s.QuarantineState("bad.json")
	if err != nil {
		t.Fatal(err)
	}
	read, _ := os.ReadFile(backup)
	if string(read) != string(broken) {
		t.Fatal("原始資料未完整保留")
	}
}
