#include "delta_e.hpp"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <stdexcept>

using namespace photocore;
using verification::delta_e_2000;
namespace {
void require(bool ok, const char *message) {
    if (!ok)
        throw std::runtime_error(message);
}
void self_test(const std::string &path) {
    std::ifstream file(std::filesystem::u8path(path));
    require(bool(file), "無法開啟 CIEDE2000 標準資料");
    Vec3 a{}, b{};
    double expected, largest = 0;
    unsigned count = 0;
    while (file >> a[0] >> a[1] >> a[2] >> b[0] >> b[1] >> b[2] >> expected) {
        const double result = delta_e_2000(a, b);
        largest = std::max(largest, std::abs(result - expected));
        require(std::abs(result - expected) <= 0.00005, "CIEDE2000 公開標準值不符");
        require(std::abs(result - delta_e_2000(b, a)) < 1e-12, "CIEDE2000 對稱性失敗");
        require(delta_e_2000(a, a) == 0, "相同 Lab 的色差必須為零");
        ++count;
    }
    require(count == 34 && file.eof(), "CIEDE2000 資料必須完整包含 34 筆");
    std::cout << "CIEDE2000：34 筆公開標準值通過，最大絕對誤差 " << largest << '\n';
}
int compare(const std::string &reference, const std::string &candidate) {
    auto a = read_pfm(reference), b = read_pfm(candidate);
    require(a.width == b.width && a.height == b.height, "最終成品尺寸不一致，禁止重採樣掩蓋誤差");
    std::vector<double> differences;
    differences.reserve(a.pixels.size());
    std::size_t failed = 0, worst = 0;
    double maximum = -1;
    for (std::size_t i = 0; i < a.pixels.size(); ++i) {
        const auto p = a.pixels[i], q = b.pixels[i];
        // 此驗收契約為匯出後的 SDR sRGB；拒絕錯誤的 HDR／中間結果，不在比較器裁色。
        for (float c : {p.r, p.g, p.b, q.r, q.g, q.b})
            require(std::isfinite(c) && c >= -1e-6f && c <= 1.000001f, "須輸入匯出後 SDR 線性 sRGB 成品");
        const double de = delta_e_2000(rgb_to_lab({p.r, p.g, p.b}), rgb_to_lab({q.r, q.g, q.b}));
        require(std::isfinite(de), "色差非有限值");
        differences.push_back(de);
        if (de >= 2)
            ++failed;
        if (de > maximum) {
            maximum = de;
            worst = i;
        }
    }
    const double mean = std::accumulate(differences.begin(), differences.end(), 0.0) / differences.size();
    std::sort(differences.begin(), differences.end());
    auto percentile = [&](double fraction) {
        return differences[std::size_t(std::ceil(fraction * differences.size())) - 1];
    };
    std::cout << std::setprecision(12)
              << "{\"metric\":\"CIEDE2000\",\"threshold\":2,\"passed\":" << (failed == 0 ? "true" : "false")
              << ",\"pixels\":" << differences.size() << ",\"mean\":" << mean
              << ",\"p95\":" << percentile(.95) << ",\"p99\":" << percentile(.99) << ",\"max\":" << maximum
              << ",\"pixels_at_or_above_2\":" << failed << ",\"worst_x\":" << worst % a.width
              << ",\"worst_y\":" << worst / a.width << "}\n";
    return failed == 0 ? 0 : 1;
}
} // namespace
int application_main(int argc, char **argv) {
    try {
        if (argc == 3 && std::string(argv[1]) == "--self-test") {
            self_test(argv[2]);
            return 0;
        }
        if (argc == 3)
            return compare(argv[1], argv[2]);
        std::cerr << "用法：photo_core_compare Swift最終.pfm C++最終.pfm\n"
                     "      photo_core_compare --self-test ciede2000.txt\n";
        return 2;
    } catch (const std::exception &e) {
        std::cerr << "比較失敗：" << e.what() << '\n';
        return 2;
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
