#include "film_internal.hpp"
#include <optional>

namespace photocore::film_cpu {
namespace {
V demand(V active, V salt, V developer, double rate) {
    V radius = pow(V(.125) + (1 - salt) / max(active, 1e-6), 1. / 3);
    V dr = .28 * rate * salt * developer;
    return min(salt, max(active * dr * (3 * radius * radius + 3 * radius * dr + dr * dr), 0));
}
std::vector<double> diffusion_weights(double variance, int radius) {
    const double half = variance / 2;
    double leading = 1;
    std::vector<double> values(std::size_t(radius) + 1);
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
        values[std::size_t(n)] = std::exp(-variance) * sum;
    }
    double total = values[0];
    for (int n = 1; n <= radius; ++n)
        total += 2 * values[std::size_t(n)];
    if (total > 0)
        for (auto &v : values)
            v /= total;
    return values;
}
Image diffuse(const Image &in, const std::vector<double> &weights, int axis) {
    return transform(in, [&](Pixel p, std::size_t x, std::size_t y) {
        double delta = 0, total = weights[0];
        for (std::size_t i = 1; i < weights.size(); ++i) {
            auto at = [&](long sign) {
                const auto xx = std::size_t(
                    std::clamp(long(x) + (axis == 0 ? sign * long(i) : 0), 0L, long(in.width) - 1));
                const auto yy = std::size_t(
                    std::clamp(long(y) + (axis == 1 ? sign * long(i) : 0), 0L, long(in.height) - 1));
                return in.pixels[yy * in.width + xx].r;
            };
            delta += weights[i] * ((at(-1) - p.r) + (at(1) - p.r));
            total += 2 * weights[i];
        }
        return pixel(V(p.r + delta / total));
    });
}
} // namespace
Image develop(Image source, const Effects &e, double strength,
              const std::function<void(const std::string &, const Image &)> &trace) {
    const double amount = std::sqrt(e.get("development_amount") / 100) * strength;
    if (amount == 0)
        return source;
    const double activity = e.get("developer_activity", 100, 20, 200) / 100 *
                            std::pow(2, (e.get("developer_temperature", 20, 10, 40) - 20) / 10);
    const double time = std::min(6., (.4 + 2.6 * e.get("development_time", 50) / 100) * activity),
                 dt = time / 12, rate = 1.6 * dt;
    const double supplied = 1 - std::exp(-2.5 * e.get("development_agitation", 50) / 100 * dt);
    const double longest = double(std::max(source.width, source.height)), scale = std::min(1., 768 / longest);
    std::optional<Image> reduced;
    if (scale < 1)
        reduced = resize_lanczos(source, scale);
    auto active = transform(reduced ? *reduced : source, [](Pixel p, std::size_t, std::size_t) {
        V x = max(rgb(p) / std::max(double(p.a), 1e-8), 0);
        return pixel(clamp(1 - V(.18) / (x + .18), 0, 1));
    });
    reduced.reset();
    if (trace)
        trace("field-active", active);
    Image salt(active.width, active.height), developer(active.width, active.height);
    // CI 的有限矩形對跨越邊界的像素保留面積覆蓋率；初始藥水／鹽量
    // 取的是預乘 RGB，非整數場的頂列／右欄不能一律初始化為 1。
    for (std::size_t y = 0; y < salt.height; ++y)
        for (std::size_t x = 0; x < salt.width; ++x) {
            const double coverageX = std::clamp(source.width * scale - x, 0., 1.);
            const double coverageY = std::clamp(source.height * scale - (salt.height - y - 1), 0., 1.);
            const float coverage = float(coverageX * coverageY);
            salt.pixels[y * salt.width + x] = {coverage, coverage, coverage, coverage};
        }
    developer = salt;
    const double sigma = longest * scale * e.get("development_diffusion", .15, .02, 1) / 100 * std::sqrt(dt);
    const int radius = int(std::min(24., std::max(4., std::ceil(4 * sigma + 4))));
    const auto weights = diffusion_weights(sigma * sigma, radius);
    for (int step = 0; step < 12; ++step) {
        // 反應僅讀同一像素，可直接更新鹽量與藥水；擴散仍使用獨立輸出。
        for (std::size_t i = 0; i < salt.pixels.size(); ++i) {
            V need = demand(rgb(active.pixels[i]), rgb(salt.pixels[i]), V(developer.pixels[i].r), rate);
            double usage = 1.6 * dot(need, V(1. / 3));
            V uptake = need * std::min(1., developer.pixels[i].r / std::max(usage, 1e-7));
            salt.pixels[i] = pixel(max(rgb(salt.pixels[i]) - uptake, 0));
            developer.pixels[i] =
                pixel(V(std::max(0., developer.pixels[i].r - 1.6 * dot(uptake, V(1. / 3)))));
        }
        developer = diffuse(diffuse(developer, weights, 0), weights, 1);
        for (auto &p : developer.pixels)
            p = pixel(V(std::clamp(double(p.r), 0., 1.) * (1 - supplied) + supplied));
    }
    if (trace)
        trace("field-salt", salt);
    auto growthRatio = [&](V activeValue, V saltValue) {
        V referenceSalt(1), referenceDeveloper(1);
        for (int step = 0; step < 12; ++step) {
            V need = demand(activeValue, referenceSalt, referenceDeveloper, rate);
            V uptake = need * min(1, referenceDeveloper / max(1.6 * need, 1e-7));
            referenceSalt = max(referenceSalt - uptake, 0);
            referenceDeveloper = mix(max(referenceDeveloper - 1.6 * uptake, 0), 1, supplied);
        }
        V relative = (max(1 - saltValue, 0) + .0001) / (max(1 - referenceSalt, 0) + .0001);
        return exp(clamp(log(relative), -.7, .7) * amount);
    };
    if (trace) {
        Image ratio = active;
        for (std::size_t i = 0; i < ratio.pixels.size(); ++i)
            ratio.pixels[i] = pixel(growthRatio(rgb(active.pixels[i]), rgb(salt.pixels[i])));
        trace("field-ratio", ratio);
    }
    // 對齊 Core Image 延後求值：先取樣反應場，再求非線性生長比；不可插值已求值的比值。
    const auto sourceHeight = source.height;
    return transform_owned(std::move(source), [&](Pixel p, std::size_t x, std::size_t y) {
        const double sx = (x + .5) * scale - .5;
        const double sy = double(active.height) - (double(sourceHeight) - y - .5) * scale - .5;
        return pixel(rgb(p) * growthRatio(bilinear(active, sx, sy), bilinear(salt, sx, sy)), p.a);
    });
}
namespace {
double density(double x, double contrast) {
    return .08 + 2.4 / (1 + std::exp(std::clamp(-4 * .65 * contrast * x / 2.4, -60., 60.)));
}
double log_exposure(double y, V curve) {
    double x = std::log(std::max(y, 1e-10) / .18) / std::log(10.) + curve.y * .3010299956639812;
    const double z = std::max(x - .3010299956639812, 0.);
    if (curve.z > 0 && z > 0) {
        const double u = curve.z * z;
        double ratio = u < .001 ? 1 - u * .5 + u * u * (1. / 3 - u * .25) : std::log1p(u) / u;
        x += z * (ratio - 1);
    }
    return x;
}
float noise(float x, float y) {
    // 保留原有 FP32 雜訊函式；座標由左上影像轉為 Core Image 的左下原點。
    const float value = std::sin(x * 127.1f + y * 311.7f + 17.0f) * 43758.5453f;
    return 2 * (value - std::floor(value)) - 1;
}
} // namespace
Image chemistry(Image source, const Effects &e, double strength, bool monochrome) {
    const Json s = e.json.value("developer_chemistry", Json::object());
    V curve{number(s, "contrast", 1, .6, 1.5), number(s, "speedEV", 0, -1, 1),
            number(s, "compensation", 0, 0, 100) / 50};
    V layers = monochrome ? V(0)
                          : V(number(s, "red", 0, -20, 20), number(s, "green", 0, -20, 20),
                              number(s, "blue", 0, -20, 20)) /
                                100;
    const double grain = number(s, "grain", 0, 0, 100) / 100 * .018,
                 acutance = number(s, "acutance", 0, 0, 100) / 100 * .24;
    if (strength == 0 || (curve.x == 1 && curve.y == 0 && curve.z == 0 && grain == 0 && acutance == 0 &&
                          layers.x == 0 && layers.y == 0 && layers.z == 0))
        return source;
    std::optional<Image> mean;
    if (acutance > 0) {
        mean = transform(source, [&](Pixel p, std::size_t, std::size_t) {
            return pixel(V(density(log_exposure(dot(straight(p), exact_w), curve), curve.x) * p.a), p.a);
        });
        mean = gaussian(std::move(*mean),
                        std::max(.5, 2 * double(std::max(source.width, source.height)) / 3000));
    }
    const double coordinateScale = 3000. / double(std::max(source.width, source.height));
    const auto sourceWidth = source.width, sourceHeight = source.height;
    return transform_owned(std::move(source), [&](Pixel p, std::size_t px, std::size_t py) {
        if (p.a <= 0)
            return Pixel{0, 0, 0, 0};
        const V color = straight(p);
        const double y = dot(color, exact_w);
        if (y <= 1e-10)
            return p;
        const double x = log_exposure(y, curve);
        double d = density(x, curve.x);
        if (acutance > 0) {
            const auto m = mean->pixels[py * sourceWidth + px];
            double delta = d - m.r / std::max(double(m.a), 1e-10);
            d += acutance * delta / (1 + std::abs(delta) / .08);
        }
        if (grain > 0) {
            const float xx = float(px + .5) * float(coordinateScale),
                        yy = float(sourceHeight - py - .5) * float(coordinateScale);
            const float cx = std::floor(xx), cy = std::floor(yy);
            float fx = xx - cx, fy = yy - cy;
            fx = fx * fx * (3 - 2 * fx);
            fy = fy * fy * (3 - 2 * fy);
            const float a = noise(cx, cy) * (1 - fx) + noise(cx + 1, cy) * fx,
                        b = noise(cx, cy + 1) * (1 - fx) + noise(cx + 1, cy + 1) * fx;
            d += grain * (a * (1 - fy) + b * fy);
        }
        const double t = std::clamp((d - .08) / 2.4, .00001, .99999);
        const double inverseX = std::log(t / (1 - t)) / (4 * .65 / 2.4);
        double target = .18 * std::exp(std::clamp(inverseX * std::log(10.), -60., 25.));
        target = y * std::clamp(target / y, .015625, 64.);
        V result = lab_luminance(color, y, target / y);
        if (!monochrome && dot(map(layers, std::abs), V(1)) > 0) {
            result *= exp(std::clamp(x, -3., 2.) * layers * std::log(10.));
            double colorY = dot(result, exact_w);
            if (colorY <= target * .0001) {
                result += target - colorY;
                colorY = target;
            }
            result *= target / colorY;
            const double lower = std::min({0., color.x, color.y, color.z}) * target / y,
                         minimum = std::min({result.x, result.y, result.z});
            if (minimum < lower)
                result =
                    V(target) + (result - target) * std::clamp((target - lower) / (target - minimum), 0., 1.);
        }
        return pixel(mix(color, result, strength) * p.a, p.a);
    });
}
} // namespace photocore::film_cpu
