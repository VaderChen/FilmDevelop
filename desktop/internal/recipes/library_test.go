package recipes

import (
	"compress/gzip"
	"encoding/json"
	"os"
	"reflect"
	"testing"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

// 參考答案來自移植前的 Swift 執行檔，涵蓋所有控制項與 schema 1–12。
func TestSwiftCompatibility(t *testing.T) {
	file, err := os.Open("testdata/swift-reference.json.gz")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	reader, err := gzip.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	var fixture struct {
		Catalog json.RawMessage
		Cases   []struct {
			Name, Method string
			Input, Value json.RawMessage
			Valid        bool
		}
	}
	if err := json.NewDecoder(reader).Decode(&fixture); err != nil {
		t.Fatal(err)
	}
	library, err := New()
	if err != nil {
		t.Fatal(err)
	}
	catalog, err := library.Catalog()
	if err != nil {
		t.Fatal(err)
	}
	assertJSON(t, catalog, fixture.Catalog)
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			var result any
			var err error
			switch test.Method {
			case "normalizeRecipe":
				var request contract.Recipe
				if err := json.Unmarshal(test.Input, &request); err != nil {
					t.Fatal(err)
				}
				result, err = library.Normalize(request)
			case "editRecipe":
				var request contract.EditorRequest
				if err := json.Unmarshal(test.Input, &request); err != nil {
					t.Fatal(err)
				}
				result, err = library.Edit(request)
			case "projectRecipes":
				var request map[string]contract.Recipe
				if err := json.Unmarshal(test.Input, &request); err != nil {
					t.Fatal(err)
				}
				result, err = library.ProjectMany(request)
			default:
				t.Fatal("未知測試操作")
			}
			if (err == nil) != test.Valid {
				t.Fatalf("接受結果不同：Swift valid=%v，Go error=%v", test.Valid, err)
			}
			if !test.Valid {
				return
			}
			actual, err := json.Marshal(result)
			if err != nil {
				t.Fatal(err)
			}
			assertJSON(t, actual, test.Value)
		})
	}
}

func assertJSON(t *testing.T, actual, expected json.RawMessage) {
	t.Helper()
	var got, want any
	if err := json.Unmarshal(actual, &got); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(expected, &want); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("與 Swift 參考配方不同\nGo: %s\nSwift: %s", actual, expected)
	}
}
