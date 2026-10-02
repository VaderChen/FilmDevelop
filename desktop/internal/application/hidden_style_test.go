package application

import "testing"

func TestCustomFilmFromHiddenStyleRemainsVisible(t *testing.T) {
	a := testApp(t)
	if err := a.saveFilm("舊相機配方", a.recipes["gr3-sky-orange"], ""); err != nil {
		t.Fatal(err)
	}
	id := a.customFilms[0].ID
	visible, hidden := false, false
	for _, raw := range a.stylePayloads() {
		s := raw.(object)
		if s["id"] == "gr3-sky-orange" {
			hidden = s["isHiddenFromCatalog"] == true
		}
		if s["id"] == id {
			visible = s["isHiddenFromCatalog"] == false && s["isCustom"] == true
		}
	}
	if !hidden || !visible {
		t.Fatal("隱藏相容配方與自訂底片的可見性不正確")
	}
	if err := a.selectStyle(id); err != nil {
		t.Fatal(err)
	}
	if a.selected != "gr3-sky-orange" {
		t.Fatal("自訂底片未沿用原相機配方")
	}
}
