#include "digital_math.hpp"
#include "camera_math.hpp"
namespace photocore::film_cpu {
namespace {
V table_pixel(const DigitalLook &look, int x, int y, int z) {
    auto i=std::size_t((z*look.dimension+y)*look.dimension+x)*4;
    return {look.table[i],look.table[i+1],look.table[i+2]};
}
V lookup(const DigitalLook &look, V color) {
    auto finish=[&](V result){
    if(!look.output_curve.empty())for(int c=0;c<3;++c) {
        double v=std::abs(result[c]);v=(v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055)*(result[c]<0?-1:1);
        v=(v+1)/9*32768;int k=int(std::clamp(v,0.,32767.));
        result[c]=look.output_curve[k*4+c]+(look.output_curve[(k+1)*4+c]-look.output_curve[k*4+c])*(v-k);
    }
        return result;
    };
    if(!look.camera.empty())return finish(camera_look(color,look.camera));
    if(!look.affine.empty()) {
        V result;
        for(int c=0;c<3;++c)result[c]=color.x*look.affine[c*4]+color.y*look.affine[c*4+1]+color.z*look.affine[c*4+2]+look.affine[c*4+3];
        return finish(result);
    }
    if(!look.monochrome_curve.empty()) {
        double y=dot(color,{.2125,.7154,.0721}),v=std::abs(y);
        v=(v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055)*(y<0?-1:1);
        v=(v+1)/9*32768;int k=int(std::clamp(v,0.,32767.));
        V result;for(int c=0;c<3;++c)result[c]=look.monochrome_curve[k*4+c]+(look.monochrome_curve[(k+1)*4+c]-look.monochrome_curve[k*4+c])*(v-k);
        return finish(result);
    }
    V q;int k[3];
    for(int c=0;c<3;++c) {
        if(!look.axis.empty()) {
            // 座標在線性光域內插，保留負值與 HDR；邊界延伸而非截斷亮部。
            auto upper=std::upper_bound(look.axis.begin(),look.axis.end(),color[c]);
            k[c]=std::clamp(int(upper-look.axis.begin())-1,0,look.dimension-2);
            q[c]=(color[c]-look.axis[k[c]])/(look.axis[k[c]+1]-look.axis[k[c]]);
        } else {
            double v=std::clamp(color[c],0.,1.);
            v=(v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055)*(look.dimension-1);
            k[c]=std::min(look.dimension-2,int(v));q[c]=v-k[c];
        }
    }
    auto a=mix(table_pixel(look,k[0],k[1],k[2]),table_pixel(look,k[0]+1,k[1],k[2]),q.x);
    auto b=mix(table_pixel(look,k[0],k[1]+1,k[2]),table_pixel(look,k[0]+1,k[1]+1,k[2]),q.x);
    auto c=mix(table_pixel(look,k[0],k[1],k[2]+1),table_pixel(look,k[0]+1,k[1],k[2]+1),q.x);
    auto d=mix(table_pixel(look,k[0],k[1]+1,k[2]+1),table_pixel(look,k[0]+1,k[1]+1,k[2]+1),q.x);
    V result=mix(mix(a,b,q.y),mix(c,d,q.y),q.z);

    return finish(result);
}
Image convolution(Image input, const std::vector<double> &kernel) {
    if(kernel.empty() || kernel.size()>65)throw std::invalid_argument("風格卷積資料不符");
    Image scratch(input.width,input.height);
    for(int axis=0;axis<2;++axis) {
        const Image &src=axis==0?input:scratch;Image &dst=axis==0?scratch:input;
        auto at=[&](long x,long y){return src.pixels[std::clamp(y,0L,long(src.height)-1)*src.width+std::clamp(x,0L,long(src.width)-1)];};
        for(size_t y=0;y<input.height;++y)for(size_t x=0;x<input.width;++x) {
            V sum=rgb(at(x,y))*kernel[0];
            for(size_t k=1;k<kernel.size();++k) sum+=(rgb(at(long(x)-(axis==0?long(k):0),long(y)-(axis==1?long(k):0)))+rgb(at(long(x)+(axis==0?long(k):0),long(y)+(axis==1?long(k):0))))*kernel[k];
            dst.pixels[y*dst.width+x]=pixel(sum,at(x,y).a);
        }
    }
    return input;
}
Image restore(Image source,const Image &adjusted) {
    for(size_t i=0;i<source.pixels.size();++i) {
        auto &p=source.pixels[i];V c=straight(p);double y=dot(c,exact_w),target=std::max(dot(straight(adjusted.pixels[i]),exact_w),0.);
        p=pixel((y>1e-20?lab_luminance(c,y,target/y):V(target))*p.a,p.a);
    }
    return source;
}
Image logs(const Image &source, double floor) {
    return transform(source,[&](Pixel p,size_t,size_t){return pixel(V(std::log2(std::max(dot(straight(p),w),floor))),1);});
}
}
Image digital_print(Image source,const Effects &e,const Database &data) {
    if(e.get("print_contrast",50)==50 && e.text("print_illuminant","reference")=="reference" && e.text("view_illuminant","reference")=="reference")return source;
    auto print=data.light_matrices.at(e.text("print_illuminant","reference")).second,view=data.light_matrices.at(e.text("view_illuminant","reference")).first;
    double contrast=std::exp2((e.get("print_contrast",50)-50)/50);
    for(auto &p:source.pixels) {
        V v=multiply(print,straight(p));for(int c=0;c<3;++c)v[c]=std::copysign(.18*std::pow(std::abs(v[c])/.18,contrast),v[c]);
        p=pixel(multiply(view,v)*p.a,p.a);
    }
    return source;
}
Image monochrome_filter(Image source,const Effects &e,double strength) {
    if(e.text("monochrome_filter","none")=="none" || e.get("monochrome_filter_strength")*strength<=0)return source;
    auto weights=monochrome_weights(e,strength);
    for(auto &p:source.pixels)p=pixel(V(dot(rgb(p),weights)),p.a);
    return source;
}
Image digital_look(Image source, const DigitalLook &look) {
    auto output=transform(source,[&](Pixel p,size_t,size_t){return pixel(lookup(look,straight(p))*p.a,p.a);});
    for(const auto &stage:look.spatial) {
        auto name=stage.at("filter").get<std::string>();const auto &params=stage.at("parameters");
        if(name=="CIBloom") {
            auto blurred=gaussian(output,params.at("inputRadius").get<double>(),false);
            double intensity=params.at("inputIntensity");
            for(size_t i=0;i<output.pixels.size();++i) {
                auto &p=output.pixels[i];p=pixel(rgb(p)+max(rgb(blurred.pixels[i])-rgb(p),0)*intensity,p.a);
            }
        } else if(name=="CISharpenLuminance") {
            auto blurred=convolution(output,stage.at("kernel").get<std::vector<double>>());double sharpness=params.at("inputSharpness");
            for(size_t i=0;i<output.pixels.size();++i) {
                auto &p=output.pixels[i];
                p=pixel(rgb(p)+(rgb(p)-rgb(blurred.pixels[i]))*sharpness,p.a);
            }
        } else throw std::invalid_argument("未支援的風格空間效果");
    }
    if(!look.casts.empty()) {
        auto masks=tone_masks(source);
        for(const auto &cast:look.casts) {
            int region=cast.at("region");V bias=vec(cast.at("bias"));
            for(size_t i=0;i<output.pixels.size();++i) {
                auto &p=output.pixels[i];p=pixel(rgb(p)+bias*rgb(masks.pixels[i])[region]*p.a,p.a);
            }
        }
    }
    return output;
}
Image white_balance(Image source,const Json &adjustment,double strength,const Database &data) {
    double warmth=number(adjustment,"whiteBalanceWarmth",0,-100,100)*strength,tint=number(adjustment,"whiteBalanceTint",0,-100,100)*strength;
    if(std::abs(warmth)<=.001 && std::abs(tint)<=.001)return source;
    auto matrix=data.white_balance_matrix(warmth,tint);
    for(auto &p:source.pixels)p=pixel(multiply(matrix,rgb(p)),p.a);
    return source;
}
std::pair<double,double> neutral_balance(V sample,double warmth,double tint,double strength,const Database &data) {
    if(!std::isfinite(strength) || strength<=0 || strength>1 || !std::isfinite(warmth) || !std::isfinite(tint))throw std::invalid_argument("白平衡取樣參數不符");
    for(int c=0;c<3;++c) {
        if(!std::isfinite(sample[c]) || sample[c]<=.02 || sample[c]>=.99)throw std::invalid_argument("白平衡樣本太暗或過曝");
        sample[c]=sample[c]<=.04045?sample[c]/12.92:std::pow((sample[c]+.055)/1.055,2.4);
    }
    auto m=data.white_balance_matrix(warmth*strength,tint*strength);
    double determinant=dot(m[0],cross(m[1],m[2]));
    auto c0=cross(m[1],m[2])/determinant,c1=cross(m[2],m[0])/determinant,c2=cross(m[0],m[1])/determinant;
    V base=c0*sample.x+c1*sample.y+c2*sample.z;
    auto loss=[&](double w,double t){auto v=multiply(data.white_balance_matrix(w*strength,t*strength),base);double r=std::log(std::max(v.x,1e-8)/std::max(v.y,1e-8)),b=std::log(std::max(v.z,1e-8)/std::max(v.y,1e-8));return r*r+b*b;};
    double w=warmth,t=tint,best=loss(w,t);
    for(double step:{40.,10.,2.5,.5,.1})for(int i=0;i<5;++i) {
        double nextW=w,nextT=t;
        for(double dw:{-step,0.,step})for(double dt:{-step,0.,step}) {
            double cw=std::clamp(w+dw,-100.,100.),ct=std::clamp(t+dt,-100.,100.),value=loss(cw,ct);
            if(value<best){best=value;nextW=cw;nextT=ct;}
        }
        if(nextW==w && nextT==t)break;
        w=nextW;t=nextT;
    }
    return {w,t};
}
Image tone_zones(Image source,const Json &adjustment,double strength,bool monochrome,const std::string &style,const Database &data) {
    const char *intensities[]={"shadowIntensity","midtoneIntensity","highlightIntensity"};
    const char *warmths[]={"shadowWarmth","midtoneWarmth","highlightWarmth"};
    Image masks(1,1),result(1,1);bool initialized=false;
    for(int region=0;region<3;++region) {
        double intensity=number(adjustment,intensities[region],0,0,100)*strength,warmth=monochrome?0:number(adjustment,warmths[region],0,-100,100)*strength;
        if(intensity<=.001 && std::abs(warmth)<=.001)continue;
        if(!initialized){masks=tone_masks(source);result=source;initialized=true;}
        auto wb=data.white_balance_matrix(warmth,0);const auto &mapping=data.tone_mappings.at(style)[region];
        double amount=intensity/100;
        for(size_t i=0;i<source.pixels.size();++i) {
            auto p=source.pixels[i];V branch=multiply(wb,straight(p));
            if(amount>.001) {
                V mapped=multiply(mapping.rows,branch)+mapping.bias;
                if(!mapping.curve.empty())for(int c=0;c<3;++c) {
                    double v=(mapped[c]+1)/5*16384;int k=int(std::clamp(v,0.,16383.));
                    mapped[c]=mapping.curve[k]+(mapping.curve[k+1]-mapping.curve[k])*(v-k);
                }
                branch=branch*(1-p.a*amount)+mapped*amount;
            }
            V mask=rgb(masks.pixels[i]);double total=mask.x+mask.y+mask.z;
            if(total>.0001)result.pixels[i]=pixel(rgb(result.pixels[i])+(branch*p.a-rgb(p))*(mask[region]/total),p.a);
        }
    }
    return initialized?result:source;
}
Image lab_adjustment(Image source,const Json &adjustment) {
    double vibrance=number(adjustment,"vibrance",0,-100,100)/100,saturation=number(adjustment,"saturation",0,-100,100)/100;
    if(vibrance==0 && saturation==0)return source;
    for(auto &p:source.pixels)p=p.a>0?pixel(lab_color(straight(p),vibrance,saturation)*p.a,p.a):Pixel{0,0,0,0};
    return source;
}
Image lens_shading(Image source,const Json &adjustment,double strength,const Database &data) {
    double amount=number(adjustment,"devignette",0,0,100)/100*strength,vignette=number(adjustment,"vignette",0,0,100)/100*strength;
    if(amount<=.005 && vignette<=.005)return source;
    if(vignette>.005 && data.vignette.empty())throw std::runtime_error("缺少暗角曲線");
    double r0=std::min(source.width,source.height)*.32,r1=std::max(source.width,source.height)*.78;
    for(size_t y=0;y<source.height;++y)for(size_t x=0;x<source.width;++x) {
        auto &p=source.pixels[y*source.width+x];
        double radius=std::hypot(x+.5-source.width*.5,y+.5-source.height*.5);
        double gain=amount>.005?std::exp2(amount*std::clamp((radius-r0)/(r1-r0),0.,1.)):1;
        if(vignette>.005) {
            double v=std::min(radius/std::min(source.width,source.height)*512,4096.);int k=std::min(4095,int(v));
            gain*=std::pow(data.vignette[k]+(data.vignette[k+1]-data.vignette[k])*(v-k),vignette*.9);
        }
        p=pixel(rgb(p)*gain,p.a);
    }
    return source;
}
namespace {
Image local_tone_curve(Image source,double contrast,double highlights,double shadows) {
    if(std::abs(contrast)<=.001 && std::abs(highlights)<=.001 && std::abs(shadows)<=.001)return source;
    auto log=logs(source,1e-6),base=guided_smooth(log,.01);
    double detailGain=1+std::max(contrast,0.)*.12+std::min(contrast,0.)*.08,pivot=std::log2(.18);
    for(size_t i=0;i<source.pixels.size();++i) {
        auto &p=source.pixels[i];double y=dot(straight(p),w);if(y<=0 || p.a<=0)continue;
        double l=log.pixels[i].r,b=base.pixels[i].r,detail=l-b;
        double result=local_tone_point(l-pivot,contrast,highlights,shadows).x;
        if(std::abs(detail)<.45) {
            auto mid=local_tone_point(b-pivot,contrast,highlights,shadows);mid.y=detailGain;
            result=detail<0?detail_segment((detail+.45)/.45,local_tone_point(b-pivot-.45,contrast,highlights,shadows),mid,.45):detail_segment(detail/.45,mid,local_tone_point(b-pivot+.45,contrast,highlights,shadows),.45);
        }
        double ratio=std::exp2(pivot+result)/std::max(std::exp2(l),1e-6);
        if(y<1e-6){double t=y/1e-6;ratio=ratio*(ratio*t+1-t)/(ratio+(1-ratio)*t*(1-t));}
        p=pixel(rgb(p)*ratio,p.a);
    }
    return source;
}
}
Image plan_tone(Image source,const Json &adjustment,double strength,bool monochrome,const Database &data) {
    auto zones=adjustment.value("sourceToneZones",Json());
    if(zones.is_null() || strength<=.001)return source;
    if(!zones.is_object())throw std::invalid_argument("分區色調格式不符");
    auto masks=tone_masks(source);Image result=source;int region=0;
    for(const char *key:{"shadows","midtones","highlights"}) {
        const auto &zone=zones.value(key,Json::object());
        double saturation=monochrome?1:1+number(zone,"base_tone",0,-100,100)/100*.55*strength;
        double tint=monochrome?0:number(zone,"tint",0,-100,100)/100*strength;
        auto branch=source;
        if(std::abs(saturation-1)>.001)for(auto &p:branch.pixels)p=pixel(mix(V(dot(rgb(p),{.2125,.7154,.0721})),rgb(p),saturation),p.a);
        if(std::abs(tint)>.001) {
            auto matrix=data.white_balance_matrix(0,tint*80/.6);
            for(auto &p:branch.pixels)p=pixel(multiply(matrix,rgb(p)),p.a);
        }
        branch=local_tone_curve(std::move(branch),number(zone,"contrast",0,-100,100)/100*strength,number(zone,"highlights",0,-100,100)/100*strength,number(zone,"shadows",0,-100,100)/100*strength);
        double fade=number(zone,"fade",0,0,100)/100*strength,softness=number(zone,"softness",0,0,100)/100*strength;
        if(fade>.005) {double lift=fade*.18;for(auto &p:branch.pixels)p=pixel(rgb(p)*V(1-lift*.25,1-lift*.20,1-lift*.18)+V(lift)*p.a,p.a);}
        if(softness>.005) {
            double scale=std::clamp(double(std::max(source.width,source.height))/1024,.5,3.),amount=std::min(.66,softness*1.18);
            auto blur=gaussian(branch,(.75+softness*7)*scale);
            for(size_t i=0;i<branch.pixels.size();++i){auto &p=branch.pixels[i];auto q=blur.pixels[i];p={float(p.r*(1-q.a*amount)+q.r*amount),float(p.g*(1-q.a*amount)+q.g*amount),float(p.b*(1-q.a*amount)+q.b*amount),float(p.a*(1-q.a*amount)+q.a*amount)};}
        }
        for(size_t i=0;i<source.pixels.size();++i) {
            V mask=rgb(masks.pixels[i]);double total=mask.x+mask.y+mask.z;
            if(total>.0001)result.pixels[i]=pixel(rgb(result.pixels[i])+(rgb(branch.pixels[i])-rgb(source.pixels[i]))*mask[region]/total,source.pixels[i].a);
        }
        ++region;
    }
    return result;
}
Image local_tone(Image source,const Json &adjustment,double strength,bool hdr) {
    const double contrast=number(adjustment,"contrast",0,-100,100)/100*strength,
                 brightness=(number(adjustment,"brightness",50,0,100)-50)/50*strength*.06;
    if(std::abs(contrast)>.001 || std::abs(brightness)>.00006) {
        auto adjusted=transform(source,[&](Pixel p,size_t,size_t){return pixel(rgb(p)+brightness*p.a,p.a);});
        adjusted=local_tone_curve(std::move(adjusted),contrast,0,0);
        source=restore(std::move(source),adjusted);
    }
    ToneSettings settings(adjustment);
    if(!hdr || settings.amount<=.0001)return source;
    auto log=logs(source,1e-5),base=guided_smooth(log,.0015);Image adjusted=source;
    for(size_t i=0;i<source.pixels.size();++i) {
        auto &p=adjusted.pixels[i];double l=log.pixels[i].r,b=base.pixels[i].r,d=l-b;
        double result=hdr_point(l,settings.points).x;
        if(std::abs(d)<.35) {
            TonePoint middle=hdr_point(b,settings.points);middle.y=settings.detail;
            result=d<0?detail_segment((d+.35)/.35,hdr_point(b-.35,settings.points),middle,.35):detail_segment(d/.35,middle,hdr_point(b+.35,settings.points),.35);
        }
        double sourceY=std::exp2(l),targetY=std::exp2(l+(result-l)*settings.amount);V color=straight(p),chroma=color-sourceY;
        double ceiling=std::max({1.,color.x,color.y,color.z}),fit=1;
        for(int c=0;c<3;++c) {
            if(chroma[c]>1e-6)fit=std::min(fit,(ceiling-targetY)/chroma[c]);
            else if(chroma[c]<-1e-6)fit=std::min(fit,-targetY/chroma[c]);
        }
        p=pixel(max(V(targetY)+chroma*std::clamp(fit,0.,1.),0)*p.a,p.a);
    }
    return restore(std::move(source),adjusted);
}
}
