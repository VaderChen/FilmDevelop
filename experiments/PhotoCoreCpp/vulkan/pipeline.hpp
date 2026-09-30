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
    Surface unary(unsigned, Surface, const std::vector<float> &, const std::string &);
    Surface gaussian(Surface, double, const std::string &);
    Surface resize(Surface, double);
    Surface develop(Surface, const film_cpu::Effects &, double);
    Surface chemistry(Surface, const film_cpu::Effects &, double, bool);
    Surface spectral(Surface, const film_cpu::Effects &, double, const film_cpu::Profile &);
};
} // namespace photocore::vk
