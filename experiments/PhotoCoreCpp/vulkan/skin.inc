namespace photocore::vk {
using namespace film_cpu;
Surface Pipeline::box_mean(Surface input,int radius) {
    radius=std::clamp(radius,1,64);
    std::vector<float> weights(size_t(radius)+2,1.f/float(2*radius+1));weights[0]=float(radius);
    auto scratch=context.create(input.width,input.height),out=context.create(input.width,input.height);
    context.dispatch(3,input,input,input,scratch,scratch,weights,table,0,"skin-box-x");
    context.dispatch(3,scratch,scratch,scratch,out,out,weights,table,1,"skin-box-y");return out;
}
Surface Pipeline::refine_mask(Surface image,Surface raw,double radius,double epsilon) {
    auto binary=[&](unsigned op,Surface a,Surface b,const std::vector<float> &params={}){auto out=context.create(a.width,a.height);context.dispatch(op,a,b,b,out,out,params,table,0,"skin-mask");return out;};
    auto guide=binary(57,image,raw);raw={};
    double scale=std::min(1.,1024./std::max(image.width,image.height));
    auto sampled=resample(guide,std::max(1L,std::lround(image.width*scale)),std::max(1L,std::lround(image.height*scale)));guide={};
    int r=int(std::clamp(std::round(radius*scale),1.,64.));
    auto mean=box_mean(sampled,r),diagonal=box_mean(unary(27,sampled,{},"skin-diagonal"),r),cross=box_mean(unary(58,sampled,{},"skin-cross"),r),correlation=box_mean(unary(59,sampled,{},"skin-correlation"),r);sampled={};
    diagonal=binary(60,diagonal,mean,{float(epsilon)});cross=binary(61,cross,mean);correlation=binary(62,correlation,mean);
    auto slope=context.create(mean.width,mean.height);
    context.dispatch(63,diagonal,cross,correlation,slope,slope,{float(epsilon)},table,0,"skin-mask-slope");diagonal={};cross={};correlation={};
    auto intercept=binary(64,mean,slope);mean={};
    slope=resample(box_mean(slope,r),image.width,image.height);intercept=resample(box_mean(intercept,r),image.width,image.height);
    auto out=context.create(image.width,image.height);context.dispatch(65,image,slope,intercept,out,out,{},table,0,"skin-mask-reconstruct");return out;
}
Surface Pipeline::skin_mask(Surface image,Surface person) {
    auto raw=unary(56,image,{},"skin-mask-raw");
    if(person.buffer){auto out=context.create(image.width,image.height);context.dispatch(70,raw,person,person,out,out,{},table,0,"skin-subject-mask");raw=out;}
    auto refined=refine_mask(image,raw,std::max(2.,4*std::max(std::min(image.width,image.height)/1600.,.5)),.0004);
    auto out=context.create(image.width,image.height);context.dispatch(86,refined,raw,raw,out,out,{},table,0,"skin-mask-protection");return out;
}
Surface Pipeline::smooth_channels(Surface image,double radius,double epsilon) {
    int r=int(std::clamp(std::round(radius),1.,64.));auto prepared=unary(66,image,{},"skin-weighted-input");
    auto mean=box_mean(prepared,r),square=box_mean(unary(83,prepared,{},"skin-square"),r);prepared={};
    auto a=context.create(image.width,image.height),b=context.create(image.width,image.height);
    context.dispatch(84,mean,square,mean,a,b,{float(epsilon)},table,0,"skin-smoothing-coefficients");mean={};square={};
    a=box_mean(a,r);b=box_mean(b,r);auto out=context.create(image.width,image.height);
    context.dispatch(67,image,a,b,out,out,{},table,0,"skin-smooth");return out;
}
Surface Pipeline::skin_enhance(Surface image,Surface mask,const Json &a,double strength) {
    double white=number(a,"skinWhitening",0,0,100)/100*strength,smoothing=number(a,"skinSmoothing",0,0,100)/100*strength,warm=number(a,"skinWarmth",0,-100,100)/100*strength;
    auto blend=[&](Surface foreground,double amount){auto out=context.create(image.width,image.height);context.dispatch(68,image,foreground,mask,out,out,{float(amount)},table,0,"skin-blend");image=out;};
    if(smoothing>.005) {
        double radius=std::max(1.,(.9+smoothing*5.4)*std::max(std::min(image.width,image.height)/1600.,.5));
        auto statistics=context.create(image.width,image.height);
        context.dispatch(87,image,mask,mask,statistics,statistics,{},table,0,"skin-log-statistics");
        auto fine=box_mean(statistics,int(std::clamp(std::round(radius*.35),1.,64.)));
        auto coarse=box_mean(statistics,int(std::clamp(std::round(radius*3),2.,64.)));statistics={};
        auto packed=context.create(image.width,image.height);
        context.dispatch(88,fine,mask,mask,packed,packed,{},table,0,"skin-pack-statistics");fine={};
        auto out=context.create(image.width,image.height);
        context.dispatch(89,image,packed,coarse,out,out,{float(smoothing*.78),float(.002+smoothing*.018)},table,0,"skin-natural-smoothing");image=out;
    }
    if(white>.005) {
        auto out=context.create(image.width,image.height);
        context.dispatch(69,image,mask,mask,out,out,{float(white)},table,0,"skin-natural-whitening");image=out;
    }
    if(std::abs(warm)>.001)blend(white_balance(image,{{"whiteBalanceWarmth",warm*100}},1),1);
    return image;
}
}
namespace photocore::vk {
Surface Pipeline::skin_white_balance(Surface image,Surface mask,double strength) {
    auto sum=context.create((image.width*image.height+255)/256,1);
    context.dispatch(71,image,mask,mask,sum,sum,{},table,0,"skin-average");
    while(sum.width*sum.height>1){auto next=context.create((sum.width*sum.height+255)/256,1);context.dispatch(72,sum,sum,sum,next,next,{},table,0,"skin-reduce");sum=next;}
    auto out=context.create(image.width,image.height);context.dispatch(73,image,sum,mask,out,out,{float(image.width*image.height),float(strength)},table,0,"skin-white-balance");return out;
}
Surface Pipeline::bokeh(Surface image,double radius) {
    if(radius<.05)return image;
    return unary(75,image,film_cpu::bokeh_samples(radius),"lens-bokeh");
}
Surface Pipeline::background_blur(Surface image,Surface subject,Surface depth,double amount,bool focus) {
    if(amount<=.005)return image;
    double scale=std::max(image.width,image.height)/1024.,radius=std::min(500.,amount*24*scale);
    auto mask=refine_mask(image,subject,std::max(2.,std::max(4*scale,radius*.35)),.0001);
    auto isolated=context.create(image.width,image.height);context.dispatch(74,image,mask,mask,isolated,isolated,{},table,0,"isolate-background");
    auto normalized=[&](Surface blurred){auto out=context.create(image.width,image.height);context.dispatch(76,image,blurred,blurred,out,out,{},table,0,"background-normalize");return out;};
    auto nearBlur=normalized(bokeh(isolated,radius*.2)),farBlur=normalized(bokeh(isolated,radius));isolated={};
    auto blurred=context.create(image.width,image.height);context.dispatch(77,nearBlur,farBlur,depth,blurred,blurred,{},table,0,"background-depth");nearBlur={};farBlur={};
    auto masks=context.create(image.width,image.height);context.dispatch(79,mask,depth,depth,masks,masks,{},table,0,"background-masks");mask={};
    auto out=context.create(image.width,image.height);context.dispatch(78,image,blurred,masks,out,out,{focus?1.f:0.f},table,0,"subject-protection");return out;
}
}
