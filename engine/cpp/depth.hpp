#pragma once
#include "skin_math.hpp"
namespace filmdevelop {
using photocore::Image;
inline Image depth_blur_mask(const Image &subject,const Image *depth,double amount,bool *focused=nullptr) {
    using namespace photocore;using namespace film_cpu;
    if(focused)*focused=false;
    if(depth) {
        double scale=std::min(1.,96./std::max(depth->width,depth->height));size_t width=std::max(1L,std::lround(depth->width*scale)),height=std::max(1L,std::lround(depth->height*scale));
        auto sample=sample_coefficients(*depth,width,height),mask=sample_coefficients(subject,width,height);std::vector<double> values;for(auto p:sample.pixels)if(std::isfinite(p.r))values.push_back(p.r);
        if(values.size()>=16) {
            std::sort(values.begin(),values.end());auto percentile=[&](double p){double k=p*(values.size()-1);size_t i=size_t(k);return values[i]+(values[std::min(i+1,values.size()-1)]-values[i])*(k-i);};
            double low=percentile(.02),high=percentile(.98),focus=0,focusWeight=0,background=0,backgroundWeight=0;
            if(high-low>.0001) {
                double cx=(width-1)*.5,cy=(height-1)*.5,sigma=std::max(std::min(width,height)*.24,1.);
                for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x) {
                    size_t i=y*width+x;double d=std::clamp(double(sample.pixels[i].r),low,high),m=std::clamp(double(mask.pixels[i].r),0.,1.);
                    if(m>=.15){double dx=(x-cx)/sigma,dy=(y-cy)/sigma,w=m*(.45+.55*std::exp(-.5*(dx*dx+dy*dy)));focus+=d*w;focusWeight+=w;}
                    else if(m<=.05){double edge=std::min({x,width-1-x,y,height-1-y}),w=(1-m)/(1+edge*.12);background+=d*w;backgroundWeight+=w;}
                }
                if(focusWeight>.01) {
                    focus/=focusWeight;double fallback=std::abs(high-focus)>=std::abs(focus-low)?high:low;
                    double bg=backgroundWeight>.01?background/backgroundWeight:fallback,direction=bg>=focus?1:-1,range=high-low,normalizedFocus=std::clamp((focus-low)/range,0.,1.),dead=std::max(.035,.13-amount*.055),gain=(1.35+amount*1.65)/std::max(.001,1-dead);
                    if(focused)*focused=true;
                    return transform(*depth,[&](Pixel p,size_t,size_t){double normalized=std::clamp((p.r-low)/range,0.,1.),distance=std::clamp(((normalized-normalizedFocus)*direction-dead)*gain,0.,1.);return pixel(V(std::pow(distance,.72)),1);});
                }
            }
        }
    }
    // 模型無有效焦平面時，沿用 Swift 的保守背景漸層。
    return transform(subject,[&](Pixel,size_t,size_t y){return pixel(V(smooth(subject.height*.62*.08,subject.height*.62,subject.height-y-.5)),1);});
}
}
