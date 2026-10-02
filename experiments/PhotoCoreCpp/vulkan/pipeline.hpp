#pragma once
#include "film_internal.hpp"
#include "runtime.hpp"
namespace photocore::vk {
struct Recipe {
    film_cpu::Effects effects;
    const film_cpu::Profile *profile;
    double strength;
};
Recipe prepare_recipe(const std::string &, const film_cpu::Database &);
class Pipeline {
    friend class StageBenchmark;
    friend class AppBridge;

  public:
    Context context;
    film_cpu::Database database;
    Surface table;
    Pipeline(const std::string &data, const std::string &shader, bool validationEnabled = true);
    Image process(Image source, const std::string &recipe, const std::string &dump = {});
    Surface exposure(Surface, const Exposure &);
    Surface raw_mapping(Surface);
    Surface calibration(Surface, const Calibration &);

  private:
    std::map<const film_cpu::DigitalLook *, Surface> digital_tables;
    std::map<const film_cpu::ToneMapping *, Surface> tone_tables;
    Surface vignette_table;
    Surface unary(unsigned, Surface, const std::vector<float> &, const std::string &);
    Surface gaussian(Surface, double, const std::string &, bool clamp_edges = true);
    Surface resize(Surface, double, bool clamp_edges = false);
    Surface resample(Surface, std::size_t, std::size_t);
    Surface tone_masks(Surface);
    Surface guided(Surface, double);
    Surface box_mean(Surface, int);
    Surface skin_mask(Surface, Surface = {});
    Surface refine_mask(Surface, Surface, double, double);
    Surface skin_white_balance(Surface, Surface, double);
    Surface background_blur(Surface, Surface, Surface, double, bool);
    Surface bokeh(Surface, double);
    Surface skin_enhance(Surface, Surface, const film_cpu::Json &, double);
    Surface smooth_channels(Surface, double, double);
    Surface digital_look(Surface, const film_cpu::DigitalLook &);
    Surface plan_tone(Surface, const film_cpu::Json &, double, bool);
    Surface local_tone_curve(Surface, double, double, double);
    Surface local_tone(Surface, const film_cpu::Json &, double, bool);
    Surface lab_adjustment(Surface, const film_cpu::Json &);
    Surface white_balance(Surface, const film_cpu::Json &, double);
    Surface tone_zones(Surface, const film_cpu::Json &, double, bool, const std::string &);
    Surface digital_print(Surface, const film_cpu::Effects &);
    Surface monochrome_filter(Surface, const film_cpu::Effects &, double);
    Surface lens_shading(Surface, const film_cpu::Json &, double);
    Surface light_scatter(Surface, const film_cpu::Effects &, double);
    Surface emulsion(Surface, const film_cpu::Effects &, const film_cpu::Json &, double, bool, bool);
    Surface develop(Surface, const film_cpu::Effects &, double);
    Surface chemistry(Surface, const film_cpu::Effects &, double, bool);
    Surface spectral(Surface, const film_cpu::Effects &, double, const film_cpu::Profile &);
};
} // namespace photocore::vk
