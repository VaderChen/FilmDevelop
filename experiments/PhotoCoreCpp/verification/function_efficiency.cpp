// 函式層級驗收：參考實作固定取自 8bdd679 的 gaussian，禁止隨最佳化同步修改。
#include "film_math.hpp"
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace photocore;
using namespace photocore::film_cpu;

namespace reference {
static const Pixel &at(const Image &in, long x, long y) {
    x = std::clamp(x, 0L, long(in.width) - 1);
    y = std::clamp(y, 0L, long(in.height) - 1);
    return in.pixels[std::size_t(y) * in.width + std::size_t(x)];
}
static Image gaussian(Image in, double sigma, bool clamp_edges) {
    if (!(sigma > 0)) return in;
    if (!std::isfinite(sigma) || sigma > 10000) throw std::invalid_argument("模糊半徑不合法");
    const int radius = std::max(1, int(std::ceil(4 * sigma)));
    std::vector<double> weights(std::size_t(radius) + 1);
    double total = 0;
    for (int i = 0; i <= radius; ++i) {
        weights[std::size_t(i)] = std::exp(-.5 * i * i / (sigma * sigma));
        total += weights[std::size_t(i)] * (i ? 2 : 1);
    }
    for (auto &v : weights) v /= total;
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
                    const auto &a = sample(*current, long(x) - (axis == 0 ? i : 0), long(y) - (axis == 1 ? i : 0));
                    const auto &b = sample(*current, long(x) + (axis == 0 ? i : 0), long(y) + (axis == 1 ? i : 0));
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
}

static Image fixture(std::size_t width, std::size_t height) {
    Image result(width, height);
    std::uint32_t state = 0x71342;
    auto next = [&] {
        state = state * 1664525U + 1013904223U;
        return float(int(state % 16384) - 4096) / 2048.f;
    };
    for (auto &p : result.pixels) p = {next(), next(), next(), next()};
    result.pixels[0] = {-0.f, 0.f, std::numeric_limits<float>::denorm_min(), 0.f};
    return result;
}
static bool equal(const Image &a, const Image &b) {
    return a.width == b.width && a.height == b.height &&
        std::memcmp(a.pixels.data(), b.pixels.data(), a.pixels.size() * sizeof(Pixel)) == 0;
}
static std::size_t verify() {
    std::size_t cases = 0;
    for (auto dimensions : {std::pair<std::size_t, std::size_t>{1,1}, {1,17}, {17,1}, {2,3}, {5,7}, {31,19}, {128,96}, {257,129}}) {
        const auto input = fixture(dimensions.first, dimensions.second), original = input;
        for (double sigma : {0., -1., .25, 1., 2.6, 8., std::numeric_limits<double>::quiet_NaN()}) {
            for (bool clamp_edges : {false, true}) {
                auto expected = reference::gaussian(input, sigma, clamp_edges);
                auto actual = photocore::film_cpu::gaussian(input, sigma, clamp_edges);
                if (!equal(expected, actual) || !equal(input, original)) throw std::runtime_error("像素或來源影像與基準不符");
                ++cases;
            }
        }
    }
    for (double sigma : {std::numeric_limits<double>::infinity(), 10001.}) {
        bool rejected = false;
        try { (void)photocore::film_cpu::gaussian(fixture(1,1), sigma, true); }
        catch (const std::invalid_argument &e) { rejected = std::string(e.what()) == "模糊半徑不合法"; }
        if (!rejected) throw std::runtime_error("非法半徑未維持原有拒絕行為");
        ++cases;
    }
    return cases;
}

int main(int argc, char **argv) {
    try {
        const auto cases = verify();
        std::cout << "{\"bitExactCases\":" << cases << ",\"benchmarks\":[";
        if (argc == 1 || std::string(argv[1]) != "--verify-only") {
            const auto input = fixture(1024,768);
            bool first = true;
            for (double sigma : {1.5,4.}) {
                for (bool clamp_edges : {false,true}) {
                    std::vector<double> samples;
                    volatile float checksum = 0;
                    for (int i = 0; i < 10; ++i) {
                        const auto start = std::chrono::steady_clock::now();
                        const auto output = photocore::film_cpu::gaussian(input, sigma, clamp_edges);
                        const auto end = std::chrono::steady_clock::now();
                        checksum = checksum + output.pixels[output.pixels.size()/2].r;
                        if (i >= 3) samples.push_back(std::chrono::duration<double,std::milli>(end-start).count());
                    }
                    if (!first) std::cout << ',';
                    first = false;
                    std::cout << "{\"function\":\"film_cpu::gaussian\",\"width\":1024,\"height\":768,\"sigma\":" << sigma
                              << ",\"clampEdges\":" << (clamp_edges ? "true" : "false") << ",\"milliseconds\":[";
                    for (std::size_t i = 0; i < samples.size(); ++i) std::cout << (i ? "," : "") << std::setprecision(9) << samples[i];
                    std::sort(samples.begin(), samples.end());
                    std::cout << "],\"medianMilliseconds\":" << samples[samples.size()/2] << ",\"checksum\":" << checksum << '}';
                }
            }
        }
        std::cout << "]}\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
