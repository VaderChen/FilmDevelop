    float hdrSlope(float left, float right) {
        return left > 0.0 && right > 0.0 ? 2.0 * left * right / (left + right) : 0.0;
    }

    vec2 hdrSegment(float x, float y0, float y1, float m0, float m1) {
        float t = clamp(x, 0.0, 1.0);
        float t2 = t * t;
        float t3 = t2 * t;
        float value = (2.0*t3 - 3.0*t2 + 1.0)*y0 + (t3 - 2.0*t2 + t)*m0
                    + (-2.0*t3 + 3.0*t2)*y1 + (t3 - t2)*m1;
        float slope = (6.0*t2 - 6.0*t)*y0 + (3.0*t2 - 4.0*t + 1.0)*m0
                    + (-6.0*t2 + 6.0*t)*y1 + (3.0*t2 - 2.0*t)*m1;
        return vec2(value, max(4.0 * slope, 0.0));
    }

    vec2 mapLocalHDRTone(
        float value, float black, float shadows, float midtones, float highlights, float white
    ) {
        // 單調 Hermite 插值；相鄰控制點相等時不會反轉亮度。
        float d0 = shadows - black;
        float d1 = midtones - shadows;
        float d2 = highlights - midtones;
        float d3 = white - highlights;
        float m1 = hdrSlope(d0, d1);
        float m2 = hdrSlope(d1, d2);
        float m3 = hdrSlope(d2, d3);
        if (value <= 0.25) return hdrSegment(value * 4.0, black, shadows, d0, m1);
        if (value <= 0.50) return hdrSegment((value-0.25)*4.0, shadows, midtones, m1, m2);
        if (value <= 0.75) return hdrSegment((value-0.50)*4.0, midtones, highlights, m2, m3);
        if (value <= 1.0) return hdrSegment((value-0.75)*4.0, highlights, white, m3, d3);
        return vec2(white + value - 1.0, 1.0);
    }

    vec2 hdrLogTonePoint(
        float logValue, float black, float shadows, float midtones, float highlights, float white
    ) {
        float value = max(exp2(logValue) - 0.00001, 0.0);
        vec2 mapped = mapLocalHDRTone(value, black, shadows, midtones, highlights, white);
        float slope = (value + 0.00001) * mapped.y / (max(mapped.x, 0.0) + 0.00001);
        // A non-finite derivative must not contaminate the spatial interpolant.
        if (!(slope >= 0.0 && slope < 1.0e20)) slope = 0.0;
        return vec2(log2(max(mapped.x, 0.0) + 0.00001), max(slope, 0.0));
    }

    // Rational quadratic Hermite interpolation. Positive endpoint slopes and
    // secant give a nonnegative derivative throughout the interval, unlike
    // mixing two curves with an input-dependent smoothstep weight.
    float hdrDetailSegment(float t, float y0, float y1, float m0, float m1, float width) {
        float delta = max(y1 - y0, 0.0);
        float secant = delta / width;
        if (secant < 0.000001) return mix(y0, y1, t);
        // With nonnegative slopes the denominator is at least secant / 2.
        float cross = t * (1.0 - t);
        float numerator = secant * t * t + m0 * cross;
        float denominator = secant + (m0 + m1 - 2.0 * secant) * cross;
        return y0 + delta * numerator / denominator;
    }


vec4 reconstructHDR(vec4 source,vec4 logLuminance,vec4 baseLogLuminance) {
float black=p[0],shadows=p[1],midtones=p[2],highlights=p[3],white=p[4],detailGain=p[5],amount=p[6];
if(source.a<=0)return vec4(0);
vec3 sourceColor=straight(source);float sourceLuminance=dot(sourceColor,W);
if(sourceLuminance<=0 && black<=0)return source;
float base = baseLogLuminance.r;
        float detail = logLuminance.r - base;
        float radius = 0.35;
        float processedLogLuminance = hdrLogTonePoint(logLuminance.r,
            black, shadows, midtones, highlights, white).x;
        if (abs(detail) < radius) {
            vec2 middle = hdrLogTonePoint(base, black, shadows, midtones, highlights, white);
            // Nonflat intervals retain detailGain at weak textures. Strong edges meet
            // the original direct tone curve in value and, where differentiable,
            // derivative. Existing curve-knot behavior is unchanged.
            if (detail < 0.0) {
                vec2 left = hdrLogTonePoint(base - radius,
                    black, shadows, midtones, highlights, white);
                processedLogLuminance = hdrDetailSegment((detail + radius) / radius,
                    left.x, middle.x, left.y, detailGain, radius);
            } else {
                vec2 right = hdrLogTonePoint(base + radius,
                    black, shadows, midtones, highlights, white);
                processedLogLuminance = hdrDetailSegment(detail / radius,
                    middle.x, right.x, detailGain, right.y, radius);
            }
        }
        float outputLogLuminance = mix(logLuminance.r, processedLogLuminance, amount);
        float outputLuminance = max(exp2(outputLogLuminance) - 0.00001, 0.0);
        vec3 chroma = sourceColor - vec3(sourceLuminance);
        float channelCeiling = max(max(max(sourceColor.r, sourceColor.g), sourceColor.b), 1.0);

        float gamutScale = 1.0;
        if (chroma.r > 0.000001) {
            gamutScale = min(gamutScale, (channelCeiling - outputLuminance) / chroma.r);
        } else if (chroma.r < -0.000001) {
            gamutScale = min(gamutScale, -outputLuminance / chroma.r);
        }
        if (chroma.g > 0.000001) {
            gamutScale = min(gamutScale, (channelCeiling - outputLuminance) / chroma.g);
        } else if (chroma.g < -0.000001) {
            gamutScale = min(gamutScale, -outputLuminance / chroma.g);
        }
        if (chroma.b > 0.000001) {
            gamutScale = min(gamutScale, (channelCeiling - outputLuminance) / chroma.b);
        } else if (chroma.b < -0.000001) {
            gamutScale = min(gamutScale, -outputLuminance / chroma.b);
        }

        vec3 outputColor = vec3(outputLuminance) + chroma * clamp(gamutScale, 0.0, 1.0);
        return vec4(max(outputColor, vec3(0.0)) * source.a, source.a);
}
vec3 colorTable(ivec3 q,int n) {int i=((q.z*n+q.y)*n+q.x)*4;return vec3(lut[i],lut[i+1],lut[i+2]);}
vec3 outputCurve(vec3 result) {
    int n=int(p[0]);
    if(p[2]>0) {
        int offset=n*n*n*4+(p[1]>0?n:0);
        for(int c=0;c<3;++c) {
            float v=abs(result[c]);v=(v<=.0031308?12.92*v:1.055*pow(v,1/2.4)-.055)*sign(result[c]);
            v=(v+1)/9*32768;int k=int(clamp(v,0,32767));
            result[c]=mix(lut[offset+k*4+c],lut[offset+(k+1)*4+c],v-k);
        }
    }
    return result;
}
vec3 colorLookup(vec3 c) {
    int n=int(p[0]);vec3 q=clamp(c,0,1);
    ivec3 k;
    if(p[1]>0) {
        int offset=n*n*n*4;
        for(int j=0;j<3;++j) {
            int low=0,high=n-1;
            for(int step=0;step<8 && high-low>1;++step) {
                int middle=(low+high)/2;
                if(lut[offset+middle]<=c[j])low=middle;else high=middle;
            }
            k[j]=min(low,n-2);
            q[j]=(c[j]-lut[offset+k[j]])/(lut[offset+k[j]+1]-lut[offset+k[j]]);
        }
    } else {
        for(int j=0;j<3;++j)q[j]=(q[j]<=.0031308?12.92*q[j]:1.055*pow(q[j],1/2.4)-.055)*(n-1);
        k=min(ivec3(q),ivec3(n-2));q-=vec3(k);
    }
    vec3 v0=mix(colorTable(k,n),colorTable(k+ivec3(1,0,0),n),q.x);
    vec3 v1=mix(colorTable(k+ivec3(0,1,0),n),colorTable(k+ivec3(1,1,0),n),q.x);
    vec3 v2=mix(colorTable(k+ivec3(0,0,1),n),colorTable(k+ivec3(1,0,1),n),q.x);
    vec3 v3=mix(colorTable(k+ivec3(0,1,1),n),colorTable(k+ivec3(1,1,1),n),q.x);
    vec3 result=mix(mix(v0,v1,q.y),mix(v2,v3,q.y),q.z);

    return outputCurve(result);
}
vec3 labColorRGB(float fy,vec2 ab) {
    vec3 xyz=vec3(.9504559270516716*labinv(fy+ab.x/500.0),labinv(fy),1.0890577507598784*labinv(fy-ab.y/200.0));
    return vec3(dot(xyz,vec3(3.240969941904521,-1.537383177570093,-.498610760293)),
        dot(xyz,vec3(-.9692436362808796,1.8759675015077202,.04155505740717559)),
        dot(xyz,vec3(.05563007969699366,-.20397695888897652,1.0569715142428786)));
}
vec4 labColorAdjustment(vec4 source) {
    if(source.a<=0)return vec4(0);
    vec3 rgb=source.rgb/source.a;
    float y=dot(rgb,EW);if(y<=0)return source;
    float fy=labf(y),x=dot(rgb,vec3(.41239079926595934,.35758433938387796,.1804807884018343)),z=dot(rgb,vec3(.01933081871559185,.11919477979462599,.9505321522496607));
    vec2 ab=vec2(500*(labf(x/.9504559270516716)-fy),200*(fy-labf(z/1.0890577507598784)));
    ab*=max(0,1+p[1])*max(0,1+p[0]*(1-smoothstep(0,100,length(ab))));
    vec3 result=labColorRGB(fy,ab);
    float lower=min(0,min(rgb.r,min(rgb.g,rgb.b))),upper=max(1,max(rgb.r,max(rgb.g,rgb.b)));
    if(min(result.r,min(result.g,result.b))<lower || max(result.r,max(result.g,result.b))>upper) {
        float lo=0,hi=1;
        for(int k=0;k<12;++k) {
            float mid=(lo+hi)*.5;vec3 q=labColorRGB(fy,ab*mid);
            if(min(q.r,min(q.g,q.b))>=lower && max(q.r,max(q.g,q.b))<=upper)lo=mid;else hi=mid;
        }
        result=labColorRGB(fy,ab*lo);
    }
    return vec4(result*source.a,source.a);
}
float localToneSlope(float lo,float hi,float x){float t=clamp((x-lo)/(hi-lo),0,1);return 6*t*(1-t)/(hi-lo);}
vec2 localTonePoint(float stops,float contrast,float highlights,float shadows) {
    float gain=1+contrast*.45,shadow=1-smoothstep(-2.3,.9,stops),protection=shadows<0?smoothstep(-5.5,-2.8,stops):1,highlight=smoothstep(.4,2.5,stops);
    return vec2(stops*gain+shadows*.75*shadow*protection-highlights*.55*highlight,
        max(0,gain+shadows*.75*(shadow*(shadows<0?localToneSlope(-5.5,-2.8,stops):0)-protection*localToneSlope(-2.3,.9,stops))-highlights*.55*localToneSlope(.4,2.5,stops)));
}
bool digital(uint i) {
    if((work.op<36 || work.op>44) && (work.op<46 || work.op>55) && work.op!=80 && work.op!=81 && work.op!=82 && work.op!=85)return false;
    vec4 px=a[i],result=px;
    if(work.op==80) {
        vec3 color=straight(px),mapped;
        for(int j=0;j<3;++j)mapped[j]=dot(color,pv(3+j*4))+p[6+j*4];
        result=vec4(outputCurve(mapped)*px.a,px.a);
    }
    else if(work.op==81) result=vec4(cameraLook(straight(px))*px.a,px.a);
    else if(work.op==82 && px.a>0) {
        float position=clamp(dot(straight(px),W),0,1)*p[0];
        int index=min(int(position),int(p[0])-1);
        float lift=mix(lut[index],lut[index+1],position-index);
        result=vec4(px.rgb*(vec3(1)-lift*vec3(.25,.20,.18))+vec3(lift*px.a),px.a);
    }
    else if(work.op==36) result=vec4(colorLookup(straight(px))*px.a,px.a);
    else if(work.op==37) result=vec4(px.rgb+(pv(0)*b[i].r+pv(3)*b[i].g+pv(6)*b[i].b)*px.a,px.a);
    else if(work.op==38) result=vec4(px.rgb+max(b[i].rgb-px.rgb,vec3(0))*p[0],px.a);
    else if(work.op==39) result=vec4(px.rgb+(px.rgb-b[i].rgb)*p[0],px.a);
    else if(work.op==85) result=vec4(vec3(log2(max(dot(straight(px),W),0)+.00001)),1);
    else if(work.op==40) result=vec4(vec3(log2(max(dot(straight(px),W),p[0]))),1);
    else if(work.op==41) result=reconstructHDR(px,b[i],c[i]);
    else if(work.op==42 && px.a>0) {
        float y=dot(straight(px),W);
        if(y>0) {
            float contrast=p[0],highlights=p[1],shadows=p[2],detailGain=1+max(contrast,0)*.12+min(contrast,0)*.08;
            float pivot=log2(.18),l=b[i].r,base=c[i].r,d=l-base,value=localTonePoint(l-pivot,contrast,highlights,shadows).x;
            if(abs(d)<.45) {
                vec2 middle=localTonePoint(base-pivot,contrast,highlights,shadows),left=localTonePoint(base-pivot-.45,contrast,highlights,shadows),right=localTonePoint(base-pivot+.45,contrast,highlights,shadows);
                value=d<0?hdrDetailSegment((d+.45)/.45,left.x,middle.x,left.y,detailGain,.45):hdrDetailSegment(d/.45,middle.x,right.x,detailGain,right.y,.45);
            }
            float ratio=exp2(pivot+value)/max(exp2(l),1e-6);
            if(y<1e-6){float t=y/1e-6;ratio=ratio*(ratio*t+1-t)/(ratio+(1-ratio)*t*(1-t));}
            result=vec4(px.rgb*ratio,px.a);
        }
    } else if(work.op==43) result=vec4(px.rgb+p[0]*px.a,px.a);
    else if(work.op==44) {
        vec3 color=straight(px);float y=dot(color,EW),target=max(dot(straight(b[i]),EW),0);
        result=vec4((y>1e-20?labLum(color,y,target/y):vec3(target))*px.a,px.a);
    }
    else if(work.op==52) {
        vec3 rgb=mix(vec3(dot(px.rgb,vec3(.2125,.7154,.0721))),px.rgb,p[0]);
        result=vec4(rgb*(vec3(1)-p[1]*vec3(.25,.20,.18))+vec3(p[1]*px.a),px.a);
    }
    else if(work.op==53) {vec3 mask=c[i].rgb;float total=mask.r+mask.g+mask.b;result=vec4(total>.0001?(b[i].rgb-px.rgb)*mask[int(p[0])]/total:vec3(0),0);}
    else if(work.op==54) result=vec4(px.rgb+b[i].rgb,px.a);
    else if(work.op==55) result=px*(1-p[0])+b[i]*p[0];
    else if(work.op==46) result=labColorAdjustment(px);
    else if(work.op==47) {
        vec2 size=vec2(work.width,work.height),position=vec2(i%work.width,i/work.width)+.5-size*.5;
        float r0=min(size.x,size.y)*.32,r1=max(size.x,size.y)*.78;
        float radius=length(position),gain=exp2(p[0]*clamp((radius-r0)/(r1-r0),0,1));
        if(p[1]>0) {
            float v=min(radius/min(size.x,size.y)*512,4096);int k=min(4095,int(v));
            gain*=pow(mix(lut[k],lut[k+1],v-k),p[1]);
        }
        result=vec4(px.rgb*gain,px.a);
    }
    else if(work.op==48) result=vec4(mul(0,px.rgb),px.a);
    else if(work.op==49) {
        vec3 branch=mul(2,straight(px));float amount=p[1];
        if(amount>.001) {
            vec3 mapped=vec3(dot(pv(11),branch)+p[14],dot(pv(15),branch)+p[18],dot(pv(19),branch)+p[22]);
            if(p[23]>0)for(int j=0;j<3;++j) {
                float v=(mapped[j]+1)/5*16384;int k=int(clamp(v,0,16383));mapped[j]=mix(lut[k],lut[k+1],v-k);
            }
            branch=branch*(1-amount)+mapped*amount;
        }
        float total=b[i].r+b[i].g+b[i].b;
        result=vec4(c[i].rgb+(total>.0001?(branch*px.a-px.rgb)*(b[i][int(p[0])]/total):vec3(0)),px.a);
    }
    else if(work.op==50) {
        vec3 v=mul(0,straight(px));v=sign(v)*.18*pow(abs(v)/.18,vec3(p[18]));
        result=vec4(mul(9,v)*px.a,px.a);
    }
    else if(work.op==51) {
        float y=dot(straight(px),vec3(.2125,.7154,.0721)),v=abs(y);
        v=(v<=.0031308?12.92*v:1.055*pow(v,1/2.4)-.055)*(y<0?-1:1);
        v=(v+1)/9*32768;int k=int(clamp(v,0,32767));
        vec3 color;for(int j=0;j<3;++j)color[j]=mix(lut[k*4+j],lut[(k+1)*4+j],v-k);
        result=vec4(color*px.a,px.a);
    }
    dst[i]=result;return true;
}
