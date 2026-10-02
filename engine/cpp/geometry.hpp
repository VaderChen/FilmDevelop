#pragma once
#include "film_internal.hpp"

namespace filmdevelop {
// Core Image／Metal 的線性取樣權重為 8-bit；越界維持透明，RGB 為預乘值。
inline photocore::Pixel sample_transparent(const photocore::Image &source,double x,double y) {
    using namespace photocore;using namespace film_cpu;
    if(!std::isfinite(x)||!std::isfinite(y)||x<=-1||y<=-1||x>=double(source.width)||y>=double(source.height))return Pixel{0,0,0,0};
    auto at=[&](long xx,long yy){return xx<0 || yy<0 || xx>=long(source.width) || yy>=long(source.height)?Pixel{0,0,0,0}:source.pixels[yy*source.width+xx];};
    long ix=long(std::floor(x)),iy=long(std::floor(y));
    double fx=std::floor((x-ix)*256+.5)/256,fy=std::floor((y-iy)*256+.5)/256;
    auto a=at(ix,iy),b=at(ix+1,iy),c=at(ix,iy+1),d=at(ix+1,iy+1);
    return pixel(mix(mix(rgb(a),rgb(b),fx),mix(rgb(c),rgb(d),fx),fy),
        float((a.a+(b.a-a.a)*fx)*(1-fy)+(c.a+(d.a-c.a)*fx)*fy));
}
// UI 的 Y 向下、Core Image 的 Y 向上；保存座標與 Swift 一致，像素只轉換一次。
struct CropGeometry {
    double x=0,y=0,width,height,rotation=0,scale=1;
    long left,bottom;
    size_t columns,rows;
    CropGeometry(size_t w,size_t h,const nlohmann::json &a):width(w),height(h) {
        using photocore::film_cpu::number;
        auto aspect=a.value("cropAspectRatio",std::string("original"));
        double ratio=double(w)/h;
        if(aspect=="threeTwo")ratio=1.5;
        else if(aspect=="oneOne")ratio=1;
        else if(aspect=="fourThree")ratio=4./3;
        else if(aspect=="sixteenNine")ratio=16./9;
        else if(aspect!="original" && aspect!="source" && aspect!="free")throw std::invalid_argument("裁切比例不符");
        if(h>w && aspect!="original" && aspect!="source" && aspect!="free")ratio=1/ratio;
        if(aspect!="original") {
            if(double(w)/h>ratio)width=h*ratio;else height=w/ratio;
            width*=number(a,aspect=="free"?"cropWidth":"cropScale",100,1,100)/100;
            height*=number(a,aspect=="free"?"cropHeight":"cropScale",100,1,100)/100;
            x=(w-width)*(number(a,"cropHorizontalPosition",0,-100,100)/100+1)/2;
            y=(h-height)*(1-number(a,"cropVerticalPosition",0,-100,100)/100)/2;
        }
        left=long(std::floor(x));bottom=long(std::floor(y));
        columns=size_t(std::ceil(x+width)-left);rows=size_t(std::ceil(y+height)-bottom);
        rotation=number(a,"cropRotation",0,-45,45)*3.14159265358979323846/180;
        if(std::abs(rotation)>1e-7)scale=std::max(std::abs(std::cos(rotation))+std::abs(std::sin(rotation))*h/w,
            std::abs(std::cos(rotation))+std::abs(std::sin(rotation))*w/h);
    }
    bool is_identity(const photocore::Image &source) const {
        return columns==source.width && rows==source.height && left==0 && bottom==0 && std::abs(rotation)<=1e-7;
    }
    photocore::Image apply(const photocore::Image &source) const {
        if(is_identity(source))return source;
        return apply_sampled(source,[&](double sx,double sy){return sample_transparent(source,sx,sy);});
    }
    template<class Sample> photocore::Image apply_sampled(const photocore::Image &source,Sample sample) const {
        using namespace photocore;using namespace film_cpu;
        Image result(columns,rows);double c=std::cos(rotation),s=std::sin(rotation);
        for(size_t row=0;row<rows;++row)for(size_t column=0;column<columns;++column) {
            double dx=left+column+.5-source.width*.5,dy=bottom+rows-row-.5-source.height*.5;
            double sx=(c*dx-s*dy)/scale+source.width*.5-.5,sy=source.height*.5-(s*dx+c*dy)/scale-.5;
            result.pixels[row*columns+column]=sample(sx,sy);
            double coverageX=std::clamp(std::min(left+column+1.,x+width)-std::max(double(left+column),x),0.,1.);
            double coverageY=std::clamp(std::min(bottom+rows-row+0.,y+height)-std::max(double(bottom+rows-row-1),y),0.,1.);
            auto &p=result.pixels[row*columns+column];double coverage=coverageX*coverageY;
            p=pixel(rgb(p)*coverage,float(p.a*coverage));
        }
        return result;
    }
};
inline nlohmann::json source_editing_adjustment(nlohmann::json a) {
    a["cropAspectRatio"]="original";a["cropRotation"]=0;a["cropScale"]=100;a["cropWidth"]=100;a["cropHeight"]=100;
    a["cropHorizontalPosition"]=0;a["cropVerticalPosition"]=0;a["frameEnabled"]=false;a["dateEnabled"]=false;
    return a;
}
}
