#pragma once
#include "codec.hpp"
#include "Contract.generated.hpp"
#include <functional>
namespace filmdevelop {
Json infer_photo(const contract::InferenceRequest &request,const std::filesystem::path &folder,const std::function<void(double)> &progress);
}
