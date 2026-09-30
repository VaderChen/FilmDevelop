#include "pipeline.hpp"
#include <filesystem>
#include <functional>
#include <iostream>
#include <random>
int main(int, char **argv) {
    using namespace photocore;
    try {
        namespace fs = std::filesystem;
        auto folder = fs::absolute(fs::u8path(argv[0])).parent_path();
        vk::Pipeline pipeline((folder / "film-data").u8string(), (folder / "film.comp.spv").u8string());
        std::mt19937 random(97031);
        std::uniform_real_distribution<float> value(-.1f, 8.f);
        Image input(65, 17);
        for (std::size_t i = 0; i < input.pixels.size(); ++i) {
            float alpha = i % 13 == 0 ? 0.f : (i % 7 == 0 ? .3f : 1.f);
            input.pixels[i] = {value(random) * alpha, value(random) * alpha, value(random) * alpha, alpha};
        }
        auto uploaded = pipeline.context.upload(input);
        double maxError = 0;
        std::size_t checks = 0;
        auto compare = [&](const Image &expected, const Image &actual) {
            if (expected.width != actual.width || expected.height != actual.height)
                throw std::runtime_error("尺寸不符");
            for (std::size_t i = 0; i < actual.pixels.size(); ++i) {
                auto a = expected.pixels[i], b = actual.pixels[i];
                std::array<float, 4> av{a.r, a.g, a.b, a.a}, bv{b.r, b.g, b.b, b.a};
                for (int c = 0; c < 4; ++c) {
                    double error = std::abs(double(av[c]) - bv[c]) / std::max(1., std::abs(double(av[c])));
                    if (!std::isfinite(bv[c]) || error > 2e-5)
                        throw std::runtime_error("GPU 基礎運算誤差超標：" + std::to_string(error));
                    maxError = std::max(maxError, error);
                    ++checks;
                }
            }
        };
        for (double ev : {-16., -2., 0., .7, 5., 16.})
            for (bool protect : {false, true})
                for (bool peak : {false, true}) {
                    Exposure e;
                    e.global_ev = ev;
                    e.zones = {ev, ev * .7, ev * .3};
                    e.protect_highlights = protect;
                    e.protect_peak = peak;
                    e.strength = .73;
                    compare(apply_exposure(input, e),
                            pipeline.context.download(pipeline.exposure(uploaded, e)));
                }
        compare(apply_raw_mapping(input), pipeline.context.download(pipeline.raw_mapping(uploaded)));
        Calibration cal;
        cal.rows = {{{{1.1, -.03, .02, .1, .02, -.05}},
                     {{.02, .95, .06, -.02, .1, .02}},
                     {{.01, .03, 1.04, .03, -.04, .02}}}};
        compare(apply_calibration(input, cal),
                pipeline.context.download(pipeline.calibration(uploaded, cal)));
        compare(input, pipeline.context.download(uploaded));
        if (pipeline.context.errors())
            throw std::runtime_error("Vulkan 驗證失敗");
        std::cout << "曝光／亮部保護／RAW 映射／六項式校色／alpha／HDR／來源保留：" << checks
                  << " 項通過，最大正規化誤差 " << maxError << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
