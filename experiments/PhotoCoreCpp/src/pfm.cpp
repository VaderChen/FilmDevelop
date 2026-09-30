#include "photocore/core.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>

namespace photocore {
namespace {
std::string line(std::istream &in) {
    std::string s;
    while (std::getline(in, s)) {
        if (!s.empty() && s.back() == '\r')
            s.pop_back();
        if (!s.empty() && s[0] != '#')
            return s;
    }
    throw std::runtime_error("PFM 標頭不完整");
}
float decode(const unsigned char *b, bool little) {
    std::uint32_t bits = 0;
    for (int i = 0; i < 4; ++i)
        bits |= std::uint32_t(b[i]) << ((little ? i : 3 - i) * 8);
    float v;
    std::memcpy(&v, &bits, 4);
    return v;
}
void encode(unsigned char *bytes, float v) {
    std::uint32_t bits;
    std::memcpy(&bits, &v, 4);
    for (int i = 0; i < 4; ++i)
        bytes[i] = static_cast<unsigned char>(bits >> (i * 8));
}
void opaque(const Image &im) {
    if (!im.width || !im.height || im.width > std::numeric_limits<std::size_t>::max() / im.height ||
        im.pixels.size() != im.width * im.height)
        throw std::invalid_argument("影像資料尺寸不符");
    for (auto p : im.pixels)
        if (p.a != 1 || !std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
            throw std::invalid_argument("RGB 檔案僅接受不透明且有限的像素");
}
} // namespace
Image read_pfm(const std::string &path) {
    std::ifstream in(std::filesystem::u8path(path), std::ios::binary);
    if (!in)
        throw std::runtime_error("無法開啟輸入 PFM");
    if (line(in) != "PF")
        throw std::runtime_error("僅支援 RGB PFM（PF）");
    std::size_t w = 0, h = 0;
    std::string extra;
    std::istringstream dims(line(in));
    if (!(dims >> w >> h) || (dims >> extra) || !w || !h ||
        w > std::numeric_limits<std::size_t>::max() / h / 12)
        throw std::runtime_error("PFM 尺寸無效");
    double scale = 0;
    std::istringstream scales(line(in));
    if (!(scales >> scale) || (scales >> extra) || !std::isfinite(scale) || scale == 0)
        throw std::runtime_error("PFM scale 無效");
    const auto start = in.tellg();
    in.seekg(0, std::ios::end);
    auto end = in.tellg();
    if (start < 0 || end < start || std::uintmax_t(end - start) != std::uintmax_t(w) * h * 12)
        throw std::runtime_error("PFM 資料長度不符");
    in.seekg(start);
    Image image(w, h);
    std::vector<unsigned char> rowBytes(w * 12);
    for (std::size_t row = 0; row < h; ++row) {
        if (!in.read(reinterpret_cast<char *>(rowBytes.data()), std::streamsize(rowBytes.size())))
            throw std::runtime_error("PFM 像素不完整");
        for (std::size_t x = 0; x < w; ++x) {
            const auto *bytes = rowBytes.data() + x * 12;
            Pixel p{float(decode(bytes, scale < 0) * std::abs(scale)),
                    float(decode(bytes + 4, scale < 0) * std::abs(scale)),
                    float(decode(bytes + 8, scale < 0) * std::abs(scale)), 1};
            if (!std::isfinite(p.r) || !std::isfinite(p.g) || !std::isfinite(p.b))
                throw std::runtime_error("PFM 包含非有限像素");
            image.pixels[(h - 1 - row) * w + x] = p;
        }
    }
    return image;
}
void write_pfm(const std::string &path, const Image &im) {
    static_assert(sizeof(float) == 4 && std::numeric_limits<float>::is_iec559, "需要 IEEE754 Float32");
    opaque(im);
    std::ofstream out(std::filesystem::u8path(path), std::ios::binary);
    if (!out)
        throw std::runtime_error("無法建立輸出 PFM");
    out << "PF\n" << im.width << ' ' << im.height << "\n-1.0\n";
    std::vector<unsigned char> rowBytes(im.width * 12);
    for (std::size_t row = 0; row < im.height; ++row) {
        for (std::size_t x = 0; x < im.width; ++x) {
            auto p = im.pixels[(im.height - 1 - row) * im.width + x];
            encode(rowBytes.data() + x * 12, p.r);
            encode(rowBytes.data() + x * 12 + 4, p.g);
            encode(rowBytes.data() + x * 12 + 8, p.b);
        }
        out.write(reinterpret_cast<const char *>(rowBytes.data()), std::streamsize(rowBytes.size()));
    }
    out.close();
    if (!out)
        throw std::runtime_error("PFM 寫入失敗");
}
void write_preview_ppm(const std::string &path, const Image &im) {
    opaque(im);
    std::ofstream out(std::filesystem::u8path(path), std::ios::binary);
    if (!out)
        throw std::runtime_error("無法建立預覽 PPM");
    out << "P6\n" << im.width << ' ' << im.height << "\n255\n";
    auto srgb = [](float v) {
        double x = std::clamp(double(v), 0., 1.);
        return static_cast<unsigned char>(
            std::lround(255 * (x <= .0031308 ? 12.92 * x : 1.055 * std::pow(x, 1 / 2.4) - .055)));
    };
    for (auto p : im.pixels) {
        const unsigned char b[]{srgb(p.r), srgb(p.g), srgb(p.b)};
        out.write(reinterpret_cast<const char *>(b), 3);
    }
    out.close();
    if (!out)
        throw std::runtime_error("PPM 寫入失敗");
}
} // namespace photocore
