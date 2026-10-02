#include "Contract.generated.hpp"
#include "PhotoCompute.h"
#include "codec.hpp"
#include "repair.hpp"
#include "inference.hpp"
#include "analysis.hpp"
#include "vision.hpp"
#include "render_pipeline.hpp"
#include "film_internal.hpp"
#include <chrono>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <set>
#include <wincrypt.h>

namespace fs = std::filesystem;
using namespace filmdevelop;
using namespace photocore;
namespace {
template <class T> T symbol(HMODULE library, const char *name) {
  auto address = GetProcAddress(library, name);
  T result = nullptr;
  static_assert(sizeof(result) == sizeof(address), "Windows 函式指標大小不符");
  std::memcpy(&result, &address, sizeof(result));
  return result;
}
fs::path executableDirectory() {
  std::wstring path(32768, L'\0');
  DWORD length =
      GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!length || length >= path.size())
    throw Failure("nativeFailure", "無法取得引擎位置");
  path.resize(length);
  return fs::path(path).parent_path();
}
// FYPMASK1 的行序與 Core Image bitmap 相同（由上至下），保留 Float32 權重。
Image savedSubjectMask(const contract::SubjectMaskInput &input) {
  std::ifstream file(fs::path(wide(input.path)),std::ios::binary|std::ios::ate);
  if(!file)throw Failure("invalidMask","無法讀取主體遮罩");
  const auto size=file.tellg();
  if(size<16 || size>268435472)throw Failure("invalidMask","主體遮罩大小不符");
  std::vector<unsigned char> bytes(size_t(size),0);file.seekg(0);file.read(reinterpret_cast<char*>(bytes.data()),std::streamsize(bytes.size()));
  if(!file || std::memcmp(bytes.data(),"FYPMASK1",8)!=0)throw Failure("invalidMask","主體遮罩標頭不符");
  HCRYPTPROV provider=0;HCRYPTHASH hash=0;
  if(!CryptAcquireContextW(&provider,nullptr,nullptr,PROV_RSA_AES,CRYPT_VERIFYCONTEXT))throw Failure("invalidMask","無法驗證遮罩");
  bool ok=CryptCreateHash(provider,CALG_SHA_256,0,0,&hash) && CryptHashData(hash,bytes.data(),DWORD(bytes.size()),0);
  BYTE digest[32];DWORD length=32;if(ok)ok=CryptGetHashParam(hash,HP_HASHVAL,digest,&length,0);
  if(hash) { CryptDestroyHash(hash); }
  CryptReleaseContext(provider,0);
  std::string actual;const char* hex="0123456789abcdef";if(ok)for(auto b:digest){actual+=hex[b>>4];actual+=hex[b&15];}
  if(!ok || actual!=input.sha256)throw Failure("invalidMask","主體遮罩完整性檢查失敗");
  auto dimension=[&](size_t i){return uint32_t(bytes[i])|(uint32_t(bytes[i+1])<<8)|(uint32_t(bytes[i+2])<<16)|(uint32_t(bytes[i+3])<<24);};
  auto w=dimension(8),h=dimension(12);
  if(w<1 || h<1 || w>4096 || h>4096 || bytes.size()!=16+size_t(w)*h*16)throw Failure("invalidMask","主體遮罩尺寸不符");
  Image result(w,h);
  for(size_t i=0;i<result.pixels.size();++i){float values[4];std::memcpy(values,bytes.data()+16+i*16,16);for(float v:values)if(!std::isfinite(v))throw Failure("invalidMask","主體遮罩權重不符");result.pixels[i]={values[0],values[1],values[2],values[3]};}
  return result;
}
// Vulkan 是可選相依。未安裝驅動時，WIC／CPU 引擎仍可正常啟動。
class GPU {
  HMODULE library = nullptr;
  void *engine = nullptr;
  decltype(&photo_compute_create) create = nullptr;
  decltype(&photo_compute_destroy) destroy = nullptr;
  decltype(&photo_compute_process_inputs) process = nullptr;
  Json device;

public:
  explicit GPU(const fs::path &folder) {
    library = LoadLibraryExW((folder / L"libPhotoCompute.dll").c_str(), nullptr,
                             LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                                 LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library)
      throw Failure("backendUnavailable", "未偵測到可用的 Vulkan 執行環境");
    try {
      auto abi =
          symbol<decltype(&photo_compute_abi)>(library, "photo_compute_abi");
      create = symbol<decltype(create)>(library, "photo_compute_create");
      destroy = symbol<decltype(destroy)>(library, "photo_compute_destroy");
      process = symbol<decltype(process)>(library, "photo_compute_process_inputs");
      if (!abi || abi() != 2 || !create || !destroy || !process)
        throw Failure("backendUnavailable", "Vulkan 計算介面版本不符");
      char error[2048]{};
      engine = create((folder / "film-data").u8string().c_str(),
                      (folder / "film.comp.spv").u8string().c_str(), error,
                      sizeof(error));
      if (!engine)
        throw Failure("backendUnavailable", error);
      auto info = symbol<decltype(&photo_compute_device_info)>(
          library, "photo_compute_device_info");
      PhotoComputeDeviceInfo detected{};
      if (!info || info(engine, &detected) ||
          detected.loader_version < ((1u << 22) | (1u << 12)) ||
          detected.device_version < ((1u << 22) | (1u << 12)))
        throw Failure("backendUnavailable", "GPU 或 Vulkan 版本未通過檢查");
      auto version = [](uint32_t v) {
        return std::to_string((v >> 22) & 127) + "." +
               std::to_string((v >> 12) & 1023) + "." +
               std::to_string(v & 4095);
      };
      device = {{"name", detected.name},
                {"loaderVersion", version(detected.loader_version)},
                {"deviceVersion", version(detected.device_version)},
                {"minimumVersion", "1.1"}};
      Image probe(2, 2);
      for (auto &p : probe.pixels)
        p = {.2f, .3f, .4f, 1};
      auto result = apply(probe, {{"schema", 1},
                                  {"stage", "scanner"},
                                  {"effects", {{"scanner_profile", "neutral"}}},
                                  {"strength", 1}});
      for (auto p : result.pixels)
        if (!std::isfinite(p.r) || std::abs(p.r - .2f) > 2e-5 ||
            std::abs(p.g - .3f) > 2e-5 || std::abs(p.b - .4f) > 2e-5 ||
            p.a != 1)
          throw Failure("backendUnavailable", "Vulkan 實際計算檢查未通過");
    } catch (...) {
      if (engine && destroy)
        destroy(engine);
      FreeLibrary(library);
      library = nullptr;
      throw;
    }
  }
  ~GPU() {
    if (engine)
      destroy(engine);
    if (library)
      FreeLibrary(library);
  }
  const Json &information() const { return device; }
  Image apply(const Image &input, const Json &request, const std::vector<Image> &auxiliary = {}) {
    std::vector<PhotoComputeImageView> views;for(const auto &image:auxiliary)views.push_back({reinterpret_cast<const float *>(image.pixels.data()),uint32_t(image.width),uint32_t(image.height)});
    Image output(input.width, input.height);
    char error[2048]{};
    if (process(engine, request.dump().c_str(),
                reinterpret_cast<const float *>(input.pixels.data()),
                reinterpret_cast<float *>(output.pixels.data()),
                static_cast<uint32_t>(input.width),
                static_cast<uint32_t>(input.height), views.data(), uint32_t(views.size()), error, sizeof(error)))
      throw Failure("renderFailed", error);
    return output;
  }
};
void emit(const std::string &id, const std::string &kind, const Json &payload,
          const Json &error = nullptr) {
  Json response{{"version", 1},
                {"id", id},
                {"kind", kind},
                {"payload", payload},
                {"error", error}};
  auto line = response.dump();
  if (line.size() >= 67108864)
    throw Failure("responseTooLarge", "引擎回覆超過大小限制");
  std::cout << line << '\n' << std::flush;
}
std::string sourceKey(const std::string &path) {
  HANDLE file=CreateFileW(wide(path).c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
  if(file==INVALID_HANDLE_VALUE)throw Failure("decodeFailed","無法讀取來源照片資訊");
  BY_HANDLE_FILE_INFORMATION identity{};FILE_BASIC_INFO times{};
  bool okay=GetFileInformationByHandle(file,&identity) && GetFileInformationByHandleEx(file,FileBasicInfo,&times,sizeof(times));
  CloseHandle(file);if(!okay)throw Failure("decodeFailed","來源照片資訊讀取失敗");
  // 同一個 NTFS 檔案的尺寸與變更時間不變時，重用已解析影像；避免每次拖曳都重讀整份 RAW。
  // ChangeTime 也涵蓋刻意還原 LastWriteTime 的修改，File ID 防止同路徑替換檔案誤命中。
  return path+":"+std::to_string(identity.dwVolumeSerialNumber)+":"+std::to_string(identity.nFileIndexHigh)+":"+std::to_string(identity.nFileIndexLow)+":"+std::to_string(identity.nFileSizeHigh)+":"+std::to_string(identity.nFileSizeLow)+":"+std::to_string(times.LastWriteTime.QuadPart)+":"+std::to_string(times.ChangeTime.QuadPart);
}

void writeNew(const std::string &path,
              const std::vector<unsigned char> &bytes) {
  HANDLE file = CreateFileW(wide(path).c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    throw Failure("outputExists", "無法建立新的工作成品；不會覆寫既有檔案");
  DWORD written = 0;
  bool okay = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()),
                        &written, nullptr) &&
              written == bytes.size();
  CloseHandle(file);
  if (!okay) {
    DeleteFileW(wide(path).c_str());
    throw Failure("encodeFailed", "成品寫入不完整");
  }
}
class Worker {
  Codec codec;
  fs::path folder = executableDirectory();
  Json neutral, catalog, monochromes;
  std::unique_ptr<film_cpu::Database> database;
  std::unique_ptr<GPU> gpu;
  std::unique_ptr<NeuralRuntime> neural;
  NeuralRuntime &inferenceRuntime(){if(!neural)neural=std::make_unique<NeuralRuntime>(folder);return *neural;}
  std::unique_ptr<Vision> vision;
  Vision &visionEngine(){if(!vision)vision=std::make_unique<Vision>(folder);return *vision;}
  std::string visionKey;
  bool subjectProbed=false;
  std::optional<Image> subjectMask,depthMap;
  bool gpuProbed = false;
  std::string gpuFailure;
  std::string cachedKey;
  std::unique_ptr<Decoded> cached;
  std::vector<std::pair<unsigned, Image>> processing;
  std::string patchKey;
  std::vector<filmdevelop::RepairPatch> patches;
  film_cpu::Database &data() {
    if (!database)
      database = std::make_unique<film_cpu::Database>(
          (folder / "film-data").u8string());
    return *database;
  }
  GPU &accelerator() {
    if (!gpu && gpuProbed)
      throw Failure("backendUnavailable", gpuFailure);
    if (!gpu) {
      gpuProbed = true;
      try {
        gpu = std::make_unique<GPU>(folder);
      } catch (const std::exception &error) {
        gpuFailure = error.what();
        throw;
      }
    }
    return *gpu;
  }
  Json capabilities() {
    auto value = codec.capabilities();
    Json backends = Json::array({"system"});
    try {
      accelerator();
      backends.push_back("vulkan");
    } catch (const std::exception &error) {
      gpuFailure = error.what();
    }
    value.update(
        {{"platform", "windows-amd64"},
         {"engine", "cpp-wic"},
         {"protocolVersion", 1},
         {"recipeVersion", 1},
         {"adjustmentVersion", 12},
         {"mlx", false},
         {"methods",
          {"capabilities", "thumbnail", "metadata", "preview", "render", "whiteBalance", "prepareRepair", "repair", "analysis", "infer"}},
         {"computeBackends", backends},
         {"gpu", gpu ? gpu->information() : Json(nullptr)},
         {"computeBackendLabels",
          {{"system", gpu ? "系統自動（Vulkan）" : "系統自動（CPU）"},
           {"vulkan", "Vulkan 加速"}}},
         {"computeBackendMessage", gpuFailure},
         {"formats", Json::array({{{"id", "jpeg"}, {"bitDepths", {8}}},
                                  {{"id", "webp"}, {"bitDepths", {8}}},
                                  {{"id", "png"}, {"bitDepths", {8, 16}}},
                                  {{"id", "tiff"}, {"bitDepths", {8, 16}}}})},
         {"colorSpaces", {"sRGB", "adobeRGB", "displayP3"}},
         {"features",
          {"source-preview", "print-exposure", "development", "chemistry",
           "scanner", "film-stock", "spectral", "emulsion", "halation", "bloom", "digital-look", "hdr", "local-tone",
           "digital-exposure", "white-balance", "lab-color", "tone-zones", "color-calibration", "crop-rotation", "lens-shading",
           "saved-repair-patches", "repair", "image-analysis", "gguf-inference", "subject-mask", "face-analysis", "skin-white-balance",
           "skin-enhancement", "denoise", "depth-blur", "frame", "date-stamp", "color-managed-export"}},
         {"supportedStyles", [&] { Json styles = Json::array({"original"}); for (const auto &p : data().profiles) styles.push_back(p.first); for (const auto &p : data().digital) styles.push_back(p.first); return styles; }()},
         {"fullRenderPipeline", true},
         {"limitations",
          {"Windows 使用 GGUF 視覺模型與 ONNX／DirectML；MLX 僅適用於 macOS。"
           "主體／深度模型、降噪、景深與日期字形採跨平台實作，與 Apple 框架的像素結果可能不同。",
           "系統 RAW 優先使用 WIC；不支援來源時改用內建 LibRaw。WIC "
           "鏡頭校正由解析器決定；LibRaw 目前未提供鏡頭校正與場景線性 HDR。"
           "目前的系統解析器與 LibRaw 不支援 Nikon HE／HE* 完整顯影。"}}});
    return value;
  }
  void validate(const filmdevelop::contract::RenderJob &job) {
    if (job.recipe.version != 1 ||
        job.recipe.adjustment.value("schemaVersion", 0) != 12)
      throw Failure("unsupportedVersion", "配方版本不符");
    if (job.recipe.style != "original" && !data().profiles.count(job.recipe.style) && !data().digital.count(job.recipe.style))
      throw Failure("unsupportedParameter", "Windows 尚未移植此配方：" + job.recipe.style);
    if (!job.recipe.repairPatches.is_array())
      throw Failure("invalidRepair", "修復貼片格式不符");
    if (job.input.rawDecoder != "system" && job.input.rawDecoder != "software")
      throw Failure("backendUnavailable", "RAW 解析選項不符");
    if (job.computeBackend != "system" && job.computeBackend != "vulkan")
      throw Failure("backendUnavailable", "運算後端不符");
    if (job.previewMaxPixel < 1 || job.previewMaxPixel > 8192 ||
        job.output.maxPixel < 0 || job.output.maxPixel > 65536)
      throw Failure("invalidRequest", "影像尺寸設定不符");
    if (job.output.colorSpace != "sRGB" && job.output.colorSpace != "adobeRGB" && job.output.colorSpace != "displayP3")
      throw Failure("unsupportedParameter", "匯出色彩空間不符");
    // 以共用 Go 配方的中性資料判斷未移植的有效效果，不能偷偷忽略後輸出原片。
    const auto &a = job.recipe.adjustment;
    const std::set<std::string> supported{"intensity", "imageScoped", "sourceToneZones", "skinWhitening", "skinSmoothing", "skinWarmth", "denoise", "backgroundBlur", "frameEnabled", "frameStyle", "dateEnabled", "dateStyle",
                                          "filmEffects", "schemaVersion", "grain", "shadowGrain", "midtoneGrain", "highlightGrain", "contrast", "brightness", "hdrAmount", "hdrToneCurve",
                                          "exposure", "highlightExposure", "midtoneExposure", "shadowExposure", "vibrance", "saturation", "devignette", "vignette", "colorCalibration", "whiteBalanceWarmth", "whiteBalanceTint",
                                          "shadowIntensity", "midtoneIntensity", "highlightIntensity", "shadowWarmth", "midtoneWarmth", "highlightWarmth",
                                          "cropAspectRatio", "cropRotation", "cropScale", "cropWidth", "cropHeight", "cropHorizontalPosition", "cropVerticalPosition"};
    for (const auto &entry : a.items())
      if (!supported.count(entry.key()) &&
          (!neutral.contains(entry.key()) ||
           entry.value() != neutral.at(entry.key())))
        throw Failure("unsupportedParameter",
                      "Windows 尚未移植此調整：" + entry.key());
    const std::set<std::string> effects{
        "print_exposure",          "print_exposure_highlights",
        "print_exposure_midtones", "print_exposure_shadows",
        "development_amount",      "development_time",
        "development_diffusion",   "development_agitation",
        "developer_temperature",   "developer_activity",
        "developer_chemistry",     "scanner_profile",
        "scan_saturation",         "scan_midtone_warmth",
        "scan_highlight_warmth",   "scan_flare", "emulsion_mtf", "bloom_amount",
        "bloom_radius", "bloom_threshold", "halation_amount", "halation_radius",
        "halation_threshold", "halation_base", "film_width_mm", "grain_size",
        "grain_clumping", "grain_chroma", "grain_distribution", "layer_response",
        "monochrome_filter", "monochrome_filter_strength", "print_illuminant",
        "scanner_illuminant", "view_illuminant", "coupler_amount", "coupler_radius",
        "print_contrast", "scan_contrast", "scan_density_correction", "scan_exposure",
        "silver_retention", "scanner_source", "paper_profile", "paper_white",
        "paper_scatter", "paper_density_offset", "reciprocity_amount", "exposure_seconds"};
    for (const auto &entry : a.at("filmEffects").items())
      if (!effects.count(entry.key()) &&
          (!neutral["filmEffects"].contains(entry.key()) ||
           entry.value() != neutral["filmEffects"].at(entry.key())))
        throw Failure("unsupportedParameter",
                      "Windows 尚未移植此底片效果：" + entry.key());
    std::error_code pathError;
    if (fs::equivalent(fs::u8path(job.input.path), fs::u8path(job.output.path),
                       pathError))
      throw Failure("outputExists", "成品不得覆寫來源");
  }
  const std::vector<filmdevelop::RepairPatch> &patchesFor(const Json &value) {
    if(!value.is_array() || value.size()>32)throw Failure("invalidRepair","修復紀錄格式或數量不符");
    const auto nextPatchKey=value.dump();
    if(nextPatchKey!=patchKey) {
      std::vector<filmdevelop::RepairPatch> next;
      for(const auto &patch:value) {
        auto x=patch.at("x").get<double>(),y=patch.at("y").get<double>(),width=patch.at("width").get<double>(),height=patch.at("height").get<double>(),gain=patch.at("linearGain").get<double>();
        if(!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(width)||!std::isfinite(height)||!std::isfinite(gain)||width<=0||height<=0||gain<=0)
          throw Failure("invalidRepair","修復貼片大小、位置或增益不符");
        next.push_back({x,y,width,height,gain,codec.decodeData(unbase64(patch.at("imageData").get<std::string>())),codec.decodeData(unbase64(patch.at("maskData").get<std::string>()),true)});
      }
      patches=std::move(next);patchKey=nextPatchKey;
    }
    return patches;
  }
  Json render(const filmdevelop::contract::RenderJob &job,
              const std::string &id, bool session) {
    validate(job);
    bool accelerated = false;
    if (job.computeBackend == "vulkan") {
      accelerator();
      accelerated = true;
    } else {
      // system 是持久化的自動選擇：GPU 必須真的通過探測，否則使用既有 CPU
      // 實作。
      try {
        accelerator();
        accelerated = true;
      } catch (const Failure &) {
      }
    }
    using Clock = std::chrono::steady_clock;
    const auto started = Clock::now();
    const auto key = sourceKey(job.input.path) + ":" + job.input.rawDecoder;
    const bool cacheHit = session && cached && key == cachedKey;
    if (!cacheHit) {
      cached = std::make_unique<Decoded>(
          codec.decode(job.input.path, 0, false, job.input.rawDecoder));
      cachedKey = key;
      processing.clear();
    }
    const unsigned size =
        job.preview && !(job.policy && job.policy->fullResolution)
            ? job.previewMaxPixel
            : 0;
    auto found = std::find_if(processing.begin(), processing.end(),
                              [&](const auto &p) { return p.first == size; });
    const bool processingHit = found != processing.end();
    if (!processingHit) {
      if (processing.size() >= 2)
        processing.erase(processing.begin());
      processing.emplace_back(size, resized(cached->image, size));
      found = processing.end() - 1;
    }
    const Image source = cached->original ? resized(*cached->original, size) : found->second;
    patchesFor(job.recipe.repairPatches);
    const auto nextVisionKey=key+patchKey+(job.subjectMask?job.subjectMask->sha256:"");
    if(visionKey!=nextVisionKey){visionKey=nextVisionKey;subjectMask.reset();depthMap.reset();subjectProbed=false;}
    const bool subjectCacheHit=job.recipe.detectSubject && subjectProbed;
    const bool depthCacheHit=job.recipe.detectSubject && depthMap.has_value();
    if(job.recipe.detectSubject) {
      if(!subjectProbed){if(job.subjectMask)subjectMask=savedSubjectMask(*job.subjectMask);else{emit(id,"progress",.12);auto prepared=filmdevelop::apply_repair_patches(resized(cached->image,800),patches);subjectMask=visionEngine().subject(prepared);}subjectProbed=true;}
      if(subjectMask && !depthMap && film_cpu::number(job.recipe.adjustment,"backgroundBlur",0,0,100)>.5){emit(id,"progress",.16);auto prepared=filmdevelop::apply_repair_patches(resized(cached->image,800),patches);depthMap=visionEngine().depth(prepared);}
    }
    const auto *subject=job.recipe.detectSubject && subjectMask?&*subjectMask:nullptr;
    const auto *depth=job.recipe.detectSubject && depthMap?&*depthMap:nullptr;
    if(job.preview && !job.subjectMask && job.subjectMaskOutputPath && subject) {
      std::ofstream file(fs::path(wide(*job.subjectMaskOutputPath)),std::ios::binary);
      file.write("FYPMASK1",8);uint32_t w=uint32_t(subject->width),h=uint32_t(subject->height);
      file.write(reinterpret_cast<const char*>(&w),4);file.write(reinterpret_cast<const char*>(&h),4);
      file.write(reinterpret_cast<const char*>(subject->pixels.data()),std::streamsize(subject->pixels.size()*16));
      file.close();if(!file)throw Failure("invalidMask","無法保存主體遮罩");
    }
    const auto decoded = Clock::now();
    emit(id, "progress", .2);
    auto finish = [&](bool useGPU) {
      filmdevelop::ComputeImage compute;
      if (useGPU) compute = [&](const Image &input, const Json &plan, const std::vector<Image> &auxiliary) { return accelerator().apply(input, plan, auxiliary); };
      return filmdevelop::render_style(found->second, source, job, neutral, catalog, monochromes, data(), compute, patches,subject,depth);
    };
    Image image(source.width, source.height);
    try { image = finish(accelerated); }
    catch (const Failure &error) {
      if (!accelerated || job.computeBackend != "system") throw;
      gpuFailure = error.what(); gpu.reset(); gpuProbed = true; accelerated = false;
      image = finish(false);
    }
    emit(id, "progress", .8);
    const auto rendered = Clock::now();
    auto output = resized(image, job.output.maxPixel);
    auto bytes = codec.encode(output, job.output.format, job.output.bitDepth,
                              job.output.quality, job.output.tiffCompression,job.output.colorSpace,job.output.webPLossless);
    const filmdevelop::CropGeometry fullGeometry(cached->image.width,cached->image.height,job.recipe.adjustment);
    const filmdevelop::FrameGeometry fullFrame(fullGeometry.columns,fullGeometry.rows,job.recipe.adjustment);
    Json result{{"width", output.width},
                {"height", output.height},
                {"sourceWidth", cached->image.width},
                {"sourceHeight", cached->image.height},
                {"cropWidth", int(fullGeometry.width)},
                {"cropHeight", int(fullGeometry.height)},
                {"outputWidth", fullFrame.width},
                {"outputHeight", fullFrame.height},
                {"bytes", bytes.size()},
                {"computeBackend", job.computeBackend},
                {"computeRoute", accelerated ? "vulkan" : "cpu"},
                {"computeFallback", accelerated ? "" : gpuFailure},
                {"rawDecoder", cached->backend},
                {"systemRAWFallback", cached->systemFallback},
                {"subjectDetected",subject!=nullptr},
                {"depthAvailable",depth!=nullptr},
                {"softwareRAWFallback", false}};
    if (job.preview) {
      auto editing = job; editing.recipe.adjustment = filmdevelop::source_editing_adjustment(job.recipe.adjustment);
      Image editor = image;
      if(editing.recipe.adjustment != job.recipe.adjustment) {
        filmdevelop::ComputeImage compute;
        if(accelerated)compute=[&](const Image &input,const Json &plan,const std::vector<Image> &auxiliary){return accelerator().apply(input,plan,auxiliary);};
        try { editor=filmdevelop::render_style(found->second,source,editing,neutral,catalog,monochromes,data(),compute,patches,subject,depth); }
        catch(const Failure &error) {
          if(!accelerated || job.computeBackend!="system")throw;
          gpuFailure=error.what();gpu.reset();gpuProbed=true;accelerated=false;
          editor=filmdevelop::render_style(found->second,source,editing,neutral,catalog,monochromes,data(),{},patches,subject,depth);
        }
      }
      result["cropImage"] =
          "data:image/jpeg;base64," +
          base64(editing.recipe.adjustment == job.recipe.adjustment && job.output.format == "jpeg" && job.output.quality == .88 && job.output.maxPixel == job.previewMaxPixel && job.output.colorSpace == "sRGB"
                     ? bytes
                     : codec.encode(resized(editor, job.previewMaxPixel), "jpeg",
                                    8, .88));
      result["sourceImage"] =
          "data:image/jpeg;base64," +
          base64(codec.encode(resized(filmdevelop::CropGeometry(source.width,source.height,job.recipe.adjustment).apply(source), job.previewMaxPixel), "jpeg", 8,
                              .88));
      result["computeRoute"]=accelerated?"vulkan":"cpu";result["computeFallback"]=accelerated?"":gpuFailure;
      auto ms = [](auto a, auto b) {
        return std::chrono::duration<double, std::milli>(b - a).count();
      };
      result["timing"] = {{"sourceCacheHit", cacheHit},
                          {"processingCacheHit", processingHit},
                          {"subjectCacheHit", subjectCacheHit},
                          {"depthCacheHit", depthCacheHit},
                          {"decodeMilliseconds", ms(started, decoded)},
                          {"renderMilliseconds", ms(decoded, rendered)},
                          {"encodeMilliseconds", ms(rendered, Clock::now())}};
    }
    writeNew(job.output.path, bytes);
    emit(id, "progress", 1.0);
    return result;
  }

public:
  Worker() {
    std::ifstream file(folder / "neutral-recipe.json");
    if (!file)
      throw Failure("nativeFailure", "缺少共用原片配方資料");
    file >> neutral;
    std::ifstream stylesFile(folder / "style-catalog.json");
    if (!stylesFile) throw Failure("nativeFailure", "缺少共用配方目錄");
    Json styles; stylesFile >> styles;
    for (const auto &style : styles.at("styles")) {
      const auto id = style.at("id").get<std::string>();
      catalog[id] = style.at("adjustment"); monochromes[id] = style.at("isMonochrome");
    }
  }
  Json execute(const filmdevelop::contract::Request &request, bool session) {
    if (request.version != 1)
      throw Failure("unsupportedVersion", "不支援此引擎契約版本");
    if (session && request.method != "preview")
      throw Failure("invalidRequest", "預覽工作階段只接受 preview");
    if (request.method == "capabilities")
      return capabilities();
    if (request.method == "whiteBalance") {
      auto v = request.payload.get<filmdevelop::contract::WhiteBalanceRequest>();
      try {
        auto result = photocore::film_cpu::neutral_balance({v.red,v.green,v.blue},v.warmth,v.tint,v.strength,data());
        return {{"warmth",result.first},{"tint",result.second}};
      } catch(const std::invalid_argument &) {
        throw Failure("invalidSample","此處過暗或已過曝，請改選灰色或白色區域。");
      }
    }
    if(request.method=="analysis") {
      auto value=request.payload.get<filmdevelop::contract::AnalysisRequest>();
      auto decoded=codec.decode(value.input.path,0,false,value.input.rawDecoder);
      auto prepared=filmdevelop::apply_repair_patches(std::move(decoded.image),patchesFor(value.recipe.repairPatches));
      return analyze_photo(prepared,codec,visionEngine().faces(resized(prepared,800)));
    }
    if(request.method=="infer")return infer_photo(request.payload.get<filmdevelop::contract::InferenceRequest>(),folder,[&](double value){emit(request.id,"progress",value);});
    if(request.method=="prepareRepair") {
      auto value=request.payload.get<filmdevelop::contract::FileRequest>();
      return inferenceRuntime().prepare(fs::u8path(value.path)/L"lama_fp32.onnx");
    }
    if(request.method=="repair") {
      auto value=request.payload.get<filmdevelop::contract::RepairRequest>();
      if(value.recipe.repairPatches.size()>=32)throw Failure("tooManyRepairs","這張照片的修復次數已達上限，請先匯出成品再繼續。");
      auto decoded=codec.decode(value.input.path,0,false,value.input.rawDecoder);
      auto source=filmdevelop::apply_repair_patches(std::move(decoded.image),patchesFor(value.recipe.repairPatches));
      return repair_photo(source,value.strokes,fs::u8path(value.modelDirectory),inferenceRuntime(),codec);
    }
    if (request.method == "metadata") {
      auto v = request.payload.get<filmdevelop::contract::FileRequest>();
      return codec.metadata(v.path);
    }
    if (request.method == "thumbnail") {
      auto v = request.payload.get<filmdevelop::contract::ThumbnailRequest>();
      if (v.maxPixel < 32 || v.maxPixel > 512)
        throw Failure("invalidRequest", "縮圖大小不符");
      auto decoded = codec.decode(v.path, v.maxPixel, true);
      auto bytes = codec.encode(decoded.image, "jpeg", 8, .8);
      return {{"imageData", base64(bytes)},
              {"width", decoded.image.width},
              {"height", decoded.image.height}};
    }
    if (request.method == "preview" || request.method == "render") {
      auto job = request.payload.get<filmdevelop::contract::RenderJob>();
      if (request.method == "preview" && !job.preview)
        throw Failure("invalidRequest", "preview 工作不得匯出");
      return render(job, request.id, session);
    }
    throw Failure("unsupportedMethod",
                  "此 Windows 引擎尚未提供操作：" + request.method);
  }
};
} // namespace
int main(int argc, char **argv) {
  std::string id;
  try {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX |
                 SEM_NOOPENFILEERRORBOX);
    checked(CoInitializeEx(nullptr, COINIT_MULTITHREADED),
            "無法初始化 Windows 影像環境");
    struct COMLifetime {
      ~COMLifetime() { CoUninitialize(); }
    } com;
    Worker worker;
    const bool session =
        argc == 2 && std::string(argv[1]) == "--preview-session";
    if (argc != 1 && !session)
      throw Failure("invalidRequest", "未知引擎啟動參數");
    std::string line;
    char c;
    while (std::cin.get(c)) {
      if (c == '\n') {
        auto packet = Json::parse(line);
        id = packet.value("id", std::string{});
        auto request = packet.get<filmdevelop::contract::Request>();
        auto result = worker.execute(request, session);
        emit(id, "result", result);
        line.clear();
        if (!session)
          return 0;
      } else {
        if (line.size() >= 67108864)
          throw Failure("requestTooLarge", "引擎請求超過大小限制");
        line.push_back(c);
      }
    }
    if (!line.empty())
      throw Failure("invalidRequest", "引擎請求未完整結束");
    return 0;
  } catch (const std::exception &error) {
    const auto *failure = dynamic_cast<const Failure *>(&error);
    try {
      emit(id, "error", nullptr,
           {{"code", failure ? failure->code : "nativeFailure"},
            {"message", error.what()}});
    } catch (...) {
    }
    return 1;
  }
}
