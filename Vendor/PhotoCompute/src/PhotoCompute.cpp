#include "PhotoCompute.h"
#include "pipeline.hpp"
#include <cstring>
#include <memory>
#include <mutex>
namespace photocore::vk {
class AppBridge {
  public:
    static Surface apply(Pipeline &p, Surface image, const film_cpu::Json &request) {
        using namespace film_cpu;
        if (request.at("schema").get<int>() != 1) throw std::invalid_argument("不支援的計算契約版本");
        const auto stage = request.at("stage").get<std::string>();
        Effects e{request.at("effects")};
        e.json["_origin_x"] = number(request,"originX",0,-1e9,1e9);
        e.json["_origin_y"] = number(request,"originY",0,-1e9,1e9);
        const double strength = number(request, "strength", 1, 0, 1);
        const bool mono = request.value("monochrome", false);
        if (stage == "denoise") { double amount=number(request.at("adjustment"),"denoise",0,0,100)/100*strength;return amount>.005?p.smooth_channels(image,2,std::pow(amount*.08,2)):image; }
        if (stage == "skinMask") return p.skin_mask(std::move(image));
        if (stage == "digitalLook") return p.digital_look(std::move(image), p.database.digital.at(request.at("style").get<std::string>()));
        if (stage == "localTone") return p.local_tone(std::move(image), request.at("adjustment"), strength, request.value("hdr", true));
        if (stage == "planTone") return p.plan_tone(std::move(image), request.at("adjustment"), strength, mono);
        if (stage == "tone") return p.local_tone(std::move(image), request.at("adjustment"), strength, false);
        if (stage == "hdr") {
            auto settings=request.at("adjustment");settings["brightness"]=50;settings["contrast"]=0;
            return p.local_tone(std::move(image), settings, strength, request.value("hdr",true));
        }
        if (stage == "labColor") return p.lab_adjustment(std::move(image), request.at("adjustment"));
        if (stage == "whiteBalance") return p.white_balance(std::move(image), request.at("adjustment"), strength);
        if (stage == "toneZones") return p.tone_zones(std::move(image), request.at("adjustment"), strength, mono, request.at("style").get<std::string>());
        if (stage == "digitalPrint") return p.digital_print(std::move(image), e);
        if (stage == "monochromeFilter") return p.monochrome_filter(std::move(image), e, strength);
        if (stage == "lensShading") return p.lens_shading(std::move(image), request.at("adjustment"), strength);
        if (stage == "calibration") {
            Calibration calibration;calibration.rows=request.at("adjustment").at("colorCalibration").at("rows").get<decltype(calibration.rows)>();
            return p.calibration(std::move(image),calibration);
        }
        if (stage == "digitalExposure" || stage == "printExposure") {
            Exposure exposure;
            if(stage=="digitalExposure") {
                const auto &a=request.at("adjustment");
                double ev=slider_to_ev(number(a,"exposure",0,-100,100)*strength);
                exposure.zones={ev,ev,ev};image=p.exposure(std::move(image),exposure);
                exposure.zones={slider_to_ev(number(a,"highlightExposure",0,-100,100)*strength),
                    slider_to_ev(number(a,"midtoneExposure",0,-100,100)*strength),slider_to_ev(number(a,"shadowExposure",0,-100,100)*strength)};
            } else {
                exposure.global_ev=e.get("print_exposure",0,-16,16);
                exposure.zones={e.get("print_exposure_highlights",exposure.global_ev,-16,16),e.get("print_exposure_midtones",exposure.global_ev,-16,16),e.get("print_exposure_shadows",exposure.global_ev,-16,16)};
                exposure.protect_highlights=request.value("highlightProtection",true);
                exposure.protect_peak=request.value("modernExposure",false);
            }
            return p.exposure(std::move(image),exposure);
        }
        if (stage == "rawMapping") return p.raw_mapping(std::move(image));
        if (stage == "monochrome") return p.unary(20, std::move(image), {}, "monochrome");
        if (stage == "lightScatter") return p.light_scatter(std::move(image), e, strength);
        if (stage == "emulsion") return p.emulsion(std::move(image), e, request.at("adjustment"), strength, mono, request.value("preview", false));
        if (stage == "development") return p.develop(std::move(image), e, strength);
        if (stage == "chemistry") return p.chemistry(std::move(image), e, strength, mono);
        if (stage == "spectral" || stage == "character") {
            const auto &profile = p.database.profiles.at(request.at("stock").get<std::string>());
            if (stage == "spectral") return p.spectral(std::move(image), e, strength, profile);
            if (profile.character.empty()) return image;
            if (profile.character.size() != 6) throw std::runtime_error("底片特性資料不完整");
            std::vector<float> params(profile.character.begin(), profile.character.end());
            params.push_back(float(profile.mono));
            return p.unary(16, image, params, "character");
        }
        if (stage == "scanner") {
            if (e.text("scanner_profile", "off") == "off") return image;
            const auto &s = p.database.scanner_styles.at(e.text("scanner_profile", "off"));
            // 原片／底片的灰階與強度混合由共用管線依原始順序執行。
            std::vector<float> params{float(e.get("scan_saturation",50)/50),
                float((e.get("scan_midtone_warmth",0,-100,100)+s[4])/100),
                float((e.get("scan_highlight_warmth",0,-100,100)+s[5])/100),
                float(std::pow(e.get("scan_flare")/100,2)*.005),float(s[0]),float(s[1]),float(s[2]),0};
            return p.unary(17, image, params, "scanner");
        }
        throw std::invalid_argument("未支援的計算階段：" + stage);
    }
    static Surface plan(Pipeline &p, Surface input, const film_cpu::Json &request, const std::vector<Surface> &inputs = {}) {
        const auto &nodes = request.at("nodes");
        if (!nodes.is_array() || nodes.empty() || nodes.size() > 64)
            throw std::invalid_argument("計算圖節點數不合法");
        // 預先驗證所有相依關係，並計算使用次數；最後一位使用者完成即釋放影像。
        std::vector<size_t> consumers(nodes.size()+1, 0);
        for (size_t i=0; i<nodes.size(); ++i) {
            const auto &node=nodes.at(i);
            if (node.at("operation").at("schema").get<int>() != 1)
                throw std::invalid_argument("計算圖節點契約版本不符");
            for (const char *key : {"source", "secondary", "tertiary"}) {
                if (std::strcmp(key,"source")!=0 && (!node.contains(key) || node.at(key).is_null())) continue;
                const auto index=node.at(key).get<int64_t>();
                if (index<0 || uint64_t(index)>i) throw std::invalid_argument("計算圖含無效或向後相依");
                ++consumers[size_t(index)];
            }
            if ((node.at("operation").at("stage")=="blend" || node.at("operation").at("stage")=="skinEnhancement") &&
                (!node.contains("secondary") || node.at("secondary").is_null()))
                throw std::invalid_argument("混合節點缺少第二張影像");
        }
        ++consumers.back(); // 保留最終輸出。
        std::vector<Surface> images(nodes.size()+1);
        images[0]=std::move(input);
        for (size_t i=0; i<nodes.size(); ++i) {
            const auto &node=nodes.at(i), &op=node.at("operation");
            const auto source=node.at("source").get<size_t>();
            if (op.at("stage")=="external") {
                const auto input=op.at("input").get<size_t>();
                if(input>=inputs.size())throw std::invalid_argument("外部影像索引不符");
                images[i+1]=inputs[input];
            } else if (op.at("stage")=="blend") {
                const auto secondary=node.at("secondary").get<size_t>();
                const float strength=float(film_cpu::number(op,"strength",1,0,1));
                if (strength<=0) images[i+1]=images[source];
                else if (strength>=1) images[i+1]=images[secondary];
                else {
                    auto &base=images[source], &foreground=images[secondary];
                    auto out=p.context.create(base.width,base.height);
                    p.context.dispatch(19,base,foreground,base,out,out,{strength},p.table,0,"blend");
                    images[i+1]=std::move(out);
                }
            } else if(op.at("stage")=="skinMask" && node.contains("secondary")) {
                images[i+1]=p.skin_mask(images[source],images[node.at("secondary").get<size_t>()]);
            } else if(op.at("stage")=="skinWhiteBalance") {
                images[i+1]=p.skin_white_balance(images[source],images[node.at("secondary").get<size_t>()],film_cpu::number(op,"strength",1,0,1));
            } else if(op.at("stage")=="backgroundBlur") {
                images[i+1]=p.background_blur(images[source],images[node.at("secondary").get<size_t>()],images[node.at("tertiary").get<size_t>()],film_cpu::number(op.at("adjustment"),"backgroundBlur",0,0,100)/100,op.value("focusedDepth",false));
            } else if(op.at("stage")=="skinEnhancement") {
                images[i+1]=p.skin_enhance(images[source],images[node.at("secondary").get<size_t>()],op.at("adjustment"),film_cpu::number(op,"strength",1,0,1));
            } else images[i+1]=apply(p,images[source],op);
            for (const char *key : {"source", "secondary", "tertiary"}) {
                if (!node.contains(key) || node.at(key).is_null()) continue;
                const auto index=node.at(key).get<size_t>();
                if (--consumers[index]==0) images[index]={};
            }
            if (consumers[i+1]==0) images[i+1]={};
        }
        return std::move(images.back());
    }
};
}
namespace {
void fail(char *error, size_t capacity, const char *message) {
    if (error && capacity) { std::strncpy(error,message,capacity-1); error[capacity-1]=0; }
}
struct Engine {
    std::mutex mutex;
    photocore::vk::Pipeline pipeline;
    Engine(const char *data, const char *shader):pipeline(data,shader,false) {}
};
}
uint32_t photo_compute_abi() { return 2; }
void *photo_compute_create(const char *data, const char *shader, char *error, size_t capacity) {
    try {
        if (!data || !shader) throw std::invalid_argument("缺少運算資源路徑");
        return new Engine(data,shader);
    } catch (const std::exception &e) { fail(error,capacity,e.what()); }
      catch (...) { fail(error,capacity,"Vulkan 初始化失敗"); }
    return nullptr;
}
int photo_compute_process_inputs(void *handle, const char *request, const float *input, float *output,
                          uint32_t width, uint32_t height, const PhotoComputeImageView *inputs, uint32_t input_count, char *error, size_t capacity) {
    try {
        if (!handle || !request || !input || !output || !width || !height ||
            width > SIZE_MAX / height / sizeof(photocore::Pixel) || input == output)
            throw std::invalid_argument("不合法的影像緩衝區");
        auto &engine=*static_cast<Engine*>(handle);
        std::lock_guard<std::mutex> lock(engine.mutex);
        auto &p=engine.pipeline;
        p.context.stats.clear();
        photocore::Image image(width,height);
        std::memcpy(image.pixels.data(),input,image.pixels.size()*sizeof(photocore::Pixel));
        for (const auto &px:image.pixels)
            for (float v:{px.r,px.g,px.b,px.a}) if(!std::isfinite(v)) throw std::invalid_argument("來源含非有限值");
        auto gpu=p.context.upload(image);
        image.pixels.clear(); image.pixels.shrink_to_fit();
        if(input_count>4 || (input_count && !inputs))throw std::invalid_argument("外部影像數量不符");
        std::vector<photocore::vk::Surface> external;
        for(uint32_t i=0;i<input_count;++i) {
            const auto &view=inputs[i];
            if(!view.pixels || view.width!=width || view.height!=height || view.pixels==output)throw std::invalid_argument("外部影像尺寸或緩衝區不符");
            photocore::Image aux(width,height);std::memcpy(aux.pixels.data(),view.pixels,aux.pixels.size()*sizeof(photocore::Pixel));
            for(auto p:aux.pixels)for(float v:{p.r,p.g,p.b,p.a})if(!std::isfinite(v))throw std::invalid_argument("外部影像含非有限值");
            external.push_back(p.context.upload(aux));
        }
        auto packet=photocore::film_cpu::Json::parse(request);
        if (packet.at("schema").get<int>() == 2)
            gpu=photocore::vk::AppBridge::plan(p,std::move(gpu),packet,external);
        else gpu=photocore::vk::AppBridge::apply(p,std::move(gpu),packet);
        auto result=p.context.download(gpu);
        for (const auto &px:result.pixels)
            for (float v:{px.r,px.g,px.b,px.a}) if(!std::isfinite(v)) throw std::runtime_error("GPU 成品含非有限值");
        if(result.width!=width || result.height!=height)throw std::invalid_argument("GPU 成品尺寸與目的緩衝區不符");
        std::memcpy(output,result.pixels.data(),result.pixels.size()*sizeof(photocore::Pixel));
        return 0;
    } catch(const std::exception &e) { fail(error,capacity,e.what()); }
      catch(...) { fail(error,capacity,"Vulkan 計算失敗"); }
    return 1;
}
int photo_compute_process(void *handle, const char *request, const float *input, float *output,
                          uint32_t width, uint32_t height, char *error, size_t capacity) {
    return photo_compute_process_inputs(handle,request,input,output,width,height,nullptr,0,error,capacity);
}
void photo_compute_destroy(void *handle) { delete static_cast<Engine*>(handle); }
int photo_compute_transfers(void *handle, PhotoComputeTransfers *output) {
    if (!handle || !output) return 1;
    try {
        auto &engine=*static_cast<Engine*>(handle);
        std::lock_guard<std::mutex> lock(engine.mutex);
        const auto &c=engine.pipeline.context;
        *output={c.image_uploads,c.image_downloads,c.uploaded_bytes,c.downloaded_bytes};
        return 0;
    } catch (...) { return 1; }
}
int photo_compute_device_info(void *handle, PhotoComputeDeviceInfo *output) {
    if (!handle || !output) return 1;
    try {
        auto &engine=*static_cast<Engine*>(handle);
        std::lock_guard<std::mutex> lock(engine.mutex);
        const auto &c=engine.pipeline.context;
        *output={c.loader_version(),c.device_version(),{}};
        const auto name=c.device_name();
        std::strncpy(output->name,name.c_str(),sizeof(output->name)-1);
        return 0;
    } catch (...) { return 1; }
}
