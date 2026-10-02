#pragma once
#include "film_internal.hpp"

namespace photocore::film_cpu {
// 與 Swift PhotoEmulsionExposureProcessor 共用的物理座標及取樣規則。
inline double light_threshold(double value) {
    value = std::clamp(value, 0., 100.) / 100;
    return value <= .04045 ? value / 12.92 : std::pow((value + .055) / 1.055, 2.4);
}
struct EmulsionSettings {
    double size, clumping, chroma, spread, pitch, scale, halo, threshold, base, sigma;
    std::size_t width, height;
    V amounts;
    bool active;
    EmulsionSettings(std::size_t w, std::size_t h, const Effects &e, const Json &a,
                     double strength, bool mono, bool preview) {
        size = e.get("grain_size", 1, .5, 4) * 36 / e.get("film_width_mm", 36, 8, 120);
        clumping = e.get("grain_clumping") / 100;
        chroma = mono ? 0 : e.get("grain_chroma") / 100;
        spread = e.get("grain_distribution") / 100;
        double grain = number(a, "grain", 0, 0, 100) / 100 * strength;
        amounts = V(std::max(grain, number(a, "shadowGrain", 0, 0, 100) / 100 * strength),
                    std::max(grain * .75, number(a, "midtoneGrain", 0, 0, 100) / 100 * strength),
                    std::max(grain * .45, number(a, "highlightGrain", 0, 0, 100) / 100 * strength));
        halo = strength * std::sqrt(e.get("halation_amount") / 100);
        active = e.text("grain_mode", "emulsion") == "emulsion" &&
                 (halo > 0 || amounts.x > 0 || amounts.y > 0 || amounts.z > 0);
        const double smallest = spread > .0001 ? std::exp(-spread) / std::sqrt(std::sinh(2 * spread) / (2 * spread)) : 1;
        const double floor = std::min(3000., std::ceil(2000 / (size * smallest)));
        const double longEdge = double(std::max(w, h));
        const double field = preview ? std::min(3000., std::max(longEdge, floor)) : 3000;
        pitch = 3000 / field;
        scale = longEdge / field;
        width = std::size_t(std::ceil(w / scale));
        height = std::size_t(std::ceil(h / scale));
        threshold = light_threshold(e.get("halation_threshold", 75));
        base = e.get("halation_base", 50) / 100;
        sigma = field * e.get("halation_radius", .1, .01, .3) / 100 * 36 / e.get("film_width_mm", 36, 8, 120);
    }
    double absorption() const {
        const double mu = 1.2 * 2.598076211 * (.25 * .25 + .25 * .35 + .35 * .35) / 3;
        V tau = mix(V(.70), V(.25, .5, 1.35), chroma);
        V exponent = (exp(-tau) - 1) * mu, delta = exponent * (.25 * clumping);
        V correction = V(1) + delta * delta / 6 + delta * delta * delta * delta / 120;
        return 1 - std::exp(exponent.x + exponent.y + exponent.z) * correction.x * correction.y * correction.z;
    }
};
} // namespace photocore::film_cpu
