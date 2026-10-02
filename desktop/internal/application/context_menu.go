package application

// 共用操作選單只提供資料與命令；輸入、確認和進度仍使用對話框。
type contextMenuItem struct {
	ID        string            `json:"id,omitempty"`
	Label     string            `json:"label,omitempty"`
	Shortcut  string            `json:"shortcut,omitempty"`
	Literal   bool              `json:"literal,omitempty"`
	Disabled  bool              `json:"disabled,omitempty"`
	Separator bool              `json:"separator,omitempty"`
	Checked   string            `json:"checked,omitempty"`
	Items     []contextMenuItem `json:"items,omitempty"`
}

func menuSeparator() contextMenuItem { return contextMenuItem{Separator: true} }

func (a *App) showMenu(title string, items []contextMenuItem, message object, submit func(string) error) error {
	choices := []dialogChoice{}
	var collect func([]contextMenuItem, bool)
	collect = func(items []contextMenuItem, disabled bool) {
		for _, item := range items {
			if item.Separator {
				continue
			}
			if len(item.Items) > 0 {
				collect(item.Items, disabled || item.Disabled)
				continue
			}
			if item.ID != "" {
				choices = append(choices, dialogChoice{ID: item.ID, Disabled: disabled || item.Disabled})
			}
		}
	}
	collect(items, false)
	a.mu.Lock()
	id, generation := identifier(), a.generation
	a.dialog = &pendingDialog{ID: id, Generation: generation, Choices: choices, Submit: submit, Menu: true}
	a.mu.Unlock()
	a.reply("handleHostMenu", object{"id": id, "title": title, "items": items, "anchor": message["menuAnchor"], "photoGeneration": generation})
	return nil
}

func menuSelection(count, total int) string {
	if count == total && total > 0 {
		return "true"
	}
	if count > 0 {
		return "mixed"
	}
	return "false"
}
