#include "film_internal.hpp"
#include <optional>

namespace photocore::film_cpu {
namespace {
double density(double ev, const Curve &c) {
    auto soft = [](double x) { return std::max(x, 0.) + std::log1p(std::exp(-std::abs(x))); };
    return c[3] * (soft(c[2] * (ev - c[0])) - soft(c[2] * (ev - c[1]))) / (c[2] * (c[1] - c[0]));
}
V unmix(V optical, const Profile &p, const Database &db, const std::array<double, 13> &light,
        const CalibrationData &cal) {
    V estimate = clamp(p.middle + multiply(cal.inverse, optical - cal.middle), 0, p.curve[3]),
      best = estimate;
    double bestError = 1e30;
    for (int iteration = 0; iteration <= 4; ++iteration) {
        V signal, j0, j1, j2;
        for (std::size_t k = 0; k < 13; ++k) {
            V dye = p.negative[k];
            V weight = db.scanner[k] * light[k] * std::exp(-2.302585093 * (p.base[k] + dot(dye, estimate)));
            signal += weight;
            j0 += weight * dye.x;
            j1 += weight * dye.y;
            j2 += weight * dye.z;
        }
        signal = max(signal, 1e-12);
        V residual = -log10(signal / cal.base) - optical;
        const double error = dot(residual, residual);
        if (error < bestError) {
            best = estimate;
            bestError = error;
        }
        if (iteration == 4 || error < 1e-12)
            break;
        j0 /= signal;
        j1 /= signal;
        j2 /= signal;
        V co0 = cross(j1, j2), co1 = cross(j2, j0), co2 = cross(j0, j1);
        const double determinant = dot(j0, co0);
        if (!std::isfinite(determinant) || std::abs(determinant) <= 1e-8)
            break;
        V step = V(dot(co0, residual), dot(co1, residual), dot(co2, residual)) / determinant;
        const double largest = std::max({std::abs(step.x), std::abs(step.y), std::abs(step.z)});
        if (!std::isfinite(largest))
            break;
        step *= std::min(1., .75 / std::max(largest, 1e-12));
        estimate = clamp(estimate - step, 0, p.curve[3]);
    }
    return best - p.middle;
}
V render_intent(V input, const Curve &paper, double chroma, bool mono) {
    const double black = std::pow(10., -paper[1]);
    const double anchor = (.18 - black) / (1 - black), bias = std::log(anchor / (1 - anchor));
    V x = clamp(input, 1e-12, 1 - 1e-7);
    V z = paper[0] * (log(x / (1 - x)) - std::log(.18 / .82)) + bias;
    V tone = black + (1 - black) / (1 + exp(-clamp(z, -80, 80)));
    for (int c = 0; c < 3; ++c) {
        if (input[c] <= 0)
            tone[c] = black;
        if (input[c] >= 1)
            tone[c] = 1;
    }
    const double silver = paper[3] * dot(-log10(max(tone, 1e-12)), w);
    tone *= std::pow(10., -silver);
    const double y = dot(tone, w);
    if (mono)
        return V(y);
    // 此處 ceiling 固定 1，輸入為負片掃描器的 SDR sigmoid。
    V delta = (tone - y) * (chroma / (1 + 2 * paper[3]));
    double scale = 1;
    for (int c = 0; c < 3; ++c) {
        if (delta[c] < 0)
            scale = std::min(scale, y / -delta[c]);
        if (delta[c] > 0)
            scale = std::min(scale, (1 - y) / delta[c]);
    }
    return V(y) + delta * std::max(0., scale);
}
} // namespace
Image spectral(Image source, const Effects &incoming, double strength, const Profile &p, const Database &db) {
    Effects e = incoming;
    // 相片來源先光學印相，再由外層正像掃描器處理；與 deferScannerRendering:true 相同。
    if (e.text("scanner_source", "film") == "paper" && e.text("scanner_profile", "off") != "off" &&
        !p.reversal)
        e.json["scanner_profile"] = "off";
    if (e.json.value("modernFilmExposureEnabled", false) ||
        e.json.value("modern_film_exposure_enabled", false))
        throw std::invalid_argument("自適應底片曝光尚未移植，不能略過");
    Exposure exposure;
    exposure.global_ev = e.get("print_exposure", 0, -16, 16);
    exposure.zones = {e.get("print_exposure_highlights", exposure.global_ev, -16, 16),
                      e.get("print_exposure_midtones", exposure.global_ev, -16, 16),
                      e.get("print_exposure_shadows", exposure.global_ev, -16, 16)};
    exposure.protect_highlights = e.json.value("highlightProtectionEnabled", true);
    Image input = apply_exposure(std::move(source), exposure);
    const bool scanning = e.text("scanner_profile", "off") != "off";
    const auto &printLight = db.lights.at(e.text("print_illuminant", "reference"));
    const auto &viewLight = db.lights.at(e.text("view_illuminant", "reference"));
    const auto &scanLight = db.lights.at(e.text("scanner_illuminant", "reference"));
    const auto &cal = p.calibrations.at(e.text("scanner_illuminant", "reference"));
    const auto &filter = db.filters.at(e.text("monochrome_filter", "none"));
    const double filterAmount = p.mono ? e.get("monochrome_filter_strength", 100) / 100 * strength : 0;
    const double coupler = e.get("coupler_amount") / 100,
                 contrast = std::pow(2, (e.get("print_contrast", 50) - 50) / 50);
    const double silver = e.get("silver_retention", 0, -100, 100) / 100;
    const double correction = e.get("scan_density_correction", 100) / 100,
                 flare = std::pow(e.get("scan_flare") / 100, 2) * .005;
    const double signature = p.reversal ? 1.35 : (p.family == "cinema" ? .65 : 1);
    const double layerAmount = p.mono ? 0 : e.get("layer_response") / 100;
    std::array<Curve, 3> curves;
    for (std::size_t c = 0; c < 3; ++c) {
        const std::array<double, 3> toe{-.20, .04, .24}, shoulder{-.25, .08, .32}, bend{-.07, .025, .09};
        curves[c] = {p.curve[0] + toe[c] * signature * layerAmount,
                     p.curve[1] + shoulder[c] * signature * layerAmount,
                     p.curve[2] * (1 + bend[c] * signature * layerAmount), p.curve[3]};
    }
    Curve paper = p.paper;
    const std::string paperProfile = e.text("paper_profile", "reference");
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
        } else if (paperProfile != "reference")
            throw std::invalid_argument("未知紙材");
        paper[1] = std::clamp(paper[1] + e.get("paper_density_offset", 0, -1, 1), 1., 4.);
    }
    const double ratio = -std::log10(.18) / paper[1];
    paper[2] = std::log(ratio / (1 - ratio));
    const double seconds = e.get("exposure_seconds", 1, .0001, 3600);
    const double baseLoss = e.get("reciprocity_amount") / 100 *
                            (.12 * std::max(0., std::log2(std::max(1., seconds))) +
                             .05 * std::max(0., std::log2(.001 / std::max(seconds, .0001))));
    V loss = p.mono ? V(baseLoss) : V(1.12, 1, 1.28) * baseLoss;
    const double radius = std::max(input.width, input.height) * e.get("coupler_radius", .1, 0, 1) / 100;
    std::optional<Image> guide;
    if (coupler > 0 && radius > 0)
        guide = gaussian(input, radius);
    std::array<V, 13> sensitivity;
    V norm;
    for (std::size_t k = 0; k < 13; ++k) {
        sensitivity[k] = p.sensitivity[k] * (1 + (filter[k] - 1) * filterAmount);
        norm += sensitivity[k];
    }
    const double baseDensity = density(p.shift, p.curve);
    V layerDensity;
    for (int c = 0; c < 3; ++c)
        layerDensity[c] = density(p.shift, curves[std::size_t(c)]);
    const std::vector<double> neutralGrade{1, 1, 0, 0};
    Image output = transform_owned(std::move(input), [&](Pixel px, std::size_t x, std::size_t y) {
        const double alpha = std::isfinite(px.a) ? std::clamp(double(px.a), 0., 1.) : 0;
        if (alpha <= 0)
            return Pixel{0, 0, 0, 0};
        V color = rgb(px) / alpha;
        for (int c = 0; c < 3; ++c)
            if (!std::isfinite(color[c]))
                color[c] = 0;
        color = clamp(color, 0, 65536);
        const auto bands = db.spectrum(color);
        V h;
        for (std::size_t k = 0; k < 13; ++k) {
            h += sensitivity[k] * bands[k];
        }
        h /= norm;
        if (p.id == "filmLomoPurple") {
            const double dominance = (color.x - std::max(color.y, color.z)) / std::max(1e-7, color.x);
            h = mix(V(.45 * h.x + .55 * h.y, h.z, h.y), h, smooth(.15, .65, dominance));
        }
        V ev = log2(max(h, 1e-7) / .18) * p.gain + p.ev - loss, d;
        for (int c = 0; c < 3; ++c)
            d[c] =
                std::clamp(density(ev[c] + p.shift, curves[std::size_t(c)]) + baseDensity - layerDensity[c],
                           0., p.curve[3]);
        if (coupler > 0) {
            V neighboring = max(straight(guide ? guide->pixels[y * guide->width + x] : px), 0);
            V activation = d * clamp((neighboring + .02) / (color + .02), .25, 4),
              inhibitor = activation / (1 + activation);
            V crossColor{dot(inhibitor, V(.1, .55, .35)), dot(inhibitor, V(.4, .1, .5)),
                         dot(inhibitor, V(.55, .35, .1))};
            d *= 1 - .35 * coupler * crossColor;
        }
        V positive;
        if (scanning) {
            V measured, white, material = p.reversal ? p.curve[3] - d : d;
            for (std::size_t k = 0; k < 13; ++k) {
                const double optical = (p.reversal ? 0 : p.base[k]) +
                                       (p.mono ? material.x : dot(p.negative[k], material)) +
                                       silver * dot(material, w);
                V sensor = db.scanner[k] * scanLight[k];
                measured += sensor * std::exp(-2.302585092994046 * optical);
                white += sensor;
            }
            if (p.reversal) {
                const V t = (measured / white + flare) / (1 + flare);
                positive = p.mono ? V(t.x) : max(multiply(db.scanner_rows, t), 0);
                positive = .18 * max(positive, 1e-12) / .18;
            } else {
                V t = (measured / cal.base + flare) / (1 + flare);
                V logD = -log10(max(t, 1e-12)) - cal.middle;
                V separated = multiply(cal.inverse, logD);
                if (!p.mono && correction > 0)
                    separated = unmix(logD + cal.middle, p, db, scanLight, cal);
                V stops = mix(logD, separated, correction) / cal.slope;
                positive = 1 / (1 + exp(-clamp(-1.516347489 + stops * .693147181, -40, 40)));
                positive = render_intent(positive, paper, p.chroma, p.mono);
            }
            positive = grade(positive, 1, 0, 0, neutralGrade, p.mono);
        } else {
            if (p.reversal) {
                d = max(p.curve[3] - d, 0);
                d += silver * dot(d, w);
            } else {
                V printH;
                for (std::size_t k = 0; k < 13; ++k) {
                    const double optical =
                        p.base[k] + (p.mono ? d.x : dot(p.negative[k], d)) + silver * dot(d, w);
                    printH += p.print_sensitivity[k] * printLight[k] * std::exp(-2.302585092994046 * optical);
                }
                V printEV = log2(max(printH / p.reference, 1e-12));
                d = paper[1] / (1 + exp(-(printEV * paper[0] + paper[2])));
                d += paper[3] * dot(d, w);
            }
            if (p.mono)
                positive = V(std::exp(-2.302585092994046 * d.x));
            else {
                V signal;
                for (std::size_t k = 0; k < 13; ++k)
                    signal +=
                        db.scanner[k] * viewLight[k] *
                        std::exp(-2.302585092994046 * dot(p.reversal ? p.negative[k] : p.print_dyes[k], d));
                positive = max(multiply(db.scanner_rows, signal), 0);
            }
        }
        positive = .18 * pow(max(positive, 0) / .18, contrast);
        return pixel(positive * alpha, float(alpha));
    });
    guide.reset();
    // 負片掃描／正片略過光學負片印相，完成後另做光源補償。
    if ((scanning || p.reversal) && e.text("print_illuminant", "reference") != "reference") {
        const auto &inverse = db.light_matrices.at(e.text("print_illuminant", "reference")).second;
        output = transform_owned(std::move(output), [&](Pixel px, std::size_t, std::size_t) {
            if (px.a <= 0)
                return Pixel{0, 0, 0, 0};
            V color = multiply(inverse, straight(px));
            if (p.mono)
                color = V(dot(color, w));
            return pixel(color * px.a, px.a);
        });
    }
    if (!scanning && !p.reversal &&
        (e.get("paper_scatter") > 0 || e.get("paper_white", 100, 80, 100) != 100 ||
         paperProfile == "warmFiber")) {
        const double sigma =
            std::max(output.width, output.height) / 3000. * 2.5 * e.get("paper_scatter") / 100;
        output = gaussian(std::move(output), sigma);
        const V white = V(1, paperProfile == "warmFiber" ? .975 : 1, paperProfile == "warmFiber" ? .91 : 1) *
                        e.get("paper_white", 100, 80, 100) / 100;
        output = transform_owned(std::move(output), [&](Pixel px, std::size_t, std::size_t) {
            return pixel(rgb(px) * white, px.a);
        });
    }
    return output;
}
} // namespace photocore::film_cpu
