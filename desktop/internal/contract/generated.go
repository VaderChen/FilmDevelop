// 此檔由 engine/contract/generate.py 產生，請修改 protocol.json。
package contract

import "encoding/json"

const Version = 1
const MaxMessageBytes = 67108864

type EngineError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type Recipe struct {
	Version       int             `json:"version"`
	Style         string          `json:"style"`
	Adjustment    json.RawMessage `json:"adjustment"`
	RepairPatches json.RawMessage `json:"repairPatches"`
	DetectSubject bool            `json:"detectSubject"`
}
type ImageInput struct {
	Path           string `json:"path"`
	RawDecoder     string `json:"rawDecoder"`
	LensCorrection bool   `json:"lensCorrection"`
}
type ImageOutput struct {
	Path            string  `json:"path"`
	Format          string  `json:"format"`
	BitDepth        int     `json:"bitDepth"`
	ColorSpace      string  `json:"colorSpace"`
	Quality         float64 `json:"quality"`
	MaxPixel        int     `json:"maxPixel"`
	WebPLossless    bool    `json:"webPLossless"`
	TiffCompression int     `json:"tiffCompression"`
	WriteExif       *bool   `json:"writeExif,omitempty"`
}
type RenderPolicy struct {
	HighlightProtection bool `json:"highlightProtection"`
	ModernExposure      bool `json:"modernExposure"`
	Hdr                 bool `json:"hdr"`
	FullResolution      bool `json:"fullResolution"`
}
type SubjectMaskInput struct {
	Path   string `json:"path"`
	Sha256 string `json:"sha256"`
}
type RenderJob struct {
	Input                 ImageInput        `json:"input"`
	Output                ImageOutput       `json:"output"`
	Recipe                Recipe            `json:"recipe"`
	ComputeBackend        string            `json:"computeBackend"`
	Preview               bool              `json:"preview"`
	PreviewMaxPixel       int               `json:"previewMaxPixel"`
	Policy                *RenderPolicy     `json:"policy,omitempty"`
	SubjectMask           *SubjectMaskInput `json:"subjectMask,omitempty"`
	SubjectMaskOutputPath *string           `json:"subjectMaskOutputPath,omitempty"`
}
type Request struct {
	Version int             `json:"version"`
	ID      string          `json:"id"`
	Method  string          `json:"method"`
	Payload json.RawMessage `json:"payload"`
}
type Response struct {
	Version int             `json:"version"`
	ID      string          `json:"id"`
	Kind    string          `json:"kind"`
	Payload json.RawMessage `json:"payload"`
	Error   *EngineError    `json:"error,omitempty"`
}
type EditorRequest struct {
	Recipe  Recipe          `json:"recipe"`
	Changes json.RawMessage `json:"changes"`
}
type ThumbnailRequest struct {
	Path     string `json:"path"`
	MaxPixel int    `json:"maxPixel"`
}
type ThumbnailResult struct {
	ImageData string `json:"imageData"`
	Width     int    `json:"width"`
	Height    int    `json:"height"`
}
type WhiteBalanceRequest struct {
	Red      float64 `json:"red"`
	Green    float64 `json:"green"`
	Blue     float64 `json:"blue"`
	Warmth   float64 `json:"warmth"`
	Tint     float64 `json:"tint"`
	Strength float64 `json:"strength"`
}
type FileRequest struct {
	Path string `json:"path"`
}
type InferenceRequest struct {
	Format        string `json:"format"`
	ModelPath     string `json:"modelPath"`
	ProjectorPath string `json:"projectorPath"`
	ImageData     string `json:"imageData"`
	SystemPrompt  string `json:"systemPrompt"`
	UserPrompt    string `json:"userPrompt"`
	Grammar       string `json:"grammar"`
	MaxTokens     int    `json:"maxTokens"`
	ContextLimit  int    `json:"contextLimit"`
}
type AnalysisRequest struct {
	Input  ImageInput `json:"input"`
	Recipe Recipe     `json:"recipe"`
}
type RepairRequest struct {
	Input          ImageInput      `json:"input"`
	Recipe         Recipe          `json:"recipe"`
	ModelDirectory string          `json:"modelDirectory"`
	Strokes        json.RawMessage `json:"strokes"`
}
