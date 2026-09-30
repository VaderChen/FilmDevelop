#pragma once
#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace photocore::smoke {
struct alignas(16) Float4 {
    float x = 0, y = 0, z = 0, w = 0;
};
static_assert(sizeof(Float4) == 16);
using Parameters = std::array<Float4, 32>;
struct Dispatch {
    std::vector<Float4> values;
    double submit_wait_ms = 0;
    double gpu_ms = -1;
    unsigned dispatches = 1;
};
class Runtime {
  public:
    explicit Runtime(const std::string &shader);
    ~Runtime();
    Runtime(const Runtime &) = delete;
    Runtime &operator=(const Runtime &) = delete;
    Dispatch run(const std::vector<Float4> &input, const Parameters &parameters);
    std::string device_name() const;
    bool float64() const;
    unsigned errors() const;
    unsigned warnings() const;

  private:
    struct State;
    std::unique_ptr<State> state_;
};
} // namespace photocore::smoke
