#pragma once
#include "Contract.generated.hpp"
#include "film_internal.hpp"
#include "geometry.hpp"
#include "repair_patches.hpp"
#include "skin_math.hpp"
#include "depth.hpp"
#include "decorations.hpp"
#include <functional>

namespace filmdevelop {
// 平台解析器提供線性影像與相機原片；共用管線維持 Swift 的階段及混合順序。
// GPU 失敗的整張重算由宿主管理，不會以半完成的中間影像接續 CPU。
using ComputeImage = std::function<photocore::Image(const photocore::Image &, const nlohmann::json &, const std::vector<photocore::Image> &)>;
inline photocore::Image render_style(const photocore::Image &input, const photocore::Image &source,
    const contract::RenderJob &job, const nlohmann::json &neutral, const nlohmann::json &catalog,
    const nlohmann::json &monochromes, photocore::film_cpu::Database &database, const ComputeImage &gpu = {},
    const std::vector<RepairPatch> &patches = {}, const photocore::Image *subjectMask = nullptr, const photocore::Image *depthMap = nullptr) {
    using namespace photocore;
    using Json = nlohmann::json;
    auto blend = [](Image base, const Image &foreground, double amount) {
      if (amount <= 0) return base;
      if (amount >= 1) return foreground;
      for (size_t i = 0; i < base.pixels.size(); ++i) {
        auto &p = base.pixels[i]; const auto q = foreground.pixels[i];
        const double remaining = 1 - amount;
        p = {float(p.r * remaining + q.r * amount), float(p.g * remaining + q.g * amount),
             float(p.b * remaining + q.b * amount), float(p.a * remaining + q.a * amount)};
      }
      return base;
    };
    auto monochrome = [](Image image) {
      for (auto &p : image.pixels) {
        float y = p.r * .2125f + p.g * .7154f + p.b * .0721f; p.r = p.g = p.b = y;
      }
      return image;
    };
    auto process = [&](Image input, const Json &adjustment, const film_cpu::Profile *profile, const std::string &style, bool useGPU) {
      const CropGeometry geometry(input.width, input.height, job.recipe.adjustment);
      std::optional<Image> subject,depth;
      if(subjectMask)subject=geometry.apply(film_cpu::sample_coefficients(*subjectMask,input.width,input.height));
      if(depthMap)depth=geometry.apply(film_cpu::sample_coefficients(*depthMap,input.width,input.height));
      if(!patches.empty() || !geometry.is_identity(input))input = apply_repaired_geometry(input, patches, geometry);
      auto effects = adjustment.at("filmEffects");
      effects["_origin_x"] = geometry.left; effects["_origin_y"] = geometry.bottom;
      const double strength = film_cpu::number(adjustment, "intensity", 50, 0, 100) / 100;
      const bool adjustsSkin = strength > 0 && (film_cpu::number(adjustment,"skinWhitening",0,0,100)*strength>.5 || film_cpu::number(adjustment,"skinSmoothing",0,0,100)*strength>.5 || std::abs(film_cpu::number(adjustment,"skinWarmth",0,-100,100))*strength>.1);
      const bool mono = monochromes.value(style, false);
      const bool adjustsSkinWB = subject.has_value() && strength > 0 && !mono && style != "original";
      const double blurAmount=film_cpu::number(adjustment,"backgroundBlur",0,0,100)/100;
      std::optional<Image> blurMask;bool focusedDepth=false;
      if(subject && blurAmount>.005)blurMask=depth_blur_mask(*subject,depth?&*depth:nullptr,blurAmount,&focusedDepth);
      const bool digital = style != "original" && !profile;
      Exposure exposure;
      exposure.global_ev = film_cpu::number(effects, "print_exposure", 0, -16, 16);
      exposure.zones = {film_cpu::number(effects, "print_exposure_highlights", exposure.global_ev, -16, 16),
                        film_cpu::number(effects, "print_exposure_midtones", exposure.global_ev, -16, 16),
                        film_cpu::number(effects, "print_exposure_shadows", exposure.global_ev, -16, 16)};
      exposure.protect_highlights = !job.policy || job.policy->highlightProtection;
      exposure.protect_peak = job.policy && job.policy->modernExposure;
      const auto calibration = adjustment.value("colorCalibration", Json());
      auto calibrateInput = [&](Image image, const char *stage) {
        if (calibration.is_null() || calibration.value("stage", std::string("input")) != stage) return image;
        Calibration c; c.rows = calibration.at("rows").get<decltype(c.rows)>();
        return apply_calibration(image, c);
      };
      auto printEffects = effects;
      effects["print_exposure"] = 0;
      for (auto key : {"print_exposure_highlights", "print_exposure_midtones", "print_exposure_shadows"}) effects[key] = 0;
      if (!digital && effects.value("scanner_profile", std::string("off")) == "off") effects["scanner_profile"] = "neutral";
      auto scanning = effects;
      if (profile && (effects.value("scanner_source", std::string("film")) == "film" || profile->reversal)) scanning["scan_flare"] = 0;
      if (useGPU) {
        Json nodes = Json::array(); size_t current = 0;std::vector<Image> auxiliary;
        auto stage = [&](const char *name, const Json &settings, size_t index) {
          nodes.push_back({{"source", index}, {"operation", {{"schema", 1}, {"stage", name},
            {"effects", settings}, {"strength", strength}, {"monochrome", mono},
            {"stock", profile ? profile->id : "original"}, {"style", style}, {"hdr", !job.policy || job.policy->hdr}, {"adjustment", adjustment}, {"preview", job.preview},
            {"highlightProtection", exposure.protect_highlights}, {"modernExposure", exposure.protect_peak},
            {"originX", geometry.left}, {"originY", geometry.bottom}}}});
          return nodes.size();
        };
        auto combine = [&](size_t base, size_t foreground) {
          nodes.push_back({{"source", base}, {"secondary", foreground},
            {"operation", {{"schema", 1}, {"stage", "blend"}, {"strength", strength}}}});
          return nodes.size();
        };
        if (!calibration.is_null() && calibration.value("stage", std::string("input")) == "input") current = stage("calibration", effects, current);
        auto external = [&](const Image &image) {auxiliary.push_back(image);size_t index=stage("external",effects,0);nodes.back()["operation"]["input"]=auxiliary.size()-1;return index;};
        const size_t subjectIndex = subject ? external(*subject) : 0;
        const size_t depthIndex = blurMask ? external(*blurMask) : 0;
        const size_t skinMask = adjustsSkin || adjustsSkinWB ? stage("skinMask", effects, current) : 0;
        if(skinMask && subjectIndex)nodes.back()["secondary"]=subjectIndex;
        if(adjustsSkinWB){current=stage("skinWhiteBalance",effects,current);nodes.back()["secondary"]=skinMask;}
        current = stage("whiteBalance", effects, current);
        current = stage("denoise", effects, current);
        current = stage("digitalExposure", effects, current);
        current = stage("printExposure", printEffects, current);
        for (auto name : {"lightScatter", "emulsion", "development"}) current = stage(name, effects, current);
        if (!digital) current = stage("chemistry", effects, current);
        if (profile) {
          size_t base = current;
          current = stage("spectral", effects, current);
          current = stage("character", effects, current);
          if (mono) base = stage("monochrome", effects, base);
          current = combine(base, current);
          if (mono) current = stage("monochrome", effects, current);
        }
        if (digital && style != "autoDetection") {
          if (mono) current = stage("monochromeFilter", effects, current);
          size_t base = current;
          current = stage("digitalLook", effects, current);
          current = stage("digitalPrint", effects, current);
          if (mono) base = stage("monochrome", effects, base);
          current = combine(base, current);
        }
        if (!profile && (!digital || style == "autoDetection")) current = combine(current, stage("digitalPrint", effects, current));
        if (!calibration.is_null() && calibration.value("stage", std::string("input")) == "output") current = stage("calibration", effects, current);
        if (adjustsSkin) { current=stage("skinEnhancement",effects,current);nodes.back()["secondary"]=skinMask; }
        for (auto name : {"planTone", "tone", "labColor", "toneZones", "hdr", "lensShading"}) current = stage(name, effects, current);
        if(blurMask){current=stage("backgroundBlur",effects,current);nodes.back()["secondary"]=subjectIndex;nodes.back()["tertiary"]=depthIndex;nodes.back()["operation"]["focusedDepth"]=focusedDepth;}
        if (mono) current = stage("monochrome", effects, current);
        if (digital) return gpu(input, {{"schema", 2}, {"nodes", nodes}}, auxiliary);
        size_t base = current;
        current = stage("scanner", scanning, current);
        if (mono) current = stage("monochrome", scanning, current);
        combine(base, current);
        return gpu(input, {{"schema", 2}, {"nodes", nodes}}, auxiliary);
      }
      film_cpu::Effects e{effects};
      input = calibrateInput(std::move(input), "input");
      std::optional<Image> skinMask; if(adjustsSkin || adjustsSkinWB)skinMask=film_cpu::skin_mask(input,subject?&*subject:nullptr);
      if(adjustsSkinWB)input=film_cpu::skin_white_balance(std::move(input),*skinMask,strength);
      input = film_cpu::white_balance(std::move(input), adjustment, strength, database);
      input = film_cpu::denoise(std::move(input),film_cpu::number(adjustment,"denoise",0,0,100)/100*strength);
      Exposure digitalExposure;
      double ev = slider_to_ev(film_cpu::number(adjustment, "exposure", 0, -100, 100) * strength);
      digitalExposure.zones = {ev, ev, ev};
      input = apply_exposure(std::move(input), digitalExposure);
      digitalExposure.zones = {slider_to_ev(film_cpu::number(adjustment, "highlightExposure", 0, -100, 100) * strength),
        slider_to_ev(film_cpu::number(adjustment, "midtoneExposure", 0, -100, 100) * strength), slider_to_ev(film_cpu::number(adjustment, "shadowExposure", 0, -100, 100) * strength)};
      input = apply_exposure(std::move(input), digitalExposure);
      input = apply_exposure(std::move(input), exposure);
      input = film_cpu::light_scatter(std::move(input), e, strength);
      input = film_cpu::emulsion(std::move(input), e, adjustment, strength, mono, job.preview);
      input = film_cpu::develop(std::move(input), e, strength);
      if (!digital) input = film_cpu::chemistry(std::move(input), e, strength, mono);
      if (profile) {
        auto developed = film_cpu::spectral(input, e, strength, *profile, database);
        developed = film_cpu::character(std::move(developed), *profile);
        if (mono) input = monochrome(std::move(input));
        input = blend(std::move(input), developed, strength);
        if (mono) input = monochrome(std::move(input));
      }
      if (digital && style != "autoDetection") {
        if (mono) input = film_cpu::monochrome_filter(std::move(input), e, strength);
        auto filtered = film_cpu::digital_look(input, database.digital.at(style));
        filtered = film_cpu::digital_print(std::move(filtered), e, database);
        if (mono) input = monochrome(std::move(input));
        input = blend(std::move(input), filtered, strength);
      }
      if (!profile && (!digital || style == "autoDetection")) input = blend(input, film_cpu::digital_print(input, e, database), strength);
      input = calibrateInput(std::move(input), "output");
      if(skinMask)input=film_cpu::skin_enhance(std::move(input),*skinMask,adjustment,strength,database);
      input = film_cpu::plan_tone(std::move(input), adjustment, strength, mono, database);
      input = film_cpu::local_tone(std::move(input), adjustment, strength, false);
      input = film_cpu::lab_adjustment(std::move(input), adjustment);
      input = film_cpu::tone_zones(std::move(input), adjustment, strength, mono, style, database);
      auto hdr = adjustment; hdr["contrast"] = 0; hdr["brightness"] = 50;
      input = film_cpu::local_tone(std::move(input), hdr, strength, !job.policy || job.policy->hdr);
      input = film_cpu::lens_shading(std::move(input), adjustment, strength, database);
      if(blurMask)input=film_cpu::background_blur(std::move(input),*subject,*blurMask,blurAmount,focusedDepth);
      if (mono) input = monochrome(std::move(input));
      if (digital) return input;
      auto scanned = film_cpu::scanner(input, film_cpu::Effects{scanning}, database, false);
      if (mono) scanned = monochrome(std::move(scanned));
      return blend(std::move(input), scanned, strength);
    };
    const auto profile = database.profiles.find(job.recipe.style);
    const auto *stock = profile == database.profiles.end() ? nullptr : &profile->second;
    auto finish = [&](bool useGPU) {
      auto adjustment = job.recipe.adjustment;
      const double intensity = film_cpu::number(adjustment, "intensity", 50, 0, 100);
      const double baseline = stock ? catalog.at(job.recipe.style).at("intensity").get<double>() : 50;
      if (stock && intensity < baseline) {
        auto original = process(source, neutral, nullptr, "original", useGPU);
        if (intensity == 0) return original;
        adjustment["intensity"] = baseline;
        return blend(std::move(original), process(input, adjustment, stock, job.recipe.style, useGPU), intensity / baseline);
      }
      return process(job.recipe.style == "original" ? source : input, adjustment, stock, job.recipe.style, useGPU);
    };
    return decorate(finish(bool(gpu)),job.recipe.adjustment,&database);
}
}
