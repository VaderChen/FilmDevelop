#include "pipeline.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
int main(int argc, char **argv) {
    using namespace photocore;
    namespace fs = std::filesystem;
    using film_cpu::Json;
    try {
        std::string input, recipe, output, data, shader, dump;
        for (int i = 1; i < argc; ++i) {
            std::string key = argv[i];
            if (key == "--help") {
                std::cout << "獨立 Vulkan 底片／顯影／掃描，GPU 常駐中間影像\n--input linear.pfm --recipe "
                             "film.json --output final.pfm [--data 目錄] [--shader SPIR-V] [--dump-stages "
                             "新目錄]\n";
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
            else if (key == "--dump-stages")
                dump = value;
            else
                throw std::invalid_argument("未知選項：" + key);
        }
        if (input.empty() || recipe.empty() || output.empty())
            throw std::invalid_argument("需要 input／recipe／output");
        auto folder = fs::absolute(fs::u8path(argv[0])).parent_path();
        if (data.empty())
            data = (folder / "film-data").u8string();
        if (shader.empty())
            shader = (folder / "film.comp.spv").u8string();
        auto canonical = [](const std::string &s) { return fs::weakly_canonical(fs::u8path(s)); };
        auto target = canonical(output), sidecar = canonical(output + ".vk.json");
        for (auto path : {input, recipe, shader, data + "/film-profiles.json", data + "/spectral-table.f32"})
            if (target == canonical(path) || sidecar == canonical(path))
                throw std::invalid_argument("輸出不可覆寫來源／配方／資料");
        if (!dump.empty()) {
            if (fs::exists(fs::u8path(dump)))
                throw std::invalid_argument("診斷目錄已存在");
            fs::create_directories(fs::u8path(dump));
        }
        auto begin = std::chrono::steady_clock::now();
        vk::Pipeline pipeline(data, shader);
        double init =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
        auto source = read_pfm(input);
        auto w = source.width, h = source.height;
        begin = std::chrono::steady_clock::now();
        auto image = pipeline.process(std::move(source), recipe, dump);
        double process =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
        if (pipeline.context.errors())
            throw std::runtime_error("Vulkan 驗證失敗");
        write_pfm(output, image);
        Json stats = Json::array();
        for (const auto &s : pipeline.context.stats)
            stats.push_back({{"stage", s.label},
                             {"host_ms", s.host_ms},
                             {"gpu_ms", s.gpu_ms},
                             {"dispatches", s.dispatches}});
        Json report{{"schema", 1},
                    {"scope", "vulkan-film-development-scanner"},
                    {"device", pipeline.context.device_name()},
                    {"passed", true},
                    {"gpu_arithmetic", "FP32"},
                    {"validation_errors", pipeline.context.errors()},
                    {"validation_warnings", pipeline.context.warnings()},
                    {"synchronization_validation", true},
                    {"cpu_pixel_fallbacks", 0},
                    {"width", w},
                    {"height", h},
                    {"init_ms", init},
                    {"process_ms", process},
                    {"peak_vulkan_buffer_bytes", pipeline.context.peak_buffer_bytes()},
                    {"stages", stats},
                    {"note", "CPU 僅負責 I/O、配方驗證、係數與小型 LUT 準備；GPU "
                             "逐像素與鄰域運算。此報告不單獨代表 ΔE 通過。"}};
        std::ofstream side(fs::u8path(output + ".vk.json"));
        side << report.dump(2) << '\n';
        side.close();
        if (!side)
            throw std::runtime_error("無法寫入 GPU 報告");
        std::cout << report.dump() << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "Vulkan 流程失敗：" << e.what() << '\n';
        return 1;
    }
}
