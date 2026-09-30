#pragma once
#include "ColorMapping.hpp"
#include <thread>

// CPU-only display mapping. Retains the reference's eight-node accumulation order.
// Cache one instance per camera; no parsing or cube construction per image.
class OptimizedMapping {
    int n_;
    std::vector<std::array<float,3>> nodes_;
public:
    explicit OptimizedMapping(const ColorMapping& reference): n_(reference.size()) {
        nodes_.reserve(size_t(n_)*n_*n_);
        for(int b=0;b<n_;++b) for(int g=0;g<n_;++g) for(int r=0;r<n_;++r)
            nodes_.push_back(reference.sample({float(r)/(n_-1),float(g)/(n_-1),float(b)/(n_-1)}));
    }
    std::vector<float> rgbaCube() const {
        std::vector<float> result; result.reserve(nodes_.size()*4);
        for(const auto& node:nodes_) {result.insert(result.end(),node.begin(),node.end());result.push_back(1);}
        return result;
    }
    void apply(unsigned char* pixels,size_t bytes,double ev=0,unsigned workers=4) const {
        if(bytes%3) throw std::runtime_error("RGB byte count must be divisible by three");
        struct Axis {int index;float a,b;};
        std::array<Axis,256> axis{};
        for(int i=0;i<256;++i) {
            double x=i/255.;
            if(ev!=0) {
                x=(x<=.04045?x/12.92:std::pow((x+.055)/1.055,2.4))*std::exp2(ev);
                x=x<=.0031308?12.92*x:1.055*std::pow(x,1/2.4)-.055;
            }
            const float q=float(std::clamp(x,0.,1.))*(n_-1);
            const int lo=std::min(int(q),n_-2);
            const float f=q-lo;axis[i]={lo,1-f,f};
        }
        auto section=[&](size_t begin,size_t end) {
            for(size_t i=begin*3;i<end*3;i+=3) {
                const auto r=axis[pixels[i]],g=axis[pixels[i+1]],b=axis[pixels[i+2]];
                const size_t base=r.index+n_*g.index+n_*n_*b.index;
                const float weights[8]={r.a*g.a*b.a,r.b*g.a*b.a,r.a*g.b*b.a,r.b*g.b*b.a,
                                        r.a*g.a*b.b,r.b*g.a*b.b,r.a*g.b*b.b,r.b*g.b*b.b};
                const int offsets[8]={0,1,n_,n_+1,n_*n_,n_*n_+1,n_*n_+n_,n_*n_+n_+1};
                float out[3]={};
                for(int j=0;j<8;++j) for(int c=0;c<3;++c) out[c]+=weights[j]*nodes_[base+offsets[j]][c];
                for(int c=0;c<3;++c) pixels[i+c]=static_cast<unsigned char>(std::lround(std::clamp(out[c],0.f,1.f)*255));
            }
        };
        const size_t count=bytes/3;
        workers=std::max(1u,std::min(workers,unsigned(std::max(size_t(1),count/262144))));
        std::vector<std::thread> threads;
        try {for(unsigned w=1;w<workers;++w) threads.emplace_back(section,count*w/workers,count*(w+1)/workers);}
        catch(...) {for(auto& t:threads)t.join();throw;}
        section(0,count/workers);
        for(auto& t:threads)t.join();
    }
};
