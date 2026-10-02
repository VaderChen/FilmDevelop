package application

import (
	"encoding/json"
	"testing"
)

func TestExifPreferenceMigrationAndPersistence(t *testing.T) {
	a := testApp(t)
	old := defaultPreferences()
	raw, _ := json.Marshal(old)
	var fields object
	json.Unmarshal(raw, &fields)
	delete(fields["exportSettings"].(map[string]any), "writeExif")
	if e := a.store.SaveState("preferences.json", fields); e != nil {
		t.Fatal(e)
	}
	if e := a.loadPreferences(); e != nil || !a.exportSettings.WriteExif {
		t.Fatalf("舊偏好未預設開啟：%v", e)
	}
	if e := a.exportSettings.update("writeExif", false); e != nil {
		t.Fatal(e)
	}
	if e := a.savePreferences(); e != nil {
		t.Fatal(e)
	}
	a.exportSettings = defaultExportSettings()
	if e := a.loadPreferences(); e != nil || a.exportSettings.WriteExif {
		t.Fatalf("未保留關閉偏好：%v", e)
	}
	output := a.exportSettings.output("photo.png")
	if output.WriteExif == nil || *output.WriteExif {
		t.Fatal("匯出快照未沿用開關")
	}
	if e := a.exportSettings.update("writeExif", 1); e == nil {
		t.Fatal("接受非布林值")
	}
}
