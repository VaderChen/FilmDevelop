#include "film_math.hpp"
#include "photocore/film.hpp"
#include <optional>
#include <stdexcept>

namespace photocore::film_cpu {
static const Pixel &at(const Image &in, long x, long y) {
    x = std::clamp(x, 0L, long(in.width) - 1);
    y = std::clamp(y, 0L, long(in.height) - 1);
    return in.pixels[std::size_t(y) * in.width + std::size_t(x)];
}
V bilinear(const Image &in, double x, double y) {
    const long ix = long(std::floor(x)), iy = long(std::floor(y));
    // 原生 Metal 線性取樣器以 8-bit 權重插值；後續的非線性運算會放大此差異。
    const double fx=std::floor((x-ix)*256+.5)/256, fy=std::floor((y-iy)*256+.5)/256;
    return mix(mix(rgb(at(in, ix, iy)), rgb(at(in, ix + 1, iy)), fx),
               mix(rgb(at(in, ix, iy + 1)), rgb(at(in, ix + 1, iy + 1)), fx), fy);
}
Image gaussian(Image in, double sigma, bool clamp_edges) {
    if (!(sigma > 0))
        return in;
    if (!std::isfinite(sigma) || sigma > 10000)
        throw std::invalid_argument("模糊半徑不合法");
    const int radius = std::max(1, int(std::ceil(4 * sigma)));
    std::vector<double> weights(std::size_t(radius) + 1);
    double total = 0;
    for (int i = 0; i <= radius; ++i) {
        weights[std::size_t(i)] = std::exp(-.5 * i * i / (sigma * sigma));
        total += weights[std::size_t(i)] * (i ? 2 : 1);
    }
    for (auto &v : weights)
        v /= total;
    auto sample = [&](const Image &src, long x, long y) {
        if (!clamp_edges && (x < 0 || y < 0 || x >= long(src.width) || y >= long(src.height))) return Pixel{0,0,0,0};
        return at(src, x, y);
    };
    Image scratch(in.width, in.height);
    const Image *current = &in;
    for (int axis = 0; axis < 2; ++axis) {
        Image &out = axis == 0 ? scratch : in;
        parallel_rows(in.height, in.width, [&](std::size_t y) {
            for (std::size_t x = 0; x < in.width; ++x) {
                V sum = rgb(sample(*current, long(x), long(y))) * weights[0];
                double alpha = sample(*current, long(x), long(y)).a * weights[0];
                for (int i = 1; i <= radius; ++i) {
                    const auto &a =
                        sample(*current, long(x) - (axis == 0 ? i : 0), long(y) - (axis == 1 ? i : 0));
                    const auto &b =
                        sample(*current, long(x) + (axis == 0 ? i : 0), long(y) + (axis == 1 ? i : 0));
                    sum += (rgb(a) + rgb(b)) * weights[std::size_t(i)];
                    alpha += (a.a + b.a) * weights[std::size_t(i)];
                }
                out.pixels[y * in.width + x] = pixel(sum, float(alpha));
            }
        });
        current = &out;
    }
    return in;
}
Image resize_lanczos(const Image &in, double scale, bool clamp_edges) {
    if (scale >= 1)
        return in;
    if (!(scale > 0) || !std::isfinite(scale))
        throw std::invalid_argument("縮放比例不合法");
    if (scale < .5) {
        // 對齊原生的大幅縮小：分段減半，並保留原始的最終有限範圍。
        const auto width=std::size_t(std::ceil(in.width*scale)), height=std::size_t(std::ceil(in.height*scale));
        auto reduced=resize_lanczos(in,.5,clamp_edges);
        auto result=resize_lanczos(reduced,scale*2,clamp_edges);
        if (result.width==width && result.height==height) return result;
        Image cropped(width,height);
        for (std::size_t y=0;y<height;++y)
            std::copy_n(result.pixels.begin()+(y+result.height-height)*result.width,width,cropped.pixels.begin()+y*width);
        return cropped;
    }
    constexpr double pi = 3.14159265358979323846;
    auto kernel = [&](double d) {
        d = std::abs(d);
        return d < 1e-12 ? 1.
                         : (d >= 3 ? 0. : std::sin(pi * d) * std::sin(pi * d / 3) / (pi * pi * d * d / 3));
    };
    std::optional<Image> storage;
    const Image *current = &in;
    for (int axis = 0; axis < 2; ++axis) {
        Image out(axis == 0 ? std::size_t(std::ceil(in.width * scale)) : current->width,
                  axis == 1 ? std::size_t(std::ceil(in.height * scale)) : current->height);
        struct TapSet {
            long start;
            std::vector<double> weights;
            double total = 0;
        };
        std::vector<TapSet> taps(axis == 0 ? out.width : out.height);
        // 同一軸位置的 Lanczos 係數全列／全欄共用，保持原有加總順序。
        for (std::size_t i = 0; i < taps.size(); ++i) {
            const double pos = axis == 0 ? (i + .5) / scale - .5
                                         : double(in.height) - (double(out.height) - i - .5) / scale - .5;
            auto &tap = taps[i];
            tap.start = long(std::ceil(pos - 3 / scale));
            const long end = long(std::floor(pos + 3 / scale));
            for (long k = tap.start; k <= end; ++k) {
                const double f = kernel((k - pos) * scale);
                tap.weights.push_back(f);
                tap.total += f;
            }
        }
        parallel_rows(out.height, out.width, [&](std::size_t y) {
            for (std::size_t x = 0; x < out.width; ++x) {
                const auto &tap = taps[axis == 0 ? x : y];
                V sum;
                double alpha = 0;
                for (std::size_t i = 0; i < tap.weights.size(); ++i) {
                    const long k = tap.start + long(i);
                    const double f = tap.weights[i];
                    // 原流程的 Lanczos 未先延展影像，邊界外保留透明黑。
                    const long sx = axis == 0 ? k : long(x), sy = axis == 1 ? k : long(y);
                    const auto p = clamp_edges ? at(*current, sx, sy) :
                        sx < 0 || sy < 0 || sx >= long(current->width) || sy >= long(current->height)
                            ? Pixel{0, 0, 0, 0}
                            : current->pixels[std::size_t(sy) * current->width + std::size_t(sx)];
                    sum += rgb(p) * f;
                    alpha += p.a * f;
                }
                out.pixels[y * out.width + x] = pixel(sum / tap.total, float(alpha / tap.total));
            }
        });
        storage = std::move(out);
        current = &*storage;
    }
    return std::move(*storage);
}
V fit_chroma(V color, double y) {
    V delta = color - y;
    double scale = 1, ceiling = std::max(1., y);
    for (int c = 0; c < 3; ++c) {
        if (delta[c] < 0)
            scale = std::min(scale, y / -delta[c]);
        if (delta[c] > 0)
            scale = std::min(scale, (ceiling - y) / delta[c]);
    }
    return V(y) + delta * std::max(0., scale);
}
V lab_luminance(V color, double y, double scale) {
    if (scale == 1)
        return color;
    if (y <= 1e-20)
        return color * scale;
    const double target = y * scale;
    if (color.x == color.y && color.y == color.z)
        return V(target);
    const auto lab = rgb_to_lab({color.x, color.y, color.z});
    const double f = target > 216. / 24389 ? std::cbrt(target) : (24389. / 27 * target + 16) / 116;
    auto inv = [](double t) { return t > 6. / 29 ? t * t * t : (116 * t - 16) * 27 / 24389; };
    V xyz{.9504559270516716 * inv(f + lab[1] / 500), target, 1.0890577507598784 * inv(f - lab[2] / 200)};
    V result = multiply({V(3.240969941904521, -1.537383177570093, -.498610760293),
                         V(-.9692436362808796, 1.8759675015077202, .04155505740717559),
                         V(.05563007969699366, -.20397695888897652, 1.0569715142428786)},
                        xyz);
    const double lower = std::min({0., color.x, color.y, color.z}) * scale,
                 minimum = std::min({result.x, result.y, result.z});
    if (minimum < lower)
        result = V(lower) + (result - minimum) * ((target - lower) / (target - minimum));
    return result;
}
} // namespace photocore::film_cpu
namespace photocore {
Image quantize_srgb16(Image source) {
    return film_cpu::transform_owned(std::move(source), [](Pixel p, std::size_t, std::size_t) {
        if (p.a != 1)
            throw std::invalid_argument("成品驗收要求不透明影像");
        auto q = [](double x) {
            if (!std::isfinite(x))
                throw std::invalid_argument("輸出含非有限像素");
            x = std::clamp(x, 0., 1.);
            x = x <= .0031308 ? 12.92 * x : 1.055 * std::pow(x, 1 / 2.4) - .055;
            x = std::round(x * 65535) / 65535;
            return float(x <= .04045 ? x / 12.92 : std::pow((x + .055) / 1.055, 2.4));
        };
        return Pixel{q(p.r), q(p.g), q(p.b), 1};
    });
}
} // namespace photocore
