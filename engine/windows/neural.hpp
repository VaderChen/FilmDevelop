#pragma once
#include "codec.hpp"
#include <memory>
namespace filmdevelop {
struct Tensor {
    std::string name;
    std::vector<int64_t> shape;
    std::vector<float> values;
};
// Go 負責模型下載、取消與工作生命週期；C++ 統一處理張量及硬體提供者。
class NeuralRuntime {
    struct Impl;
    std::unique_ptr<Impl> impl;
public:
    explicit NeuralRuntime(const std::filesystem::path &folder);
    ~NeuralRuntime();
    Json prepare(const std::filesystem::path &model);
    std::vector<Tensor> run(const std::filesystem::path &model, const std::vector<Tensor> &inputs);
    std::string route() const;
};
}
