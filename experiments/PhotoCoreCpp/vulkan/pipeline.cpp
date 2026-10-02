#include "pipeline.hpp"
#include <filesystem>
#include <optional>
namespace photocore::vk {
using namespace film_cpu;
namespace {
std::vector<float> floats(std::initializer_list<double> values) {
    std::vector<float> r;
    for (auto v : values)
        r.push_back(float(v));
    return r;
}
void put(std::vector<float> &a, int index, V v) {
    a.at(index) = float(v.x);
    a.at(index + 1) = float(v.y);
    a.at(index + 2) = float(v.z);
}
void put(std::vector<float> &a, int index, const Matrix &m) {
    for (int j = 0; j < 3; ++j)
        put(a, index + j * 3, m[j]);
}
double density(double ev, const Curve &c) {
    auto soft = [](double x) { return std::max(x, 0.) + std::log1p(std::exp(-std::abs(x))); };
    return c[3] * (soft(c[2] * (ev - c[0])) - soft(c[2] * (ev - c[1]))) / (c[2] * (c[1] - c[0]));
}
} // namespace
Pipeline::Pipeline(const std::string &data, const std::string &shader, bool validationEnabled)
    : context(shader, validationEnabled), database(data), table(context.upload_floats(database.table)) {}
Surface Pipeline::unary(unsigned op, Surface src, const std::vector<float> &p, const std::string &tag) {
    auto out = context.create(src.width, src.height);
    context.dispatch(op, src, src, src, out, out, p, table, 0, tag);
    return out;
}
Surface Pipeline::gaussian(Surface src, double sigma, const std::string &tag, bool clamp_edges) {
    if (!(sigma > 0))
        return src;
    if (!std::isfinite(sigma) || sigma > 10000)
        throw std::invalid_argument("模糊半徑不合法");
    int radius = std::max(1, int(std::ceil(4 * sigma)));
    std::vector<double> weights(radius + 1);
    double total = 0;
    for (int i = 0; i <= radius; ++i) {
        weights[i] = std::exp(-.5 * i * i / (sigma * sigma));
        total += weights[i] * (i ? 2 : 1);
    }
    std::vector<float> p{float(radius)};
    for (auto value : weights)
        p.push_back(float(value / total));
    auto scratch = context.create(src.width, src.height);
    context.dispatch(clamp_edges ? 3 : 45, src, src, src, scratch, scratch, p, table, 0, tag + "-x");
    // Surface 可能被同一張運算圖的多個分支持有；不得覆寫其他分支仍需使用的來源。
    auto output = context.create(src.width, src.height);
    context.dispatch(clamp_edges ? 3 : 45, scratch, scratch, scratch, output, output, p, table, 1, tag + "-y");
    return output;
}
Surface Pipeline::resize(Surface src, double scale, bool clamp_edges) {
    if (scale >= 1)
        return src;
    if (!(scale > 0))
        throw std::invalid_argument("縮放比例不合法");
    const auto targetWidth = std::size_t(std::ceil(src.width * scale));
    const auto targetHeight = std::size_t(std::ceil(src.height * scale));
    // CILanczosScaleTransform 大幅縮小會分段減半，再做最後一次 Lanczos。
    // 保留原始目標範圍，避免奇數尺寸的中途進位改變最終高度／寬度。
    while (scale < .5) {
        src = resize(std::move(src), .5, clamp_edges);
        scale *= 2;
    }
    auto height = src.height;
    constexpr double pi = 3.14159265358979323846;
    auto kernel = [&](double d) {
        d = std::abs(d);
        return d < 1e-12 ? 1.
                         : (d >= 3 ? 0. : std::sin(pi * d) * std::sin(pi * d / 3) / (pi * pi * d * d / 3));
    };
    for (unsigned axis = 0; axis < 2; ++axis) {
        auto out = context.create(axis == 0 ? targetWidth : src.width,
                                  axis == 1 ? targetHeight : src.height);
        const int stride = int(std::ceil(6 / scale)) + 5;
        std::vector<float> params(1 + (axis == 0 ? out.width : out.height) * stride);
        params[0] = float(stride);
        for (std::size_t i = 0; i < (axis == 0 ? out.width : out.height); ++i) {
            double pos = axis == 0 ? (i + .5) / scale - .5
                                   : double(height) - (double(out.height) - i - .5) / scale - .5;
            long start = long(std::ceil(pos - 3 / scale)), end = long(std::floor(pos + 3 / scale));
            int base = 1 + int(i) * stride;
            double total = 0;
            params[base] = float(start);
            params[base + 2] = float(end - start + 1);
            for (long k = start; k <= end; ++k) {
                double weight = kernel((k - pos) * scale);
                params.at(base + 3 + k - start) = float(weight);
                total += weight;
            }
            params[base + 1] = float(total);
        }
        context.dispatch(clamp_edges ? 34 : 4, src, src, src, out, out, params, table, axis, "lanczos");
        src = std::move(out);
    }
    return src;
}
Surface Pipeline::develop(Surface source, const Effects &e, double strength) {
    double amount = std::sqrt(e.get("development_amount") / 100) * strength;
    if (amount == 0)
        return source;
    double activity = e.get("developer_activity", 100, 20, 200) / 100 *
                      std::pow(2, (e.get("developer_temperature", 20, 10, 40) - 20) / 10);
    double time = std::min(6., (.4 + 2.6 * e.get("development_time", 50) / 100) * activity), dt = time / 12,
           rate = 1.6 * dt, supplied = 1 - std::exp(-2.5 * e.get("development_agitation", 50) / 100 * dt);
    double longest = double(std::max(source.width, source.height)), scale = std::min(1., 768 / longest);
    auto reduced = resize(source, scale);
    auto active = unary(5, reduced, {}, "development-active");
    reduced = {};
    auto salt =
        unary(6, active, floats({source.width * scale, source.height * scale}), "development-initial-salt");
    auto developer = unary(6, active, floats({source.width * scale, source.height * scale}),
                           "development-initial-developer");
    double sigma = longest * scale * e.get("development_diffusion", .15, .02, 1) / 100 * std::sqrt(dt),
           variance = sigma * sigma, half = variance / 2, leading = 1;
    int radius = int(std::min(24., std::max(4., std::ceil(4 * sigma + 4))));
    std::vector<double> weights(radius + 1);
    for (int n = 0; n <= radius; ++n) {
        if (n > 0)
            leading *= half / n;
        double term = leading, sum = term;
        for (int k = 1; k <= 160; ++k) {
            term *= half * half / (double(k) * (k + n));
            sum += term;
            if (term <= sum * 1e-15)
                break;
        }
        weights[n] = std::exp(-variance) * sum;
    }
    double total = weights[0];
    for (int n = 1; n <= radius; ++n)
        total += 2 * weights[n];
    std::vector<float> params{float(radius)};
    for (auto w : weights)
        params.push_back(float(total > 0 ? w / total : w));
    auto nextSalt = context.create(active.width, active.height),
         nextDev = context.create(active.width, active.height),
         scratch = context.create(active.width, active.height);
    for (int i = 0; i < 12; ++i) {
        context.dispatch(7, active, salt, developer, nextSalt, nextDev, floats({rate}), table, 0,
                         "development-reaction");
        std::swap(salt, nextSalt);
        std::swap(developer, nextDev);
        context.dispatch(8, developer, developer, developer, scratch, scratch, params, table, 0,
                         "development-diffusion-x");
        context.dispatch(8, scratch, scratch, scratch, developer, developer, params, table, 1,
                         "development-diffusion-y");
        context.dispatch(9, developer, developer, developer, nextDev, nextDev, floats({supplied}), table, 0,
                         "development-replenish");
        std::swap(developer, nextDev);
    }
    auto out = context.create(source.width, source.height);
    context.dispatch(10, source, active, salt, out, out,
                     floats({scale, amount, rate, supplied, double(active.width), double(active.height)}),
                     table, 0, "development-growth");
    return out;
}
Surface Pipeline::chemistry(Surface source, const Effects &e, double strength, bool mono) {
    const Json s = e.json.value("developer_chemistry", Json::object());
    V curve{number(s, "contrast", 1, .6, 1.5), number(s, "speedEV", 0, -1, 1),
            number(s, "compensation", 0, 0, 100) / 50};
    V layers = mono ? V(0)
                    : V(number(s, "red", 0, -20, 20), number(s, "green", 0, -20, 20),
                        number(s, "blue", 0, -20, 20)) /
                          100;
    double grain = number(s, "grain", 0, 0, 100) / 100 * .018,
           acutance = number(s, "acutance", 0, 0, 100) / 100 * .24;
    if (strength == 0 || (curve.x == 1 && curve.y == 0 && curve.z == 0 && grain == 0 && acutance == 0 &&
                          layers.x == 0 && layers.y == 0 && layers.z == 0))
        return source;
    auto params =
        floats({curve.x, curve.y, curve.z, strength, grain, acutance,
                3000. / std::max(source.width, source.height), double(mono), layers.x, layers.y, layers.z,
                e.get("_origin_x",0,-1e9,1e9), e.get("_origin_y",0,-1e9,1e9)});
    Surface mean = source;
    if (acutance > 0)
        mean = gaussian(unary(11, source, params, "chemistry-density"),
                        std::max(.5, 2 * double(std::max(source.width, source.height)) / 3000),
                        "chemistry-gaussian");
    auto out = context.create(source.width, source.height);
    context.dispatch(12, source, mean, source, out, out, params, table, 0, "chemistry");
    return out;
}
Surface Pipeline::exposure(Surface source, const Exposure &s) {
    auto ev = [](double v) { return std::isfinite(v) ? std::clamp(v, -16., 16.) : 0.; };
    double amount = std::isfinite(s.strength) ? std::clamp(s.strength, 0., 1.) : 0.;
    Vec3 zones{ev(s.zones[0]), ev(s.zones[1]), ev(s.zones[2])};
    if (amount <= 0 || zones == Vec3{0, 0, 0})
        return source;
    double global = ev(s.global_ev);
    auto curve = exposure_curve({zones[0] - global, zones[1] - global, zones[2] - global});
    return unary(0, source,
                 floats({curve[0], curve[1], curve[2], global, amount, double(s.protect_highlights),
                         double(s.protect_peak)}),
                 "exposure");
}
Surface Pipeline::raw_mapping(Surface source) {
    return unary(1, source, {}, "raw-highlight-mapping");
}
Surface Pipeline::calibration(Surface source, const Calibration &s) {
    validate(s);
    std::vector<float> p;
    for (auto row : s.rows)
        for (double v : row)
            p.push_back(float(v));
    return unary(2, source, p, "calibration");
}
Surface Pipeline::spectral(Surface source, const Effects &incoming, double strength, const Profile &profile) {
    const auto &p = profile;
    auto &db = database;
    Effects e = incoming;
    if (e.text("scanner_source", "film") == "paper" && e.text("scanner_profile", "off") != "off" &&
        !p.reversal)
        e.json["scanner_profile"] = "off";
    if (e.json.value("modernFilmExposureEnabled", false) ||
        e.json.value("modern_film_exposure_enabled", false))
        throw std::invalid_argument("自適應底片曝光尚未移植");
    Exposure ex;
    ex.global_ev = e.get("print_exposure", 0, -16, 16);
    ex.zones = {e.get("print_exposure_highlights", ex.global_ev, -16, 16),
                e.get("print_exposure_midtones", ex.global_ev, -16, 16),
                e.get("print_exposure_shadows", ex.global_ev, -16, 16)};
    ex.protect_highlights = e.json.value("highlightProtectionEnabled", true);
    source = exposure(source, ex);
    bool scanning = e.text("scanner_profile", "off") != "off";
    auto &printLight = db.lights.at(e.text("print_illuminant", "reference"));
    auto &viewLight = db.lights.at(e.text("view_illuminant", "reference"));
    auto &scanLight = db.lights.at(e.text("scanner_illuminant", "reference"));
    auto &cal = p.calibrations.at(e.text("scanner_illuminant", "reference"));
    auto &filter = db.filters.at(e.text("monochrome_filter", "none"));
    double filterAmount = p.mono ? e.get("monochrome_filter_strength", 100) / 100 * strength : 0,
           coupler = e.get("coupler_amount") / 100,
           contrast = std::pow(2, (e.get("print_contrast", 50) - 50) / 50);
    double signature = p.reversal ? 1.35 : (p.family == "cinema" ? .65 : 1),
           layer = p.mono ? 0 : e.get("layer_response") / 100;
    Curve paper = p.paper;
    std::string paperProfile = e.text("paper_profile", "reference");
    if (!scanning && !p.reversal) {
        if (paperProfile == "glossy") {
            paper[0] = 1.12;
            paper[1] = 2.8;
        } else if (paperProfile == "matte") {
            paper[0] = .88;
            paper[1] = 2.05;
        } else if (paperProfile == "warmFiber") {
            paper[0] = .96;
            paper[1] = 2.3;
        }
        paper[1] = std::clamp(paper[1] + e.get("paper_density_offset", 0, -1, 1), 1., 4.);
    }
    double ratio = -std::log10(.18) / paper[1];
    paper[2] = std::log(ratio / (1 - ratio));
    double seconds = e.get("exposure_seconds", 1, .0001, 3600),
           baseLoss = e.get("reciprocity_amount") / 100 *
                      (.12 * std::max(0., std::log2(std::max(1., seconds))) +
                       .05 * std::max(0., std::log2(.001 / std::max(seconds, .0001))));
    double radius = std::max(source.width, source.height) * e.get("coupler_radius", .1, 0, 1) / 100;
    // Gaussian 會重用輸入配置，因此先產生獨立副本（乘白色），保留主來源。
    Surface guide = source;
    if (coupler > 0 && radius > 0)
        guide = gaussian(unary(15, source, {1, 1, 1}, "coupler-copy"), radius, "coupler-gaussian");
    std::vector<float> q(324);
    q[0] = float(p.mono);
    q[1] = float(p.reversal);
    q[2] = float(scanning);
    q[3] = float(p.id == "filmLomoPurple");
    for (int j = 0; j < 4; ++j) {
        q[4 + j] = float(p.curve[j]);
        q[8 + j] = float(paper[j]);
    }
    put(q, 12, p.gain);
    q[15] = float(p.shift);
    put(q, 16, p.ev);
    q[19] = float(p.middle);
    put(q, 20, p.mono ? V(baseLoss) : V(1.12, 1, 1.28) * baseLoss);
    q[23] = float(p.chroma);
    V norm;
    for (int k = 0; k < 13; ++k) {
        V sens = p.sensitivity[k] * (1 + (filter[k] - 1) * filterAmount);
        norm += sens;
        put(q, 24 + k * 3, sens);
        put(q, 63 + k * 3, p.negative[k]);
        q[102 + k] = float(p.base[k]);
        put(q, 115 + k * 3, p.print_sensitivity[k] * printLight[k]);
        put(q, 154 + k * 3, p.print_dyes[k]);
        put(q, 193 + k * 3, db.scanner[k] * scanLight[k]);
        put(q, 232 + k * 3, db.scanner[k] * viewLight[k]);
    }
    put(q, 271, db.scanner_rows);
    put(q, 280, norm);
    std::array<double, 3> toe{-.20, .04, .24}, shoulder{-.25, .08, .32}, bend{-.07, .025, .09};
    for (int j = 0; j < 3; ++j) {
        Curve c{p.curve[0] + toe[j] * signature * layer, p.curve[1] + shoulder[j] * signature * layer,
                p.curve[2] * (1 + bend[j] * signature * layer), p.curve[3]};
        q[283 + j] = float(density(p.shift, c));
        for (int k = 0; k < 4; ++k)
            q[286 + j * 4 + k] = float(c[k]);
    }
    q[298] = float(density(p.shift, p.curve));
    q[299] = float(coupler);
    q[300] = float(e.get("scan_density_correction", 100) / 100);
    q[301] = float(std::pow(e.get("scan_flare") / 100, 2) * .005);
    q[302] = float(contrast);
    put(q, 303, cal.base);
    put(q, 306, cal.middle);
    put(q, 309, cal.inverse);
    q[318] = float(cal.slope);
    q[319] = float(db.dimension);
    q[320] = float(e.get("silver_retention", 0, -100, 100) / 100);
    put(q, 321, p.reference);
    auto out = context.create(source.width, source.height);
    context.dispatch(13, source, guide, source, out, out, q, table, 0, "spectral");
    source = {};
    guide = {};
    if ((scanning || p.reversal) && e.text("print_illuminant", "reference") != "reference") {
        std::vector<float> matrix(10);
        put(matrix, 0, db.light_matrices.at(e.text("print_illuminant", "reference")).second);
        matrix[9] = float(p.mono);
        out = unary(14, out, matrix, "illuminant");
    }
    if (!scanning && !p.reversal &&
        (e.get("paper_scatter") > 0 || e.get("paper_white", 100, 80, 100) != 100 ||
         paperProfile == "warmFiber")) {
        out = gaussian(out, std::max(out.width, out.height) / 3000. * 2.5 * e.get("paper_scatter") / 100,
                       "paper-scatter");
        V white = V(1, paperProfile == "warmFiber" ? .975 : 1, paperProfile == "warmFiber" ? .91 : 1) *
                  e.get("paper_white", 100, 80, 100) / 100;
        out = unary(15, out, floats({white.x, white.y, white.z}), "paper-white");
    }
    return out;
}
Image Pipeline::process(Image source, const std::string &path, const std::string &dump) {
    if (source.width == 0 || source.height == 0 || source.width > SIZE_MAX / source.height ||
        source.pixels.size() != source.width * source.height)
        throw std::invalid_argument("來源尺寸不符");
    for (auto px : source.pixels)
        for (float v : {px.r, px.g, px.b, px.a})
            if (!std::isfinite(v))
                throw std::invalid_argument("來源含非有限值");
    auto recipe = prepare_recipe(path, database);
    auto &e = recipe.effects;
    auto &p = *recipe.profile;
    double strength = recipe.strength;
    auto image = context.upload(source);
    source.pixels = {};
    source.pixels.shrink_to_fit();
    auto trace = [&](const std::string &name) {
        if (!dump.empty())
            write_pfm((std::filesystem::u8path(dump) / (name + ".pfm")).u8string(), context.download(image));
    };
    image = develop(std::move(image), e, strength);
    trace("development");
    image = chemistry(std::move(image), e, strength, p.mono);
    trace("chemistry");
    image = spectral(std::move(image), e, strength, p);
    trace("spectral");
    if (!p.character.empty()) {
        if (p.character.size() != 6)
            throw std::runtime_error("底片風格參數長度不符");
        std::vector<float> params;
        for (auto v : p.character)
            params.push_back(float(v));
        params.push_back(float(p.mono));
        image = unary(16, image, params, "character");
    }
    trace("character");
    Effects scan = e;
    if (scan.text("scanner_profile", "off") == "off")
        scan.json["scanner_profile"] = "neutral";
    if (scan.text("scanner_source", "film") == "film" || p.reversal)
        scan.json["scan_flare"] = 0;
    auto &s = database.scanner_styles.at(scan.text("scanner_profile", "off"));
    image =
        unary(17, image,
              floats({scan.get("scan_saturation", 50) / 50,
                      (scan.get("scan_midtone_warmth", 0, -100, 100) + s[4]) / 100,
                      (scan.get("scan_highlight_warmth", 0, -100, 100) + s[5]) / 100,
                      std::pow(scan.get("scan_flare") / 100, 2) * .005, s[0], s[1], s[2], double(p.mono)}),
              "scanner");
    trace("scanner");
    image = unary(18, image, {}, "srgb16");
    auto result = context.download(image);
    for (auto px : result.pixels)
        for (float v : {px.r, px.g, px.b, px.a})
            if (!std::isfinite(v))
                throw std::runtime_error("GPU 成品含非有限值");
    return result;
}
} // namespace photocore::vk
