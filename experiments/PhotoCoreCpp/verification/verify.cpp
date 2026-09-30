#include "photocore/core.hpp"
#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
using namespace photocore;
namespace {
std::size_t checks = 0;
void require(bool ok, const std::string &message) {
    ++checks;
    if (!ok)
        throw std::runtime_error(message);
}
void close(double actual, double expected, const std::string &label, double tolerance = 2e-6) {
    require(std::isfinite(actual) &&
                std::abs(actual - expected) <= tolerance * std::max(1., std::abs(expected)),
            label + " 差異超限");
}
void pixel(Pixel a, Pixel b, const std::string &s) {
    close(a.r, b.r, s);
    close(a.g, b.g, s);
    close(a.b, b.b, s);
    close(a.a, b.a, s);
}
void invariants() {
    Exposure e;
    e.zones = {1, 1, 1};
    pixel(expose({-.1f, .2f, 2, 1}, e), {-.2f, .4f, 4, 1}, "正曝光、負分量與 HDR");
    e.zones = {-1, -1, -1};
    e.protect_highlights = true;
    pixel(expose({.2f, .4f, 2, 1}, e), {.1f, .2f, 1, 1}, "負曝光精確減半");
    e.zones = {1, 1, 1};
    pixel(expose({2, 3, 4, 0}, e), {2, 3, 4, 0}, "透明像素");
    e.protect_highlights = false;
    pixel(expose({.1f, .2f, .3f, .5f}, e), {.2f, .4f, .6f, .5f}, "預乘 alpha");
    e.strength = 0;
    pixel(expose({-.1f, .2f, 2, 1}, e), {-.1f, .2f, 2, 1}, "零強度");
    e.strength = std::numeric_limits<double>::quiet_NaN();
    pixel(expose({.1f, .2f, 2, 1}, e), {.1f, .2f, 2, 1}, "非有限強度");
    for (Vec3 z : {Vec3{-16, 16, -16}, Vec3{16, -16, 16}, Vec3{2, 1, -3}, Vec3{0, 0, 0}}) {
        auto c = exposure_curve(z);
        require(c[1] >= .5 - 1e-9 && c[1] <= 2 + 1e-9 && c[2] >= .5 - 1e-9 && c[2] <= 2 + 1e-9,
                "分區反差斜率界限");
        double prev = -1;
        for (int i = 0; i < 4096; ++i) {
            double y = std::exp2(-24 + i * 30. / 4095) * .18;
            double value = y * std::exp2(zone_ev(y, c));
            require(value >= prev, "分區曲線單調");
            prev = value;
        }
    }
    for (double gain : {1.0001, 2., 32., 65536.}) {
        double previous = -1;
        for (int i = 0; i <= 4096; ++i) {
            double y = i / 4096.;
            double value = protected_peak(y, gain);
            require(value >= previous && value <= 1 + 1e-12, "高光保護單調與白點");
            previous = value;
        }
        close(protected_peak(1, gain), 1, "白點不變");
    }
    pixel(map_raw_highlights({.1f, .2f, .7f, 1}), {.1f, .2f, .7f, 1}, "RAW 暗部不變");
    auto m = map_raw_highlights({-.2f, .4f, 4, 1});
    require(m.r < 0 && m.b > .99 && m.b <= 1, "RAW 映射保留負分量");
    Calibration c;
    pixel(calibrate({.2f, .4f, 2, .5f}, c), {.2f, .4f, 2, .5f}, "校準 identity");
    c.rows[0][3] = .1;
    auto a = calibrate({.2f, .3f, .4f, 1}, c), b = calibrate({.4f, .6f, .8f, 1}, c);
    close(b.r, 2 * a.r, "校準曝光同次性");
    pixel(calibrate({-.1f, .3f, .4f, 1}, c), {-.1f, .3f, .4f, 1}, "校準略過負分量");
    c.rows[0][0] = 17;
    bool rejected = false;
    try {
        validate(c);
    } catch (const std::invalid_argument &) {
        rejected = true;
    }
    require(rejected, "非法校準拒絕");
    Image source(2, 2);
    source.pixels = {{-.1f, .3f, 4, 1}, {.2f, .4f, .6f, 1}, {.7f, .8f, .9f, 1}, {1, 2, 3, 1}};
    auto temp = std::filesystem::temp_directory_path() / "photocore-驗證.pfm";
    write_pfm(temp.u8string(), source);
    auto roundtrip = read_pfm(temp.u8string());
    for (std::size_t i = 0; i < 4; ++i)
        pixel(roundtrip.pixels[i], source.pixels[i], "PFM 順序／Float32 往返");
    {
        std::ofstream f(temp, std::ios::binary);
        f << "PF\n2000000000 2000000000\n-1\n";
    }
    rejected = false;
    try {
        read_pfm(temp.u8string());
    } catch (const std::exception &) {
        rejected = true;
    }
    require(rejected, "截斷／超大檔案在配置前拒絕");
    {
        std::ofstream f(temp, std::ios::binary);
        f << "PF\n1 1\n2\n";
        unsigned char bytes[]{0x3f, 0x80, 0, 0, 0x40, 0, 0, 0, 0x40, 0x40, 0, 0};
        f.write(reinterpret_cast<char *>(bytes), 12);
    }
    pixel(read_pfm(temp.u8string()).pixels[0], {2, 4, 6, 1}, "大端序與 scale");
    std::filesystem::remove(temp);
    e.strength = 1;
    e.zones = {1, 1, 1};
    auto out = apply_exposure(source, e);
    require(source.pixels[0].r == -.1f, "處理不改寫輸入");
    pixel(out.pixels[0], {-.2f, .6f, 8, 1}, "整張影像處理");
}
void reference(const char *path) {
    std::ifstream input(std::filesystem::u8path(path));
    if (!input)
        throw std::runtime_error("無法讀取 Swift 參考資料");
    std::string line;
    std::size_t rows = 0;
    while (std::getline(input, line)) {
        if (line.empty() || line[0] == '#')
            continue;
        std::istringstream s(line);
        std::string op;
        s >> op;
        auto number = [&]() {
            double v;
            if (!(s >> v))
                throw std::runtime_error("參考資料格式錯誤");
            return v;
        };
        if (op == "curve") {
            Vec3 z;
            for (auto &x : z)
                x = number();
            auto c = exposure_curve(z);
            for (double x : c)
                close(x, number(), op, 1e-10);
        } else if (op == "zone") {
            double y = number();
            Vec3 c;
            for (auto &x : c)
                x = number();
            close(zone_ev(y, c), number(), op, 1e-10);
        } else if (op == "peak") {
            double y = number(), g = number();
            close(protected_peak(y, g), number(), op, 1e-10);
        } else if (op == "lab") {
            Vec3 rgb;
            for (auto &x : rgb)
                x = number();
            for (double x : rgb_to_lab(rgb))
                close(x, number(), op, 1e-10);
        } else if (op == "slider") {
            double v = number();
            close(slider_to_ev(v), number(), op, 1e-12);
        } else if (op == "exposure" || op == "gpu" || op == "raw" || op == "calibration") {
            Pixel p;
            p.r = float(number());
            p.g = float(number());
            p.b = float(number());
            p.a = float(number());
            Pixel result;
            if (op == "exposure" || op == "gpu") {
                Exposure e;
                for (auto &z : e.zones)
                    z = number();
                e.global_ev = number();
                e.strength = number();
                e.protect_highlights = number() != 0;
                e.protect_peak = number() != 0;
                result = expose(p, e);
            } else if (op == "raw")
                result = map_raw_highlights(p);
            else {
                Calibration c;
                for (auto &row : c.rows)
                    for (auto &v : row)
                        v = number();
                result = calibrate(p, c);
            }
            const double tol = (op == "gpu" || op == "raw" || op == "calibration") ? 3e-5 : 2e-6;
            for (double v : {result.r, result.g, result.b, result.a})
                close(v, number(), op, tol);
        } else
            throw std::runtime_error("未知參考運算：" + op);
        std::string extra;
        require(!(s >> extra), "參考資料尾端不可有多餘欄位");
        ++rows;
    }
    require(rows > 1000, "參考資料筆數不足");
    std::cout << "Swift／Core Image 參考比對：" << rows << " 筆通過\n";
}
} // namespace
int main(int argc, char **argv) {
    try {
        invariants();
        if (argc == 2)
            reference(argv[1]);
        else if (argc != 1)
            throw std::invalid_argument("用法：photo_core_verify [swift-reference.txt]");
        std::cout << "PASS：" << checks << " 項檢查\n";
    } catch (const std::exception &e) {
        std::cerr << "FAIL：" << e.what() << '\n';
        return 1;
    }
    return 0;
}
