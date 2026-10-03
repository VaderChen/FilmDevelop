#include "plan_fade.hpp"
#include "skin_math.hpp"
#include "digital_math.hpp"
#include "natural_skin.hpp"
#include <iostream>
#include <stdexcept>
using namespace photocore;
using namespace photocore::film_cpu;
namespace {
void require(bool value,const char *message) {if(!value)throw std::runtime_error(message);}
Json zones(int s,int m,int h) {
    return {{"shadows",{{"fade",s}}},{"midtones",{{"fade",m}}},{"highlights",{{"fade",h}}}};
}
}
int main() {try {
    std::cout<<"自然膚質回歸："<<skin_verification::verify().dump()<<'\n';
    int curves=0;
    for(double strength:{.25,.5,.75,1.})for(int s:{0,25,50,75,100})
    for(int m:{0,25,50,75,100})for(int h:{0,25,50,75,100}) {
        auto curve=plan_fade_lifts(zones(s,m,h),strength);
        V previous(-1);
        for(int i=0;i<=4096;++i) {
            const double y=i/4096.;const auto out=plan_fade_pixel(pixel(V(y),1),curve);const V color=rgb(out);
            for(int c=0;c<3;++c)require(color[c]>previous[c],"淡化灰階反轉或壓平");
            require(out.a==1,"淡化改變 alpha");previous=color;
        }
        ++curves;
    }
    for(double scale:{1.,.5,.25,.125,.0625}) {
        const V skin=V(.457,.234,.162)*scale;
        require(skin_coverage(skin)>.5,"欠曝膚色辨識失效");
        for(V color:{V(0),V(.4),V(.08,.18,.65),V(.08,.6,.1)})
            require(skin_coverage(color*scale)<.02,"非膚色被新遮罩誤判");
    }
    auto curve=plan_fade_lifts(zones(100,100,100),1);
    for(Pixel p:{Pixel{.2f,.4f,.1f,1},Pixel{.8f,.56f,.32f,.4f},Pixel{-.03f,.2f,.1f,1},Pixel{0,0,0,0}}) {
        const auto output=plan_fade_pixel(p,curve);const V expected=rgb(p)*(V(1)-V(.25,.20,.18)*.18)+V(.18*p.a);
        for(int c=0;c<3;++c)require(std::abs(rgb(output)[c]-expected[c])<1e-6,"全區淡化改變既有色彩或 HDR");
        require(output.a==p.a,"全區淡化改變 alpha");
    }
    Image noisy(128,64);uint32_t seed=7;double before=0;
    for(auto &p:noisy.pixels) {seed=seed*1664525u+1013904223u;const double noise=(double(seed>>8)/0xffffff-.5)*.06;p=pixel(V(.4+noise),1);}
    auto reduced=denoise(noisy,.25);double after=0;
    for(size_t y=8;y<56;++y)for(size_t x=8;x<120;++x) {
        const size_t i=y*128+x;before+=std::pow(noisy.pixels[i].r-.4,2);after+=std::pow(reduced.pixels[i].r-.4,2);
    }
    require(after<before*.6,"中段降噪效果不足");
    // 改變覆蓋率不應改變平坦區顏色；包含 SDR、HDR 與合法的負通道。
    for(V color:{V(.4,.25,.12),V(2,.8,.25),V(-.05,.2,.3)}) {
        Image edge(35,16);const double alphas[]={0,.001,.1,.5,1};
        for(size_t y=0;y<edge.height;++y)for(size_t x=0;x<edge.width;++x) {
            double a=alphas[x/7];edge.pixels[y*edge.width+x]=pixel(color*a,a);
        }
        for(double amount:{.25,.5,1.})for(bool skin:{false,true}) {
            auto output=skin?smooth_channels(edge,3,.002+amount*.018):denoise(edge,amount);
            for(size_t i=0;i<edge.pixels.size();++i) {
                const auto p=output.pixels[i];require(p.a==edge.pixels[i].a,"平滑改變 alpha");
                for(int c=0;c<3;++c)require(std::abs(straight(p)[c]-(p.a>0?color[c]:0))<1e-5,"平滑受透明邊界污染");
            }
        }
    }
    for(double alpha:{.001,.25,1.}) {
        double previous=-1;
        for(double value:{0.,1e-8,1e-7,1e-6,1e-5,.18,1.,2.}) {
            Image source(32,16);for(auto &p:source.pixels)p=pixel(V(value*alpha),alpha);
            auto output=local_tone(source,{{"hdrAmount",100}},1,true);
            auto p=output.pixels[8*32+16];double y=p.r/p.a;
            require(p.a==source.pixels[0].a && std::isfinite(y),"HDR 改變 alpha 或產生非有限數");
            require(y>previous,"HDR 極暗階調壓平或反轉");
            if(value==0)require(y==0,"HDR 抬升固定黑位");
            if(value>0 && value<=1e-5)require(std::abs(y-1.52*value)<value*.001+3e-11,"HDR 原點斜率不正確");
            if(value>=1)require(std::abs(y-value)<1e-5,"HDR 裁掉高光範圍");
            previous=y;
        }
        Image black(32,16);for(auto &p:black.pixels)p=pixel(V(0),alpha);
        Json a={{"hdrAmount",100},{"hdrToneCurve",{{"black",5},{"shadows",30},{"midtones",50},{"highlights",75},{"white",100},{"detail",0}}}};
        auto lifted=local_tone(black,a,1,true);require(std::abs(lifted.pixels[0].r/alpha-.05)<1e-5,"HDR 忽略明確的黑位抬升");
    }
    int colorCases=0;
    for(V color:{V(.9,.03,.01),V(.04,.7,.08),V(.05,.1,.9),V(.18),V(.003,.001,.0005),V(2,.8,.2),V(-.02,.2,.1)})
    for(double vibrance:{-1.,0.,1.})for(double saturation:{-1.,0.,1.}) {
        auto output=lab_color(color,vibrance,saturation);
        require(std::abs(dot(output,exact_w)-dot(color,exact_w))<1e-8,"Lab 色彩調整改變亮度");
        for(int c=0;c<3;++c)require(output[c]>=std::min({0.,color.x,color.y,color.z})-1e-8 && output[c]<=std::max({1.,color.x,color.y,color.z})+1e-8,"Lab 色域約束失效");
        if(saturation==-1)require(std::abs(output.x-output.y)<1e-8 && std::abs(output.y-output.z)<1e-8,"去飽和未成為中性色");
        ++colorCases;
    }
    for(double contrast:{-1.,0.,1.})for(double highlights:{-1.,0.,1.})for(double shadows:{-1.,0.,1.}) {
        double previous=-1e9;
        for(int i=0;i<=20000;++i) {
            auto point=local_tone_point(-12+i*.001,contrast,highlights,shadows);
            require(std::isfinite(point.x) && point.x>previous && point.y>0,"局部階調反轉或壓平");previous=point.x;
        }
    }
    std::cout<<"數位修圖回歸通過："<<curves<<" 條淡化曲線、欠曝遮罩、HDR／alpha，降噪 MSE 比="<<after/before<<'\n';
    std::cout<<"數學不變量：透明邊界 18 組、HDR 極暗階調 24 組／自訂黑位 3 組、Lab "<<colorCases<<" 組、局部階調 27 條曲線\n";
    return 0;
}catch(const std::exception &error){std::cerr<<error.what()<<'\n';return 1;}}
