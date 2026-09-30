#include "delta_e.hpp"
#include "hook.hpp"
#include "photocore/film.hpp"
#include "runtime.hpp"
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace photocore::smoke {
using namespace film_cpu;
namespace {
struct Capture {
    bool replay = false;
    bool benchmark = false;
    std::vector<V> original;
    Profile savedProfile;
    CalibrationData savedCalibration;
    std::array<double, 13> savedLight{};
    const Database *database = nullptr;
    std::vector<Float4> input, expected, gpu;
    Parameters parameters{};
    const Profile *profile = nullptr;
    const CalibrationData *calibration = nullptr;
    const std::array<double, 13> *light = nullptr;
    std::size_t index = 0, cpuCalls = 0;
};
Capture *active = nullptr;
using Clock = std::chrono::steady_clock;
double milliseconds(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
Float4 pack(V v, float fourth = 0) {
    return {float(v.x), float(v.y), float(v.z), fourth};
}
} // namespace
V route_unmix(V optical, const Profile &p, const Database &db, const std::array<double, 13> &light,
              const CalibrationData &cal, const std::function<V()> &cpu) {
    if (!active)
        throw std::runtime_error("GPU Smoke 接線未啟用");
    auto &a = *active;
    if (!a.profile) {
        a.profile = &p;
        a.calibration = &cal;
        a.light = &light;
        if (a.benchmark) {
            a.savedProfile = p;
            a.savedCalibration = cal;
            a.savedLight = light;
            a.database = &db;
        }
        a.parameters[0] = {float(p.middle), float(p.curve[3]), 0, 0};
        a.parameters[1] = pack(cal.base);
        a.parameters[2] = pack(cal.middle);
        for (unsigned i = 0; i < 3; ++i)
            a.parameters[3 + i] = pack(cal.inverse[i]);
        for (unsigned i = 0; i < 13; ++i) {
            a.parameters[6 + i] = pack(p.negative[i], float(p.base[i]));
            a.parameters[19 + i] = pack(db.scanner[i] * light[i]);
        }
    }
    if (a.profile != &p || a.calibration != &cal || a.light != &light)
        throw std::runtime_error("同一 GPU 批次混入不同光譜參數");
    const auto input = pack(optical);
    if (!a.replay) {
        auto value = cpu();
        ++a.cpuCalls;
        a.input.push_back(input);
        a.expected.push_back(pack(value));
        if (a.benchmark)
            a.original.push_back(optical);
        return value;
    }
    if (a.index >= a.input.size() || std::memcmp(&input, &a.input[a.index], sizeof(input)))
        throw std::runtime_error("重播的反算輸入與原始 CPU 流程不一致");
    const auto result = a.gpu.at(a.index++);
    return {result.x, result.y, result.z};
}
} // namespace photocore::smoke
int main(int argc, char **argv) {
    using namespace photocore;
    using namespace photocore::film_cpu;
    using namespace photocore::smoke;
    namespace fs = std::filesystem;
    try {
        std::string input, recipe, output, data, shader;
        unsigned repeats = 0;
        for (int i = 1; i < argc; ++i) {
            std::string key = argv[i];
            if (key == "--help") {
                std::cout << "Vulkan unmix 混合流程 Smoke（不代表全 GPU 移植）\n--input linear.pfm --recipe "
                             "film.json --output final.pfm [--data 目錄] [--shader SPIR-V] [--benchmark-repeats 1..10]\n";
                return 0;
            }
            if (i + 1 >= argc)
                throw std::invalid_argument("選項缺值：" + key);
            std::string value = argv[++i];
            if (key == "--input")
                input = value;
            else if (key == "--recipe")
                recipe = value;
            else if (key == "--output")
                output = value;
            else if (key == "--data")
                data = value;
            else if (key == "--shader")
                shader = value;
            else if (key == "--benchmark-repeats") {
                std::size_t parsed = 0;
                repeats = std::stoul(value, &parsed);
                if (parsed != value.size() || repeats < 1 || repeats > 10)
                    throw std::invalid_argument("量測次數必須介於 1 至 10");
            }
            else
                throw std::invalid_argument("未知選項：" + key);
        }
        if (input.empty() || recipe.empty() || output.empty())
            throw std::invalid_argument("需要 input／recipe／output");
        const auto folder = fs::absolute(fs::u8path(argv[0])).parent_path();
        if (data.empty())
            data = (folder / "film-data").u8string();
        if (shader.empty())
            shader = (folder / "unmix.comp.spv").u8string();
        const auto target = fs::weakly_canonical(fs::u8path(output));
        // 每次使用新成品，避免錯誤流程留下舊檔被當成成功。
        if (fs::exists(target) || fs::exists(fs::u8path(output + ".gpu.json")))
            throw std::invalid_argument("Smoke 成品路徑已存在，請使用新檔名");
        const auto initStart = Clock::now();
        Runtime gpu(shader);
        const double initMs = milliseconds(initStart);
        FilmProcessor processor(data);
        const auto source = read_pfm(input);
        Capture capture;
        capture.benchmark = repeats > 0;
        if (repeats)
            capture.original.reserve(source.pixels.size());
        capture.input.reserve(source.pixels.size());
        capture.expected.reserve(source.pixels.size());
        active = &capture;
        const auto captureStart = Clock::now();
        const auto cpu = quantize_srgb16(processor.process(source, recipe));
        const double captureMs = milliseconds(captureStart);
        if (capture.input.empty() || capture.cpuCalls != capture.input.size())
            throw std::runtime_error("此配方未執行彩色負片 unmix，不能當成 GPU 通過");
        Json benchmark;
        if (repeats) {
            std::vector<V> cpuOutput(capture.original.size());
            auto cpuRun = [&] {
                auto start = Clock::now();
                benchmark_cpu_unmix(capture.original, cpuOutput, capture.savedProfile, *capture.database,
                                    capture.savedLight, capture.savedCalibration);
                auto elapsed = milliseconds(start);
                for (std::size_t i = 0; i < cpuOutput.size(); ++i) {
                    auto packed = pack(cpuOutput[i]);
                    if (std::memcmp(&packed, &capture.expected[i], sizeof(packed)))
                        throw std::runtime_error("CPU 量測未重現原始反算結果");
                }
                return elapsed;
            };
            auto gpuRun = [&] {
                auto start = Clock::now();
                auto result = gpu.run(capture.input, capture.parameters);
                auto elapsed = milliseconds(start);
                double error = 0;
                for (std::size_t i = 0; i < result.values.size(); ++i) {
                    auto a = result.values[i], b = capture.expected[i];
                    if (!std::isfinite(a.x) || !std::isfinite(a.y) || !std::isfinite(a.z) || a.w != 1)
                        throw std::runtime_error("GPU 效能量測結果無效");
                    error = std::max({error, std::abs(double(a.x)-b.x), std::abs(double(a.y)-b.y),
                                      std::abs(double(a.z)-b.z)});
                }
                if (error >= 1e-3)
                    throw std::runtime_error("GPU 效能量測分量誤差超標");
                return Json{{"host_wall_ms", elapsed}, {"dispatch_ms", result.gpu_ms},
                            {"dispatches", result.dispatches},
                            {"submit_wait_ms", result.submit_wait_ms}, {"max_component_error", error}};
            };
            benchmark = Json{{"runtime_init_ms", initMs}, {"cpu_capture_pipeline_ms", captureMs},
                             {"first_gpu_run", gpuRun()}, {"cpu_warmup_ms", cpuRun()},
                             {"runs", Json::array()}};
            for (unsigned i = 0; i < repeats; ++i) {
                Json row;
                if (i % 2) {
                    row["gpu"] = gpuRun();
                    row["cpu_ms"] = cpuRun();
                } else {
                    row["cpu_ms"] = cpuRun();
                    row["gpu"] = gpuRun();
                }
                benchmark["runs"].push_back(row);
            }
        }
        // 首次 dispatch 同時覆蓋只有 1／63／65 個元素的非整組邊界。
        double rawMax = 0;
        for (std::size_t length : {std::size_t(1), std::size_t(63), std::size_t(65)}) {
            const auto count = std::min(length, capture.input.size());
            std::vector<Float4> small(capture.input.begin(), capture.input.begin() + count);
            auto trial = gpu.run(small, capture.parameters);
            for (std::size_t i = 0; i < count; ++i) {
                const auto a = trial.values[i], b = capture.expected[i];
                for (float v : {a.x, a.y, a.z, a.w})
                    if (!std::isfinite(v))
                        throw std::runtime_error("GPU Smoke 出現非有限值");
                if (a.w != 1)
                    throw std::runtime_error("GPU 未寫入每個有效元素");
                rawMax = std::max({rawMax, std::abs(double(a.x) - b.x), std::abs(double(a.y) - b.y),
                                   std::abs(double(a.z) - b.z)});
            }
        }
        auto first = gpu.run(capture.input, capture.parameters);
        auto second = gpu.run(capture.input, capture.parameters);
        if (std::memcmp(first.values.data(), second.values.data(), first.values.size() * sizeof(Float4)))
            throw std::runtime_error("GPU 重複執行結果不一致");
        for (std::size_t i = 0; i < first.values.size(); ++i) {
            const auto a = first.values[i], b = capture.expected[i];
            for (float v : {a.x, a.y, a.z, a.w})
                if (!std::isfinite(v))
                    throw std::runtime_error("GPU 結果出現非有限值");
            if (a.w != 1)
                throw std::runtime_error("GPU 結果缺少元素");
            rawMax = std::max({rawMax, std::abs(double(a.x) - b.x), std::abs(double(a.y) - b.y),
                               std::abs(double(a.z) - b.z)});
        }
        if (rawMax >= 1e-3)
            throw std::runtime_error("GPU 反算分量誤差超過 0.001 Smoke 容差");
        capture.gpu = std::move(second.values);
        capture.replay = true;
        const auto callsBefore = capture.cpuCalls;
        const auto replayStart = Clock::now();
        const auto hybrid = quantize_srgb16(processor.process(source, recipe));
        if (repeats)
            benchmark["cpu_replay_pipeline_ms"] = milliseconds(replayStart);
        active = nullptr;
        if (capture.index != capture.input.size() || capture.cpuCalls != callsBefore)
            throw std::runtime_error("GPU 重播漏用結果或退回 CPU");
        double maxDelta = 0, total = 0;
        std::size_t failed = 0;
        for (std::size_t i = 0; i < cpu.pixels.size(); ++i) {
            auto a = cpu.pixels[i], b = hybrid.pixels[i];
            auto delta = verification::delta_e_2000(rgb_to_lab({a.r, a.g, a.b}), rgb_to_lab({b.r, b.g, b.b}));
            if (!std::isfinite(delta))
                throw std::runtime_error("非有限 ΔE");
            maxDelta = std::max(maxDelta, delta);
            total += delta;
            if (delta >= 2)
                ++failed;
        }
        Json report{{"schema", 1},
                    {"scope", "gpu-unmix-cpu-film-development-scanner"},
                    {"passed", failed == 0 && gpu.errors() == 0},
                    {"device", gpu.device_name()},
                    {"shaderFloat64", gpu.float64()},
                    {"gpu_arithmetic", "FP32"},
                    {"synchronization_validation", true},
                    {"unmix_component_tolerance", 0.001},
                    {"gpu_elements", capture.input.size()},
                    {"cpu_fallback_calls_in_replay", capture.cpuCalls - callsBefore},
                    {"dispatch_count", 3 + first.dispatches + second.dispatches},
                    {"guard_and_repeat_checks", true},
                    {"validation_errors", gpu.errors()},
                    {"validation_warnings", gpu.warnings()},
                    {"max_unmix_component_error", rawMax},
                    {"cpu_vs_hybrid_max_delta_e00", maxDelta},
                    {"cpu_vs_hybrid_mean_delta_e00", total / cpu.pixels.size()},
                    {"pixels_at_or_above_2", failed},
                    {"warm_gpu_dispatch_ms", second.gpu_ms},
                    {"warm_submit_wait_ms", second.submit_wait_ms},
                    {"timing_note",
                     "僅 GPU dispatch；不含資料配置／上傳／下載、管線編譯及 CPU 流程，不代表整體加速"}};
        if (repeats) {
            benchmark["scope"] = "CPU 單執行緒 double 反算與 GPU FP32 相同輸入；非整體流程加速；驗證層開啟";
            benchmark["gpu_host_wall_includes"] = "每次配置、映射、上傳複製、同步、dispatch、回讀複製及內部資源釋放；不含輸入擷取、FP32 封裝與結果檢查";
            report["benchmark"] = benchmark;
        }
        if (failed || gpu.errors()) {
            std::cerr << report.dump(2) << '\n';
            return 1;
        }
        write_pfm(output, hybrid);
        std::ofstream sidecar(fs::u8path(output + ".gpu.json"));
        sidecar << report.dump(2) << '\n';
        sidecar.close();
        if (!sidecar)
            throw std::runtime_error("無法寫入 GPU 報告");
        std::cout << report.dump() << '\n';
        return 0;
    } catch (const std::exception &error) {
        photocore::smoke::active = nullptr;
        std::cerr << "Vulkan Smoke 失敗：" << error.what() << '\n';
        return 1;
    }
}
