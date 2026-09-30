#include "photocore/film.hpp"
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>

int application_main(int argc, char **argv) {
    try {
        std::string input, recipe, output, data, dump;
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            auto value = [&]() {
                if (++i >= argc)
                    throw std::invalid_argument("選項缺少值：" + arg);
                return std::string(argv[i]);
            };
            if (arg == "--input")
                input = value();
            else if (arg == "--recipe")
                recipe = value();
            else if (arg == "--output")
                output = value();
            else if (arg == "--data")
                data = value();
            else if (arg == "--dump-stages")
                dump = value();
            else if (arg == "--help") {
                std::cout << "獨立 CPU 底片／顯影／掃描測試（尚非 App 全流程）\n"
                             "photo_core_film --input linear.pfm --recipe film.json --output final.pfm\n"
                             "  [--data film-data資料夾] [--dump-stages 診斷資料夾]\n";
                return 0;
            } else
                throw std::invalid_argument("未知選項：" + arg);
        }
        if (input.empty() || recipe.empty() || output.empty())
            throw std::invalid_argument("必須指定 input／recipe／output");
        namespace fs = std::filesystem;
        auto canonical = [](const std::string &s) { return fs::weakly_canonical(fs::u8path(s)); };
        if (data.empty())
            data = (fs::absolute(fs::u8path(argv[0])).parent_path() / "film-data").u8string();
        const auto target = canonical(output);
        if (target == canonical(input) || target == canonical(recipe) ||
            target == canonical(data + "/film-profiles.json") ||
            target == canonical(data + "/spectral-table.f32"))
            throw std::invalid_argument("輸出不可覆寫來源、配方或光譜資料");
        if (!dump.empty()) {
            if (fs::exists(fs::u8path(dump)))
                throw std::invalid_argument("診斷目錄已存在；請使用新目錄避免覆寫");
            fs::create_directories(fs::u8path(dump));
        }
        photocore::FilmProcessor processor(data);
        std::function<void(const std::string &, const photocore::Image &)> trace;
        if (!dump.empty())
            trace = [&](const std::string &stage, const photocore::Image &image) {
                photocore::write_pfm((fs::u8path(dump) / (stage + ".pfm")).u8string(), image);
            };
        auto image = processor.process(photocore::read_pfm(input), recipe, trace);
        photocore::write_pfm(output, photocore::quantize_srgb16(std::move(image)));
        std::cout << "已完成 CPU 顯影 → 藥水 → 光譜底片 → 片種風格 → 掃描 → sRGB16 成品\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "底片處理失敗：" << e.what() << '\n';
        return 1;
    }
}
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
int wmain(int argc, wchar_t **argv) {
    std::vector<std::string> strings;
    for (int i = 0; i < argc; ++i) {
        int size =
            WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, nullptr, 0, nullptr, nullptr);
        if (size == 0)
            return 1;
        std::string value(static_cast<std::size_t>(size), '\0');
        if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, argv[i], -1, value.data(), size, nullptr,
                                 nullptr))
            return 1;
        value.pop_back();
        strings.push_back(std::move(value));
    }
    std::vector<char *> args;
    for (auto &s : strings)
        args.push_back(s.data());
    SetConsoleOutputCP(CP_UTF8);
    return application_main(argc, args.data());
}
#else
int main(int argc, char **argv) {
    return application_main(argc, argv);
}
#endif
