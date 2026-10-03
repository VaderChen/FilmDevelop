package application

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"

	"github.com/VaderChen/FilmDevelop/internal/contract"
)

var aiComputationItems = []string{"場景、主體與整體亮度分析", "亮部／中調／暗部調整參數", "單張局部動態範圍壓縮曲線", "風格比例與背景模糊", "膚色、美白與磨皮", "降噪、顆粒與暗角", "套用參數並產生預覽"}

func (a *App) computationItems() []string {
	if a.computing {
		return aiComputationItems
	}
	return []string{}
}

func (a *App) cancelAI() {
	a.mu.Lock()
	if a.computing && !a.cancellingComputation && a.computationCompleted < len(aiComputationItems) && a.cancel != nil {
		a.cancellingComputation = true
		a.computationStep = "正在取消，等待目前運算結束"
		a.cancel()
	}
	a.mu.Unlock()
	a.state()
}

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
	a.cancellingComputation = false
	a.computationCompleted = 0
	a.computationStep = aiComputationItems[0]
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
		progress := func(value float64) {
			if math.IsNaN(value) || math.IsInf(value, 0) {
				return
			}
			a.mu.Lock()
			if !a.computing || a.cancellingComputation || ctx.Err() != nil {
				a.mu.Unlock()
				return
			}
			index := min(len(aiComputationItems)-1, max(0, int(value*float64(len(aiComputationItems)))))
			changed := index > a.computationCompleted
			if changed {
				a.computationCompleted = index
				a.computationStep = aiComputationItems[index]
			}
			a.mu.Unlock()
			if changed {
				a.state()
			}
		}
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
			data, err = a.services.Native(ctx, "infer", contract.InferenceRequest{Format: model.Format, ModelPath: model.Path, ProjectorPath: model.Projector, ImageData: analysis.ImageData, SystemPrompt: defaultPrompts.System, UserPrompt: user, Grammar: defaultPrompts.Grammar, MaxTokens: 3072, ContextLimit: 12288}, progress)
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
		cancelled := ctx.Err() != nil
		if err == nil && valid {
			a.pushHistory()
			a.recipes[style] = recipe
			a.selectedCustom = ""
			a.customBase = nil
			a.forceSubject = true
			a.skipSubject = false
			a.computationCompleted = len(aiComputationItems)
			a.computationStep = aiComputationItems[len(aiComputationItems)-1]
			a.expandAdjustments = true
			err = a.refreshUI()
		}
		a.mu.Unlock()
		if err == nil && valid {
			err = a.persist()
			if err == nil {
				a.preview()
				err = a.waitPreview(a.ctx)
			}
		}
		a.mu.Lock()
		a.computing, a.cancellingComputation = false, false
		a.computationCompleted, a.computationStep = 0, ""
		a.mu.Unlock()
		a.state()
		if cancelled {
			a.toast(errors.New("已取消 AI 分析，照片未變更。"))
		} else if err != nil {
			a.toast(err)
		} else if valid {
			a.toast(errors.New("AI 分析完成。"))
		}
	}()
	return nil
}
