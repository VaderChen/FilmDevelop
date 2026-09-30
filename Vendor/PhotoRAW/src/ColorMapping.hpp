#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Standard red-fast .cube, encoded sRGB in/out. CPU only. No Apple dependency,
// spatial coordinates, reference image, image filename or input hash in lookup.
class ColorMapping {
    int size_ = 0;
    std::vector<std::array<float, 3>> values_;
public:
    int size() const { return size_; }
    std::filesystem::path path;
    bool useDngBaseline = false;
    static std::filesystem::path find(const std::filesystem::path& directory,
                                     const std::string& make, const std::string& model) {
        std::ifstream index(directory / "index.tsv");
        if (!index) throw std::runtime_error("Cannot read mapping index.tsv");
        std::string line;
        std::filesystem::path result;
        while (std::getline(index, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (line.empty() || line[0] == '#') continue;
            std::istringstream fields(line);
            std::string a, b, c;
            if (!std::getline(fields,a,'\t') || !std::getline(fields,b,'\t') || !std::getline(fields,c,'\t') || c.empty())
                throw std::runtime_error("Invalid mapping index row");
            if (a != make || b != model) continue;
            auto file = std::filesystem::u8path(c);
            if (file.has_parent_path() || file.extension() != ".cube" || !result.empty())
                throw std::runtime_error("Invalid or duplicate camera mapping");
            result = directory / file;
        }
        return result; // Unknown models explicitly retain the fixed renderer.
    }
    explicit ColorMapping(const std::filesystem::path& file) : path(file) {
        std::ifstream input(file);
        if (!input) throw std::runtime_error("Cannot open mapping cube");
        std::string line;
        bool domainMin=false, domainMax=false;
        while (std::getline(input, line)) {
            if (line == "# RAW_LAB_INPUT_EXPOSURE DNG_BASELINE") useDngBaseline=true;
            line = line.substr(0,line.find('#'));
            std::istringstream row(line);
            std::string key;
            if (!(row >> key)) continue;
            if (key == "TITLE") continue;
            if (key == "LUT_3D_SIZE") {
                if (size_ || !(row >> size_) || size_<2 || size_>129)
                    throw std::runtime_error("Invalid cube size");
            } else if (key == "DOMAIN_MIN" || key == "DOMAIN_MAX") {
                float a,b,c; const float expected=key=="DOMAIN_MIN"?0.f:1.f;
                bool& seen=key=="DOMAIN_MIN"?domainMin:domainMax;
                if (seen || !(row>>a>>b>>c) || a!=expected || b!=expected || c!=expected)
                    throw std::runtime_error("Cube domain must be [0,1]");
                seen=true;
            } else {
                row.clear(); row.str(line);
                std::array<float,3> value{};
                std::string extra;
                if (!size_ || !(row>>value[0]>>value[1]>>value[2]) || (row>>extra))
                    throw std::runtime_error("Invalid cube entry");
                for (float v:value) if (!std::isfinite(v) || v<0 || v>1)
                    throw std::runtime_error("Non-finite or out-of-range cube value");
                if (values_.size() >= size_t(size_)*size_*size_)
                    throw std::runtime_error("Too many cube entries");
                values_.push_back(value);
            }
        }
        if (input.bad() || !size_ || values_.size()!=size_t(size_)*size_*size_)
            throw std::runtime_error("Incomplete mapping cube");
    }
    std::array<float,3> sample(const std::array<float,3>& rgb) const {
        std::array<int,3> lo{};
        std::array<float,3> fraction{},out{};
        for (int c=0;c<3;++c) {
            const float q=std::clamp(rgb[c],0.f,1.f)*(size_-1);
            lo[c]=std::min(int(q),size_-2); fraction[c]=q-lo[c];
        }
        for (int b=0;b<2;++b) for(int g=0;g<2;++g) for(int r=0;r<2;++r) {
            const float weight=(r?fraction[0]:1-fraction[0])*(g?fraction[1]:1-fraction[1])*(b?fraction[2]:1-fraction[2]);
            const auto& v=values_[lo[0]+r+size_*(lo[1]+g)+size_*size_*(lo[2]+b)];
            for(int c=0;c<3;++c) out[c]+=weight*v[c];
        }
        return out;
    }
    void apply(unsigned char* pixels,size_t count,double inputEV=0) const {
        std::array<float,256> input{};
        for(int i=0;i<256;++i) {
            double x=i/255.;
            if(inputEV!=0) {
                x=(x<=.04045?x/12.92:std::pow((x+.055)/1.055,2.4))*std::exp2(inputEV);
                x=x<=.0031308?12.92*x:1.055*std::pow(x,1/2.4)-.055;
            }
            input[i]=float(std::clamp(x,0.,1.));
        }
        for(size_t i=0;i<count;i+=3) {
            const auto v=sample({input[pixels[i]],input[pixels[i+1]],input[pixels[i+2]]});
            for(int c=0;c<3;++c) pixels[i+c]=static_cast<unsigned char>(std::lround(std::clamp(v[c],0.f,1.f)*255));
        }
    }
};
