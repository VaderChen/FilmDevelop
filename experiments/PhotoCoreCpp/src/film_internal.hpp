#pragma once
#include "film_math.hpp"
#include "nlohmann/json.hpp"
#include <string>

namespace photocore::film_cpu {
using Json = nlohmann::json;
inline double number(const Json &j, const char *key, double fallback, double low, double high) {
    if (!j.contains(key) || j.at(key).is_null())
        return fallback;
    if (!j.at(key).is_number())
        throw std::invalid_argument(std::string("參數不是數值：") + key);
    double v = j.at(key).get<double>();
    if (!std::isfinite(v))
        throw std::invalid_argument(std::string("參數不是有限數值：") + key);
    return std::clamp(v, low, high);
}
struct Effects {
    Json json;
    double get(const char *key, double fallback = 0, double low = 0, double high = 100) const {
        return number(json, key, fallback, low, high);
    }
    std::string text(const char *key, const std::string &fallback) const {
        return json.value(key, fallback);
    }
};
inline V vec(const Json &j) {
    if (!j.is_array() || j.size() != 3)
        throw std::invalid_argument("光譜向量長度不符");
    V v(j.at(0).get<double>(), j.at(1).get<double>(), j.at(2).get<double>());
    for (int c = 0; c < 3; ++c)
        if (!std::isfinite(v[c]))
            throw std::invalid_argument("光譜向量含非有限值");
    return v;
}
inline Matrix matrix(const Json &j) {
    if (!j.is_array() || j.size() != 3)
        throw std::invalid_argument("矩陣尺寸不符");
    return {vec(j.at(0)), vec(j.at(1)), vec(j.at(2))};
}
using Curve = std::array<double, 4>;
struct CalibrationData {
    V base, middle;
    Matrix inverse;
    double slope;
};
struct Profile {
    bool mono = false, reversal = false;
    std::string id, family;
    Curve curve{}, paper{};
    double shift = 0, middle = 0, chroma = 1;
    V gain, ev, reference;
    std::array<V, 13> sensitivity{}, negative{}, print_sensitivity{}, print_dyes{};
    std::array<double, 13> base{};
    std::vector<double> character;
    std::map<std::string, CalibrationData> calibrations;
    Json defaults;
};
struct Database {
    std::map<std::string, Profile> profiles;
    std::map<std::string, std::array<double, 13>> lights, filters;
    std::map<std::string, std::pair<Matrix, Matrix>> light_matrices;
    std::map<std::string, std::vector<double>> scanner_styles;
    std::array<V, 13> scanner{};
    Matrix scanner_rows;
    int dimension = 0;
    std::vector<float> table;
    explicit Database(const std::string &folder);
    std::array<double, 13> spectrum(V rgb) const;
};
Image develop(Image source, const Effects &e, double strength,
              const std::function<void(const std::string &, const Image &)> &trace = {});
Image chemistry(Image source, const Effects &e, double strength, bool monochrome);
Image spectral(Image source, const Effects &e, double strength, const Profile &profile, const Database &data);
Image character(Image source, const Profile &profile);
Image scanner(Image source, const Effects &e, const Database &data, bool monochrome);
V grade(V rgb, double saturation, double mid_warmth, double high_warmth, const std::vector<double> &style,
        bool monochrome);
} // namespace photocore::film_cpu
