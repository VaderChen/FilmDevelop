#include "film_internal.hpp"

namespace photocore::film_cpu {
V grade(V rgb, double saturation, double mid_warmth, double high_warmth, const std::vector<double> &style,
        bool mono) {
    const double sourceY = std::max(0., dot(rgb, w));
    double y = sourceY;
    if (style[1] != 1 || style[2] != 0) {
        if (sourceY > 0 && sourceY < 1) {
            const double z =
                style[1] * (std::log(sourceY / (1 - sourceY)) - std::log(.18 / .82)) + std::log(.18 / .82);
            y = 1 / (1 + std::exp(-z));
        }
        y = style[2] + (1 - style[2]) * y;
    }
    rgb = sourceY > 1e-12 ? rgb * (y / sourceY) : V(y);
    if (mono)
        return V(y);
    rgb = fit_chroma(V(y) + (rgb - y) * saturation * style[0], y);
    const double mid = smooth(.02, .18, y) * (1 - smooth(.3, .65, y));
    const double high = smooth(.25, .7, y) * (1 - smooth(.85, 1, y));
    const double warmth = mid_warmth * mid + high_warmth * high;
    rgb *= exp(V(.35, .10, -.4) * warmth * std::log(2.));
    return fit_chroma(rgb * (y / std::max(1e-12, dot(rgb, w))), y);
}
Image scanner(Image source, const Effects &e, const Database &data, bool monochrome) {
    std::string profile = e.text("scanner_profile", "off");
    if (profile == "off")
        return source;
    const auto &style = data.scanner_styles.at(profile);
    const double saturation = e.get("scan_saturation", 50) / 50;
    const double mid = (e.get("scan_midtone_warmth", 0, -100, 100) + style[4]) / 100;
    const double high = (e.get("scan_highlight_warmth", 0, -100, 100) + style[5]) / 100;
    const double flare = std::pow(e.get("scan_flare") / 100, 2) * .005;
    return transform_owned(std::move(source), [&](Pixel p, std::size_t, std::size_t) {
        V rgb = (film_cpu::rgb(p) / std::max(double(p.a), 1e-6) + flare) / (1 + flare);
        rgb = grade(rgb, saturation, mid, high, style, false);
        if (monochrome)
            rgb = V(dot(rgb, w));
        return pixel(rgb * p.a, p.a);
    });
}
Image character(Image source, const Profile &p) {
    if (p.character.empty())
        return source;
    if (p.character.size() != 6)
        throw std::runtime_error("底片風格參數長度不符");
    const auto &r = p.character;
    return transform_owned(std::move(source), [&](Pixel px, std::size_t, std::size_t) {
        if (px.a <= 0)
            return Pixel{0, 0, 0, 0};
        V color = max(straight(px), 0);
        double before = dot(color, w), y = before;
        if (y > 0 && y < 1 && r[0] != 1) {
            const double z = r[0] * (std::log(y / (1 - y)) - std::log(.18 / .82)) + std::log(.18 / .82);
            y = 1 / (1 + std::exp(-std::clamp(z, -80., 80.)));
        }
        color = before > 1e-12 ? color * (y / before) : V(y);
        if (p.mono)
            return pixel(V(y) * px.a, px.a);
        const double warm = smooth(-.25, .25, (color.x - color.z) / std::max(.02, y));
        color = fit_chroma(V(y) + (color - y) * (r[3] + (r[2] - r[3]) * warm), y);
        const double shadows = smooth(0, .012, y) * (1 - smooth(.025, .18, y));
        const double highlights = smooth(.25, .70, y) * (1 - smooth(.85, 1, y));
        const double mid = smooth(.025, .18, y) * (1 - smooth(.3, .65, y));
        const double warmth = r[4] * shadows + r[5] * highlights + r[1] * mid;
        color *= exp(V(.35, .10, -.4) * warmth * std::log(2.));
        color *= y / std::max(1e-12, dot(color, w));
        return pixel(fit_chroma(color, y) * px.a, px.a);
    });
}
} // namespace photocore::film_cpu
