#include "pipeline.hpp"
#include "film_optics.hpp"

namespace photocore::vk {
using namespace film_cpu;
Surface Pipeline::resample(Surface src, std::size_t width, std::size_t height) {
    auto out = context.create(width, height);
    context.dispatch(26, src, src, src, out, out, {}, table, 0, "bilinear");
    return out;
}
Surface Pipeline::light_scatter(Surface source, const Effects &e, double strength) {
    double amount = e.get("emulsion_mtf") / 100 * strength;
    if (amount > 0) {
        double scale = double(std::max(source.width, source.height)) / 3000 * 36 / e.get("film_width_mm", 36, 8, 120);
        auto copy = [&] { return unary(15, source, {1,1,1}, "mtf-copy"); };
        auto r = gaussian(copy(), 1.8 * scale, "mtf-red"), g = gaussian(copy(), 1.2 * scale, "mtf-green"), b = gaussian(copy(), .8 * scale, "mtf-blue");
        auto packed = context.create(source.width, source.height);
        context.dispatch(21, r, g, b, packed, packed, {}, table, 0, "mtf-pack");
        r = {}; g = {}; b = {};
        auto out = context.create(source.width, source.height);
        context.dispatch(22, source, packed, source, out, out, {float(amount)}, table, 0, "mtf");
        source = std::move(out);
    }
    double bloom = std::sqrt(e.get("bloom_amount") / 100) * strength;
    if (bloom > 0) {
        auto energy = unary(23, source, {float(light_threshold(e.get("bloom_threshold", 75)))}, "bloom-extract");
        auto spread = gaussian(unary(15, energy, {1,1,1}, "bloom-copy"),
            std::max(source.width, source.height) * e.get("bloom_radius", .4, .05, 2) / 100, "bloom-gaussian");
        auto out = context.create(source.width, source.height);
        context.dispatch(24, source, energy, spread, out, out, {float(bloom)}, table, 0, "bloom");
        source = std::move(out);
    }
    return source;
}
Surface Pipeline::tone_masks(Surface source) {
    auto masks = unary(25, source, {}, "grain-tone-masks");
    return guided(std::move(masks), .0008);
}
Surface Pipeline::guided(Surface masks, double epsilon) {
    const auto width = masks.width, height = masks.height;
    const double scale = std::min(.5, 256. / std::min(width, height));
    auto reduced = resample(masks, std::max(1L, std::lround(width * scale)), std::max(1L, std::lround(height * scale)));
    int radius = int(std::round(std::clamp(double(std::min(reduced.width, reduced.height)) / 32, 2., 8.)));
    std::vector<float> weights(std::size_t(radius) + 2, 1.f / float(2 * radius + 1)); weights[0] = float(radius);
    auto box = [&](Surface src) {
        auto scratch = context.create(src.width, src.height);
        context.dispatch(3, src, src, src, scratch, scratch, weights, table, 0, "guided-box-x");
        context.dispatch(3, scratch, scratch, scratch, src, src, weights, table, 1, "guided-box-y");
        return src;
    };
    auto squared = unary(27, reduced, {}, "guided-square");
    auto mean = box(std::move(reduced)), correlation = box(std::move(squared));
    auto slope = context.create(mean.width, mean.height), intercept = context.create(mean.width, mean.height);
    context.dispatch(28, mean, correlation, mean, slope, intercept, {float(epsilon)}, table, 0, "guided-coefficients");
    mean = {}; correlation = {};
    slope = box(std::move(slope)); intercept = box(std::move(intercept));
    auto out = context.create(width, height);
    context.dispatch(29, masks, slope, intercept, out, out, {float(slope.width), float(slope.height)}, table, 0, "guided-reconstruct");
    return out;
}
Surface Pipeline::emulsion(Surface source, const Effects &e, const Json &adjustment, double strength, bool mono, bool preview) {
    EmulsionSettings s(source.width, source.height, e, adjustment, strength, mono, preview);
    if (!s.active) return source;
    auto captured = context.create(s.width, s.height);
    std::vector<float> params{float(s.size),float(s.clumping),float(s.chroma),float(s.spread),float(s.pitch),float(s.scale)};
    context.dispatch(30, source, source, source, captured, captured, params, table, 0, "emulsion-capture");
    Surface bounced;
    if (s.halo > 0) {
        bounced = context.create(s.width, s.height);
        context.dispatch(31, source, captured, source, bounced, bounced,
            {float(s.scale),float(s.halo),float(s.threshold),float(s.base)}, table, 0, "emulsion-return");
        bounced = gaussian(std::move(bounced), s.sigma, "emulsion-halo");
    }
    auto full = [&](Surface in) {
        if (s.scale < 1) {
            in = resize(std::move(in), s.scale, true);
            if (in.width != source.width || in.height != source.height) {
                auto out = context.create(source.width, source.height);
                context.dispatch(35, in, in, in, out, out, {}, table, 0, "emulsion-crop");
                in = std::move(out);
            }
            return in;
        }
        return resample(std::move(in), source.width, source.height);
    };
    captured = full(std::move(captured));
    bounced = s.halo > 0 ? full(std::move(bounced)) : unary(15, source, {0,0,0}, "emulsion-no-halo");
    auto masks = tone_masks(source), withAmount = context.create(source.width, source.height);
    context.dispatch(32, bounced, masks, bounced, withAmount, withAmount,
        {float(s.amounts.x),float(s.amounts.y),float(s.amounts.z)}, table, 0, "emulsion-amount");
    masks = {}; bounced = {};
    auto out = context.create(source.width, source.height);
    context.dispatch(33, source, captured, withAmount, out, out, {float(s.absorption())}, table, 0, "emulsion-composite");
    return out;
}
} // namespace photocore::vk
