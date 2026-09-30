#include "photocore/core.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace photocore {
namespace {
double dot(Vec3 a, Vec3 b) {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
Vec3 add(Vec3 a, Vec3 b) {
    return {a[0] + b[0], a[1] + b[1], a[2] + b[2]};
}
Vec3 mul(Vec3 a, double s) {
    return {a[0] * s, a[1] * s, a[2] * s};
}
double ev(double x) {
    return std::isfinite(x) ? std::clamp(x, -16., 16.) : 0.;
}
bool finite(Vec3 v) {
    return std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
}
constexpr Vec3 weights{0.21263900587151027, 0.7151686787677559, 0.07219231536073371};
struct Prepared {
    Vec3 curve;
    double global, amount;
    bool enabled, protection, peak;
    explicit Prepared(const Exposure &s)
        : global(ev(s.global_ev)), amount(std::isfinite(s.strength) ? std::clamp(s.strength, 0., 1.) : 0.),
          protection(s.protect_highlights), peak(s.protect_peak) {
        Vec3 z{ev(s.zones[0]), ev(s.zones[1]), ev(s.zones[2])};
        enabled = amount > 0 && z != Vec3{0, 0, 0}; // 保留現有 Swift 的全零區域略過契約。
        curve = exposure_curve(add(z, {-global, -global, -global}));
    }
    Pixel apply(Pixel p) const {
        if (!enabled || p.a <= 0)
            return p;
        Vec3 rgb{p.r / p.a, p.g / p.a, p.b / p.a};
        const double y = dot(rgb, weights);
        double gain = std::exp2(global + zone_ev(y, curve));
        const double anchor = peak ? std::max({rgb[0], rgb[1], rgb[2]}) : y;
        if (protection && gain > 1 && anchor > 1e-20)
            gain = protected_peak(anchor, gain) / anchor;
        gain = 1 + (gain - 1) * amount;
        return {float(p.r * gain), float(p.g * gain), float(p.b * gain), p.a};
    }
};
} // namespace
Image::Image(std::size_t w, std::size_t h) : width(w), height(h) {
    if (!w || !h || w > std::numeric_limits<std::size_t>::max() / h ||
        w * h > std::vector<Pixel>().max_size())
        throw std::invalid_argument("影像尺寸無效或溢位");
    pixels.resize(w * h);
}
double slider_to_ev(double x) {
    if (!std::isfinite(x))
        return 0;
    x = std::clamp(x, -100., 100.);
    return x / 100 * (x >= 0 ? 5 : 2);
}
double ev_to_slider(double x) {
    if (!std::isfinite(x))
        return 0;
    x = std::clamp(x, -2., 5.);
    return x / (x >= 0 ? 5 : 2) * 100;
}
Vec3 exposure_curve(Vec3 z) {
    if (!finite(z))
        return {0, 1, 1};
    if (z[0] == z[1] && z[2] == z[1])
        return {z[1], 1, 1};
    const Vec3 anchors{-6, -1, 2}, target = add(anchors, {z[2], z[1], z[0]});
    const std::array<Vec3, 4> rows{{{{-1, 1, 0}}, {{1, -1, 0}}, {{0, -1, 1}}, {{0, 1, -1}}}};
    const std::array<double, 4> limits{2.5, -10, 1.5, -6};
    const double mean = (z[0] + z[1] + z[2]) / 3;
    Vec3 best = add(anchors, {mean, mean, mean});
    auto loss = [&](Vec3 x) {
        auto d = add(x, mul(target, -1));
        return dot(d, d);
    };
    double best_loss = loss(best);
    auto consider = [&](Vec3 x) {
        for (std::size_t i = 0; i < 4; ++i)
            if (dot(rows[i], x) < limits[i] - 1e-10)
                return;
        double l = loss(x);
        if (l < best_loss) {
            best = x;
            best_loss = l;
        }
    };
    consider(target);
    for (std::size_t i = 0; i < 4; ++i) {
        const double residual = limits[i] - dot(rows[i], target);
        consider(add(target, mul(rows[i], residual / 2)));
        for (std::size_t j = i + 1; j < 4; ++j) {
            double cross = dot(rows[i], rows[j]), det = 4 - cross * cross;
            if (det <= 0)
                continue;
            double other = limits[j] - dot(rows[j], target);
            consider(add(add(target, mul(rows[i], (2 * residual - cross * other) / det)),
                         mul(rows[j], (2 * other - cross * residual) / det)));
        }
    }
    return {best[0] + 6, (best[1] - best[0]) / 5, (best[2] - best[1]) / 3};
}
double zone_ev(double y, Vec3 c) {
    if (c[1] == 1 && c[2] == 1)
        return c[0];
    double x = std::log2(std::max(y, 1e-20) / .18);
    auto sp = [](double v) { return std::max(v, 0.) + .4 * std::log1p(std::exp(-std::abs(v) / .4)); };
    return c[0] + (c[1] - 1) * (sp(x + 6) - sp(x + 1)) + (c[2] - 1) * (sp(x + 1) - sp(x - 2));
}
double protected_peak(double v, double g) {
    if (g == 1 || v <= 0)
        return v;
    if (g < 1)
        return v * g;
    if (v >= 1)
        return v;
    const double start = .6 / g;
    if (v <= start)
        return v * g;
    const double d = v - start, curvature = g / .4 - 1 / (1 - start);
    return .6 + g * d / (1 + curvature * d);
}
Vec3 rgb_to_lab(Vec3 rgb) {
    auto f = [](double t) { return t > 216. / 24389 ? std::cbrt(t) : (24389. / 27 * t + 16) / 116; };
    double x = dot(rgb, {.41239079926595934, .35758433938387796, .1804807884018343});
    double y = dot(rgb, weights), z = dot(rgb, {.01933081871559185, .11919477979462599, .9505321522496607}),
           fy = f(y);
    return {116 * fy - 16, 500 * (f(x / .9504559270516716) - fy), 200 * (fy - f(z / 1.0890577507598784))};
}
Pixel expose(Pixel p, const Exposure &s) {
    return Prepared(s).apply(p);
}
Pixel map_raw_highlights(Pixel p) {
    if (p.a <= 0)
        return p;
    const double peak = std::max({p.r / p.a, p.g / p.a, p.b / p.a});
    if (peak <= .78)
        return p;
    const double scale = (.78 + .22 * (1 - std::exp(-(peak - .78) / .22))) / std::max(peak, .00001);
    return {float(p.r * scale), float(p.g * scale), float(p.b * scale), p.a};
}
void validate(const Calibration &c) {
    for (const auto &row : c.rows)
        for (double v : row)
            if (!std::isfinite(v) || std::abs(v) > 16)
                throw std::invalid_argument("校準係數須有限且介於 -16 至 16");
}
Pixel calibrate(Pixel p, const Calibration &c) {
    if (!(p.a > 0))
        return p;
    Vec3 x{p.r / p.a, p.g / p.a, p.b / p.a};
    if (!finite(x) || *std::min_element(x.begin(), x.end()) < 0)
        return p;
    const std::array<double, 6> f{x[0],
                                  x[1],
                                  x[2],
                                  std::sqrt(x[0]) * std::sqrt(x[1]),
                                  std::sqrt(x[1]) * std::sqrt(x[2]),
                                  std::sqrt(x[0]) * std::sqrt(x[2])};
    Vec3 result{};
    for (std::size_t i = 0; i < 3; ++i)
        for (std::size_t j = 0; j < 6; ++j)
            result[i] += c.rows[i][j] * f[j];
    return {float(result[0] * p.a), float(result[1] * p.a), float(result[2] * p.a), p.a};
}
Image apply_exposure(const Image &input, const Exposure &s) {
    return apply_exposure(Image(input), s);
}
Image apply_exposure(Image &&input, const Exposure &s) {
    Prepared prepared(s);
    for (auto &p : input.pixels)
        p = prepared.apply(p);
    return std::move(input);
}
Image apply_raw_mapping(const Image &input) {
    Image output = input;
    for (auto &p : output.pixels)
        p = map_raw_highlights(p);
    return output;
}
Image apply_calibration(const Image &input, const Calibration &s) {
    validate(s);
    Image output = input;
    for (auto &p : output.pixels)
        p = calibrate(p, s);
    return output;
}
} // namespace photocore
