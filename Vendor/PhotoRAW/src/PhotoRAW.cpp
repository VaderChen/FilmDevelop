#include "PhotoRAW.h"
#include "RasterOutput.hpp"
#include "OptimizedMapping.hpp"
#include <map>
#include <mutex>

namespace {
std::mutex decoderMutex;
thread_local std::string lastError;
struct Mapping {
    ColorMapping reference;
    OptimizedMapping optimized;
    explicit Mapping(const std::filesystem::path& p): reference(p), optimized(reference) {}
};
std::map<std::filesystem::path, std::unique_ptr<Mapping>> mappings;
void checked(int error) { if(error) throw std::runtime_error(libraw_strerror(error)); }
}
extern "C" const char* photo_raw_error() { return lastError.c_str(); }
extern "C" void photo_raw_free(PhotoRAWPixels* out) {
    if(!out) return;
    std::free(out->linear_rgba); std::free(out->display_rgb); *out = {};
}
extern "C" int photo_raw_decode(const unsigned char* bytes, size_t length, int half,
                                const char* directory, PhotoRAWPixels* out) {
    if(!out) return -1;
    *out = {};
    try {
        if(!bytes || !length || !directory || (half != 0 && half != 1))
            throw std::runtime_error("Invalid RAW input");
        // The pinned LIBRAW_NOTHREADS build contains shared demosaic state.
        // Serialize every instance rather than relying on Swift caller queues.
        std::lock_guard<std::mutex> lock(decoderMutex);
        // LibRaw's state exceeds the small stack of a GCD/pthread worker.
        // The standalone CLI ran on the larger main-thread stack; app calls
        // must put this state on the heap.
        auto storage = std::make_unique<photoraw::CpuRaw>();
        auto& raw = *storage;
        auto& p = raw.imgdata.params;
        p.output_bps=16; p.output_color=1; p.gamm[0]=1; p.gamm[1]=1;
        p.use_camera_wb=1; p.use_auto_wb=0; p.use_camera_matrix=1;
        p.no_auto_bright=1; p.auto_bright_thr=.01; p.bright=1;
        p.adjust_maximum_thr=0; p.no_auto_scale=0; p.user_qual=3;
        p.half_size=half; p.four_color_rgb=0; p.highlight=0;
        p.exp_correc=0; p.threshold=0; p.med_passes=0; p.fbdd_noiserd=0; p.user_flip=-1;
        checked(raw.open_buffer(const_cast<unsigned char*>(bytes),length));
        checked(raw.unpack()); checked(raw.dcraw_process());
        auto linear = raw.render(true);
        // Gamma affects final materialization only. Reuse the developed raster
        // for the separately calibrated Original view; never feed its LUT into
        // the linear film input and never decode through an 8-bit PNG.
        p.output_bps=8; p.gamm[0]=1./2.4; p.gamm[1]=12.92;
        auto display = raw.render();
        const auto path = ColorMapping::find(std::filesystem::u8path(directory),
                                             raw.imgdata.idata.make, raw.imgdata.idata.model);
        if(!path.empty()) {
            auto& mapping = mappings[path];
            if(!mapping) mapping = std::make_unique<Mapping>(path);
            const double ev = mapping->reference.useDngBaseline
                ? raw.imgdata.color.dng_levels.baseline_exposure : 0;
            mapping->optimized.apply(display.data(),display.data_size,ev,4);
        }
        if(linear.width != display.width || linear.height != display.height)
            throw std::runtime_error("RAW output dimensions differ");
        out->width=linear.width; out->height=linear.height; out->mapping_applied=!path.empty();
        out->linear_rgba=reinterpret_cast<float*>(linear.storage.release());
        out->display_rgb=display.storage.release();
        lastError.clear(); return 0;
    } catch(const std::exception& e) {
        lastError=e.what(); photo_raw_free(out); return -1;
    } catch(...) {
        lastError="Unknown RAW decoding error"; photo_raw_free(out); return -1;
    }
}
