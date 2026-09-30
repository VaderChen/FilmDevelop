#pragma once
#include "film_internal.hpp"
#include <functional>
namespace photocore::smoke {
void benchmark_cpu_unmix(const std::vector<film_cpu::V> &input, std::vector<film_cpu::V> &output,
                         const film_cpu::Profile &profile, const film_cpu::Database &database,
                         const std::array<double, 13> &light, const film_cpu::CalibrationData &calibration);
film_cpu::V route_unmix(film_cpu::V optical, const film_cpu::Profile &profile,
                        const film_cpu::Database &database, const std::array<double, 13> &light,
                        const film_cpu::CalibrationData &calibration,
                        const std::function<film_cpu::V()> &cpu);
}
