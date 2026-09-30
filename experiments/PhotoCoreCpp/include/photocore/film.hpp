#pragma once
#include "core.hpp"
#include <functional>
#include <memory>

namespace photocore {
// 資料庫只含原有片種常數與光譜重建表；執行時完全使用 C++ CPU。
class FilmProcessor {
  public:
    explicit FilmProcessor(const std::string &data_directory);
    // 僅接受 film-development-scanner 配方；不可冒充尚未移植的 App 全流程。
    Image process(Image source, const std::string &recipe_path,
                  const std::function<void(const std::string &, const Image &)> &stage = {}) const;

  private:
    struct Impl;
    std::shared_ptr<const Impl> impl_;
};
// 與 PNG16/sRGB 的量化邊界相同，再還原為線性 sRGB 供成品 ΔE 比較。
Image quantize_srgb16(Image source);
} // namespace photocore
