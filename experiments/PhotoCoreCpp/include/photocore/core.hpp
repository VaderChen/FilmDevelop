#pragma once
#include <array>
#include <cstddef>
#include <string>
#include <vector>

namespace photocore {
// 核心固定採 extended-linear sRGB、Float32、預乘 alpha；不裁掉負值或 HDR。
struct Pixel {
    float r = 0, g = 0, b = 0, a = 1;
};
struct Image {
    std::size_t width = 0, height = 0;
    std::vector<Pixel> pixels;
    Image(std::size_t width, std::size_t height);
};
using Vec3 = std::array<double, 3>;
struct Exposure {
    // 與 Swift 相同：區域依序為亮部／中調／暗部的絕對 EV。
    Vec3 zones{0, 0, 0};
    double global_ev = 0;
    double strength = 1;
    bool protect_highlights = false;
    bool protect_peak = false;
};
struct Calibration {
    std::array<std::array<double, 6>, 3> rows{
        {{{1, 0, 0, 0, 0, 0}}, {{0, 1, 0, 0, 0, 0}}, {{0, 0, 1, 0, 0, 0}}}};
};
double slider_to_ev(double value);
double ev_to_slider(double value);
Vec3 exposure_curve(Vec3 zones);
double zone_ev(double luminance, Vec3 curve);
double protected_peak(double value, double gain);
Vec3 rgb_to_lab(Vec3 rgb);
Pixel expose(Pixel pixel, const Exposure &settings);
Pixel map_raw_highlights(Pixel pixel);
Pixel calibrate(Pixel pixel, const Calibration &settings);
void validate(const Calibration &settings);
// 一次準備曲線；迭代影像時不重複求解約束。
Image apply_exposure(const Image &input, const Exposure &settings);
Image apply_exposure(Image &&input, const Exposure &settings);
Image apply_raw_mapping(const Image &input);
Image apply_calibration(const Image &input, const Calibration &settings);
// PFM 是測試交換格式：linear sRGB、RGB 浮點、左上原點，檔案依 PFM 底列先存。
// PFM 沒有 alpha；輸出非不透明影像時明確拒絕。
Image read_pfm(const std::string &path);
void write_pfm(const std::string &path, const Image &image);
void write_preview_ppm(const std::string &path, const Image &image);
} // namespace photocore
