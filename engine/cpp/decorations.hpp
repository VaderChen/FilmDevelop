#pragma once
#include "film_internal.hpp"
#include <ctime>
#include <iomanip>
#include <sstream>
namespace filmdevelop {
struct FrameGeometry {
    double left=0,right=0,top=0,bottom=0,gray=0;
    size_t width,height;
    FrameGeometry(size_t w,size_t h,const nlohmann::json &a):width(w),height(h) {
        if(!a.value("frameEnabled",false))return;
        double shortSide=std::min(w,h);auto style=a.value("frameStyle",std::string("whitePaperThin"));
        if(style=="whitePaperThin"){left=right=top=bottom=std::max(shortSide*.035,14.);gray=.965;}
        else if(style=="whitePaperWide"){left=right=top=bottom=std::max(shortSide*.085,32.);gray=.965;}
        else if(style=="whitePaperPolaroid"){left=right=top=std::max(shortSide*.060,24.);bottom=std::max(shortSide*.220,86.);gray=.970;}
        else if(style=="blackLine"){left=right=top=bottom=std::max(shortSide*.030,12.);gray=.035;}
        else if(style=="filmStrip"){left=right=std::max(shortSide*.090,34.);top=bottom=std::max(shortSide*.025,10.);gray=.030;}
        else if(style=="cleanInset"){left=right=top=bottom=std::max(shortSide*.055,22.);gray=.955;}
        else throw std::invalid_argument("外框樣式不符");
        width=size_t(std::lround(w+left+right));height=size_t(std::lround(h+top+bottom));
    }
};
namespace decorations {
using namespace photocore;using namespace photocore::film_cpu;
inline double linear(double v){return v<=.04045?v/12.92:std::pow((v+.055)/1.055,2.4);}
inline void over(Pixel &p,V color,double opacity){opacity=std::clamp(opacity,0.,1.);p=pixel(rgb(p)*(1-opacity)+color*opacity,float(p.a*(1-opacity)+opacity));}
// Quartz 的矩形填色與筆畫皆輸出 8-bit 遮罩，但矩形先量化兩軸邊界。
// 筆畫先合併面積才混色，避免框線轉角被多次 source-over。
inline double rectangle_area(long x,long y,double left,double top,double width,double height) {
    return std::clamp(std::min(x+1.,left+width)-std::max(double(x),left),0.,1.)*
        std::clamp(std::min(y+1.,top+height)-std::max(double(y),top),0.,1.);
}
inline double rectangle_coverage(long x,long y,double left,double top,double width,double height) {
    auto span=[](long pixel,double start,double length) {
        return std::clamp(std::min(double(pixel+1)*256,std::round((start+length)*256))-
            std::max(double(pixel)*256,std::round(start*256))-1,0.,255.);
    };
    return std::floor(span(x,left,width)*span(y,top,height)/255)/255;
}
inline void fill(Image &image,double left,double top,double width,double height,V color,double opacity=1) {
    long x0=long(std::max(0.,std::floor(left))),y0=long(std::max(0.,std::floor(top))),x1=long(std::min(double(image.width),std::ceil(left+width))),y1=long(std::min(double(image.height),std::ceil(top+height)));
    for(long y=y0;y<y1;++y)for(long x=x0;x<x1;++x)over(image.pixels[y*image.width+x],color,opacity*rectangle_coverage(x,y,left,top,width,height));
}
inline void stroke(Image &image,double left,double top,double width,double height,double lineWidth,V color,double opacity) {
    long x0=long(std::max(0.,std::floor(left))),y0=long(std::max(0.,std::floor(top))),x1=long(std::min(double(image.width),std::ceil(left+width))),y1=long(std::min(double(image.height),std::ceil(top+height)));
    for(long y=y0;y<y1;++y)for(long x=x0;x<x1;++x) {
        if(y>=top+lineWidth && y+1<=top+height-lineWidth && x>=left+lineWidth && x+1<=left+width-lineWidth) {
            x=long(std::floor(left+width-lineWidth))-1;continue;
        }
        double area=rectangle_area(x,y,left,top,width,height);
        if(width>2*lineWidth && height>2*lineWidth)area-=rectangle_area(x,y,left+lineWidth,top+lineWidth,width-2*lineWidth,height-2*lineWidth);
        if(area>0)over(image.pixels[y*image.width+x],color,opacity*std::min(std::floor(area*256),255.)/255);
    }
}
struct Point {double x,y;};
using Polygon=std::vector<Point>;
inline void segment(std::vector<Polygon> &paths,Point start,Point end,double width,double origin=0) {
    double length=std::hypot(end.x-start.x,end.y-start.y);if(length<=0)return;
    double dx=(end.x-start.x)/length*width*.5,dy=(end.y-start.y)/length*width*.5;
    paths.push_back({{start.x+origin,start.y},{start.x+dx-dy+origin,start.y+dy+dx},{end.x-dx-dy+origin,end.y-dy+dx},{end.x+origin,end.y},{end.x-dx+dy+origin,end.y-dy-dx},{start.x+dx+dy+origin,start.y+dy-dx}});
}
inline void date(Image &image,const FrameGeometry &frame,size_t sourceWidth,size_t sourceHeight,const std::string &style) {
    std::time_t now=std::time(nullptr);std::tm date=*std::localtime(&now);std::ostringstream text;
    if(style=="numeric")text<<std::put_time(&date,"%Y.%m.%d");else if(style=="slash")text<<std::put_time(&date,"%y/%m/%d");else if(style=="compact")text<<std::put_time(&date,"%Y%m%d");else if(style=="japanese")text<<date.tm_year+1900<<'Y'<<date.tm_mon+1<<'M'<<date.tm_mday<<'D';else throw std::invalid_argument("日期樣式不符");
    const int digits[]{0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f};
    const Point starts[]{{.08,.045},{.555,.105},{.555,.555},{.08,.955},{.045,.555},{.045,.105},{.08,.5}};
    const Point ends[]{{.52,.045},{.555,.445},{.555,.895},{.52,.955},{.045,.895},{.045,.445},{.52,.5}};
    std::vector<Polygon> paths;double origin=0;
    for(char c:text.str()) {
        if(c>='0' && c<='9'){for(int k=0;k<7;++k)if(digits[c-'0']&(1<<k))segment(paths,starts[k],ends[k],.075,origin);origin+=.75;}
        else if(c=='.'){paths.push_back({{origin+.015,.89},{origin+.110,.89},{origin+.110,.985},{origin+.015,.985}});origin+=.27;}
        else if(c=='/'){segment(paths,{.04,.94},{.38,.05},.065,origin);origin+=.53;}
        else {
            // 年、月、日以自製幾何筆畫呈現，不依賴 Windows 未必安裝的字型。
            auto line=[&](Point a,Point b){segment(paths,a,b,.055,origin);};
            if(c=='Y'){line({.2,.07},{.08,.28});line({.17,.18},{.75,.18});line({.23,.22},{.23,.55});line({.23,.38},{.73,.38});line({.08,.61},{.8,.61});line({.52,.18},{.52,.94});}
            else if(c=='M'){line({.18,.12},{.18,.77});line({.18,.77},{.08,.94});line({.18,.12},{.71,.12});line({.71,.12},{.71,.92});line({.71,.92},{.58,.87});line({.2,.39},{.69,.39});line({.2,.64},{.69,.64});}
            else {line({.17,.13},{.17,.91});line({.17,.13},{.71,.13});line({.71,.13},{.71,.91});line({.17,.52},{.71,.52});line({.17,.88},{.71,.88});}
            origin+=.95;
        }
    }
    double x0=1e10,y0=1e10,x1=-1e10,y1=-1e10;for(auto &path:paths)for(auto p:path){x0=std::min(x0,p.x);x1=std::max(x1,p.x);y0=std::min(y0,p.y);y1=std::max(y1,p.y);}
    double shortSide=std::min(sourceWidth,sourceHeight),padding=shortSide*.038,height=std::min(shortSide*.024,(sourceWidth-padding*2)/std::max(x1-x0,1.));
    double bx=-1e10,by=-1e10;for(auto &path:paths)for(auto &p:path){p={height*(p.x-.035*p.y),height*p.y};bx=std::max(bx,p.x);by=std::max(by,p.y);}
    double dx=frame.left+sourceWidth-padding-bx,dy=frame.top+sourceHeight-padding-by;
    x0=y0=1e10;x1=y1=-1e10;for(auto &path:paths)for(auto &p:path){p.x+=dx;p.y+=dy;x0=std::min(x0,p.x);x1=std::max(x1,p.x);y0=std::min(y0,p.y);y1=std::max(y1,p.y);}
    int margin=std::max(2,int(std::ceil(height*.5))),left=int(std::floor(x0))-margin,top=int(std::floor(y0))-margin,width=int(std::ceil(x1))-left+margin,rows=int(std::ceil(y1))-top+margin;
    if(width<=0 || rows<=0)return;
    Image core(width,rows),stroke(width,rows);
    auto distance=[](Point p,Point a,Point b){double vx=b.x-a.x,vy=b.y-a.y,t=std::clamp(((p.x-a.x)*vx+(p.y-a.y)*vy)/(vx*vx+vy*vy),0.,1.);return std::hypot(p.x-a.x-vx*t,p.y-a.y-vy*t);};
    for(int y=0;y<rows;++y)for(int x=0;x<width;++x){double filled=0,outlined=0;
        for(int sy=0;sy<4;++sy)for(int sx=0;sx<4;++sx){Point q{left+x+(sx+.5)/4,top+y+(sy+.5)/4};bool inside=false;double edge=1e10;
            for(const auto &path:paths){bool within=false;for(size_t i=0,j=path.size()-1;i<path.size();j=i++){auto a=path[j],b=path[i];if((a.y>q.y)!=(b.y>q.y) && q.x<(b.x-a.x)*(q.y-a.y)/(b.y-a.y)+a.x)within=!within;edge=std::min(edge,distance(q,a,b));}inside=inside||within;}
            if(inside)filled+=1./16;
            if(edge<=height*.009)outlined+=1./16;
        }
        core.pixels[y*width+x]=pixel(V(filled),1);stroke.pixels[y*width+x]=pixel(V(outlined),1);}
    auto halo=gaussian(core,std::max(.1,height*.09),false),glow=gaussian(stroke,std::max(.1,height*.0175),false);
    const V haloInk{1,linear(.16),linear(.015)},ink{1,linear(.43),linear(.09)},glowInk{1,linear(.48),linear(.12)},outlineInk{1,linear(.71),linear(.31)};
    for(int y=0;y<rows;++y)for(int x=0;x<width;++x){int xx=left+x,yy=top+y;if(xx<frame.left || yy<frame.top || xx>=frame.left+sourceWidth || yy>=frame.top+sourceHeight || xx<0 || yy<0 || xx>=int(image.width) || yy>=int(image.height))continue;size_t i=y*width+x;auto &p=image.pixels[yy*image.width+xx];over(p,haloInk,halo.pixels[i].r*.55);over(p,ink,core.pixels[i].r*.94);over(p,glowInk,glow.pixels[i].r*.45);over(p,outlineInk,stroke.pixels[i].r*.38);}
}
}
inline photocore::Image decorate(photocore::Image source,const nlohmann::json &adjustment,const photocore::film_cpu::Database *data=nullptr) {
    using namespace photocore;using namespace film_cpu;using namespace decorations;
    if(!adjustment.value("frameEnabled",false) && !adjustment.value("dateEnabled",false))return source;
    FrameGeometry frame(source.width,source.height,adjustment);Image canvas(frame.width,frame.height);
    for(auto &p:canvas.pixels)p=adjustment.value("frameEnabled",false)?pixel(V(linear(frame.gray)),1):Pixel{0,0,0,0};
    if(adjustment.value("frameEnabled",false)) {
        auto style=adjustment.value("frameStyle",std::string("whitePaperThin"));double shortSide=std::min(source.width,source.height),fine=std::max(shortSide*.004,1.5),medium=std::max(shortSide*.01,3.);
        if(style=="filmStrip"){
            double strip=std::max(frame.left,frame.width-frame.left-source.width),gap=strip*.62;
            for(double y=gap*.7;y<frame.height-gap*.4;y+=gap){fill(canvas,strip*.33,y,strip*.34,strip*.24,V(1),.65);fill(canvas,frame.width-strip*.67,y,strip*.34,strip*.24,V(1),.65);}
        } else {
            double width=style=="blackLine"?medium:fine,offset=style=="cleanInset"?medium*1.4+fine*.5:width;
            double l=frame.left-offset,t=frame.top-offset,w=source.width+2*offset,h=source.height+2*offset;
            V color(style=="blackLine"?0:linear(style=="cleanInset"?.72:.82));double alpha=style=="blackLine"?.9:(style=="cleanInset"?.55:.28);
            stroke(canvas,l,t,w,h,width,color,alpha);
        }
    }
    auto at=[&](long x,long y){return source.pixels[size_t(std::clamp(y,0L,long(source.height)-1))*source.width+size_t(std::clamp(x,0L,long(source.width)-1))];};
    struct Tap {long dx,dy;double weight;};
    std::array<std::vector<Tap>,9> kernels;
    if(data && data->frame_sampling.empty())throw std::runtime_error("缺少框圖取樣相位表");
    if(data && !data->frame_sampling.empty()) {
        auto phase=[](double offset){return size_t(std::clamp(std::round((offset-std::floor(offset))*256),0.,255.));};
        auto offset=(phase(frame.top)*256+phase(frame.left))*9;
        for(size_t i=0;i<9;++i) {
            const auto &weights=data->frame_sampling[data->frame_phase_indices[offset+i]];
            for(int j=0;j<9;++j)if(weights[j]>0)kernels[i].push_back({j%3-1,j/3-1,weights[j]});
        }
    }
    size_t x0=size_t(std::floor(frame.left)),y0=size_t(std::floor(frame.top)),x1=std::min(canvas.width,size_t(std::ceil(frame.left+source.width))),y1=std::min(canvas.height,size_t(std::ceil(frame.top+source.height)));
    for(size_t y=y0;y<y1;++y)for(size_t x=x0;x<x1;++x){double coverage=x>x0 && x<x1-1 && y>y0 && y<y1-1?1:rectangle_coverage(long(x),long(y),frame.left,frame.top,source.width,source.height);if(coverage<=0)continue;
        V color;double alpha;
        if(!kernels[0].empty() && source.width>=3 && source.height>=3) {
            long ix=long(x)-long(std::floor(frame.left)),iy=long(y)-long(std::floor(frame.top));
            auto category=[](long index,size_t size){return index<=0?1:(index>=long(size)?2:0);};
            int cx=category(ix,source.width),cy=category(iy,source.height);
            if(cx)ix=std::clamp(ix,1L,long(source.width)-2);
            if(cy)iy=std::clamp(iy,1L,long(source.height)-2);
            color=V(0);alpha=0;
            for(const auto &tap:kernels[cy*3+cx]) {
                auto p=at(ix+tap.dx,iy+tap.dy);color+=rgb(p)*tap.weight;alpha+=p.a*tap.weight;
            }
        } else {
            double sx=x-frame.left,sy=y-frame.top;long ix=long(std::floor(sx)),iy=long(std::floor(sy));double fx=sx-ix,fy=sy-iy;
            auto a=at(ix,iy),b=at(ix+1,iy),c=at(ix,iy+1),d=at(ix+1,iy+1);
            color=mix(mix(rgb(a),rgb(b),fx),mix(rgb(c),rgb(d),fx),fy);alpha=(a.a*(1-fx)+b.a*fx)*(1-fy)+(c.a*(1-fx)+d.a*fx)*fy;
        }
        auto &p=canvas.pixels[y*canvas.width+x];p=pixel(rgb(p)*(1-alpha*coverage)+color*coverage,float(p.a*(1-alpha*coverage)+alpha*coverage));}
    if(adjustment.value("dateEnabled",false))date(canvas,frame,source.width,source.height,adjustment.value("dateStyle",std::string("numeric")));
    return canvas;
}
}
