#include "delta_e.hpp"
#include <cmath>
#include <stdexcept>

namespace photocore::verification {
namespace {
constexpr double pi = 3.1415926535897932384626433832795;
double radians(double degrees) {
    return degrees * pi / 180;
}
double chroma_ratio(double c) {
    // 寫成比例避免 C^7 的不必要溢位。
    if (c == 0)
        return 0;
    return 1 / (1 + std::pow(25 / c, 7));
}
double hue(double a, double b) {
    if (a == 0 && b == 0)
        return 0;
    const double h = std::atan2(b, a) * 180 / pi;
    return h < 0 ? h + 360 : h;
}
} // namespace
double delta_e_2000(Vec3 first, Vec3 second) {
    for (auto lab : {first, second})
        for (auto v : lab)
            if (!std::isfinite(v))
                throw std::invalid_argument("Lab 必須是有限數值");
    const double c1 = std::hypot(first[1], first[2]), c2 = std::hypot(second[1], second[2]);
    const double g = 0.5 * (1 - std::sqrt(chroma_ratio((c1 + c2) / 2)));
    const double a1 = first[1] * (1 + g), a2 = second[1] * (1 + g);
    const double cp1 = std::hypot(a1, first[2]), cp2 = std::hypot(a2, second[2]);
    const double h1 = hue(a1, first[2]), h2 = hue(a2, second[2]);
    const double dl = second[0] - first[0], dc = cp2 - cp1;
    double dh = h2 - h1;
    if (cp1 * cp2 == 0)
        dh = 0;
    else if (dh > 180)
        dh -= 360;
    else if (dh < -180)
        dh += 360;
    const double dH = 2 * std::sqrt(cp1 * cp2) * std::sin(radians(dh / 2));
    const double lb = (first[0] + second[0]) / 2, cb = (cp1 + cp2) / 2;
    double hb = (h1 + h2) / 2;
    if (cp1 * cp2 == 0)
        hb = h1 + h2;
    else if (std::abs(h1 - h2) > 180)
        hb += h1 + h2 < 360 ? 180 : -180;
    const double t = 1 - .17 * std::cos(radians(hb - 30)) + .24 * std::cos(radians(2 * hb)) +
                     .32 * std::cos(radians(3 * hb + 6)) - .20 * std::cos(radians(4 * hb - 63));
    const double l50sq = (lb - 50) * (lb - 50);
    const double sl = 1 + .015 * l50sq / std::sqrt(20 + l50sq);
    const double sc = 1 + .045 * cb, sh = 1 + .015 * cb * t;
    const double theta = 30 * std::exp(-std::pow((hb - 275) / 25, 2));
    const double rt = -2 * std::sqrt(chroma_ratio(cb)) * std::sin(radians(2 * theta));
    const double l = dl / sl, c = dc / sc, h = dH / sh;
    return std::sqrt(l * l + c * c + h * h + rt * c * h);
}
} // namespace photocore::verification
