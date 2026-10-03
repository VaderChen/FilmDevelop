vec4 rawSkinMask(vec4 s) {
            if(s.a<=0)return vec4(0,0,0,1);
            vec3 rgb = s.rgb / s.a;
            float sourceLuma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            // 只正規化辨識訊號：欠曝膚色沿用色相／彩度判定，不改動照片曝光。
            rgb *= max(1.0, 0.18 / max(sourceLuma, 0.00001));
            float r = rgb.r;
            float g = rgb.g;
            float b = rgb.b;
            float l = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
            float maxc = max(r, max(g, b));
            float minc = min(r, min(g, b));
            float chroma = maxc - minc;
            float saturation = chroma / max(maxc, 0.001);
            float cb = (b - l) * 0.565;
            float cr = (r - l) * 0.713;
            float hue = 0.0;
            if (chroma > 0.0001) {
                if (maxc == r) {
                    hue = (g - b) / chroma;
                    if (hue < 0.0) { hue += 6.0; }
                } else if (maxc == g) {
                    hue = ((b - r) / chroma) + 2.0;
                } else {
                    hue = ((r - g) / chroma) + 4.0;
                }
                hue *= 60.0;
            }

            float lumaMask = smoothstep(0.0005, 0.01, sourceLuma) * (1.0 - smoothstep(0.96, 1.0, sourceLuma));
            float saturationMask = smoothstep(0.015, 0.080, saturation) * (1.0 - smoothstep(0.76, 0.96, saturation));

            float rgbNormal = smoothstep(0.24, 0.38, r)
                * smoothstep(0.10, 0.18, g)
                * smoothstep(0.04, 0.10, b)
                * smoothstep(0.035, 0.10, chroma)
                * smoothstep(-0.03, 0.07, r - g)
                * smoothstep(-0.04, 0.08, r - b)
                * (1.0 - smoothstep(0.32, 0.58, abs(r - g)))
                * (1.0 - smoothstep(0.02, 0.20, g - r));

            float rgbBright = smoothstep(0.72, 0.86, r)
                * smoothstep(0.66, 0.82, g)
                * smoothstep(0.54, 0.72, b)
                * (1.0 - smoothstep(0.06, 0.18, abs(r - g)))
                * smoothstep(-0.02, 0.07, r - b)
                * smoothstep(-0.02, 0.07, g - b);

            float ycbcrFamily = smoothstep(-0.245, -0.185, cb)
                * (1.0 - smoothstep(0.010, 0.070, cb))
                * smoothstep(0.015, 0.070, cr)
                * (1.0 - smoothstep(0.205, 0.280, cr));

            float hueLow = 1.0 - smoothstep(48.0, 76.0, hue);
            float hueHigh = smoothstep(332.0, 348.0, hue);
            float hsvFamily = max(hueLow, hueHigh)
                * smoothstep(0.05, 0.18, saturation)
                * (1.0 - smoothstep(0.72, 0.92, saturation))
                * smoothstep(0.12, 0.24, maxc);

            float warmFamily = smoothstep(-0.16, 0.035, r - b)
                * (1.0 - smoothstep(0.30, 0.58, abs(r - g)))
                * (1.0 - smoothstep(0.04, 0.24, g - r));

            float skinFamily = max(max(rgbNormal, rgbBright), max(ycbcrFamily, max(hsvFamily, warmFamily)));
            // 亮度正規化不應把非膚色色相擴充進遮罩。
            float redProtection=1.0-smoothstep(0.35,0.55,(r-g)/max(r+g+b,0.00001));
            float m = s.a>0 ? clamp(lumaMask * saturationMask * skinFamily * max(hueLow, hueHigh)*redProtection, 0.0, 1.0) : 0;
            return vec4(m, m, m, 1.0);
}

vec3 skinLuminance(vec3 color,float targetY) {
    float fy=labf(dot(color,EW));
    float x=dot(color,vec3(.41239079926595934,.35758433938387796,.1804807884018343));
    float z=dot(color,vec3(.01933081871559185,.11919477979462599,.9505321522496607));
    vec2 ab=vec2(500*(labf(x/.9504559270516716)-fy),200*(fy-labf(z/1.0890577507598784)));
    float targetF=labf(targetY);vec3 result=labColorRGB(targetF,ab);
    float lower=min(0,min(color.r,min(color.g,color.b))),upper=max(1,max(color.r,max(color.g,color.b)));
    if(min(result.r,min(result.g,result.b))<lower || max(result.r,max(result.g,result.b))>upper) {
        float lo=0,hi=1;
        for(int k=0;k<16;++k){float mid=(lo+hi)*.5;vec3 q=labColorRGB(targetF,ab*mid);
            if(min(q.r,min(q.g,q.b))>=lower && max(q.r,max(q.g,q.b))<=upper)lo=mid;else hi=mid;}
        result=labColorRGB(targetF,ab*lo);
    }
    return result;
}
bool skin(uint i) {
    if(work.op<56 || (work.op>80 && work.op!=83 && work.op!=84 && (work.op<86 || work.op>89)))return false;
    vec4 px=a[i],result=px;
    if(work.op==56)result=rawSkinMask(px);
    else if(work.op==57){vec3 v=max(straight(px),vec3(0));result=vec4(v/(1+v),b[i].r);}
    else if(work.op==58)result=vec4(px.r*px.g,px.r*px.b,px.g*px.b,1);
    else if(work.op==59)result=vec4(px.rgb*px.a,1);
    else if(work.op==60)result=vec4(max(px.rgb-b[i].rgb*b[i].rgb,vec3(0))+p[0],1);
    else if(work.op==61){vec3 m=b[i].rgb;result=vec4(px.rgb-vec3(m.r*m.g,m.r*m.b,m.g*m.b),1);}
    else if(work.op==62)result=vec4(px.rgb-b[i].rgb*b[i].a,1);
    else if(work.op==63){
        vec3 d=px.rgb,cross=b[i].rgb,v=c[i].rgb;
        float l10=cross.r/d.r,l20=cross.g/d.r,d1=max(d.g-l10*cross.r,p[0]*.01),l21=(cross.b-l20*cross.r)/d1,d2=max(d.b-l20*cross.g-l21*l21*d1,p[0]*.01);
        float y1=v.g-l10*v.r,y2=v.b-l20*v.r-l21*y1,a2=y2/d2,a1=y1/d1-l21*a2,a0=v.r/d.r-l10*a1-l20*a2;
        result=vec4(a0,a1,a2,1);
    }
    else if(work.op==64)result=vec4(vec3(px.a-dot(b[i].rgb,px.rgb)),1);
    else if(work.op==65){vec3 v=max(straight(px),vec3(0));float q=px.a<=.00001?0:clamp(dot(b[i].rgb,v/(1+v))+c[i].r,0,1);result=vec4(vec3(q),1);}
    else if(work.op==66)result=px.a>0?px:vec4(0);
    else if(work.op==67)result=px.a>0?vec4(px.rgb*straight(b[i])+straight(c[i])*px.a,px.a):vec4(0);
    else if(work.op==83)result=vec4(straight(px)*px.rgb,px.a);
    else if(work.op==84) {
        float weight=max(px.a,1e-20);vec3 mean=px.rgb/weight;
        vec3 variance=max(b[i].rgb/weight-mean*mean,vec3(0)),slope=variance/(variance+p[0]);
        result=vec4(slope*px.a,px.a);dst2[i]=vec4(mean*(1-slope)*px.a,px.a);
    }
    else if(work.op==68)result=vec4(mix(px.rgb,b[i].rgb,clamp(c[i].r*p[0],0,1)),px.a);
    else if(work.op==69) {
        vec3 color=straight(px);float y=dot(color,EW),weight=clamp(b[i].r,0,1)*.68*p[0];
        if(px.a>0 && weight>0 && y>0 && y<1) {
            float l=(116*labf(y)-16)/100,target=l+1.5*weight*l*(1-l)*(1-l);
            result=vec4(skinLuminance(color,labinv((100*target+16)/116))*px.a,px.a);
        }
    }
    else if(work.op==70)result=vec4(px.rgb*clamp(b[i].r,0,1),1);
    else if(work.op==86)result=vec4(vec3(clamp(px.r,0,1)*smoothstep(0,.15,clamp(b[i].r,0,1))),1);
    else if(work.op==87) {
        float y=max(0,dot(straight(px),EW)),value=log2(y+.00001),weight=px.a*clamp(b[i].r,0,1);
        result=px.a>0?vec4(value*weight,value*value*weight,0,weight):vec4(0);
    }
    // b 通道保存原始遮罩，讓最後一步在三個輸入內取得兩尺度統計與遮罩。
    else if(work.op==88)result=vec4(px.rg,b[i].r,px.a);
    else if(work.op==89) {
        vec4 fine=b[i],coarse=c[i];vec3 color=straight(px);float y=dot(color,EW),weight=clamp(fine.b,0,1)*p[0];
        if(px.a>0 && weight>0 && y>0 && fine.a>1e-8 && coarse.a>1e-8) {
            float value=log2(y+.00001),mf=fine.r/fine.a,mc=coarse.r/coarse.a;
            float vf=max(0,fine.g/fine.a-mf*mf),vc=max(0,coarse.g/coarse.a-mc*mc);
            float fineDelta=(mf-value)*p[1]/(vf+p[1]),coarseDelta=(mc-value)*p[1]/(vc+p[1]);
            float attenuation=.12+.23*smoothstep(.35,.85,vf/max(vc,.000001));
            float delta=coarseDelta-(1-attenuation)*fineDelta;
            delta=clamp(delta,min(0,mc-value),max(0,mc-value))*weight*(1-smoothstep(.025,.12,vc));
            if(abs(delta)>=1e-7)result=vec4(skinLuminance(color,max(0,exp2(value+delta)-.00001))*px.a,px.a);
        }
    }
    else if(work.op==71) {
        vec4 total=vec4(0);uint count=work.aw*work.ah;
        for(uint k=0;k<256;++k){uint index=i*256+k;if(index>=count)break;float m=b[index].r;total+=vec4(a[index].rgb*m,m);}
        result=total;
    }
    else if(work.op==72) {vec4 total=vec4(0);for(uint k=0;k<256;++k){uint index=i*256+k;if(index>=work.aw*work.ah)break;total+=a[index];}result=total;}
    else if(work.op==73) {
        vec4 mean=b[0]/p[0];vec3 average=mean.rgb;float coverage=mean.a;
        for(int k=0;k<3;++k)average[k]=average[k]<=.0031308?12.92*average[k]:1.055*pow(average[k],1/2.4)-.055;
        coverage=coverage<=.0031308?12.92*coverage:1.055*pow(coverage,1/2.4)-.055;
        if(coverage>.02 && coverage<.55){
            float confidence=min(clamp((coverage-.02)/.08,0,1),clamp((.55-coverage)/.15,0,1));
            if(confidence>.05){
                average=clamp(average/coverage,0,1);float green=max(average.g,.001),correction=.55*confidence;
                vec3 gain=vec3(clamp(1+(1.18/max(average.r/green,.001)-1)*correction,.88,1.12),1,clamp(1+(.82/max(average.b/green,.001)-1)*correction,.88,1.12));
                gain=clamp(gain*clamp(max(.001,dot(average,W))/max(.001,dot(average*gain,W)),.92,1.08),.86,1.14);
                if(max(max(abs(gain.r-1),abs(gain.g-1)),abs(gain.b-1))>.012){vec3 corrected=px.rgb*gain;vec3 adjusted=mix(mix(px.rgb,corrected,.16*confidence),corrected,c[i].r*.58*confidence);result=vec4(px.rgb*(1-p[1])+adjusted*p[1],px.a);}
            }
        }
    }
    else if(work.op==74) {float weight=1-clamp(b[i].r,0,1);result=px*weight;}
    else if(work.op==75) {vec4 total=vec4(0);vec2 pos=vec2(i%work.width,i/work.width);for(int k=0;k<int(p[0]);++k)total+=linearA(pos+vec2(p[1+k*3],p[2+k*3]))*p[3+k*3];result=total;}
    else if(work.op==76) {vec4 blurred=b[i];vec3 color=max(blurred.rgb,vec3(0))/max(blurred.a,.05);result=vec4(mix(px.rgb,color*px.a,smoothstep(.05,.20,blurred.a)),px.a);}
    else if(work.op==77) result=vec4(mix(px.rgb,b[i].rgb,c[i].r),px.a);
    else if(work.op==78) {vec3 background=b[i].rgb;if(p[0]>0)background=mix(px.rgb,background,clamp(c[i].g*5,0,1));result=vec4(mix(background,px.rgb,c[i].r),px.a);}
    else if(work.op==79)result=vec4(px.r,b[i].r,0,1);
    else if(work.op==80)result=vec4(straight(px),1);
    dst[i]=result;return true;
}
