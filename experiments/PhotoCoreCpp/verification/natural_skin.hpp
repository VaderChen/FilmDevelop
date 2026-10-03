#pragma once
#include "skin_math.hpp"
#include <stdexcept>

namespace photocore::skin_verification {
using namespace film_cpu;
inline Json verify() {
    auto check=[](bool value,const char *message){if(!value)throw std::runtime_error(message);};
    int colorCases=0;double maxChromaError=0;
    for(V color:{V(.457,.234,.162),V(.24,.16,.14),V(.65,.49,.31),V(.05,.022,.014),V(.35)})
    for(double alpha:{.001,.4,1.})for(double amount:{.25,.5,1.})for(double mask:{0.,.5,1.}) {
        auto source=pixel(color*alpha,alpha),output=skin_whiten(source,mask,amount);
        check(source.a==output.a,"自然美白改變 alpha");
        auto sourceRGB=straight(source),outputRGB=straight(output);
        auto before=rgb_to_lab({sourceRGB.x,sourceRGB.y,sourceRGB.z}),after=rgb_to_lab({outputRGB.x,outputRGB.y,outputRGB.z});
        if(mask>0)check(after[0]>before[0],"自然美白未增加明度");
        else check(output.r==source.r && output.g==source.g && output.b==source.b,"零遮罩仍改變色彩");
        for(int c=1;c<3;++c)maxChromaError=std::max(maxChromaError,std::abs(after[c]-before[c]));
        ++colorCases;
    }
    check(maxChromaError<.003,"自然美白改變原始 Lab 色相／彩度");
    for(double amount:{.25,.5,1.}) {
        double previous=-1;
        for(int i=0;i<=4096;++i) {
            const double y=i/4096.*1.25;auto output=skin_whiten(pixel(V(y),1),1,amount);
            check(output.r>previous,"自然美白在黑白或 HDR 邊界反轉");previous=output.r;
            if(y>=1)check(output.r==float(y),"自然美白裁切 HDR");
            if(i==0)check(output.r==0,"自然美白抬升純黑");
        }
    }
    const double highlightLift=skin_whiten(pixel(V(.95),1),1,1).r-float(.95);
    const double midtoneLift=skin_whiten(pixel(V(.35),1),1,1).r-float(.35);
    check(highlightLift<midtoneLift*.05,"自然美白未保護高光");
    check(midtoneLift>.1 && midtoneLift<.15,"美白滑桿滿值未達預期提亮幅度");
    Image texture(256,32),mask(256,32);
    for(size_t y=0;y<texture.height;++y)for(size_t x=0;x<texture.width;++x) {
        texture.pixels[y*texture.width+x]=pixel(V(.3*std::exp2(.06*std::sin(2*3.141592653589793*x/16)+(x%2==0?.012:-.012))),1);
        mask.pixels[y*texture.width+x]=pixel(V(1),1);
    }
    auto output=skin_smooth(texture,mask,3.15,1);
    auto amplitudes=[](const Image &image){V sum;for(size_t x=32;x<224;++x){double value=std::log2(image.pixels[16*256+x].r/.3);sum.x+=value*std::sin(2*3.141592653589793*x/16);sum.y+=value*(x%2==0?1:-1);}return sum;};
    V before=amplitudes(texture),after=amplitudes(output);
    const double midRatio=after.x/before.x,poreRatio=after.y/before.y;
    check(midRatio<.4 && midRatio>.2,"柔膚未選擇性降低中尺度不均");
    check(poreRatio>.8 && poreRatio<=1.02,"柔膚損失過多微紋理或產生銳化");
    Image edge(128,32),edgeMask(128,32);const double alphas[]={0,.001,.4,1};
    for(size_t y=0;y<edge.height;++y)for(size_t x=0;x<edge.width;++x) {
        double alpha=x<32?1:alphas[(x-32)/24];
        edge.pixels[y*edge.width+x]=pixel((x<32?V(.8,.1,.4):V(.4,.25,.12))*alpha,alpha);
        edgeMask.pixels[y*edge.width+x]=pixel(V(x<32?0:1),1);
    }
    auto protectedImage=skin_smooth(edge,edgeMask,3.15,1);
    for(size_t i=0;i<edge.pixels.size();++i) {
        check(edge.pixels[i].a==protectedImage.pixels[i].a,"柔膚改變透明度");
        for(int c=0;c<3;++c)check(std::abs(rgb(edge.pixels[i])[c]-rgb(protectedImage.pixels[i])[c])<1e-5,"非皮膚或透明像素污染柔膚");
    }
    Image skin(128,32),subject(128,32);
    for(size_t y=0;y<skin.height;++y)for(size_t x=0;x<skin.width;++x) {
        skin.pixels[y*skin.width+x]=pixel(x<64?V(.457,.234,.162):V(.6,.13,.16),1);
        subject.pixels[y*skin.width+x]=pixel(V(x<32?0:1),1);
    }
    auto protectedMask=skin_mask(skin,&subject);
    for(size_t x=0;x<32;++x)check(protectedMask.pixels[16*128+x].r==0,"皮膚遮罩滲入人物外");
    check(protectedMask.pixels[16*128+48].r>.5,"遮罩過度排除正常皮膚");
    check(protectedMask.pixels[16*128+96].r<.02,"遮罩未保護高彩度唇色");
    return {{"colorCases",colorCases},{"maxLabChromaError",maxChromaError},{"monotoneCurves",3},
        {"mediumScaleAmplitudeRatio",midRatio},{"poreAmplitudeRatio",poreRatio},{"highlightLift",highlightLift},{"midtoneLift",midtoneLift}};
}
}
