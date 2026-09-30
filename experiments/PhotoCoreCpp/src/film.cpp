#include "photocore/film.hpp"
#include "film_internal.hpp"
#include <filesystem>
#include <fstream>
#include <limits>

namespace photocore {
struct FilmProcessor::Impl {
    film_cpu::Database data;
    explicit Impl(const std::string &folder) : data(folder) {}
};
FilmProcessor::FilmProcessor(const std::string &folder) : impl_(std::make_shared<Impl>(folder)) {}
Image FilmProcessor::process(Image source, const std::string &path,
                             const std::function<void(const std::string &, const Image &)> &stage) const {
    using namespace film_cpu;
    // 驗證所有輸入，避免 NaN／缺件被核心的保護性略過當成成功。
    if (source.width == 0 || source.height == 0 ||
        source.width > std::numeric_limits<std::size_t>::max() / source.height ||
        source.pixels.size() != source.width * source.height)
        throw std::invalid_argument("來源尺寸不符");
    for (auto p : source.pixels)
        for (float v : {p.r, p.g, p.b, p.a})
            if (!std::isfinite(v))
                throw std::invalid_argument("來源含非有限像素");
    std::ifstream file(std::filesystem::u8path(path));
    if (!file)
        throw std::runtime_error("無法讀取底片配方");
    Json recipe;
    file >> recipe;
    if (recipe.value("schema", 0) != 1 ||
        recipe.value("scope", std::string{}) != "film-development-scanner" || recipe.value("isPreview", true))
        throw std::invalid_argument(
            "僅接受 film-development-scanner 完整三模組配方；不支援 App 全流程／預覽配方");
    const auto &db = impl_->data;
    const auto it = db.profiles.find(recipe.at("style").get<std::string>());
    if (it == db.profiles.end())
        throw std::invalid_argument("未知底片型號");
    const Profile &p = it->second;
    Effects e{p.defaults};
    if (!recipe.at("effects").is_object())
        throw std::invalid_argument("effects 必須為物件");
    for (const auto &item : recipe.at("effects").items()) {
        if (!e.json.contains(item.key()) && item.key() != "print_exposure_highlights" &&
            item.key() != "print_exposure_midtones" && item.key() != "print_exposure_shadows")
            throw std::invalid_argument("未知底片參數：" + item.key());
        const auto &value = item.value();
        if (e.json.contains(item.key()) && !value.is_null()) {
            const auto &expected = e.json.at(item.key());
            if ((expected.is_number() && !value.is_number()) ||
                (expected.is_string() && !value.is_string()) || (expected.is_object() && !value.is_object()))
                throw std::invalid_argument("底片參數型別錯誤：" + item.key());
        }
        if (value.is_null() && e.json.contains(item.key()) && e.json.at(item.key()).is_object())
            e.json[item.key()] = p.defaults.at(item.key());
        else
            e.json[item.key()] = value;
    }
    if (e.json.contains("developer_chemistry") && !e.json.at("developer_chemistry").is_null()) {
        const auto &defaults = p.defaults.at("developer_chemistry");
        for (const auto &item : e.json.at("developer_chemistry").items()) {
            if (!defaults.contains(item.key()) || (!item.value().is_null() && !item.value().is_number()))
                throw std::invalid_argument("未知或無效的藥水參數：" + item.key());
        }
    }
    // 先檢查選項，不能碰到未使用的分支才發現無效值。
    (void)db.scanner_styles.at(e.text("scanner_profile", "off"));
    (void)db.filters.at(e.text("monochrome_filter", "none"));
    for (const char *key : {"print_illuminant", "view_illuminant", "scanner_illuminant"})
        (void)db.lights.at(e.text(key, "reference"));
    const auto origin = e.text("scanner_source", "film"), paper = e.text("paper_profile", "reference");
    if (origin != "film" && origin != "paper")
        throw std::invalid_argument("未知掃描來源");
    if (paper != "reference" && paper != "glossy" && paper != "matte" && paper != "warmFiber")
        throw std::invalid_argument("未知紙材");
    const double strength = number(recipe, "strength", 1, 0, 1);
    auto image = develop(std::move(source), e, strength, stage);
    if (stage)
        stage("development", image);
    image = chemistry(std::move(image), e, strength, p.mono);
    if (stage)
        stage("chemistry", image);
    image = spectral(std::move(image), e, strength, p, db);
    if (stage)
        stage("spectral", image);
    image = character(std::move(image), p);
    if (stage)
        stage("character", image);
    Effects scan = e;
    if (scan.text("scanner_profile", "off") == "off")
        scan.json["scanner_profile"] = "neutral";
    if (scan.text("scanner_source", "film") == "film" || p.reversal)
        scan.json["scan_flare"] = 0;
    image = scanner(std::move(image), scan, db, p.mono);
    if (stage)
        stage("scanner", image);
    return image;
}
} // namespace photocore
