#include "photocore/core.hpp"
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

int application_main(int argc, char **argv) {
    try {
        std::string input, output, preview, calibration;
        bool generate = false, mapping = false;
        photocore::Exposure exposure;
        auto number = [](const std::string &s) {
            std::size_t used = 0;
            double n = std::stod(s, &used);
            if (used != s.size() || !std::isfinite(n))
                throw std::invalid_argument("參數須為有限數值");
            return n;
        };
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            auto value = [&]() {
                if (++i >= argc)
                    throw std::invalid_argument("選項缺少值：" + arg);
                return std::string(argv[i]);
            };
            if (arg == "--help") {
                std::cout << "PhotoCore C++ 獨立演算法測試\n"
                             "photo_core_test (--input linear.pfm | --generate) --output result.pfm\n"
                             "  [--ev N] [--zones 亮部EV 中調EV 暗部EV] [--strength 0..1]\n"
                             "  [--protect-highlights | --protect-peak] [--raw-map]\n"
                             "  [--calibration coefficients.txt] [--preview view.ppm]\n"
                             "--ev 設定全區絕對 EV；--zones 覆寫區域，選項依輸入順序生效。\n"
                             "處理順序：輸入色彩校準 → 曝光 → 選用 RAW 高光映射。\n"
                             "PFM 保留線性浮點；PPM 為裁至 SDR 的 sRGB 檢視檔。\n";
                return 0;
            } else if (arg == "--input")
                input = value();
            else if (arg == "--output")
                output = value();
            else if (arg == "--preview")
                preview = value();
            else if (arg == "--calibration")
                calibration = value();
            else if (arg == "--generate")
                generate = true;
            else if (arg == "--raw-map")
                mapping = true;
            else if (arg == "--ev") {
                double n = number(value());
                exposure.zones = {n, n, n};
                exposure.global_ev = n;
            } else if (arg == "--zones")
                for (auto &z : exposure.zones)
                    z = number(value());
            else if (arg == "--strength")
                exposure.strength = number(value());
            else if (arg == "--protect-highlights")
                exposure.protect_highlights = true;
            else if (arg == "--protect-peak") {
                exposure.protect_highlights = true;
                exposure.protect_peak = true;
            } else
                throw std::invalid_argument("未知選項：" + arg);
        }
        if (output.empty() || generate == !input.empty())
            throw std::invalid_argument("請指定輸出，並擇一使用 --input 或 --generate；詳見 --help");
        auto same = [](const std::string &a, const std::string &b) {
            if (a.empty() || b.empty())
                return false;
            return std::filesystem::weakly_canonical(std::filesystem::u8path(a)) ==
                   std::filesystem::weakly_canonical(std::filesystem::u8path(b));
        };
        if (same(input, output) || same(input, preview) || same(output, preview) ||
            same(calibration, output) || same(calibration, preview))
            throw std::invalid_argument("輸入與輸出路徑不可相同");
        auto image = generate ? photocore::Image(768, 256) : photocore::read_pfm(input);
        if (generate)
            for (std::size_t y = 0; y < image.height; ++y)
                for (std::size_t x = 0; x < image.width; ++x) {
                    float v = float(std::exp2(-12 + 16 * double(x) / (image.width - 1)) * .18);
                    image.pixels[y * image.width + x] =
                        y < 128 ? photocore::Pixel{v, v, v, 1} : photocore::Pixel{v, v * .5f, v * .2f, 1};
                }
        const auto start = std::chrono::steady_clock::now();
        if (!calibration.empty()) {
            photocore::Calibration c;
            std::ifstream file(std::filesystem::u8path(calibration));
            for (auto &row : c.rows)
                for (auto &v : row)
                    if (!(file >> v))
                        throw std::invalid_argument("校準檔須為 18 個係數（3×6）");
            std::string extra;
            if (file >> extra)
                throw std::invalid_argument("校準檔包含多餘資料");
            image = photocore::apply_calibration(image, c);
        }
        image = photocore::apply_exposure(image, exposure);
        if (mapping)
            image = photocore::apply_raw_mapping(image);
        const double ms =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        photocore::write_pfm(output, image);
        if (!preview.empty())
            photocore::write_preview_ppm(preview, image);
        std::cout << "完成 " << image.width << " × " << image.height << "，核心處理 " << ms << " ms\n";
    } catch (const std::exception &e) {
        std::cerr << "錯誤：" << e.what() << '\n';
        return 1;
    }
    return 0;
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
