#include "repair.hpp"
#include <array>
#include <cmath>
#include <limits>
#include <sstream>
namespace filmdevelop {
using namespace photocore;
using namespace photocore::film_cpu;
namespace {
struct Point {double x,y;};
struct Stroke {double radius;std::vector<Point> points;};
double distance(Point p,Point a,Point b) {
    double dx=b.x-a.x,dy=b.y-a.y,length=dx*dx+dy*dy,t=length>0?std::clamp(((p.x-a.x)*dx+(p.y-a.y)*dy)/length,0.,1.):0;
    return std::hypot(p.x-a.x-t*dx,p.y-a.y-t*dy);
}
double encode(double v){return v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055;}
double decode(double v){return v<=.04045?v/12.92:std::pow((v+.055)/1.055,2.4);}
}
Json repair_photo(const Image &source,const Json &strokes,const std::filesystem::path &directory,NeuralRuntime &runtime,Codec &codec) {
    if(!strokes.is_array() || strokes.empty() || strokes.size()>128)throw Failure("invalidMask","請先在照片上塗抹要修復的區域。");
    size_t count=0;std::vector<Stroke> lines;
    double x0=source.width,y0=source.height,x1=0,y1=0;
    for(const auto &stroke:strokes) {
        double radius=stroke.at("radius").get<double>();const auto &points=stroke.at("points");
        if(!std::isfinite(radius) || radius<=0 || radius>.5 || !points.is_array() || points.empty())throw Failure("invalidMask","修復筆刷資料不符");
        count+=points.size();if(count>20000)throw Failure("invalidMask","修復筆刷資料過大");
        Stroke line{radius*source.width,{}};
        for(const auto &point:points) {
            double x=point.at("x").get<double>(),y=point.at("y").get<double>();
            if(!std::isfinite(x)||!std::isfinite(y)||x<0||x>1||y<0||y>1)throw Failure("invalidMask","修復座標不符");
            x*=source.width;y*=source.height;line.points.push_back({x,y});
            x0=std::min(x0,x-line.radius);y0=std::min(y0,y-line.radius);x1=std::max(x1,x+line.radius);y1=std::max(y1,y+line.radius);
        }
        lines.push_back(std::move(line));
    }
    double margin=std::max(64.,std::max(x1-x0,y1-y0)*.5);
    x0=std::floor(std::max(0.,x0-margin));y0=std::floor(std::max(0.,y0-margin));
    x1=std::ceil(std::min(double(source.width),x1+margin));y1=std::ceil(std::min(double(source.height),y1+margin));
    const double roiWidth=x1-x0,roiHeight=y1-y0;
    if(roiWidth<=0 || roiHeight<=0)throw Failure("invalidMask","修復區域不符");
    constexpr int edge=512;constexpr size_t area=edge*edge;
    double scale=std::min(edge/roiWidth,edge/roiHeight),fitWidth=roiWidth*scale,fitHeight=roiHeight*scale,fitX=(edge-fitWidth)*.5,fitY=(edge-fitHeight)*.5;
    auto at=[&](long x,long y){return source.pixels[size_t(std::clamp(y,long(y0),long(y1)-1))*source.width+size_t(std::clamp(x,long(x0),long(x1)-1))];};
    Image input(edge,edge),mask(edge,edge);double gain=1;
    for(int y=0;y<edge;++y)for(int x=0;x<edge;++x) {
        double sx=(x+.5-fitX)/scale+x0-.5,sy=(y+.5-fitY)/scale+y0-.5;long ix=long(std::floor(sx)),iy=long(std::floor(sy));
        double fx=sx-ix,fy=sy-iy;
        V rgb=mix(mix(straight(at(ix,iy)),straight(at(ix+1,iy)),fx),mix(straight(at(ix,iy+1)),straight(at(ix+1,iy+1)),fx),fy);
        for(int c=0;c<3;++c)if(std::isfinite(rgb[c]))gain=std::max(gain,rgb[c]);else throw Failure("invalidImage","修復來源含非有限色彩數值");
        input.pixels[y*edge+x]=pixel(rgb,1);mask.pixels[y*edge+x]={0,0,0,1};
    }
    // 筆刷以原片座標定義；只處理每段的包圍盒，不隨筆刷點數遍歷整張照片。
    for(const auto &stroke:lines) {
        auto fit=[&](Point p){return Point{(p.x-x0)*scale+fitX,(p.y-y0)*scale+fitY};};
        double radius=std::max(1.,stroke.radius*scale);
        for(size_t i=0;i<stroke.points.size();++i) {
            Point a=fit(stroke.points[i]),b=fit(stroke.points[i?i-1:i]);
            int left=int(std::floor(std::max(0.,std::min(a.x,b.x)-radius-1))),right=int(std::ceil(std::min(double(edge),std::max(a.x,b.x)+radius+1)));
            int top=int(std::floor(std::max(0.,std::min(a.y,b.y)-radius-1))),bottom=int(std::ceil(std::min(double(edge),std::max(a.y,b.y)+radius+1)));
            for(int y=top;y<bottom;++y)for(int x=left;x<right;++x) {
                double coverage=0;for(double dy:{.25,.75})for(double dx:{.25,.75})coverage+=distance({x+dx,y+dy},a,b)<=radius?.25:0;
                auto &p=mask.pixels[y*edge+x];p=pixel(V(std::max(double(p.r),coverage)),1);
            }
        }
    }
    Tensor photo{"image",{1,3,edge,edge},std::vector<float>(area*3)},paint{"mask",{1,1,edge,edge},std::vector<float>(area)};
    for(size_t i=0;i<area;++i) {
        auto rgb=straight(input.pixels[i]);for(int c=0;c<3;++c)photo.values[c*area+i]=float(std::round(std::clamp(encode(rgb[c]/gain),0.,1.)*255)/255);
        paint.values[i]=mask.pixels[i].r>0?1:0;
    }
    auto output=runtime.run(directory/L"lama_fp32.onnx",{photo,paint});
    if(output.size()!=1 || output[0].shape!=std::vector<int64_t>{1,3,edge,edge})throw Failure("invalidModel","修復模型輸出尺寸不符");
    auto softened=gaussian(mask,.8,false);
    int left=int(std::floor(fitX)),top=int(std::floor(fitY)),right=int(std::ceil(fitX+fitWidth)),bottom=int(std::ceil(fitY+fitHeight));
    Image repaired(right-left,bottom-top),coverage(right-left,bottom-top);
    for(int y=top;y<bottom;++y)for(int x=left;x<right;++x) {
        size_t i=y*edge+x,j=(y-top)*repaired.width+x-left;V rgb;
        for(int c=0;c<3;++c){double v=output[0].values[c*area+i];if(!std::isfinite(v))throw Failure("invalidModel","修復模型輸出含非有限數值");rgb[c]=decode(std::clamp(v/255,0.,1.));}
        repaired.pixels[j]=pixel(rgb,1);
        // 貼片遮罩讀取時不做 ICC 轉換，將覆蓋率直接保存為 8 bit 樣本。
        coverage.pixels[j]=pixel(V(decode(std::clamp(double(softened.pixels[i].r),0.,1.))),1);
    }
    GUID uuid{};checked(CoCreateGuid(&uuid),"無法建立修復紀錄識別");wchar_t text[40]{};StringFromGUID2(uuid,text,40);std::wstring identity(text);identity=identity.substr(1,identity.size()-2);
    return {{"id",utf8(identity)},{"x",x0/source.width},{"y",1-y1/source.height},{"width",roiWidth/source.width},{"height",roiHeight/source.height},
        {"linearGain",gain},{"imageData",base64(codec.encode(repaired,"png",8,1))},{"maskData",base64(codec.encode(coverage,"png",8,1))}};
}
}
