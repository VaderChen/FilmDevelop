#include "pipeline.hpp"
#include "digital_math.hpp"
namespace photocore::vk {
using namespace film_cpu;
Surface Pipeline::digital_print(Surface source,const Effects &e) {
    if(e.get("print_contrast",50)==50 && e.text("print_illuminant","reference")=="reference" && e.text("view_illuminant","reference")=="reference")return source;
    auto print=database.light_matrices.at(e.text("print_illuminant","reference")).second,view=database.light_matrices.at(e.text("view_illuminant","reference")).first;
    std::vector<float> params;
    for(const auto &matrix:{print,view})for(auto row:matrix)for(int c=0;c<3;++c)params.push_back(float(row[c]));
    params.push_back(float(std::exp2((e.get("print_contrast",50)-50)/50)));
    return unary(50,source,params,"digital-print");
}
Surface Pipeline::monochrome_filter(Surface source,const Effects &e,double strength) {
    if(e.text("monochrome_filter","none")=="none" || e.get("monochrome_filter_strength")*strength<=0)return source;
    // 權重是 Swift 定義的彩色濾鏡感光比例；先套用，再進行黑白風格映射。
    auto v=monochrome_weights(e,strength);
    return unary(48,source,{float(v.x),float(v.y),float(v.z),float(v.x),float(v.y),float(v.z),float(v.x),float(v.y),float(v.z)},"monochrome-filter");
}
Surface Pipeline::digital_look(Surface source,const DigitalLook &look) {
    auto it=digital_tables.find(&look);
    if(it==digital_tables.end()) {
        auto values=look.monochrome_curve.empty()?look.table:look.monochrome_curve;
        values.insert(values.end(),look.axis.begin(),look.axis.end());
        values.insert(values.end(),look.output_curve.begin(),look.output_curve.end());
        it=digital_tables.emplace(&look,context.upload_floats(values)).first;
    }
    auto image=context.create(source.width,source.height);
    std::vector<float> parameters{float(look.dimension),look.axis.empty()?0.f:1.f,look.output_curve.empty()?0.f:1.f};
    parameters.insert(parameters.end(),look.affine.begin(),look.affine.end());
    unsigned operation=look.affine.empty()?(look.monochrome_curve.empty()?36:51):80;
    if(!look.camera.empty()){operation=81;parameters=look.camera;}
    context.dispatch(operation,source,source,source,image,image,parameters,it->second,0,"digital-look");
    for(const auto &stage:look.spatial) {
        const auto name=stage.at("filter").get<std::string>();const auto &params=stage.at("parameters");
        double radius=name=="CIBloom"?params.at("inputRadius").get<double>():1.69;
        Surface blur;
        if(name=="CISharpenLuminance") {
            auto kernel=stage.at("kernel").get<std::vector<float>>();
            if(kernel.empty() || kernel.size()>65)throw std::invalid_argument("風格卷積資料不符");
            std::vector<float> weights{float(kernel.size()-1)};weights.insert(weights.end(),kernel.begin(),kernel.end());
            auto scratch=context.create(source.width,source.height);blur=context.create(source.width,source.height);
            context.dispatch(3,image,image,image,scratch,scratch,weights,table,0,"digital-kernel-x");
            context.dispatch(3,scratch,scratch,scratch,blur,blur,weights,table,1,"digital-kernel-y");
        } else blur=gaussian(unary(15,image,{1,1,1},"digital-copy"),radius,"digital-blur",false);
        auto out=context.create(source.width,source.height);
        unsigned op=name=="CIBloom"?38:39;
        double amount=params.at(name=="CIBloom"?"inputIntensity":"inputSharpness");
        context.dispatch(op,image,blur,image,out,out,{float(amount)},table,0,name);
        image=std::move(out);
    }
    if(!look.casts.empty()) {
        auto masks=tone_masks(source);
        std::vector<float> bias(9,0);
        for(const auto &cast:look.casts) {
            int region=cast.at("region");auto v=vec(cast.at("bias"));
            for(int c=0;c<3;++c)bias.at(region*3+c)+=float(v[c]);
        }
        auto out=context.create(source.width,source.height);
        context.dispatch(37,image,masks,image,out,out,bias,table,0,"digital-tone-cast");
        image=std::move(out);
    }
    return image;
}
Surface Pipeline::white_balance(Surface source,const Json &adjustment,double strength) {
    double warmth=number(adjustment,"whiteBalanceWarmth",0,-100,100)*strength,tint=number(adjustment,"whiteBalanceTint",0,-100,100)*strength;
    if(std::abs(warmth)<=.001 && std::abs(tint)<=.001)return source;
    auto matrix=database.white_balance_matrix(warmth,tint);std::vector<float> params;
    for(auto row:matrix)for(int c=0;c<3;++c)params.push_back(float(row[c]));
    return unary(48,source,params,"white-balance");
}
Surface Pipeline::tone_zones(Surface source,const Json &adjustment,double strength,bool monochrome,const std::string &style) {
    const char *intensities[]={"shadowIntensity","midtoneIntensity","highlightIntensity"};
    const char *warmths[]={"shadowWarmth","midtoneWarmth","highlightWarmth"};
    Surface masks,result=source;bool initialized=false;
    for(int region=0;region<3;++region) {
        double intensity=number(adjustment,intensities[region],0,0,100)*strength,warmth=monochrome?0:number(adjustment,warmths[region],0,-100,100)*strength;
        if(intensity<=.001 && std::abs(warmth)<=.001)continue;
        if(!initialized){masks=tone_masks(source);initialized=true;}
        auto wb=database.white_balance_matrix(warmth,0);const auto &mapping=database.tone_mappings.at(style)[region];
        std::vector<float> params{float(region),float(intensity/100)};
        for(auto row:wb)for(int c=0;c<3;++c)params.push_back(float(row[c]));
        for(int r=0;r<3;++r){for(int c=0;c<3;++c)params.push_back(float(mapping.rows[r][c]));params.push_back(float(mapping.bias[r]));}
        params.push_back(mapping.curve.empty()?0:1);
        auto curve=table;
        if(!mapping.curve.empty()) {
            auto it=tone_tables.find(&mapping);
            if(it==tone_tables.end())it=tone_tables.emplace(&mapping,context.upload_floats(mapping.curve)).first;
            curve=it->second;
        }
        auto out=context.create(source.width,source.height);
        context.dispatch(49,source,masks,result,out,out,params,curve,0,"tone-zone");result=std::move(out);
    }
    return result;
}
Surface Pipeline::lab_adjustment(Surface source,const Json &adjustment) {
    double vibrance=number(adjustment,"vibrance",0,-100,100)/100,saturation=number(adjustment,"saturation",0,-100,100)/100;
    if(vibrance==0 && saturation==0)return source;
    return unary(46,source,{float(vibrance),float(saturation)},"lab-color");
}
Surface Pipeline::lens_shading(Surface source,const Json &adjustment,double strength) {
    double amount=number(adjustment,"devignette",0,0,100)/100*strength,vignette=number(adjustment,"vignette",0,0,100)/100*strength;
    if(amount<=.005 && vignette<=.005)return source;
    if(database.vignette.empty())throw std::runtime_error("缺少暗角曲線");
    if(!vignette_table.buffer)vignette_table=context.upload_floats(database.vignette);
    auto out=context.create(source.width,source.height);
    context.dispatch(47,source,source,source,out,out,{float(amount>.005?amount:0),float(vignette>.005?vignette*.9:0)},vignette_table,0,"lens-shading");
    return out;
}
Surface Pipeline::local_tone_curve(Surface source,double contrast,double highlights,double shadows) {
    if(std::abs(contrast)<=.001 && std::abs(highlights)<=.001 && std::abs(shadows)<=.001)return source;
    auto log=unary(40,source,{1e-6f},"tone-log"),base=guided(log,.01);
    auto out=context.create(source.width,source.height);
    context.dispatch(42,source,log,base,out,out,{float(contrast),float(highlights),float(shadows)},table,0,"local-tone");
    return out;
}
Surface Pipeline::plan_tone(Surface source,const Json &adjustment,double strength,bool monochrome) {
    auto zones=adjustment.value("sourceToneZones",Json());
    if(zones.is_null() || strength<=.001)return source;
    if(!zones.is_object())throw std::invalid_argument("分區色調格式不符");
    auto masks=tone_masks(source);Surface result=source;int region=0;
    for(const char *key:{"shadows","midtones","highlights"}) {
        const auto &zone=zones.value(key,Json::object());
        double saturation=monochrome?1:1+number(zone,"base_tone",0,-100,100)/100*.55*strength;
        double tint=monochrome?0:number(zone,"tint",0,-100,100)/100*strength;
        auto branch=source;
        if(std::abs(saturation-1)>.001)branch=unary(52,branch,{float(saturation),0},"plan-saturation");
        if(std::abs(tint)>.001) {
            auto matrix=database.white_balance_matrix(0,tint*80/.6);std::vector<float> params;
            for(auto row:matrix)for(int c=0;c<3;++c)params.push_back(float(row[c]));
            branch=unary(48,branch,params,"plan-tint");
        }
        branch=local_tone_curve(branch,number(zone,"contrast",0,-100,100)/100*strength,number(zone,"highlights",0,-100,100)/100*strength,number(zone,"shadows",0,-100,100)/100*strength);
        double fade=number(zone,"fade",0,0,100)/100*strength,softness=number(zone,"softness",0,0,100)/100*strength;
        if(fade>.005)branch=unary(52,branch,{1,float(fade*.18)},"plan-fade");
        if(softness>.005) {
            double scale=std::clamp(double(std::max(source.width,source.height))/1024,.5,3.),amount=std::min(.66,softness*1.18);
            auto blur=gaussian(branch,(.75+softness*7)*scale,"plan-softness"),out=context.create(source.width,source.height);
            context.dispatch(55,branch,blur,branch,out,out,{float(amount)},table,0,"plan-softness-blend");branch=out;
        }
        auto delta=context.create(source.width,source.height),out=context.create(source.width,source.height);
        context.dispatch(53,source,branch,masks,delta,delta,{float(region)},table,0,"plan-zone-delta");
        context.dispatch(54,result,delta,result,out,out,{},table,0,"plan-zone-composite");result=out;++region;
    }
    return result;
}
Surface Pipeline::local_tone(Surface source,const Json &adjustment,double strength,bool hdr) {
    double contrast=number(adjustment,"contrast",0,-100,100)/100*strength,
           brightness=(number(adjustment,"brightness",50,0,100)-50)/50*strength*.06;
    if(std::abs(contrast)>.001 || std::abs(brightness)>.00006) {
        auto adjusted=unary(43,source,{float(brightness)},"brightness");
        adjusted=local_tone_curve(std::move(adjusted),contrast,0,0);
        auto out=context.create(source.width,source.height);
        context.dispatch(44,source,adjusted,source,out,out,{},table,0,"tone-lab-lightness");
        source=std::move(out);
    }
    ToneSettings settings(adjustment);
    if(!hdr || settings.amount<=.0001)return source;
    auto log=unary(40,source,{1e-5f},"hdr-log"),base=guided(log,.0015);
    auto adjusted=context.create(source.width,source.height);
    std::vector<float> params(settings.points.begin(),settings.points.end());
    params.push_back(float(settings.detail));params.push_back(float(settings.amount));
    context.dispatch(41,source,log,base,adjusted,adjusted,params,table,0,"hdr");
    log={};base={};
    auto out=context.create(source.width,source.height);
    context.dispatch(44,source,adjusted,source,out,out,{},table,0,"hdr-lab-lightness");
    return out;
}
}

#include "skin_math.hpp"
#include "skin.inc"
