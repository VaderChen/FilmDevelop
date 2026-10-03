#pragma once
#include "film_internal.hpp"

namespace photocore::film_cpu {
// 與 Swift 相同的單調分區淡化。固定小表不隨影像尺寸增加記憶體。
inline std::vector<float> plan_fade_lifts(const Json &zones,double strength) {
    V amounts;int region=0;
    for(const char *key:{"shadows","midtones","highlights"}) {
        const double amount=number(zones.value(key,Json::object()),"fade",0,0,100)/100*strength;
        amounts[region++]=amount>.005?amount:0;
    }
    if(std::max({amounts.x,amounts.y,amounts.z})<=0)return {};
    constexpr int samples=1025;
    constexpr double slope=.1,attenuation=.209186;
    struct Block {double sum;int count;};
    std::vector<Block> blocks;blocks.reserve(samples);
    for(int i=0;i<samples;++i) {
        const double y=double(i)/(samples-1),stops=std::log2(std::max(y,.000001)/.18),sigma=stops<0?.65:1.35;
        const V weights{1-smooth(-1.55,0,stops),std::exp2(-.5*std::pow(stops/sigma,2)),smooth(.55,2.55,stops)};
        const double lift=.18*dot(weights,amounts)/(weights.x+weights.y+weights.z);
        blocks.push_back({y*(1-attenuation*lift)+lift-slope*y,1});
        while(blocks.size()>1) {
            const auto right=blocks.back();auto &left=blocks[blocks.size()-2];
            if(left.sum/left.count<=right.sum/right.count)break;
            left.sum+=right.sum;left.count+=right.count;blocks.pop_back();
        }
    }
    std::vector<float> result;result.reserve(samples);
    for(const auto &block:blocks)for(int i=0;i<block.count;++i) {
        const double y=double(result.size())/(samples-1),mapped=block.sum/block.count+slope*y;
        result.push_back(float(std::max(0.,(mapped-y)/(1-attenuation*y))));
    }
    return result;
}
inline Pixel plan_fade_pixel(Pixel p,const std::vector<float> &curve) {
    if(p.a<=0 || curve.empty())return p;
    const double position=std::clamp(dot(straight(p),w),0.,1.)*(curve.size()-1);
    const size_t index=std::min(size_t(position),curve.size()-2);
    const double lift=curve[index]+(curve[index+1]-curve[index])*(position-index);
    return pixel(rgb(p)*(V(1)-V(.25,.20,.18)*lift)+V(lift*p.a),p.a);
}
}
