// 此檔由 engine/contract/generate.py 產生，請修改 protocol.json。
import Foundation
enum EngineProtocol { static let version = 1; static let maxMessageBytes = 67108864 }
struct EngineError: Codable {
 var code: String
 var message: String
}
struct Recipe: Codable {
 var version: Int
 var style: String
 var adjustment: JSONValue
 var repairPatches: JSONValue
 var detectSubject: Bool
}
struct ImageInput: Codable {
 var path: String
 var rawDecoder: String
 var lensCorrection: Bool
}
struct ImageOutput: Codable {
 var path: String
 var format: String
 var bitDepth: Int
 var colorSpace: String
 var quality: Double
 var maxPixel: Int
 var webPLossless: Bool
 var tiffCompression: Int
 var writeExif: Bool?
}
struct RenderPolicy: Codable {
 var highlightProtection: Bool
 var modernExposure: Bool
 var hdr: Bool
 var fullResolution: Bool
}
struct SubjectMaskInput: Codable {
 var path: String
 var sha256: String
}
struct RenderJob: Codable {
 var input: ImageInput
 var output: ImageOutput
 var recipe: Recipe
 var computeBackend: String
 var preview: Bool
 var previewMaxPixel: Int
 var policy: RenderPolicy?
 var subjectMask: SubjectMaskInput?
 var subjectMaskOutputPath: String?
}
struct Request: Codable {
 var version: Int
 var id: String
 var method: String
 var payload: JSONValue
}
struct Response: Codable {
 var version: Int
 var id: String
 var kind: String
 var payload: JSONValue
 var error: EngineError?
}
struct EditorRequest: Codable {
 var recipe: Recipe
 var changes: JSONValue
}
struct ThumbnailRequest: Codable {
 var path: String
 var maxPixel: Int
}
struct ThumbnailResult: Codable {
 var imageData: String
 var width: Int
 var height: Int
}
struct WhiteBalanceRequest: Codable {
 var red: Double
 var green: Double
 var blue: Double
 var warmth: Double
 var tint: Double
 var strength: Double
}
struct FileRequest: Codable {
 var path: String
}
struct InferenceRequest: Codable {
 var format: String
 var modelPath: String
 var projectorPath: String
 var imageData: String
 var systemPrompt: String
 var userPrompt: String
 var grammar: String
 var maxTokens: Int
 var contextLimit: Int
}
struct AnalysisRequest: Codable {
 var input: ImageInput
 var recipe: Recipe
}
struct RepairRequest: Codable {
 var input: ImageInput
 var recipe: Recipe
 var modelDirectory: String
 var strokes: JSONValue
}
