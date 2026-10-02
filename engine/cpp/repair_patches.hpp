#pragma once
#include "film_internal.hpp"
#include "geometry.hpp"

namespace filmdevelop {
struct RepairPatch {
    double x,y,width,height,gain;
    photocore::Image image,mask;
};
template<bool Decode> inline double repair_transfer(double value) {
    if(!std::isfinite(value))throw std::invalid_argument("修復貼片像素非有限值");
    auto exact=[](double v) {
        if constexpr(Decode)return v<=.04045?v/12.92:std::pow((v+.055)/1.055,2.4);
        else return v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055;
    };
    // 分段函數的接點保留原公式，查表區間不可跨過接點。
    if(value<=(Decode?.04045:.0031308)+1./65536 || value>1)return exact(value);
    // PNG 在 0...1 內以高精度一維表內插；擴展色域仍走原公式。
    // 保留取樣先後順序，同時避免每個預覽像素重算三次 pow。
    static const auto table=[&] {
        std::array<double,65537> values{};
        for(size_t i=0;i<values.size();++i)values[i]=exact(double(i)/65536);
        return values;
    }();
    double position=value*65536;size_t index=std::min(size_t(position),size_t(65535));
    return table[index]+(table[index+1]-table[index])*(position-index);
}
inline photocore::Image encoded_repair_image(const photocore::Image &linear) {
    using namespace photocore;using namespace film_cpu;
    Image encoded=linear;
    for(auto &p:encoded.pixels) {
        auto v=straight(p);
        for(int c=0;c<3;++c)v[c]=repair_transfer<false>(v[c]);
        p=pixel(v*p.a,p.a);
    }
    return encoded;
}
inline photocore::Pixel sample_repair_image(const photocore::Image &encoded,double x,double y) {
    using namespace photocore;using namespace film_cpu;
    auto p=sample_transparent(encoded,x,y);auto v=rgb(p);
    // Swift 的 PNG 貼片先仿射取樣，才轉入工作線性色域；遮罩本身始終是線性的。
    for(int c=0;c<3;++c)v[c]=repair_transfer<true>(v[c]);
    return pixel(v,p.a);
}
inline photocore::Image apply_repair_patches(photocore::Image source,const std::vector<RepairPatch> &patches) {
    using namespace photocore;using namespace film_cpu;
    for(const auto &patch:patches) {
        const auto encoded=encoded_repair_image(patch.image);
        double left=patch.x*source.width,top=(1-patch.y-patch.height)*source.height,width=patch.width*source.width,height=patch.height*source.height;
        for(double v:{left,top,width,height,left+width,top+height,patch.gain})if(!std::isfinite(v))throw std::invalid_argument("修復貼片座標非有限值");
        if(width<=0 || height<=0 || patch.gain<=0)throw std::invalid_argument("修復貼片大小或增益不符");
        long x0=long(std::floor(std::clamp(left,0.,double(source.width)))),y0=long(std::floor(std::clamp(top,0.,double(source.height))));
        long x1=long(std::ceil(std::clamp(left+width,0.,double(source.width)))),y1=long(std::ceil(std::clamp(top+height,0.,double(source.height))));
        for(long y=y0;y<y1;++y)for(long x=x0;x<x1;++x) {
            double u=(x+.5-left)/width,v=(y+.5-top)/height;
            auto replacement=sample_repair_image(encoded,u*patch.image.width-.5,v*patch.image.height-.5);
            auto mask=sample_transparent(patch.mask,u*patch.mask.width-.5,v*patch.mask.height-.5);
            double coverage=std::clamp(std::min(x+1.,left+width)-std::max(double(x),left),0.,1.)*
                std::clamp(std::min(y+1.,top+height)-std::max(double(y),top),0.,1.);
            double weight=std::clamp(double(mask.r)*coverage,0.,1.);auto &p=source.pixels[y*source.width+x];
            p=pixel(mix(rgb(p),rgb(replacement)*(patch.gain*coverage),weight),float(p.a*(1-weight)+replacement.a*coverage*weight));
        }
    }
    return source;
}
inline photocore::Image apply_repaired_geometry(const photocore::Image &source,const std::vector<RepairPatch> &patches,const CropGeometry &geometry) {
    using namespace photocore;using namespace film_cpu;
    if(patches.empty())return geometry.apply(source);
    if(std::abs(geometry.rotation)<=1e-7)return geometry.apply(apply_repair_patches(source,patches));
    struct PlacedPatch {
        const RepairPatch *patch;double left,top,width,height,imageScaleX,imageScaleY,maskScaleX,maskScaleY;
        bool uniformMask;Image encoded;
    };
    std::vector<PlacedPatch> placed;
    for(const auto &patch:patches) {
        double left=patch.x*source.width,top=(1-patch.y-patch.height)*source.height,width=patch.width*source.width,height=patch.height*source.height;
        for(double v:{left,top,width,height,left+width,top+height,patch.gain})if(!std::isfinite(v))throw std::invalid_argument("修復貼片座標非有限值");
        if(width<=0 || height<=0 || patch.gain<=0)throw std::invalid_argument("修復貼片大小或增益不符");
        bool uniform=std::all_of(patch.mask.pixels.begin(),patch.mask.pixels.end(),[](Pixel p){return p.r==1 && p.a==1;});
        placed.push_back({&patch,left,top,width,height,patch.image.width/width,patch.image.height/height,
            patch.mask.width/width,patch.mask.height/height,uniform,encoded_repair_image(patch.image)});
    }
    // 與 Swift 的延遲影像圖一致：在最終座標直接取樣來源、貼片及遮罩。
    // 先烘焙貼片再旋轉會多插值一次，改變遮罩邊緣與細節。
    return geometry.apply_sampled(source,[&](double sx,double sy) {
        auto result=sample_transparent(source,sx,sy);
        for(const auto &p:placed) {
            const auto &patch=*p.patch;
            if(sx+1<=p.left || sy+1<=p.top || sx>=p.left+p.width || sy>=p.top+p.height)continue;
            // Core Image 在貼片原座標計算裁切覆蓋，再與仿射取樣合併。
            double coverage=std::clamp(std::min(sx+1.,p.left+p.width)-std::max(sx,p.left),0.,1.)*
                std::clamp(std::min(sy+1.,p.top+p.height)-std::max(sy,p.top),0.,1.);
            if(coverage<=0)continue;
            double px=sx+.5-p.left,py=sy+.5-p.top,mx=px*p.maskScaleX-.5,my=py*p.maskScaleY-.5;
            auto mask=p.uniformMask && mx>=0 && my>=0 && mx<=patch.mask.width-1 && my<=patch.mask.height-1?
                Pixel{1,1,1,1}:sample_transparent(patch.mask,mx,my);
            double weight=std::clamp(double(mask.r)*coverage,0.,1.);if(weight<=0)continue;
            auto replacement=sample_repair_image(p.encoded,px*p.imageScaleX-.5,py*p.imageScaleY-.5);
            result=pixel(mix(rgb(result),rgb(replacement)*(patch.gain*coverage),weight),float(result.a*(1-weight)+replacement.a*coverage*weight));
        }
        return result;
    });
}
}
