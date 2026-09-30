#pragma once
#include "photocore/core.hpp"

namespace photocore::verification {
// CIEDE2000，標準觀察條件 kL = kC = kH = 1；輸入為相同參考白點的 CIELAB。
double delta_e_2000(Vec3 first, Vec3 second);
} // namespace photocore::verification
