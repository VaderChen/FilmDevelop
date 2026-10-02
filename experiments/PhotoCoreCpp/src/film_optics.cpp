#include "film_optics.hpp"
#include <atomic>
#include <thread>

namespace photocore::film_cpu {
namespace {
const V W(.2126, .7152, .0722);
Pixel at(const Image &s, long x, long y) {
    return s.pixels[std::clamp(y, 0L, long(s.height) - 1) * s.width +
                    std::clamp(x, 0L, long(s.width) - 1)];
}
Pixel sample(const Image &s, double x, double y) {
    const long ix = long(std::floor(x)), iy = long(std::floor(y));
    double fx = std::floor((x - ix) * 256 + .5) / 256,
           fy = std::floor((y - iy) * 256 + .5) / 256;
    auto a = at(s, ix, iy), b = at(s, ix + 1, iy), c = at(s, ix, iy + 1), d = at(s, ix + 1, iy + 1);
    return pixel(mix(mix(rgb(a), rgb(b), fx), mix(rgb(c), rgb(d), fx), fy),
                 float((a.a + (b.a - a.a) * fx) * (1 - fy) + (c.a + (d.a - c.a) * fx) * fy));
}
Image resample(const Image &s, std::size_t w, std::size_t h) {
    Image out(w, h);
    for (std::size_t y = 0; y < h; ++y)
        for (std::size_t x = 0; x < w; ++x)
            out.pixels[y * w + x] = sample(s, (x + .5) * s.width / w - .5, (y + .5) * s.height / h - .5);
    return out;
}
Image box(Image s, int radius) {
    Image scratch(s.width, s.height);
    for (int axis = 0; axis < 2; ++axis) {
        Image &out = axis == 0 ? scratch : s;
        const Image &in = axis == 0 ? s : scratch;
        for (std::size_t y = 0; y < s.height; ++y)
            for (std::size_t x = 0; x < s.width; ++x) {
                V sum;
                for (int i = -radius; i <= radius; ++i)
                    sum += rgb(at(in, long(x) + (axis == 0 ? i : 0), long(y) + (axis == 1 ? i : 0)));
                out.pixels[y * s.width + x] = pixel(sum / (2 * radius + 1), 1);
            }
    }
    return s;
}
uint32_t hash(uint32_t x) {
    x ^= x >> 16; x *= 0x7feb352dU; x ^= x >> 15; x *= 0x846ca68bU; return x ^ (x >> 16);
}
float uniform(uint32_t x) { return (float(hash(x) >> 8) + .5f) / 16777216.f; }
uint32_t cell(int x, int y, uint32_t seed) { return hash(uint32_t(x) * 0x9e3779b9U ^ uint32_t(y) * 0x85ebca6bU ^ seed); }
int poisson(uint32_t seed, float lambda) {
    float p = std::exp(-lambda), sum = p, u = uniform(seed); int k = 0;
    for (int i = 1; i < 20 && u > sum; ++i) { p *= lambda / float(i); sum += p; k = i; }
    return k;
}
// 各列相互獨立；CPU 回退保持同一晶體種子，排程不影響輸出。
template<class F> void parallel_rows(std::size_t rows, F f) {
    unsigned count = std::min(8U, std::max(1U, std::thread::hardware_concurrency()));
    std::atomic<std::size_t> next{0};
    std::vector<std::thread> workers;
    for (unsigned t = 0; t < count; ++t) workers.emplace_back([&] {
        for (;;) { auto y = next.fetch_add(1); if (y >= rows) break; f(y); }
    });
    for (auto &worker : workers) worker.join();
}
}
Image guided_smooth(Image masks, double epsilon) {
    const double scale = std::min(.5, 256. / std::min(masks.width, masks.height));
    auto reduced = resample(masks, std::max(1L, std::lround(masks.width * scale)), std::max(1L, std::lround(masks.height * scale)));
    int radius = int(std::round(std::clamp(double(std::min(reduced.width, reduced.height)) / 32, 2., 8.)));
    auto squared = transform(reduced, [](Pixel p, std::size_t, std::size_t) { return pixel(rgb(p) * rgb(p), 1); });
    auto mean = box(reduced, radius), correlation = box(std::move(squared), radius);
    Image slopes(mean.width, mean.height), intercepts(mean.width, mean.height);
    for (std::size_t i = 0; i < mean.pixels.size(); ++i) {
        V m = rgb(mean.pixels[i]), variance = max(rgb(correlation.pixels[i]) - m * m, 0);
        V slope = variance / (variance + epsilon);
        slopes.pixels[i] = pixel(slope, 1);
        intercepts.pixels[i] = pixel(m * (V(1) - slope), 1);
    }
    slopes = resample(box(std::move(slopes), radius), masks.width, masks.height);
    intercepts = resample(box(std::move(intercepts), radius), masks.width, masks.height);
    for (std::size_t i = 0; i < masks.pixels.size(); ++i)
        masks.pixels[i] = pixel(rgb(masks.pixels[i]) * rgb(slopes.pixels[i]) + rgb(intercepts.pixels[i]), 1);
    return masks;
}
Image tone_masks(const Image &s) {
    auto masks = transform(s, [](Pixel p, std::size_t, std::size_t) {
        if (!(p.a > 0)) return Pixel{0, 0, 0, 1};
        double z = std::log2(std::max(dot(straight(p), W), 1e-6) / .18);
        double n = z / (z < 0 ? .65 : 1.35);
        V v(1 - smooth(-1.55, 0, z), std::exp2(-.5 * n * n), smooth(.55, 2.55, z));
        return pixel(v / std::max(v.x + v.y + v.z, .0001), 1);
    });
    return guided_smooth(std::move(masks), .0008);
}
Image light_scatter(Image source, const Effects &e, double strength) {
    const double amount = e.get("emulsion_mtf") / 100 * strength;
    if (amount > 0) {
        double scale = double(std::max(source.width, source.height)) / 3000 * 36 / e.get("film_width_mm", 36, 8, 120);
        auto red = gaussian(source, 1.8 * scale), green = gaussian(source, 1.2 * scale), blue = gaussian(source, .8 * scale);
        for (std::size_t i = 0; i < source.pixels.size(); ++i)
            source.pixels[i] = pixel(mix(rgb(source.pixels[i]), V(red.pixels[i].r, green.pixels[i].g, blue.pixels[i].b), amount), source.pixels[i].a);
    }
    const double bloom = std::sqrt(e.get("bloom_amount") / 100) * strength;
    if (bloom > 0) {
        const double threshold = light_threshold(e.get("bloom_threshold", 75));
        auto energy = transform(source, [&](Pixel p, std::size_t, std::size_t) {
            return pixel(V(std::max(dot(max(straight(p), 0), W) - threshold, 0.) * p.a), 1);
        });
        auto spread = gaussian(energy, std::max(source.width, source.height) * e.get("bloom_radius", .4, .05, 2) / 100);
        for (std::size_t i = 0; i < source.pixels.size(); ++i) {
            auto &p = source.pixels[i];
            p = pixel(rgb(p) + std::max(double(spread.pixels[i].r - energy.pixels[i].r) - 1e-6, 0.) * bloom * p.a, p.a);
        }
    }
    return source;
}
Image emulsion(Image source, const Effects &e, const Json &adjustment, double strength, bool mono, bool preview) {
    EmulsionSettings s(source.width, source.height, e, adjustment, strength, mono, preview);
    if (!s.active) return source;
    Image captured(s.width, s.height), bounced(s.width, s.height);
    const float pitch = float(s.pitch), scale = float(s.scale), spacing = 3.6f * float(s.size);
    auto sourceAt = [&](float x, float y) { return sample(source, x * scale - .5, source.height - y * scale - .5); };
    auto radiance = [&](float x, float y) { return max(straight(sourceAt(x / pitch, y / pitch)), 0); };
    parallel_rows(s.height, [&](std::size_t y) {
        for (std::size_t x = 0; x < s.width; ++x) {
            float px = (float(x) + .5f) * pitch, py = (float(s.height - y) - .5f) * pitch;
            auto original = sourceAt(float(x) + .5f, float(s.height - y) - .5f);
            if (!(original.a > 0)) { captured.pixels[y * s.width + x] = {0,0,0,0}; continue; }
            V incident = max(straight(original), 0), total; double opacity = 0;
            for (int sub = 0; sub < 4; ++sub) {
                float qx = px + (sub & 1 ? .25f : -.25f) * pitch, qy = py + (sub & 2 ? .25f : -.25f) * pitch;
                V remaining = incident; double throughput = 1;
                for (uint32_t layer = 0; layer < 3; ++layer) {
                    uint32_t seed = 0x243f6a88U + layer * 0x9e3779b9U;
                    int ix = int(std::floor(qx / spacing)), iy = int(std::floor(qy / spacing));
                    double hits = 0; V footprint;
                    for (int cy = -1; cy <= 1; ++cy) for (int cx = -1; cx <= 1; ++cx) {
                        int gx = ix + cx, gy = iy + cy;
                        auto key = cell(gx, gy, seed);
                        float group = uniform(cell(int(std::floor(float(gx) / 5)), int(std::floor(float(gy) / 5)), seed));
                        int count = poisson(key, 1.2f + (.9f + .6f * group - 1.2f) * float(s.clumping));
                        for (int j = 0; j < count; ++j) {
                            auto h = hash(key ^ uint32_t(j + 1) * 0x63d83595U);
                            float centerX = (gx + uniform(h)) * spacing, centerY = (gy + uniform(h ^ 0xa511e9b3U)) * spacing;
                            float radius = (.25f + .10f * uniform(h ^ 0x3c6ef372U)) * spacing;
                            float spread = float(s.spread);
                            if (spread > .0001f) radius *= std::exp(spread * (2 * uniform(h ^ 0x91e10da5U) - 1)) / std::sqrt(std::sinh(2 * spread) / (2 * spread));
                            float angle = 6.2831853f * uniform(h ^ 0xbb67ae85U), cs = std::cos(angle), sn = std::sin(angle);
                            float dx = qx - centerX, dy = qy - centerY, rx = cs * dx + sn * dy, ry = -sn * dx + cs * dy;
                            float edge = std::max({std::abs(rx), std::abs(.5f * rx + .8660254f * ry), std::abs(-.5f * rx + .8660254f * ry)});
                            if (edge <= .8660254f * radius) {
                                footprint += (radiance(centerX, centerY) + radiance(centerX + radius * .5f, centerY) + radiance(centerX - radius * .5f, centerY)) / 3;
                                hits += 1;
                            }
                        }
                    }
                    V tau = mix(V(.70), layer == 0 ? V(.25,.5,1.35) : layer == 1 ? V(.5,1.35,.25) : V(1.35,.25,.5), s.chroma);
                    throughput *= std::exp(-.70 * hits);
                    V capacity = hits > 0 ? footprint / hits : V(0);
                    remaining -= min(remaining, capacity) * (V(1) - exp(tau * -hits));
                }
                total += incident - remaining; opacity += 1 - throughput;
            }
            auto c = pixel(total * (.25 * original.a), float(opacity * .25 * original.a));
            captured.pixels[y * s.width + x] = c;
            V reflection = min(V(.65,.16,.035) * exp(V(1,1.8,2.5) * (.5 - s.base)), 1);
            double gate = smooth(s.threshold, s.threshold + .25, dot(incident, W));
            bounced.pixels[y * s.width + x] = pixel(max(rgb(original) - rgb(c), 0) * reflection * (s.halo * gate), original.a);
        }
    });
    if (s.halo > 0) bounced = gaussian(std::move(bounced), s.sigma);
    auto full = [&](Image in) {
        if (s.scale < 1) in = resize_lanczos(in, s.scale, true);
        else return resample(in, source.width, source.height);
        // 保持左下物理原點；奇數尺寸的進位只裁掉上緣與右緣。
        Image out(source.width, source.height);
        for (std::size_t y = 0; y < out.height; ++y)
            std::copy_n(in.pixels.begin() + (y + in.height - out.height) * in.width, out.width, out.pixels.begin() + y * out.width);
        return out;
    };
    captured = full(std::move(captured)); bounced = full(std::move(bounced));
    auto masks = tone_masks(source); double absorption = s.absorption();
    for (std::size_t i = 0; i < source.pixels.size(); ++i) {
        auto &p = source.pixels[i]; const auto c = captured.pixels[i];
        V weights = max(rgb(masks.pixels[i]), 0), rgbSource = rgb(p);
        double amount = dot(weights, s.amounts) / std::max(weights.x + weights.y + weights.z, 1e-6);
        double fraction = p.a > 0 ? std::clamp(double(c.a / p.a), 0., 1.) : 0;
        V color = straight(p); double peak = std::max({color.x, color.y, color.z});
        p = pixel(mix(rgbSource, rgb(c) / absorption, amount * .35 / std::max(1., peak)) + rgb(bounced.pixels[i]) * (fraction / absorption), p.a);
    }
    return source;
}
} // namespace photocore::film_cpu
