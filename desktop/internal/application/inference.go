package application

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

func (a *App) applyAI() error { return a.applyAIWith("", "") }
func (a *App) applyAIWith(promptOverride, languageOverride string) error {
	a.mu.Lock()
	model, ready := a.activeModel()
	if a.source == "" || a.selected == "original" || !ready || a.modelBusy || a.computing {
		a.mu.Unlock()
		return errors.New("請先選取照片、底片與可用的本機視覺模型")
	}
	a.invalidatePreview()
	ctx, cancel := context.WithCancel(a.ctx)
	a.cancel = cancel
	a.computing = true
	a.computationStep = "準備照片與本機模型"
	generation, revision := a.generation, a.revision
	style := a.selected
	base := clone(a.recipes[style])
	input := a.job("", base, true).Input
	language := a.effectivePromptLanguage()
	if languageOverride != "" {
		language = languageOverride
	}
	prompt := a.prompts[style][language]
	if prompt == "" {
		prompt = defaultPrompts.Styles[style].Prompts[language]
	}
	if promptOverride != "" {
		prompt = strings.TrimSpace(promptOverride)
	}
	title, mode := style, "color"
	for _, entry := range a.catalog["styles"].([]any) {
		s := entry.(object)
		if s["id"] == style {
			title, _ = s["title"].(string)
			if s["isMonochrome"] == true {
				mode = "monochrome"
			}
		}
	}
	a.mu.Unlock()
	a.state()
	a.workers.Add(1)
	go func() {
		defer a.workers.Done()
		defer cancel()
		var recipe contract.Recipe
		data, err := a.services.Native(ctx, "analysis", contract.AnalysisRequest{Input: input, Recipe: base}, nil)
		var analysis struct {
			ImageData string
			Analysis  string
		}
		if err == nil {
			err = json.Unmarshal(data, &analysis)
		}
		if err == nil {
			editor := object{}
			fields := recipeFields(base)
			for _, pair := range strings.Fields("exposure:exposure white_balance_warmth:whiteBalanceWarmth white_balance_tint:whiteBalanceTint contrast:contrast brightness:brightness hdr_amount:hdrAmount crop_aspect_ratio:cropAspectRatio crop_rotation:cropRotation crop_scale:cropScale crop_width:cropWidth crop_height:cropHeight crop_horizontal_position:cropHorizontalPosition crop_vertical_position:cropVerticalPosition frame_enabled:frameEnabled frame_style:frameStyle date_enabled:dateEnabled date_style:dateStyle") {
				p := strings.Split(pair, ":")
				editor[p[0]] = fields[p[1]]
			}
			editorJSON, _ := json.Marshal(editor)
			user := fmt.Sprintf("<image>\nSelected base style: %s\nRendering color_mode: %s\nCurrent editor_controls (preserve crop/frame/date unless requested): %s\n%s\nUser editing target:\n%s\n", title, mode, editorJSON, analysis.Analysis, prompt)
			custom := true
			for _, p := range defaultPrompts.Styles[style].Prompts {
				if prompt == p {
					custom = false
				}
			}
			if custom {
				user += "The customized target REPLACES aesthetic defaults. Preserve every explicitly requested numeric value, zone and disabled effect. Other/rest/其餘 refers only to unspecified controls. Never reintroduce grain, fade, warmth or glow against the request.\n"
			} else {
				baseline, _ := json.Marshal(recipeFields(a.defaults[style])["filmEffects"])
				user += fmt.Sprintf("Suggested starting ranges: %s\nSelected film texture baseline: grain=%v, film_effects=%s. Correct the photograph's exposure independently of this baseline. Inspect faces and subjects separately from bright backgrounds; use global exposure for the main correction and zones only for remaining problems. Do not brighten an intentionally dark scene or compound several corrections for the same shadow deficit.\n", defaultPrompts.Styles[style].Guidance, recipeFields(a.defaults[style])["grain"], baseline)
			}
			user += "Return one complete executable schema 6 JSON object. Recheck all explicit numbers before answering."
			a.mu.Lock()
			a.computationStep = "本機模型正在分析照片"
			a.mu.Unlock()
			a.state()
			data, err = a.services.Native(ctx, "infer", contract.InferenceRequest{Format: model.Format, ModelPath: model.Path, ProjectorPath: model.Projector, ImageData: analysis.ImageData, SystemPrompt: defaultPrompts.System, UserPrompt: user, Grammar: defaultPrompts.Grammar, MaxTokens: 3072, ContextLimit: 12288}, nil)
			if err == nil {
				var result struct{ Text string }
				err = json.Unmarshal(data, &result)
				if err == nil {
					recipe, err = a.services.MapPlan(result.Text, base)
				}
			}
		}
		a.mu.Lock()
		valid := a.generation == generation && a.revision == revision && a.selected == style && ctx.Err() == nil
		a.computing = false
		a.computationStep = ""
		if err == nil && valid {
			a.pushHistory()
			a.recipes[style] = recipe
			a.selectedCustom = ""
			a.customBase = nil
			err = a.refreshUI()
		}
		a.mu.Unlock()
		if err != nil && ctx.Err() == nil {
			a.toast(err)
		}
		if err == nil && valid {
			if err = a.persist(); err != nil {
				a.toast(err)
			}
			a.preview()
		} else {
			a.state()
		}
	}()
	return nil
}
