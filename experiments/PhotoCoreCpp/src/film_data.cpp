#include "film_internal.hpp"
#include <cstring>
#include <filesystem>
#include <fstream>

namespace photocore::film_cpu {
Database::Database(const std::string &folder) {
    auto root = std::filesystem::u8path(folder);
    std::ifstream file(root / "film-profiles.json");
    if (!file)
        throw std::runtime_error("找不到 film-profiles.json");
    Json json;
    file >> json;
    std::function<void(const Json &)> validate = [&](const Json &node) {
        if (node.is_number_float() && !std::isfinite(node.get<double>()))
            throw std::runtime_error("底片資料含非有限數值");
        if (node.is_structured())
            for (const auto &child : node)
                validate(child);
    };
    validate(json);
    if (json.at("schema") != 1)
        throw std::runtime_error("光譜資料版本不支援");
    dimension = json.at("dimension").get<int>();
    if (dimension < 2 || dimension > 256)
        throw std::runtime_error("光譜表尺寸不合法");
    auto v13 = [](const Json &j) {
        if (j.size() != 13)
            throw std::runtime_error("須為 13 波段");
        std::array<V, 13> a{};
        for (int i = 0; i < 13; ++i)
            a[std::size_t(i)] = vec(j.at(i));
        return a;
    };
    scanner = v13(json.at("scanner"));
    scanner_rows = matrix(json.at("scannerToRGB"));
    auto scalar13 = [](const Json &j) {
        if (j.size() != 13)
            throw std::runtime_error("須為 13 波段");
        auto a = j.get<std::array<double, 13>>();
        for (double x : a)
            if (!std::isfinite(x))
                throw std::runtime_error("無效光譜");
        return a;
    };
    for (const auto &item : json.at("lights").items())
        lights[item.key()] = scalar13(item.value());
    for (const auto &item : json.at("filters").items())
        filters[item.key()] = scalar13(item.value());
    for (const auto &item : json.at("lightMatrices").items())
        light_matrices[item.key()] = {matrix(item.value().at("forward")), matrix(item.value().at("inverse"))};
    for (const auto &item : json.at("scanners").items()) {
        auto values = item.value().at("rendering").get<std::vector<double>>();
        auto warmth = item.value().at("warmth").get<std::vector<double>>();
        if (values.size() != 4 || warmth.size() != 2)
            throw std::runtime_error("掃描風格資料不完整");
        values.insert(values.end(), warmth.begin(), warmth.end());
        scanner_styles[item.key()] = values;
    }
    for (const auto &item : json.at("profiles").items()) {
        auto j = item.value();
        Profile p;
        p.id = item.key();
        p.mono = j.at("monochrome");
        p.reversal = j.at("reversal");
        p.family = j.at("family");
        p.curve = j.at("curve").get<Curve>();
        p.paper = j.at("paper").get<Curve>();
        if (!(p.curve[1] > p.curve[0]) || !(p.curve[2] > 0) || !(p.curve[3] > 0))
            throw std::runtime_error("底片密度曲線不合法");
        p.shift = j.at("shift");
        p.middle = j.at("middleDensity");
        p.chroma = j.at("scannerChroma");
        p.gain = vec(j.at("gain"));
        p.ev = vec(j.at("ev"));
        p.reference = vec(j.at("referencePrintExposure"));
        p.sensitivity = v13(j.at("sensitivity"));
        p.negative = v13(j.at("negativeDyes"));
        p.print_sensitivity = v13(j.at("printSensitivity"));
        p.print_dyes = v13(j.at("printDyes"));
        p.base = scalar13(j.at("baseDensity"));
        p.character = j.value("character", std::vector<double>{});
        p.defaults = j.at("defaults");
        for (const auto &cal : j.at("calibrations").items()) {
            const auto &c = cal.value();
            p.calibrations[cal.key()] = {vec(c.at("base")), vec(c.at("middle")), matrix(c.at("inverse")),
                                         c.at("slope").get<double>()};
        }
        profiles[p.id] = std::move(p);
    }
    std::ifstream data(root / "spectral-table.f32", std::ios::binary | std::ios::ate);
    const auto count = std::size_t(5 * 3 * dimension * dimension * 4);
    if (!data || data.tellg() != std::streamoff(count * 4))
        throw std::runtime_error("光譜表長度不符");
    data.seekg(0);
    table.resize(count);
    for (float &v : table) {
        unsigned char bytes[4];
        data.read(reinterpret_cast<char *>(bytes), 4);
        const std::uint32_t bits = std::uint32_t(bytes[0]) | (std::uint32_t(bytes[1]) << 8) |
                                   (std::uint32_t(bytes[2]) << 16) | (std::uint32_t(bytes[3]) << 24);
        std::memcpy(&v, &bits, 4);
        if (!std::isfinite(v))
            throw std::runtime_error("光譜表含非有限值");
    }
}
std::array<double, 13> Database::spectrum(V rgb) const {
    const double amplitude = std::max({rgb.x, rgb.y, rgb.z});
    std::array<double, 13> bands{};
    if (amplitude <= 0)
        return bands;
    const int face = rgb.x >= rgb.y && rgb.x >= rgb.z ? 0 : (rgb.y >= rgb.z ? 1 : 2);
    const double u = rgb[(face + 1) % 3] / amplitude * (dimension - 1),
                 v = rgb[(face + 2) % 3] / amplitude * (dimension - 1);
    const int x = std::min(dimension - 2, int(u)), y = std::min(dimension - 2, int(v));
    const double fx = u - x, fy = v - y;
    for (int k = 0; k < 13; ++k) {
        auto at = [&](int dx, int dy) {
            return double(table[std::size_t(
                ((k / 3 * 3 * dimension + face * dimension + y + dy) * dimension + x + dx) * 4 + k % 3)]);
        };
        bands[std::size_t(k)] =
            ((at(0, 0) * (1 - fx) + at(1, 0) * fx) * (1 - fy) + (at(0, 1) * (1 - fx) + at(1, 1) * fx) * fy) *
            amplitude;
    }
    return bands;
}
} // namespace photocore::film_cpu
