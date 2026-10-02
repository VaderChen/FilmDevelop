#pragma once
#include "neural.hpp"
#include "repair_patches.hpp"
namespace filmdevelop {
Json repair_photo(const photocore::Image &source,const Json &strokes,const std::filesystem::path &directory,NeuralRuntime &runtime,Codec &codec);
}
