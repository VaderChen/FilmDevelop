// 此檔由 engine/contract/generate.py 產生，請修改 protocol.json。
#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <limits>
#include <stdexcept>
#include <nlohmann/json.hpp>
namespace filmdevelop::contract {
inline constexpr int version = 1;
inline constexpr size_t maxMessageBytes = 67108864;
struct EngineError {
 std::string code;
 std::string message;
};
inline void from_json(const nlohmann::json& j, EngineError& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "code" && field.key() != "message") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("code").get_to(v.code);
 j.at("message").get_to(v.message);
}
inline void to_json(nlohmann::json& j, const EngineError& v) {
 j = nlohmann::json::object();
 j["code"] = v.code;
 j["message"] = v.message;
}
struct Recipe {
 int64_t version;
 std::string style;
 nlohmann::json adjustment;
 nlohmann::json repairPatches;
 bool detectSubject;
};
inline void from_json(const nlohmann::json& j, Recipe& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "version" && field.key() != "style" && field.key() != "adjustment" && field.key() != "repairPatches" && field.key() != "detectSubject") throw std::invalid_argument("未知契約欄位：" + field.key());
 if (!j.at("version").is_number_integer() || (j.at("version").is_number_unsigned() && j.at("version").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：version");
 j.at("version").get_to(v.version);
 j.at("style").get_to(v.style);
 j.at("adjustment").get_to(v.adjustment);
 j.at("repairPatches").get_to(v.repairPatches);
 j.at("detectSubject").get_to(v.detectSubject);
}
inline void to_json(nlohmann::json& j, const Recipe& v) {
 j = nlohmann::json::object();
 j["version"] = v.version;
 j["style"] = v.style;
 j["adjustment"] = v.adjustment;
 j["repairPatches"] = v.repairPatches;
 j["detectSubject"] = v.detectSubject;
}
struct ImageInput {
 std::string path;
 std::string rawDecoder;
 bool lensCorrection;
};
inline void from_json(const nlohmann::json& j, ImageInput& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "path" && field.key() != "rawDecoder" && field.key() != "lensCorrection") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("path").get_to(v.path);
 j.at("rawDecoder").get_to(v.rawDecoder);
 j.at("lensCorrection").get_to(v.lensCorrection);
}
inline void to_json(nlohmann::json& j, const ImageInput& v) {
 j = nlohmann::json::object();
 j["path"] = v.path;
 j["rawDecoder"] = v.rawDecoder;
 j["lensCorrection"] = v.lensCorrection;
}
struct ImageOutput {
 std::string path;
 std::string format;
 int64_t bitDepth;
 std::string colorSpace;
 double quality;
 int64_t maxPixel;
 bool webPLossless;
 int64_t tiffCompression;
 std::optional<bool> writeExif;
};
inline void from_json(const nlohmann::json& j, ImageOutput& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "path" && field.key() != "format" && field.key() != "bitDepth" && field.key() != "colorSpace" && field.key() != "quality" && field.key() != "maxPixel" && field.key() != "webPLossless" && field.key() != "tiffCompression" && field.key() != "writeExif") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("path").get_to(v.path);
 j.at("format").get_to(v.format);
 if (!j.at("bitDepth").is_number_integer() || (j.at("bitDepth").is_number_unsigned() && j.at("bitDepth").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：bitDepth");
 j.at("bitDepth").get_to(v.bitDepth);
 j.at("colorSpace").get_to(v.colorSpace);
 j.at("quality").get_to(v.quality);
 if (!j.at("maxPixel").is_number_integer() || (j.at("maxPixel").is_number_unsigned() && j.at("maxPixel").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：maxPixel");
 j.at("maxPixel").get_to(v.maxPixel);
 j.at("webPLossless").get_to(v.webPLossless);
 if (!j.at("tiffCompression").is_number_integer() || (j.at("tiffCompression").is_number_unsigned() && j.at("tiffCompression").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：tiffCompression");
 j.at("tiffCompression").get_to(v.tiffCompression);
 if (j.contains("writeExif") && !j.at("writeExif").is_null()) v.writeExif = j.at("writeExif").get<bool>(); else v.writeExif.reset();
}
inline void to_json(nlohmann::json& j, const ImageOutput& v) {
 j = nlohmann::json::object();
 j["path"] = v.path;
 j["format"] = v.format;
 j["bitDepth"] = v.bitDepth;
 j["colorSpace"] = v.colorSpace;
 j["quality"] = v.quality;
 j["maxPixel"] = v.maxPixel;
 j["webPLossless"] = v.webPLossless;
 j["tiffCompression"] = v.tiffCompression;
 if (v.writeExif) j["writeExif"] = *v.writeExif; else j["writeExif"] = nullptr;
}
struct RenderPolicy {
 bool highlightProtection;
 bool modernExposure;
 bool hdr;
 bool fullResolution;
};
inline void from_json(const nlohmann::json& j, RenderPolicy& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "highlightProtection" && field.key() != "modernExposure" && field.key() != "hdr" && field.key() != "fullResolution") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("highlightProtection").get_to(v.highlightProtection);
 j.at("modernExposure").get_to(v.modernExposure);
 j.at("hdr").get_to(v.hdr);
 j.at("fullResolution").get_to(v.fullResolution);
}
inline void to_json(nlohmann::json& j, const RenderPolicy& v) {
 j = nlohmann::json::object();
 j["highlightProtection"] = v.highlightProtection;
 j["modernExposure"] = v.modernExposure;
 j["hdr"] = v.hdr;
 j["fullResolution"] = v.fullResolution;
}
struct SubjectMaskInput {
 std::string path;
 std::string sha256;
};
inline void from_json(const nlohmann::json& j, SubjectMaskInput& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "path" && field.key() != "sha256") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("path").get_to(v.path);
 j.at("sha256").get_to(v.sha256);
}
inline void to_json(nlohmann::json& j, const SubjectMaskInput& v) {
 j = nlohmann::json::object();
 j["path"] = v.path;
 j["sha256"] = v.sha256;
}
struct RenderJob {
 ImageInput input;
 ImageOutput output;
 Recipe recipe;
 std::string computeBackend;
 bool preview;
 int64_t previewMaxPixel;
 std::optional<RenderPolicy> policy;
 std::optional<SubjectMaskInput> subjectMask;
 std::optional<std::string> subjectMaskOutputPath;
};
inline void from_json(const nlohmann::json& j, RenderJob& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "input" && field.key() != "output" && field.key() != "recipe" && field.key() != "computeBackend" && field.key() != "preview" && field.key() != "previewMaxPixel" && field.key() != "policy" && field.key() != "subjectMask" && field.key() != "subjectMaskOutputPath") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("input").get_to(v.input);
 j.at("output").get_to(v.output);
 j.at("recipe").get_to(v.recipe);
 j.at("computeBackend").get_to(v.computeBackend);
 j.at("preview").get_to(v.preview);
 if (!j.at("previewMaxPixel").is_number_integer() || (j.at("previewMaxPixel").is_number_unsigned() && j.at("previewMaxPixel").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：previewMaxPixel");
 j.at("previewMaxPixel").get_to(v.previewMaxPixel);
 if (j.contains("policy") && !j.at("policy").is_null()) v.policy = j.at("policy").get<RenderPolicy>(); else v.policy.reset();
 if (j.contains("subjectMask") && !j.at("subjectMask").is_null()) v.subjectMask = j.at("subjectMask").get<SubjectMaskInput>(); else v.subjectMask.reset();
 if (j.contains("subjectMaskOutputPath") && !j.at("subjectMaskOutputPath").is_null()) v.subjectMaskOutputPath = j.at("subjectMaskOutputPath").get<std::string>(); else v.subjectMaskOutputPath.reset();
}
inline void to_json(nlohmann::json& j, const RenderJob& v) {
 j = nlohmann::json::object();
 j["input"] = v.input;
 j["output"] = v.output;
 j["recipe"] = v.recipe;
 j["computeBackend"] = v.computeBackend;
 j["preview"] = v.preview;
 j["previewMaxPixel"] = v.previewMaxPixel;
 if (v.policy) j["policy"] = *v.policy; else j["policy"] = nullptr;
 if (v.subjectMask) j["subjectMask"] = *v.subjectMask; else j["subjectMask"] = nullptr;
 if (v.subjectMaskOutputPath) j["subjectMaskOutputPath"] = *v.subjectMaskOutputPath; else j["subjectMaskOutputPath"] = nullptr;
}
struct Request {
 int64_t version;
 std::string id;
 std::string method;
 nlohmann::json payload;
};
inline void from_json(const nlohmann::json& j, Request& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "version" && field.key() != "id" && field.key() != "method" && field.key() != "payload") throw std::invalid_argument("未知契約欄位：" + field.key());
 if (!j.at("version").is_number_integer() || (j.at("version").is_number_unsigned() && j.at("version").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：version");
 j.at("version").get_to(v.version);
 j.at("id").get_to(v.id);
 j.at("method").get_to(v.method);
 j.at("payload").get_to(v.payload);
}
inline void to_json(nlohmann::json& j, const Request& v) {
 j = nlohmann::json::object();
 j["version"] = v.version;
 j["id"] = v.id;
 j["method"] = v.method;
 j["payload"] = v.payload;
}
struct Response {
 int64_t version;
 std::string id;
 std::string kind;
 nlohmann::json payload;
 std::optional<EngineError> error;
};
inline void from_json(const nlohmann::json& j, Response& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "version" && field.key() != "id" && field.key() != "kind" && field.key() != "payload" && field.key() != "error") throw std::invalid_argument("未知契約欄位：" + field.key());
 if (!j.at("version").is_number_integer() || (j.at("version").is_number_unsigned() && j.at("version").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：version");
 j.at("version").get_to(v.version);
 j.at("id").get_to(v.id);
 j.at("kind").get_to(v.kind);
 j.at("payload").get_to(v.payload);
 if (j.contains("error") && !j.at("error").is_null()) v.error = j.at("error").get<EngineError>(); else v.error.reset();
}
inline void to_json(nlohmann::json& j, const Response& v) {
 j = nlohmann::json::object();
 j["version"] = v.version;
 j["id"] = v.id;
 j["kind"] = v.kind;
 j["payload"] = v.payload;
 if (v.error) j["error"] = *v.error; else j["error"] = nullptr;
}
struct EditorRequest {
 Recipe recipe;
 nlohmann::json changes;
};
inline void from_json(const nlohmann::json& j, EditorRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "recipe" && field.key() != "changes") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("recipe").get_to(v.recipe);
 j.at("changes").get_to(v.changes);
}
inline void to_json(nlohmann::json& j, const EditorRequest& v) {
 j = nlohmann::json::object();
 j["recipe"] = v.recipe;
 j["changes"] = v.changes;
}
struct ThumbnailRequest {
 std::string path;
 int64_t maxPixel;
};
inline void from_json(const nlohmann::json& j, ThumbnailRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "path" && field.key() != "maxPixel") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("path").get_to(v.path);
 if (!j.at("maxPixel").is_number_integer() || (j.at("maxPixel").is_number_unsigned() && j.at("maxPixel").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：maxPixel");
 j.at("maxPixel").get_to(v.maxPixel);
}
inline void to_json(nlohmann::json& j, const ThumbnailRequest& v) {
 j = nlohmann::json::object();
 j["path"] = v.path;
 j["maxPixel"] = v.maxPixel;
}
struct ThumbnailResult {
 std::string imageData;
 int64_t width;
 int64_t height;
};
inline void from_json(const nlohmann::json& j, ThumbnailResult& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "imageData" && field.key() != "width" && field.key() != "height") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("imageData").get_to(v.imageData);
 if (!j.at("width").is_number_integer() || (j.at("width").is_number_unsigned() && j.at("width").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：width");
 j.at("width").get_to(v.width);
 if (!j.at("height").is_number_integer() || (j.at("height").is_number_unsigned() && j.at("height").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：height");
 j.at("height").get_to(v.height);
}
inline void to_json(nlohmann::json& j, const ThumbnailResult& v) {
 j = nlohmann::json::object();
 j["imageData"] = v.imageData;
 j["width"] = v.width;
 j["height"] = v.height;
}
struct WhiteBalanceRequest {
 double red;
 double green;
 double blue;
 double warmth;
 double tint;
 double strength;
};
inline void from_json(const nlohmann::json& j, WhiteBalanceRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "red" && field.key() != "green" && field.key() != "blue" && field.key() != "warmth" && field.key() != "tint" && field.key() != "strength") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("red").get_to(v.red);
 j.at("green").get_to(v.green);
 j.at("blue").get_to(v.blue);
 j.at("warmth").get_to(v.warmth);
 j.at("tint").get_to(v.tint);
 j.at("strength").get_to(v.strength);
}
inline void to_json(nlohmann::json& j, const WhiteBalanceRequest& v) {
 j = nlohmann::json::object();
 j["red"] = v.red;
 j["green"] = v.green;
 j["blue"] = v.blue;
 j["warmth"] = v.warmth;
 j["tint"] = v.tint;
 j["strength"] = v.strength;
}
struct FileRequest {
 std::string path;
};
inline void from_json(const nlohmann::json& j, FileRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "path") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("path").get_to(v.path);
}
inline void to_json(nlohmann::json& j, const FileRequest& v) {
 j = nlohmann::json::object();
 j["path"] = v.path;
}
struct InferenceRequest {
 std::string format;
 std::string modelPath;
 std::string projectorPath;
 std::string imageData;
 std::string systemPrompt;
 std::string userPrompt;
 std::string grammar;
 int64_t maxTokens;
 int64_t contextLimit;
};
inline void from_json(const nlohmann::json& j, InferenceRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "format" && field.key() != "modelPath" && field.key() != "projectorPath" && field.key() != "imageData" && field.key() != "systemPrompt" && field.key() != "userPrompt" && field.key() != "grammar" && field.key() != "maxTokens" && field.key() != "contextLimit") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("format").get_to(v.format);
 j.at("modelPath").get_to(v.modelPath);
 j.at("projectorPath").get_to(v.projectorPath);
 j.at("imageData").get_to(v.imageData);
 j.at("systemPrompt").get_to(v.systemPrompt);
 j.at("userPrompt").get_to(v.userPrompt);
 j.at("grammar").get_to(v.grammar);
 if (!j.at("maxTokens").is_number_integer() || (j.at("maxTokens").is_number_unsigned() && j.at("maxTokens").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：maxTokens");
 j.at("maxTokens").get_to(v.maxTokens);
 if (!j.at("contextLimit").is_number_integer() || (j.at("contextLimit").is_number_unsigned() && j.at("contextLimit").get<uint64_t>() > uint64_t(std::numeric_limits<int64_t>::max()))) throw std::invalid_argument("契約欄位需要整數：contextLimit");
 j.at("contextLimit").get_to(v.contextLimit);
}
inline void to_json(nlohmann::json& j, const InferenceRequest& v) {
 j = nlohmann::json::object();
 j["format"] = v.format;
 j["modelPath"] = v.modelPath;
 j["projectorPath"] = v.projectorPath;
 j["imageData"] = v.imageData;
 j["systemPrompt"] = v.systemPrompt;
 j["userPrompt"] = v.userPrompt;
 j["grammar"] = v.grammar;
 j["maxTokens"] = v.maxTokens;
 j["contextLimit"] = v.contextLimit;
}
struct AnalysisRequest {
 ImageInput input;
 Recipe recipe;
};
inline void from_json(const nlohmann::json& j, AnalysisRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "input" && field.key() != "recipe") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("input").get_to(v.input);
 j.at("recipe").get_to(v.recipe);
}
inline void to_json(nlohmann::json& j, const AnalysisRequest& v) {
 j = nlohmann::json::object();
 j["input"] = v.input;
 j["recipe"] = v.recipe;
}
struct RepairRequest {
 ImageInput input;
 Recipe recipe;
 std::string modelDirectory;
 nlohmann::json strokes;
};
inline void from_json(const nlohmann::json& j, RepairRequest& v) {
 if (!j.is_object()) throw std::invalid_argument("契約需要物件");
 for (const auto& field : j.items()) if (field.key() != "input" && field.key() != "recipe" && field.key() != "modelDirectory" && field.key() != "strokes") throw std::invalid_argument("未知契約欄位：" + field.key());
 j.at("input").get_to(v.input);
 j.at("recipe").get_to(v.recipe);
 j.at("modelDirectory").get_to(v.modelDirectory);
 j.at("strokes").get_to(v.strokes);
}
inline void to_json(nlohmann::json& j, const RepairRequest& v) {
 j = nlohmann::json::object();
 j["input"] = v.input;
 j["recipe"] = v.recipe;
 j["modelDirectory"] = v.modelDirectory;
 j["strokes"] = v.strokes;
}
}
