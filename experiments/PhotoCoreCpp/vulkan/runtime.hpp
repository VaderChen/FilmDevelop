#pragma once
#include "photocore/core.hpp"
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>
namespace photocore::vk {
struct Buffer;
struct Surface {
    std::size_t width = 0, height = 0;
    std::shared_ptr<Buffer> buffer;
};
struct DispatchStat {
    std::string label;
    double host_ms = 0, gpu_ms = 0;
    unsigned dispatches = 0;
};
class Context {
  public:
    explicit Context(const std::string &shader, bool validationEnabled = true);
    ~Context();
    Context(const Context &) = delete;
    Context &operator=(const Context &) = delete;
    Surface create(std::size_t width, std::size_t height);
    Surface upload(const Image &image);
    Surface upload_floats(const std::vector<float> &values);
    Image download(const Surface &image);
    void dispatch(unsigned op, const Surface &a, const Surface &b, const Surface &c, const Surface &out,
                  const Surface &second, const std::vector<float> &parameters, const Surface &table,
                  unsigned axis, const std::string &label);
    std::string device_name() const;
    unsigned errors() const;
    unsigned warnings() const;
    std::size_t peak_buffer_bytes() const;
    std::vector<DispatchStat> stats;
    // 只計算影像跨 CPU/GPU 的傳輸；不含 LUT／uniform 參數。
    uint64_t image_uploads = 0, image_downloads = 0, uploaded_bytes = 0, downloaded_bytes = 0;

  private:
    struct State;
    std::unique_ptr<State> state_;
};
} // namespace photocore::vk
