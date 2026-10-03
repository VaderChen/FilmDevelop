#pragma once
#include "film_internal.hpp"
#include "digital_math.hpp"
namespace photocore::film_cpu {
// 離散方框平均：滑動視窗維持 O(像素數)，邊界延伸與 Swift 的 CIBoxBlur 一致。
inline Image box_mean(const Image &source,int radius) {
    radius=std::clamp(radius,1,64);Image scratch(source.width,source.height),output(source.width,source.height);
    for(int axis=0;axis<2;++axis) {
        const Image &input=axis?scratch:source;Image &out=axis?output:scratch;
        const size_t length=axis?input.height:input.width,lines=axis?input.width:input.height;
        for(size_t line=0;line<lines;++line) {
            auto at=[&](long i)->const Pixel&{size_t k=size_t(std::clamp(i,0L,long(length)-1));return input.pixels[axis?k*input.width+line:line*input.width+k];};
            V sum;double alpha=0;for(int k=-radius;k<=radius;++k){sum+=rgb(at(k));alpha+=at(k).a;}
            for(size_t k=0;k<length;++k) {
                out.pixels[axis?k*out.width+line:line*out.width+k]=pixel(sum/(2*radius+1),float(alpha/(2*radius+1)));
                sum+=rgb(at(long(k)+radius+1))-rgb(at(long(k)-radius));alpha+=at(long(k)+radius+1).a-at(long(k)-radius).a;
            }
        }
    }
    return output;
}
inline Image sample_coefficients(const Image &source,size_t width,size_t height) {
    if(width==source.width && height==source.height)return source;
    Image out(width,height);
    auto at=[&](long x,long y){return source.pixels[size_t(std::clamp(y,0L,long(source.height)-1))*source.width+size_t(std::clamp(x,0L,long(source.width)-1))];};
    for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x) {
        double sx=(x+.5)*source.width/width-.5,sy=(y+.5)*source.height/height-.5;long ix=long(std::floor(sx)),iy=long(std::floor(sy));
        double fx=std::round((sx-ix)*256)/256,fy=std::round((sy-iy)*256)/256;
        const auto a=at(ix,iy),b=at(ix+1,iy),c=at(ix,iy+1),d=at(ix+1,iy+1);
        out.pixels[y*width+x]=pixel(mix(mix(rgb(a),rgb(b),fx),mix(rgb(c),rgb(d),fx),fy),float((a.a*(1-fx)+b.a*fx)*(1-fy)+(c.a*(1-fx)+d.a*fx)*fy));
    }
    return out;
}
inline Image guided_mask(const Image &mask,const Image &image,double radius,double epsilon=.0004) {
    auto guide=transform(image,[](Pixel p,size_t,size_t){auto v=max(straight(p),V(0));return pixel(v/(V(1)+v),1);});
    double scale=std::min(1.,1024./std::max(image.width,image.height));
    size_t width=std::max(1L,std::lround(image.width*scale)),height=std::max(1L,std::lround(image.height*scale));
    auto sampled=sample_coefficients(guide,width,height),input=sample_coefficients(mask,width,height);
    int r=int(std::clamp(std::round(radius*scale),1.,64.));
    auto mean=box_mean(sampled,r),meanP=box_mean(input,r);
    auto diagonal=box_mean(transform(sampled,[](Pixel p,size_t,size_t){return pixel(rgb(p)*rgb(p),1);}),r);
    auto crossMean=box_mean(transform(sampled,[](Pixel p,size_t,size_t){return Pixel{p.r*p.g,p.r*p.b,p.g*p.b,1};}),r);
    auto correlation=box_mean(transform(sampled,[&](Pixel p,size_t x,size_t y){return pixel(rgb(p)*input.pixels[y*width+x].r,1);}),r);
    Image slope(width,height),intercept(width,height);
    for(size_t i=0;i<slope.pixels.size();++i) {
        V m=rgb(mean.pixels[i]),d=max(rgb(diagonal.pixels[i])-m*m,V(0))+epsilon,c=rgb(crossMean.pixels[i])-V(m.x*m.y,m.x*m.z,m.y*m.z),v=rgb(correlation.pixels[i])-m*meanP.pixels[i].r;
        double l10=c.x/d.x,l20=c.y/d.x,d1=std::max(d.y-l10*c.x,epsilon*.01),l21=(c.z-l20*c.x)/d1,d2=std::max(d.z-l20*c.y-l21*l21*d1,epsilon*.01);
        double y1=v.y-l10*v.x,y2=v.z-l20*v.x-l21*y1,a2=y2/d2,a1=y1/d1-l21*a2,a0=v.x/d.x-l10*a1-l20*a2;
        V a{a0,a1,a2};slope.pixels[i]=pixel(a,1);intercept.pixels[i]=pixel(V(meanP.pixels[i].r-dot(a,m)),1);
    }
    slope=sample_coefficients(box_mean(slope,r),image.width,image.height);intercept=sample_coefficients(box_mean(intercept,r),image.width,image.height);
    return transform(image,[&](Pixel p,size_t x,size_t y){size_t i=y*image.width+x;double q=p.a<=.00001?0:std::clamp(dot(rgb(slope.pixels[i]),rgb(guide.pixels[i]))+intercept.pixels[i].r,0.,1.);return pixel(V(q),1);});
}
inline double skin_coverage(V v) {
    const double sourceLuma=dot(v,w);
    // 僅正規化膚色辨識訊號，照片像素與曝光控制保持原樣。
    v*=std::max(1.,.18/std::max(sourceLuma,.00001));
    const double r=v.x,g=v.y,b=v.z,l=dot(v,w),maxc=std::max({r,g,b}),minc=std::min({r,g,b}),chroma=maxc-minc,saturation=chroma/std::max(maxc,.001),cb=(b-l)*.565,cr=(r-l)*.713;
    double hue=0;if(chroma>.0001){if(maxc==r){hue=(g-b)/chroma;if(hue<0)hue+=6;}else if(maxc==g)hue=(b-r)/chroma+2;else hue=(r-g)/chroma+4;hue*=60;}
    const double luma=smooth(.0005,.01,sourceLuma)*(1-smooth(.96,1,sourceLuma)),sat=smooth(.015,.080,saturation)*(1-smooth(.76,.96,saturation));
    const double normal=smooth(.24,.38,r)*smooth(.10,.18,g)*smooth(.04,.10,b)*smooth(.035,.10,chroma)*smooth(-.03,.07,r-g)*smooth(-.04,.08,r-b)*(1-smooth(.32,.58,std::abs(r-g)))*(1-smooth(.02,.20,g-r));
    const double bright=smooth(.72,.86,r)*smooth(.66,.82,g)*smooth(.54,.72,b)*(1-smooth(.06,.18,std::abs(r-g)))*smooth(-.02,.07,r-b)*smooth(-.02,.07,g-b);
    const double ycbcr=smooth(-.245,-.185,cb)*(1-smooth(.010,.070,cb))*smooth(.015,.070,cr)*(1-smooth(.205,.280,cr));
    const double hueWeight=std::max(1-smooth(48,76,hue),smooth(332,348,hue));
    const double hsv=hueWeight*smooth(.05,.18,saturation)*(1-smooth(.72,.92,saturation))*smooth(.12,.24,maxc);
    const double warm=smooth(-.16,.035,r-b)*(1-smooth(.30,.58,std::abs(r-g)))*(1-smooth(.04,.24,g-r));
    // 過度偏紅通常包含唇色；只作保守色彩保護，不宣稱具備語意辨識。
    const double redProtection=1-smooth(.35,.55,(r-g)/std::max(r+g+b,.00001));
    return std::clamp(luma*sat*std::max({normal,bright,ycbcr,hsv,warm})*hueWeight*redProtection,0.,1.);
}
inline Image skin_mask(const Image &image,const Image *subject=nullptr) {
    auto raw=transform(image,[&](Pixel p,size_t x,size_t y){double v=p.a>0?skin_coverage(straight(p)):0;if(subject)v*=std::clamp(double(subject->pixels[y*image.width+x].r),0.,1.);return pixel(V(v),1);});
    auto refined=guided_mask(raw,image,std::max(2.,4*std::max(std::min(image.width,image.height)/1600.,.5)));
    return transform_owned(std::move(refined),[&](Pixel p,size_t x,size_t y){return pixel(V(std::clamp(double(p.r),0.,1.)*smooth(0,.15,raw.pixels[y*image.width+x].r)),1);});
}
inline Image smooth_channels(const Image &image,double radius,double epsilon) {
    int r=int(std::clamp(std::round(radius),1.,64.));
    // alpha 加權的局部統計；透明像素不充當黑色樣本。
    auto prepared=transform(image,[](Pixel p,size_t,size_t){return p.a>0?p:Pixel{0,0,0,0};});
    auto mean=box_mean(prepared,r),square=box_mean(transform(prepared,[](Pixel p,size_t,size_t){return pixel(straight(p)*rgb(p),p.a);}),r);
    Image a(image.width,image.height),b(image.width,image.height);
    for(size_t i=0;i<a.pixels.size();++i) {
        const auto average=mean.pixels[i];const double weight=std::max(double(average.a),1e-20);
        V m=rgb(average)/weight,variance=max(rgb(square.pixels[i])/weight-m*m,V(0)),slope=variance/(variance+epsilon);
        a.pixels[i]=pixel(slope*average.a,average.a);b.pixels[i]=pixel(m*(V(1)-slope)*average.a,average.a);
    }
    a=box_mean(a,r);b=box_mean(b,r);
    return transform(image,[&](Pixel p,size_t x,size_t y){size_t i=y*image.width+x;return p.a>0?pixel(rgb(p)*straight(a.pixels[i])+straight(b.pixels[i])*p.a,p.a):Pixel{0,0,0,0};});
}
// 調整 L，保留來源 Lab a/b；只有超出來源色域時才沿同一色相縮減彩度。
inline V skin_luminance(V color,double targetY) {
    auto lab=rgb_to_lab({color.x,color.y,color.z});
    const double fy=targetY>216./24389?std::cbrt(targetY):(24389./27*targetY+16)/116;
    auto result=lab_color_rgb(fy,lab[1],lab[2]);
    const double lower=std::min({0.,color.x,color.y,color.z}),upper=std::max({1.,color.x,color.y,color.z});
    auto fits=[&](V value){return std::min({value.x,value.y,value.z})>=lower && std::max({value.x,value.y,value.z})<=upper;};
    if(!fits(result)) {
        double lo=0,hi=1;
        for(int i=0;i<16;++i){double mid=(lo+hi)*.5;if(fits(lab_color_rgb(fy,lab[1]*mid,lab[2]*mid)))lo=mid;else hi=mid;}
        result=lab_color_rgb(fy,lab[1]*lo,lab[2]*lo);
    }
    return result;
}
inline Pixel skin_whiten(Pixel source,double mask,double amount) {
    const double weight=std::clamp(mask,0.,1.)*.68*amount;
    if(source.a<=0 || weight<=0)return source;
    const V color=straight(source);const double y=dot(color,exact_w);
    if(y<=0 || y>=1)return source;
    const double l=rgb_to_lab({color.x,color.y,color.z})[0]/100;
    // 提亮幅度增加 25%；最大 k=1.02，仍保留單調曲線與黑白端點。
    const double target=l+1.5*weight*l*(1-l)*(1-l),f=(100*target+16)/116;
    const double targetY=f>6./29?f*f*f:(116*f-16)*27/24389;
    return pixel(skin_luminance(color,targetY)*source.a,source.a);
}
inline Pixel skin_log_statistics(Pixel source,double mask) {
    if(source.a<=0)return {0,0,0,0};
    const double y=std::max(0.,dot(straight(source),exact_w)),value=std::log2(y+.00001),weight=source.a*std::clamp(mask,0.,1.);
    return pixel(V(value*weight,value*value*weight,0),weight);
}
inline Pixel skin_smoothing_pixel(Pixel source,Pixel fine,Pixel coarse,double mask,double amount,double epsilon) {
    const double weight=std::clamp(mask,0.,1.)*amount;
    if(source.a<=0 || weight<=0 || fine.a<=1e-8 || coarse.a<=1e-8)return source;
    const V color=straight(source);const double y=dot(color,exact_w);if(y<=0)return source;
    const double value=std::log2(y+.00001),mf=double(fine.r)/fine.a,mc=double(coarse.r)/coarse.a;
    const double vf=std::max(0.,double(fine.g)/fine.a-mf*mf),vc=std::max(0.,double(coarse.g)/coarse.a-mc*mc);
    const double fineDelta=(mf-value)*epsilon/(vf+epsilon),coarseDelta=(mc-value)*epsilon/(vc+epsilon);
    const double attenuation=.12+.23*smooth(.35,.85,vf/std::max(vc,.000001));
    double delta=coarseDelta-(1-attenuation)*fineDelta;
    delta=std::clamp(delta,std::min(0.,mc-value),std::max(0.,mc-value))*weight*(1-smooth(.025,.12,vc));
    if(std::abs(delta)<1e-7)return source;
    const double targetY=std::max(0.,std::exp2(value+delta)-.00001);
    return pixel(skin_luminance(color,targetY)*source.a,source.a);
}
inline Image skin_smooth(const Image &image,const Image &mask,double radius,double amount) {
    auto scales=[&]{
        auto statistics=transform(image,[&](Pixel p,size_t x,size_t y){return skin_log_statistics(p,mask.pixels[y*image.width+x].r);});
        return std::pair{box_mean(statistics,int(std::clamp(std::round(radius*.35),1.,64.))),
                         box_mean(statistics,int(std::clamp(std::round(radius*3),2.,64.)))};
    }();
    // 混合強度連續增加到 100%，不提前封頂；保留既有細紋與結構保護。
    return transform(image,[&](Pixel p,size_t x,size_t y){size_t i=y*image.width+x;return skin_smoothing_pixel(p,scales.first.pixels[i],scales.second.pixels[i],mask.pixels[i].r,amount*.78,.002+amount*.018);});
}
inline Image skin_enhance(Image image,const Image &mask,const Json &adjustment,double strength,const Database &database) {
    double white=number(adjustment,"skinWhitening",0,0,100)/100*strength,smoothing=number(adjustment,"skinSmoothing",0,0,100)/100*strength,warm=number(adjustment,"skinWarmth",0,-100,100)/100*strength;
    auto blend=[&](const Image &foreground,double amount){for(size_t i=0;i<image.pixels.size();++i){auto &p=image.pixels[i];auto q=foreground.pixels[i];double m=std::clamp(double(mask.pixels[i].r)*amount,0.,1.);p=pixel(mix(rgb(p),rgb(q),m),p.a);}};
    if(smoothing>.005)image=skin_smooth(image,mask,std::max(1.,(.9+smoothing*5.4)*std::max(std::min(image.width,image.height)/1600.,.5)),smoothing);
    if(white>.005)image=transform_owned(std::move(image),[&](Pixel p,size_t x,size_t y){return skin_whiten(p,mask.pixels[y*mask.width+x].r,white);});
    if(std::abs(warm)>.001)blend(white_balance(image,{{"whiteBalanceWarmth",warm*100}},1,database),1);
    return image;
}
}
namespace photocore::film_cpu {
inline Image skin_white_balance(Image source,const Image &mask,double strength) {
    V weighted;double coverage=0;for(size_t i=0;i<source.pixels.size();++i){double m=mask.pixels[i].r;weighted+=rgb(source.pixels[i])*m;coverage+=m;}
    auto encode=[](double v){return v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055;};
    weighted/=source.pixels.size();coverage=encode(coverage/source.pixels.size());if(coverage<=.02 || coverage>=.55)return source;
    double confidence=std::min(std::clamp((coverage-.02)/.08,0.,1.),std::clamp((.55-coverage)/.15,0.,1.));if(confidence<=.05)return source;
    V average;for(int c=0;c<3;++c)average[c]=std::clamp(encode(weighted[c])/coverage,0.,1.);
    double green=std::max(average.y,.001),correction=.55*confidence;
    V gain{std::clamp(1+(1.18/std::max(average.x/green,.001)-1)*correction,.88,1.12),1,std::clamp(1+(.82/std::max(average.z/green,.001)-1)*correction,.88,1.12)};
    gain=clamp(gain*std::clamp(std::max(.001,dot(average,w))/std::max(.001,dot(average*gain,w)),.92,1.08),V(.86),V(1.14));
    if(std::max({std::abs(gain.x-1),std::abs(gain.y-1),std::abs(gain.z-1)})<=.012)return source;
    return transform_owned(std::move(source),[&](Pixel p,size_t x,size_t y){V color=rgb(p),corrected=color*gain;double m=mask.pixels[y*mask.width+x].r*.58*confidence;V result=mix(mix(color,corrected,.16*confidence),corrected,m);return pixel(color*(1-strength)+result*strength,p.a);});
}
inline Image denoise(Image source,double amount) {
    if(amount<=.005)return source;
    // Swift／C++／Vulkan 共用逐通道自引導降噪，不附加銳化。
    return smooth_channels(source,2,std::pow(amount*.08,2));
}
inline std::vector<float> bokeh_samples(double radius) {
    std::vector<float> taps{64};double total=0;
    for(int k=0;k<64;++k){double r=std::sqrt((k+.5)/64.),angle=k*2.399963229728653,weight=1-smooth(.7,1,r);taps.push_back(float(std::cos(angle)*r*radius));taps.push_back(float(std::sin(angle)*r*radius));taps.push_back(float(weight));total+=weight;}
    for(int k=0;k<64;++k)taps[3+k*3]/=float(total);
    return taps;
}
inline Image bokeh(const Image &input,double radius) {
    if(radius<.05)return input;
    auto taps=bokeh_samples(radius);Image result(input.width,input.height);
    auto at=[&](long x,long y){return input.pixels[size_t(std::clamp(y,0L,long(input.height)-1))*input.width+size_t(std::clamp(x,0L,long(input.width)-1))];};
    for(size_t y=0;y<input.height;++y)for(size_t x=0;x<input.width;++x){V sum;double alpha=0;
        for(int k=0;k<int(taps[0]);++k){double sx=x+taps[1+k*3],sy=y+taps[2+k*3],weight=taps[3+k*3];long ix=long(std::floor(sx)),iy=long(std::floor(sy));double fx=std::round((sx-ix)*256)/256,fy=std::round((sy-iy)*256)/256;auto a=at(ix,iy),b=at(ix+1,iy),c=at(ix,iy+1),d=at(ix+1,iy+1);sum+=mix(mix(rgb(a),rgb(b),fx),mix(rgb(c),rgb(d),fx),fy)*weight;alpha+=((a.a*(1-fx)+b.a*fx)*(1-fy)+(c.a*(1-fx)+d.a*fx)*fy)*weight;}
        result.pixels[y*input.width+x]=pixel(sum,float(alpha));}
    return result;
}
inline Image background_blur(Image image,const Image &subject,const Image &depth,double amount,bool focus) {
    if(amount<=.005)return image;
    double scale=std::max(image.width,image.height)/1024.,radius=std::min(500.,amount*24*scale);
    auto mask=guided_mask(subject,image,std::max(2.,std::max(4*scale,radius*.35)),.0001);
    auto isolated=transform(image,[&](Pixel p,size_t x,size_t y){double weight=1-std::clamp(double(mask.pixels[y*image.width+x].r),0.,1.);return pixel(rgb(p)*weight,p.a*weight);});
    auto normalized=[&](Image blurred){return transform_owned(std::move(blurred),[&](Pixel p,size_t x,size_t y){const auto q=image.pixels[y*image.width+x];V color=max(rgb(p),V(0))/std::max(double(p.a),.05);return pixel(mix(rgb(q),color*q.a,smooth(.05,.20,p.a)),q.a);});};
    auto nearBlur=normalized(bokeh(isolated,radius*.2)),farBlur=normalized(bokeh(isolated,radius));
    return transform_owned(std::move(image),[&](Pixel p,size_t x,size_t y){size_t i=y*subject.width+x;double d=depth.pixels[i].r,m=mask.pixels[i].r;V background=mix(rgb(nearBlur.pixels[i]),rgb(farBlur.pixels[i]),d);if(focus)background=mix(rgb(p),background,std::clamp(d*5,0.,1.));return pixel(mix(background,rgb(p),m),p.a);});
}
}
