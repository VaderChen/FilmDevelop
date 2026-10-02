// 與 PhotoEmulsionExposureProcessor 的 Metal 晶體模型一致，種子固定為 0。
vec4 field4(uint which, ivec2 q, int fw, int fh) {
    q=clamp(q,ivec2(0),ivec2(fw,fh)-1);
    return which==0?b[q.y*fw+q.x]:c[q.y*fw+q.x];
}
vec4 sample4(uint which, vec2 q, int fw, int fh) {
    ivec2 k=ivec2(floor(q)); vec2 f=floor((q-vec2(k))*256+.5)/256;
    return mix(mix(field4(which,k,fw,fh),field4(which,k+ivec2(1,0),fw,fh),f.x),
        mix(field4(which,k+ivec2(0,1),fw,fh),field4(which,k+ivec2(1,1),fw,fh),f.x),f.y);
}
vec4 linearA(vec2 q) {
    ivec2 k=ivec2(floor(q)); vec2 f=floor((q-vec2(k))*256+.5)/256;
    return mix(mix(sampleA(k),sampleA(k+ivec2(1,0)),f.x),
        mix(sampleA(k+ivec2(0,1)),sampleA(k+ivec2(1,1)),f.x),f.y);
}
uint eh(uint x) { x^=x>>16; x*=0x7feb352du; x^=x>>15; x*=0x846ca68bu; return x^(x>>16); }
float eu(uint x) { return (float(eh(x)>>8)+.5)/16777216.; }
uint cellSeed(ivec2 q,uint seed) { return eh(uint(q.x)*0x9e3779b9u ^ uint(q.y)*0x85ebca6bu ^ seed); }
int countPoisson(uint seed,float lambda) {
    float v=exp(-lambda),sum=v,u=eu(seed); int k=0;
    for(int j=1;j<20 && u>sum;++j) { v*=lambda/float(j);sum+=v;k=j; } return k;
}
vec4 canonicalSource(vec2 point, float scale) {
    return linearA(vec2(point.x*scale-.5,float(work.ah)-point.y*scale-.5));
}
vec3 crystalRadiance(vec2 point) { return max(straight(canonicalSource(point/p[4],p[5])),vec3(0)); }
vec4 capture(vec2 coord) {
    vec2 point=coord*p[4]; vec4 original=canonicalSource(coord,p[5]);
    if(!(original.a>0)) return vec4(0);
    vec3 incident=max(straight(original),vec3(0)),total=vec3(0); float opacity=0,spacing=3.6*p[0];
    for(int sub=0;sub<4;++sub) {
        vec2 q=point+vec2((sub&1)!=0?.25:-.25,(sub&2)!=0?.25:-.25)*p[4];
        vec3 remaining=incident; float throughput=1;
        for(uint layer=0;layer<3;++layer) {
            uint seed=0x243f6a88u+layer*0x9e3779b9u; ivec2 cell=ivec2(floor(q/spacing));
            float hits=0; vec3 footprint=vec3(0);
            for(int cy=-1;cy<=1;++cy) for(int cx=-1;cx<=1;++cx) {
                ivec2 candidate=cell+ivec2(cx,cy); uint key=cellSeed(candidate,seed);
                float group=eu(cellSeed(ivec2(floor(vec2(candidate)/5)),seed));
                int count=countPoisson(key,mix(1.2,.9+.6*group,p[1]));
                for(int j=0;j<count;++j) {
                    uint h=eh(key^uint(j+1)*0x63d83595u);
                    vec2 center=(vec2(candidate)+vec2(eu(h),eu(h^0xa511e9b3u)))*spacing;
                    float radius=(.25+.10*eu(h^0x3c6ef372u))*spacing;
                    if(p[3]>.0001) radius*=exp(p[3]*(2*eu(h^0x91e10da5u)-1))/sqrt(sinh(2*p[3])/(2*p[3]));
                    float angle=6.2831853*eu(h^0xbb67ae85u),cs=cos(angle),sn=sin(angle);
                    vec2 d=q-center; d=vec2(cs*d.x+sn*d.y,-sn*d.x+cs*d.y);
                    float edge=max(abs(d.x),max(abs(.5*d.x+.8660254*d.y),abs(-.5*d.x+.8660254*d.y)));
                    if(edge<=.8660254*radius) {
                        footprint+=(crystalRadiance(center)+crystalRadiance(center+vec2(radius*.5,0))+crystalRadiance(center-vec2(radius*.5,0)))/3;
                        hits+=1;
                    }
                }
            }
            vec3 tau=mix(vec3(.70),layer==0?vec3(.25,.5,1.35):(layer==1?vec3(.5,1.35,.25):vec3(1.35,.25,.5)),p[2]);
            throughput*=exp(-.70*hits);
            vec3 capacity=hits>0?footprint/hits:vec3(0);
            remaining-=min(remaining,capacity)*(1-exp(-tau*hits));
        }
        total+=incident-remaining; opacity+=1-throughput;
    }
    return vec4(total*(.25*original.a),opacity*(.25*original.a));
}
bool optics(uint i,uint x,uint y) {
    vec2 coord=vec2(float(x)+.5,float(work.height-y)-.5);
    if(work.op==26) {
        dst[i]=linearA((vec2(x,y)+.5)*vec2(work.aw,work.ah)/vec2(work.width,work.height)-.5);return true;
    }
    if(work.op==30) { dst[i]=capture(coord);return true; }
    if(work.op==31) {
        vec4 source=canonicalSource(coord,p[0]);
        float luma=dot(max(straight(source),vec3(0)),W),gate=smoothGate(p[2],p[2]+.25,luma);
        vec3 reflectance=min(vec3(1),vec3(.65,.16,.035)*exp(-vec3(1,1.8,2.5)*(p[3]-.5)));
        dst[i]=vec4(max(source.rgb-b[i].rgb,vec3(0))*reflectance*(p[1]*gate),source.a);return true;
    }
    if(work.op==35) { dst[i]=sampleA(ivec2(x,y+work.ah-work.height));return true; }
    if(work.op<21 || work.op>33) return false;
    vec4 px=a[i],result=px;
    if(work.op==21) result=vec4(px.r,b[i].g,c[i].b,1);
    else if(work.op==22) result=vec4(mix(px.rgb,b[i].rgb,p[0]),px.a);
    else if(work.op==23) result=vec4(vec3(max(dot(max(straight(px),vec3(0)),W)-p[0],0)*px.a),1);
    else if(work.op==24) result=vec4(px.rgb+max(c[i].r-b[i].r-1e-6,0)*p[0]*px.a,px.a);
    else if(work.op==25) {
        float z=log2(max(dot(straight(px),W),1e-6)/.18),n=z/(z<0?.65:1.35);
        vec3 v=vec3(1-smoothGate(-1.55,0,z),exp2(-.5*n*n),smoothGate(.55,2.55,z));
        result=vec4(px.a>0?v/max(dot(v,vec3(1)),.0001):vec3(0),1);
    } else if(work.op==27) result=vec4(px.rgb*px.rgb,1);
    else if(work.op==28) {
        vec3 variance=max(b[i].rgb-px.rgb*px.rgb,vec3(0)),slope=variance/(variance+p[0]);
        result=vec4(slope,1);dst2[i]=vec4(px.rgb*(1-slope),1);
    } else if(work.op==29) {
        vec2 pos=(vec2(x,y)+.5)*vec2(p[0],p[1])/vec2(work.width,work.height)-.5;
        result=vec4(px.rgb*sample4(0,pos,int(p[0]),int(p[1])).rgb+sample4(1,pos,int(p[0]),int(p[1])).rgb,1);
    } else if(work.op==32) {
        vec3 weights=max(b[i].rgb,vec3(0));result=vec4(px.rgb,dot(weights,pv(0))/max(dot(weights,vec3(1)),1e-6));
    } else if(work.op==33) {
        float fraction=px.a>0?clamp(b[i].a/px.a,0,1):0;vec3 color=straight(px);
        float peak=max(color.r,max(color.g,color.b));
        result=vec4(mix(px.rgb,b[i].rgb/p[0],c[i].a*.35/max(1,peak))+c[i].rgb*fraction/p[0],px.a);
    }
    dst[i]=result;return true;
}
