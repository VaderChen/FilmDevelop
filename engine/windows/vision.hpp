#pragma once
#include "neural.hpp"
#include <map>
#include <memory>
namespace filmdevelop {
struct FaceBox { double left,top,right,bottom,score; };
class Vision {
    std::filesystem::path folder;
    std::map<std::string,std::unique_ptr<NeuralRuntime>> runtimes;
    NeuralRuntime &runtime(const std::string &name);
public:
    explicit Vision(std::filesystem::path engineFolder):folder(std::move(engineFolder)){}
    std::optional<photocore::Image> subject(const photocore::Image &source);
    photocore::Image depth(const photocore::Image &source);
    std::vector<FaceBox> faces(const photocore::Image &source);
};
}
