#include "pipeline.hpp"
#include "photocore/film.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
namespace photocore::vk {
class StageBenchmark {
  public:
    static Surface apply(Pipeline &pipeline, Surface input, const Recipe &recipe, const std::string &stage) {
        if (stage == "development")
            return pipeline.develop(std::move(input), recipe.effects, recipe.strength);
        if (stage == "spectral")
            return pipeline.spectral(std::move(input), recipe.effects, recipe.strength, *recipe.profile);
        throw std::invalid_argument("未知階段");
    }
};
} // namespace photocore::vk
int main(int argc, char **argv) {
    using namespace photocore;
    using film_cpu::Json;
    namespace fs = std::filesystem;
    using Clock = std::chrono::steady_clock;
    try {
        if (argc == 4 && std::string(argv[1]) == "--quantize") {
            if (fs::exists(fs::u8path(argv[3])))
                throw std::invalid_argument("量化成品路徑已存在");
            write_pfm(argv[3], quantize_srgb16(read_pfm(argv[2])));
            return 0;
        }
        if (argc != 7 && argc != 8)
            throw std::invalid_argument("用法：photo_core_vulkan_stage_benchmark input.pfm recipe.json "
                                        "development|spectral output.pfm report.json repeats [validation-off]");
        if (argc == 8 && std::string(argv[7]) != "validation-off")
            throw std::invalid_argument("未知驗證模式");
        const bool validationEnabled = argc == 7;
        std::string stage = argv[3];
        std::size_t parsed = 0;
        auto repeats = std::stoul(argv[6], &parsed);
        if (parsed != std::string(argv[6]).size() || repeats < 1 || repeats > 15 ||
            (stage != "development" && stage != "spectral"))
            throw std::invalid_argument("階段或次數不符");
        if (fs::exists(fs::u8path(argv[4])) || fs::exists(fs::u8path(argv[5])))
            throw std::invalid_argument("請使用全新輸出路徑");
        auto folder = fs::absolute(fs::u8path(argv[0])).parent_path();
        const auto source = read_pfm(argv[1]);
        auto begin = Clock::now();
        vk::Pipeline pipeline((folder / "film-data").u8string(), (folder / "film.comp.spv").u8string(), validationEnabled);
        double init = std::chrono::duration<double, std::milli>(Clock::now() - begin).count();
        auto recipe = vk::prepare_recipe(argv[2], pipeline.database);
        Json runs = Json::array(), stageStats = Json::array();
        std::vector<double> times;
        double first = 0;
        uint64_t expected = 0;
        for (unsigned trial = 0; trial <= repeats; ++trial) {
            pipeline.context.stats.clear();
            auto start = Clock::now();
            auto uploaded = pipeline.context.upload(source);
            auto output = vk::StageBenchmark::apply(pipeline, std::move(uploaded), recipe, stage);
            auto image = pipeline.context.download(output);
            double elapsed = std::chrono::duration<double, std::milli>(Clock::now() - start).count();
            for (auto pixel : image.pixels)
                for (float value : {pixel.r, pixel.g, pixel.b, pixel.a})
                    if (!std::isfinite(value))
                        throw std::runtime_error("成品含非有限值");
            uint64_t hash = 14695981039346656037ULL;
            const auto *bytes = reinterpret_cast<const unsigned char *>(image.pixels.data());
            for (std::size_t i = 0; i < image.pixels.size() * sizeof(Pixel); ++i) {
                hash ^= bytes[i];
                hash *= 1099511628211ULL;
            }
            if (trial == 0) {
                expected = hash;
                first = elapsed;
            } else {
                if (expected != hash)
                    throw std::runtime_error("GPU 重複結果不一致");
                times.push_back(elapsed);
                runs.push_back(elapsed);
            }
            if (trial == repeats) {
                write_pfm(argv[4], image);
                for (const auto &s : pipeline.context.stats)
                    stageStats.push_back({{"stage", s.label}, {"gpu_ms", s.gpu_ms}, {"host_ms", s.host_ms}});
            }
        }
        if (pipeline.context.errors())
            throw std::runtime_error("Vulkan 驗證失敗");
        std::sort(times.begin(), times.end());
        Json report{
            {"schema", 1},
            {"backend", "vulkan-moltenvk"},
            {"device", pipeline.context.device_name()},
            {"stage", stage},
            {"width", source.width},
            {"height", source.height},
            {"init_ms", init},
            {"first_ms", first},
            {"runs_ms", runs},
            {"median_ms", times[times.size() / 2]},
            {"deterministic", true},
            {"validation_enabled", validationEnabled},
            {"validation_errors", pipeline.context.errors()},
            {"validation_warnings", pipeline.context.warnings()},
            {"cpu_pixel_fallbacks", 0},
            {"peak_vulkan_buffer_bytes", pipeline.context.peak_buffer_bytes()},
            {"last_run_stages", stageStats},
            {"scope", "相同 CPU 輸入 → 單一階段 → 同步 CPU RGBAf 回讀；不含 PFM I/O、配方解析與結果 hash"}};
        std::ofstream file(fs::u8path(argv[5]));
        file << report.dump(2) << '\n';
        file.close();
        if (!file)
            throw std::runtime_error("報告寫入失敗");
        std::cout << stage << " " << source.width << 'x' << source.height << "：" << times[times.size() / 2]
                  << " ms\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "Vulkan 階段量測失敗：" << e.what() << '\n';
        return 1;
    }
}
