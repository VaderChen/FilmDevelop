package application

import (
	"github.com/VaderChen/FilmDevelop/internal/photos"
	"testing"
)

func TestContextMenuRejectsUnavailableAndStaleActions(t *testing.T) {
	a := testApp(t)
	a.generation = "first"
	calls := 0
	items := []contextMenuItem{{ID: "allowed", Label: "可用"}, {Label: "停用子選單", Disabled: true, Items: []contextMenuItem{{ID: "blocked", Label: "不可執行"}}}, menuSeparator()}
	show := func() {
		t.Helper()
		if err := a.showMenu("測試", items, object{}, func(string) error { calls++; return nil }); err != nil {
			t.Fatal(err)
		}
	}
	for _, value := range []string{"blocked", "unknown", ""} {
		show()
		if a.resolveDialog(object{"id": a.dialog.ID, "value": value}) == nil {
			t.Fatal("接受無效選單動作", value)
		}
	}
	show()
	id := a.dialog.ID
	a.generation = "second"
	if a.resolveDialog(object{"id": id, "value": "allowed"}) == nil {
		t.Fatal("換圖後執行舊命令")
	}
	show()
	old := a.dialog.ID
	show()
	next := a.dialog.ID
	if err := a.resolveDialog(object{"id": old, "cancelled": true}); err != nil || a.dialog.ID != next {
		t.Fatal("舊取消事件蓋掉新選單", err)
	}
	if err := a.resolveDialog(object{"id": next, "value": "allowed"}); err != nil || calls != 1 {
		t.Fatal("選單動作未正確執行", err, calls)
	}
	if a.resolveDialog(object{"id": next, "value": "allowed"}) == nil {
		t.Fatal("重複執行選單動作")
	}
}

func TestOrganizationSubmenusKeepMixedAndDisabledStates(t *testing.T) {
	a := testApp(t)
	paths := []string{"/one.jpg", "/two.jpg"}
	a.organization.Tags = []string{"未使用", "旅行"}
	a.organization.Photos[photos.Identity(paths[0])] = photoMetadata{Rating: 4, Tags: []string{"旅行"}}
	a.organization.Photos[photos.Identity(paths[1])] = photoMetadata{Rating: 0, Tags: []string{}}
	items, actions := a.organizationMenus(paths)
	if items[0].Items[4].Checked != "mixed" || items[0].Items[0].Checked != "mixed" {
		t.Fatal("多選分級未顯示混合狀態")
	}
	var tagID string
	for _, item := range items[1].Items {
		if item.Label == "旅行" {
			tagID = item.ID
			if item.Checked != "mixed" {
				t.Fatal("多選分類未顯示混合狀態")
			}
		}
	}
	removal := items[1].Items[len(items[1].Items)-1]
	for _, item := range removal.Items {
		if item.Disabled != (item.Label == "旅行") {
			t.Fatal("分類移除未依使用狀態停用")
		}
	}
	if err := actions[tagID](); err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if !contains(a.organization.Photos[photos.Identity(path)].Tags, "旅行") {
			t.Fatal("未將混合分類套用至全部照片")
		}
	}
	if err := actions["rating:5"](); err != nil {
		t.Fatal(err)
	}
	for _, path := range paths {
		if a.organization.Photos[photos.Identity(path)].Rating != 5 {
			t.Fatal("多選分級未保存")
		}
	}
	items, _ = a.organizationMenus(paths)
	if items[0].Items[5].Checked != "true" {
		t.Fatal("全部選取的勾選狀態不符")
	}
}
