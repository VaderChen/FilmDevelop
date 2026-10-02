#include "film_internal.hpp"
#include <cstring>
#include <filesystem>
#include <fstream>

namespace photocore::film_cpu {
Matrix Database::white_balance_matrix(double warmth,double tint) const {
    Matrix result{V(1,0,0),V(0,1,0),V(0,0,1)};
    if(std::abs(warmth)<=.001 && std::abs(tint)<=.001)return result;
    if(white_balance.empty())throw std::runtime_error("缺少共用白平衡資料");
    double x=(std::clamp(warmth,-140.,140.)+140)/2,y=(std::clamp(tint,-140.,140.)+140)/2;
    int ix=std::min(139,int(x)),iy=std::min(139,int(y));x-=ix;y-=iy;
    for(int r=0;r<3;++r)for(int c=0;c<3;++c) {
        auto at=[&](int dx,int dy){return double(white_balance[((iy+dy)*141+ix+dx)*9+r*3+c]);};
        result[r][c]=(at(0,0)*(1-x)+at(1,0)*x)*(1-y)+(at(0,1)*(1-x)+at(1,1)*x)*y;
    }
    return result;
}
Database::Database(const std::string &folder) {
    auto root = std::filesystem::u8path(folder);
    std::ifstream frame(root / "editor/frame-sampling.bin",std::ios::binary|std::ios::ate);
    if(frame) {
        constexpr size_t phases=256*256*9;auto size=frame.tellg();frame.seekg(0);
        unsigned char header[16]{};frame.read(reinterpret_cast<char *>(header),16);
        auto u16=[&](int i){return unsigned(header[i])|(unsigned(header[i+1])<<8);};
        unsigned count=u16(12)|(u16(14)<<16);
        if(std::memcmp(header,"FDSF",4)!=0 || u16(4)!=1 || u16(6)!=256 || u16(8)!=9 || u16(10)!=3 || count==0 || count>256 || size!=std::streamoff(16+count*9*sizeof(float)+phases))
            throw std::runtime_error("框圖取樣相位表格式不符");
        frame_sampling.resize(count);frame_phase_indices.resize(phases);
        frame.read(reinterpret_cast<char *>(frame_sampling.data()),count*9*sizeof(float));
        frame.read(reinterpret_cast<char *>(frame_phase_indices.data()),phases);
        if(!frame)throw std::runtime_error("框圖取樣相位表讀取不完整");
        for(const auto &kernel:frame_sampling) {
            double sum=0;for(float v:kernel){if(!std::isfinite(v) || v<0 || v>1)throw std::runtime_error("框圖取樣相位表非有限值");sum+=v;}
            if(std::abs(sum-1)>1e-5)throw std::runtime_error("框圖取樣相位表權重不符");
        }
        for(auto index:frame_phase_indices)if(index>=count)throw std::runtime_error("框圖核心索引不符");
    }
    std::ifstream radial(root / "editor/vignette.f32",std::ios::binary|std::ios::ate);
    if(radial) {
        if(radial.tellg()!=std::streamoff(4097*sizeof(float)))throw std::runtime_error("暗角曲線長度不符");
        vignette.resize(4097);radial.seekg(0);radial.read(reinterpret_cast<char *>(vignette.data()),vignette.size()*sizeof(float));
        for(float v:vignette)if(!std::isfinite(v) || v<0 || v>1)throw std::runtime_error("暗角曲線數值不符");
    }
    std::ifstream balance(root / "editor/white-balance.f32", std::ios::binary | std::ios::ate);
    if (balance) {
        constexpr size_t count = 141 * 141 * 9;
        if (balance.tellg() != std::streamoff(count * sizeof(float))) throw std::runtime_error("白平衡資料長度不符");
        white_balance.resize(count); balance.seekg(0); balance.read(reinterpret_cast<char *>(white_balance.data()), count * sizeof(float));
        for (float v : white_balance) if (!std::isfinite(v)) throw std::runtime_error("白平衡資料非有限值");
    }
    std::ifstream looks(root / "digital-looks/manifest.json");
    std::ifstream toneFile(root / "editor/tone-zones.json");
    if(toneFile) {
        Json zones;toneFile>>zones;
        for(const auto &style:zones.items()) {
            auto &mappings=tone_mappings[style.key()];
            if(style.value().size()!=3)throw std::runtime_error("三區色調數量不符");
            for(int i=0;i<3;++i) {
                auto &mapping=mappings[i];const auto &entry=style.value().at(i);
                auto rows=entry.at("rows").get<std::array<std::array<double,4>,3>>();
                for(int r=0;r<3;++r) {
                    for(double v:rows[r])if(!std::isfinite(v))throw std::runtime_error("三區色調矩陣非有限值");
                    mapping.rows[r]={rows[r][0],rows[r][1],rows[r][2]};mapping.bias[r]=rows[r][3];
                }
                if(entry.contains("curve")) {
                    auto name=entry.at("curve").get<std::string>();
                    if(std::filesystem::path(name).filename()!=name)throw std::runtime_error("三區色調曲線路徑不符");
                    std::ifstream curve(root / "editor" / name,std::ios::binary|std::ios::ate);
                    if(!curve || curve.tellg()!=std::streamoff(16385*sizeof(float)))throw std::runtime_error("三區色調曲線長度不符");
                    mapping.curve.resize(16385);curve.seekg(0);curve.read(reinterpret_cast<char *>(mapping.curve.data()),mapping.curve.size()*sizeof(float));
                    for(float v:mapping.curve)if(!std::isfinite(v))throw std::runtime_error("三區色調曲線非有限值");
                }
            }
        }
    }
    if (looks) {
        Json manifest; looks >> manifest;
        if (manifest.at("schema") != 1) throw std::runtime_error("數位風格資料版本不符");
        for (const auto &item : manifest.at("styles")) {
            DigitalLook look; look.dimension = item.at("dimension");
            if (look.dimension < 2 || look.dimension > 129) throw std::runtime_error("風格色彩表尺寸不符");
            if(item.contains("axis")) {
                look.axis=item.at("axis").get<std::vector<float>>();
                if(look.axis.size()!=std::size_t(look.dimension))throw std::runtime_error("風格色彩座標數量不符");
                for(std::size_t i=0;i<look.axis.size();++i)
                    if(!std::isfinite(look.axis[i]) || (i && look.axis[i]<=look.axis[i-1]))throw std::runtime_error("風格色彩座標必須遞增");
            }
            if(item.contains("affine")) {
                look.affine=item.at("affine").get<std::vector<float>>();
                if(look.affine.size()!=12)throw std::runtime_error("風格色彩矩陣尺寸不符");
                for(float v:look.affine)if(!std::isfinite(v))throw std::runtime_error("風格色彩矩陣非有限值");
            }
            const auto name = item.at("file").get<std::string>();
            if (std::filesystem::path(name).filename() != name) throw std::runtime_error("風格色彩表路徑不符");
            std::ifstream table(root / "digital-looks" / name, std::ios::binary | std::ios::ate);
            const auto count = std::size_t(look.dimension) * look.dimension * look.dimension * 4;
            if (!table || table.tellg() != std::streamoff(count * sizeof(float))) throw std::runtime_error("風格色彩表缺少或長度不符");
            look.table.resize(count); table.seekg(0); table.read(reinterpret_cast<char *>(look.table.data()), count * sizeof(float));
            for (float v : look.table) if (!std::isfinite(v)) throw std::runtime_error("風格色彩表非有限值");
            look.casts = item.at("casts"); look.spatial = item.at("spatial");
            if(item.contains("monochromeCurve")) {
                auto name=item.at("monochromeCurve").get<std::string>();
                if(std::filesystem::path(name).filename()!=name)throw std::runtime_error("灰階曲線路徑不符");
                std::ifstream curve(root / "digital-looks" / name,std::ios::binary|std::ios::ate);
                if(!curve || curve.tellg()!=std::streamoff(32769*4*sizeof(float)))throw std::runtime_error("灰階曲線長度不符");
                look.monochrome_curve.resize(32769*4);curve.seekg(0);curve.read(reinterpret_cast<char *>(look.monochrome_curve.data()),look.monochrome_curve.size()*sizeof(float));
                for(float v:look.monochrome_curve)if(!std::isfinite(v))throw std::runtime_error("灰階曲線非有限值");
            }
            if(item.contains("outputCurve")) {
                auto name=item.at("outputCurve").get<std::string>();
                if(std::filesystem::path(name).filename()!=name)throw std::runtime_error("輸出曲線路徑不符");
                std::ifstream curve(root / "digital-looks" / name,std::ios::binary|std::ios::ate);
                if(!curve || curve.tellg()!=std::streamoff(32769*4*sizeof(float)))throw std::runtime_error("輸出曲線長度不符");
                look.output_curve.resize(32769*4);curve.seekg(0);curve.read(reinterpret_cast<char *>(look.output_curve.data()),look.output_curve.size()*sizeof(float));
                for(float v:look.output_curve)if(!std::isfinite(v))throw std::runtime_error("輸出曲線非有限值");
            }
            if(item.contains("camera")) {
                look.camera=item.at("camera").get<std::vector<float>>();
                if(look.camera.size()!=20)throw std::runtime_error("相機配方參數數量不符");
                for(float v:look.camera)if(!std::isfinite(v))throw std::runtime_error("相機配方參數非有限值");
            }
            digital.emplace(item.at("id").get<std::string>(), std::move(look));
        }
    }
    std::ifstream file(root / "film-profiles.json");
    if (!file)
        throw std::runtime_error("找不到 film-profiles.json");
    Json json;
    file >> json;
    std::function<void(const Json &)> validate = [&](const Json &node) {
        if (node.is_number_float() && !std::isfinite(node.get<double>()))
            throw std::runtime_error("底片資料含非有限數值");
        if (node.is_structured())
            for (const auto &child : node)
                validate(child);
    };
    validate(json);
    if (json.at("schema") != 1)
        throw std::runtime_error("光譜資料版本不支援");
    dimension = json.at("dimension").get<int>();
    if (dimension < 2 || dimension > 256)
        throw std::runtime_error("光譜表尺寸不合法");
    auto v13 = [](const Json &j) {
        if (j.size() != 13)
            throw std::runtime_error("須為 13 波段");
        std::array<V, 13> a{};
        for (int i = 0; i < 13; ++i)
            a[std::size_t(i)] = vec(j.at(i));
        return a;
    };
    scanner = v13(json.at("scanner"));
    scanner_rows = matrix(json.at("scannerToRGB"));
    auto scalar13 = [](const Json &j) {
        if (j.size() != 13)
            throw std::runtime_error("須為 13 波段");
        auto a = j.get<std::array<double, 13>>();
        for (double x : a)
            if (!std::isfinite(x))
                throw std::runtime_error("無效光譜");
        return a;
    };
    for (const auto &item : json.at("lights").items())
        lights[item.key()] = scalar13(item.value());
    for (const auto &item : json.at("filters").items())
        filters[item.key()] = scalar13(item.value());
    for (const auto &item : json.at("lightMatrices").items())
        light_matrices[item.key()] = {matrix(item.value().at("forward")), matrix(item.value().at("inverse"))};
    for (const auto &item : json.at("scanners").items()) {
        auto values = item.value().at("rendering").get<std::vector<double>>();
        auto warmth = item.value().at("warmth").get<std::vector<double>>();
        if (values.size() != 4 || warmth.size() != 2)
            throw std::runtime_error("掃描風格資料不完整");
        values.insert(values.end(), warmth.begin(), warmth.end());
        scanner_styles[item.key()] = values;
    }
    for (const auto &item : json.at("profiles").items()) {
        auto j = item.value();
        Profile p;
        p.id = item.key();
        p.mono = j.at("monochrome");
        p.reversal = j.at("reversal");
        p.family = j.at("family");
        p.curve = j.at("curve").get<Curve>();
        p.paper = j.at("paper").get<Curve>();
        if (!(p.curve[1] > p.curve[0]) || !(p.curve[2] > 0) || !(p.curve[3] > 0))
            throw std::runtime_error("底片密度曲線不合法");
        p.shift = j.at("shift");
        p.middle = j.at("middleDensity");
        p.chroma = j.at("scannerChroma");
        p.gain = vec(j.at("gain"));
        p.ev = vec(j.at("ev"));
        p.reference = vec(j.at("referencePrintExposure"));
        p.sensitivity = v13(j.at("sensitivity"));
        p.negative = v13(j.at("negativeDyes"));
        p.print_sensitivity = v13(j.at("printSensitivity"));
        p.print_dyes = v13(j.at("printDyes"));
        p.base = scalar13(j.at("baseDensity"));
        p.character = j.value("character", std::vector<double>{});
        p.defaults = j.at("defaults");
        for (const auto &cal : j.at("calibrations").items()) {
            const auto &c = cal.value();
            p.calibrations[cal.key()] = {vec(c.at("base")), vec(c.at("middle")), matrix(c.at("inverse")),
                                         c.at("slope").get<double>()};
        }
        profiles[p.id] = std::move(p);
    }
    std::ifstream data(root / "spectral-table.f32", std::ios::binary | std::ios::ate);
    const auto count = std::size_t(5 * 3 * dimension * dimension * 4);
    if (!data || data.tellg() != std::streamoff(count * 4))
        throw std::runtime_error("光譜表長度不符");
    data.seekg(0);
    table.resize(count);
    for (float &v : table) {
        unsigned char bytes[4];
        data.read(reinterpret_cast<char *>(bytes), 4);
        const std::uint32_t bits = std::uint32_t(bytes[0]) | (std::uint32_t(bytes[1]) << 8) |
                                   (std::uint32_t(bytes[2]) << 16) | (std::uint32_t(bytes[3]) << 24);
        std::memcpy(&v, &bits, 4);
        if (!std::isfinite(v))
            throw std::runtime_error("光譜表含非有限值");
    }
}
std::array<double, 13> Database::spectrum(V rgb) const {
    const double amplitude = std::max({rgb.x, rgb.y, rgb.z});
    std::array<double, 13> bands{};
    if (amplitude <= 0)
        return bands;
    const int face = rgb.x >= rgb.y && rgb.x >= rgb.z ? 0 : (rgb.y >= rgb.z ? 1 : 2);
    const double u = rgb[(face + 1) % 3] / amplitude * (dimension - 1),
                 v = rgb[(face + 2) % 3] / amplitude * (dimension - 1);
    const int x = std::min(dimension - 2, int(u)), y = std::min(dimension - 2, int(v));
    const double fx = u - x, fy = v - y;
    for (int k = 0; k < 13; ++k) {
        auto at = [&](int dx, int dy) {
            return double(table[std::size_t(
                ((k / 3 * 3 * dimension + face * dimension + y + dy) * dimension + x + dx) * 4 + k % 3)]);
        };
        bands[std::size_t(k)] =
            ((at(0, 0) * (1 - fx) + at(1, 0) * fx) * (1 - fy) + (at(0, 1) * (1 - fx) + at(1, 1) * fx) * fy) *
            amplitude;
    }
    return bands;
}
} // namespace photocore::film_cpu
