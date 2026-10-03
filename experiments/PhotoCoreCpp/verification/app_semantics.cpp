// 主體、景深及多影像 ABI 的 GPU／CPU 對照：含 HDR、alpha、焦平面與無效輸入。
#include "PhotoCompute.h"
#include "render_pipeline.hpp"
#include <fstream>
#include <cstring>
#include <iostream>
#include <memory>
using namespace photocore;
using Json=nlohmann::json;
void require(bool valid,const char *message){if(!valid)throw std::runtime_error(message);}
int main(int argc,char **argv){try{
 require(argc==4,"需資料、shader、配方目錄");char error[2048]{};
 std::unique_ptr<void,decltype(&photo_compute_destroy)> engine(photo_compute_create(argv[1],argv[2],error,sizeof(error)),photo_compute_destroy);require(bool(engine),error);
 film_cpu::Database data(argv[1]);Json sourceCatalog;std::ifstream(argv[3])>>sourceCatalog;Json catalog,mono,neutral;
 for(const auto &style:sourceCatalog.at("styles")){std::string id=style.at("id");catalog[id]=style.at("adjustment");mono[id]=style.at("isMonochrome");if(id=="original")neutral=style.at("adjustment");}
 constexpr size_t width=128,height=96;Image source(width,height),subject(width,height),depth(width,height);
 for(size_t y=0;y<height;++y)for(size_t x=0;x<width;++x){double dx=(x+.5)/width-.5,dy=(y+.5)/height-.5,distance=std::hypot(dx,dy),m=1-film_cpu::smooth(.24,.32,distance),noise=((x*431+y*733)%127)/127.-.5;float alpha=x<3?float(x)/3:1;
  source.pixels[y*width+x]=film_cpu::pixel(film_cpu::V(.48+dx*.35+noise*.04,.28+dy*.25+noise*.04,.16+noise*.04)*(x>120?3.:1)*alpha,alpha);
  subject.pixels[y*width+x]=film_cpu::pixel(film_cpu::V(m),1);depth.pixels[y*width+x]=film_cpu::pixel(film_cpu::V(1-distance),1);}
 filmdevelop::ComputeImage compute=[&](const Image &image,const Json &plan,const std::vector<Image> &inputs){Image result(image.width,image.height);std::vector<PhotoComputeImageView> views;for(const auto &a:inputs)views.push_back({reinterpret_cast<const float *>(a.pixels.data()),uint32_t(a.width),uint32_t(a.height)});auto text=plan.dump();require(photo_compute_process_inputs(engine.get(),text.c_str(),reinterpret_cast<const float *>(image.pixels.data()),reinterpret_cast<float *>(result.pixels.data()),uint32_t(image.width),uint32_t(image.height),views.data(),uint32_t(views.size()),error,sizeof(error))==0,error);return result;};
 Json report=Json::array();
 for(const auto &style:{"original","filmEktachrome100","japaneseBWSoft"})for(const auto &effect:{"skin","denoise","depth","combined"}) {
  filmdevelop::contract::RenderJob job;job.recipe.style=style;job.recipe.adjustment=catalog.at(style);job.preview=true;
  auto &a=job.recipe.adjustment;if(std::string(effect)=="skin" || std::string(effect)=="combined"){a["skinWhitening"]=60;a["skinSmoothing"]=80;a["skinWarmth"]=-35;}
  if(std::string(effect)=="denoise" || std::string(effect)=="combined")a["denoise"]=75;
  if(std::string(effect)=="depth" || std::string(effect)=="combined")a["backgroundBlur"]=80;
  auto cpu=filmdevelop::render_style(source,source,job,neutral,catalog,mono,data,{}, {},&subject,&depth);
  auto gpu=filmdevelop::render_style(source,source,job,neutral,catalog,mono,data,compute,{},&subject,&depth);
  double maximum=0,squared=0,change=0;
  for(size_t i=0;i<source.pixels.size();++i){auto x=film_cpu::rgb(cpu.pixels[i]),y=film_cpu::rgb(gpu.pixels[i]);for(int c=0;c<3;++c){double delta=std::abs(x[c]-y[c]);maximum=std::max(maximum,delta);squared+=delta*delta;change+=std::abs(y[c]-film_cpu::rgb(source.pixels[i])[c]);}require(std::abs(cpu.pixels[i].a-gpu.pixels[i].a)<1e-5,"GPU 改變 alpha");}
  double rmse=std::sqrt(squared/(source.pixels.size()*3));std::cout<<style<<" "<<effect<<" max="<<maximum<<" rmse="<<rmse<<std::endl;
  require(maximum<.003 && rmse<.0005,"主體／景深 CPU 與 GPU 不一致");require(change>.1,"調整未產生效果");report.push_back({{"style",style},{"effect",effect},{"maxError",maximum},{"rmse",rmse}});
 }
 // 分區淡化包含全量及混合區域，必須同時維持 GPU／CPU 一致與灰階次序。
 Image ramp(1025,1);for(size_t i=0;i<ramp.width;++i)ramp.pixels[i]=film_cpu::pixel(film_cpu::V(double(i)/(ramp.width-1)),1);
 for(int intensity:{50,75,100})for(int bits=1;bits<8;++bits) {
  filmdevelop::contract::RenderJob job;job.recipe.style="original";job.recipe.adjustment=neutral;job.preview=true;
  auto &a=job.recipe.adjustment;a["intensity"]=intensity;a["sourceToneZones"]={{"shadows",{{"fade",(bits&1)?100:0}}},{"midtones",{{"fade",(bits&2)?100:0}}},{"highlights",{{"fade",(bits&4)?100:0}}}};
  auto cpu=filmdevelop::render_style(ramp,ramp,job,neutral,catalog,mono,data);
  auto gpu=filmdevelop::render_style(ramp,ramp,job,neutral,catalog,mono,data,compute);
  double maximum=0;for(size_t i=0;i<ramp.width;++i)for(int c=0;c<3;++c) {
   maximum=std::max(maximum,std::abs(film_cpu::rgb(cpu.pixels[i])[c]-film_cpu::rgb(gpu.pixels[i])[c]));
   // 完整 SDR 流程允許白點剪裁成 1；曲線內部仍須保有次序與細節。
   if(i && film_cpu::rgb(gpu.pixels[i])[c]<=film_cpu::rgb(gpu.pixels[i-1])[c]
        && film_cpu::rgb(gpu.pixels[i])[c]<1-1e-6) {
    std::cerr<<"fade intensity="<<intensity<<" zones="<<bits<<" x="<<i<<" channel="<<c<<" previous="<<film_cpu::rgb(gpu.pixels[i-1])[c]<<" current="<<film_cpu::rgb(gpu.pixels[i])[c]<<" cpu="<<film_cpu::rgb(cpu.pixels[i])[c]<<std::endl;
    throw std::runtime_error("GPU 淡化反轉或壓平灰階");
   }
  }
  require(maximum<.00002,"分區淡化 CPU／GPU 不一致");
 }
 for(double exposure:{.5,.25,.125,.0625}) {
  Image dark(32,32);for(auto &p:dark.pixels)p=film_cpu::pixel(film_cpu::V(.457,.234,.162)*exposure,1);
  filmdevelop::contract::RenderJob job;job.recipe.style="original";job.recipe.adjustment=neutral;job.recipe.adjustment["skinWhitening"]=100;job.preview=true;
  auto cpu=filmdevelop::render_style(dark,dark,job,neutral,catalog,mono,data);
  auto gpu=filmdevelop::render_style(dark,dark,job,neutral,catalog,mono,data,compute);
  for(size_t i=0;i<dark.pixels.size();++i) {
   require(gpu.pixels[i].r>dark.pixels[i].r+.005,"GPU 欠曝膚色美白失效");
   for(int c=0;c<3;++c)require(std::abs(film_cpu::rgb(cpu.pixels[i])[c]-film_cpu::rgb(gpu.pixels[i])[c])<.0001,"欠曝膚色 CPU／GPU 不一致");
  }
 }
 // 直接執行單一算法，防止完整 SDR 輸出掩蓋黑位、HDR 與 alpha 問題。
 auto operation=[](const char *stage,const Json &adjustment,double strength=1.) {
  return Json{{"schema",1},{"stage",stage},{"effects",Json::object()},{"adjustment",adjustment},{"strength",strength},{"style","original"},{"monochrome",false},{"hdr",true}};
 };
 // 在同一外部遮罩下直接比較新柔膚／美白，避免配方或 SDR 匯出掩蓋差異。
 Image skinSource(256,64),skinMask(256,64);
 for(size_t y=0;y<skinSource.height;++y)for(size_t x=0;x<skinSource.width;++x) {
  double detail=.06*std::sin(2*3.141592653589793*x/16)+(x%2==0?.012:-.012);
  double alpha=x<16?double(x%4)/3:1.;
  film_cpu::V color=x<128?film_cpu::V(.457,.234,.162):film_cpu::V(.12,.08,.06);
  if(y<8)color=film_cpu::V(2,.8,.3);
  if(y>55)color=film_cpu::V(-.02,.2,.1);
  skinSource.pixels[y*skinSource.width+x]=film_cpu::pixel(color*std::exp2(detail)*alpha,alpha);
  skinMask.pixels[y*skinSource.width+x]=film_cpu::pixel(film_cpu::V(x<8?0:(x<16?.5:1)),1);
 }
 double skinMaximum=0;int skinCases=0;
 for(int smoothing:{0,50,100})for(int whitening:{0,50,100}) {
  Json adjustment={{"skinSmoothing",smoothing},{"skinWhitening",whitening}};
  Json external={{"schema",1},{"stage","external"},{"input",0}};
  Json plan={{"schema",2},{"nodes",Json::array({
    {{"source",0},{"operation",external}},
    {{"source",0},{"secondary",1},{"operation",operation("skinEnhancement",adjustment)}}})}};
  auto cpu=film_cpu::skin_enhance(skinSource,skinMask,adjustment,1,data),gpu=compute(skinSource,plan,{skinMask});
  double maximum=0;
  for(size_t i=0;i<skinSource.pixels.size();++i) {
   require(gpu.pixels[i].a==skinSource.pixels[i].a,"自然柔膚／美白改變 alpha");
   for(int c=0;c<3;++c) {
    double error=std::abs(film_cpu::rgb(cpu.pixels[i])[c]-film_cpu::rgb(gpu.pixels[i])[c]);maximum=std::max(maximum,error);
    if(skinMask.pixels[i].r==0)require(film_cpu::rgb(gpu.pixels[i])[c]==film_cpu::rgb(skinSource.pixels[i])[c],"GPU 改變遮罩外像素");
   }
  }
  std::cout<<"natural skin smoothing="<<smoothing<<" whitening="<<whitening<<" max="<<maximum<<std::endl;
  require(maximum<.0001,"自然柔膚／美白 CPU 與 GPU 不一致");skinMaximum=std::max(skinMaximum,maximum);++skinCases;
 }
 Image coverage(35,16);const double alphas[]={0,.001,.1,.5,1};const film_cpu::V color(.4,.25,.12);
 for(size_t y=0;y<coverage.height;++y)for(size_t x=0;x<coverage.width;++x){double a=alphas[x/7];coverage.pixels[y*coverage.width+x]=film_cpu::pixel(color*a,a);}
 for(double amount:{.25,.5,1.}) {
  auto cpu=film_cpu::denoise(coverage,amount),gpu=compute(coverage,operation("denoise",{{"denoise",100}},amount),{});
  for(size_t i=0;i<coverage.pixels.size();++i) {
   require(gpu.pixels[i].a==coverage.pixels[i].a,"GPU 降噪改變覆蓋率");
   for(int c=0;c<3;++c){double value=film_cpu::straight(gpu.pixels[i])[c];require(std::abs(value-(gpu.pixels[i].a>0?color[c]:0))<1e-5,"GPU 透明邊緣降噪偏色");require(std::abs(value-film_cpu::straight(cpu.pixels[i])[c])<1e-5,"加權降噪 CPU／GPU 不一致");}
  }
 }
 for(double alpha:{.001,.25,1.})for(double value:{0.,1e-8,1e-7,1e-6,1e-5,.18,1.,2.}) {
  Image flat(32,16);for(auto &p:flat.pixels)p=film_cpu::pixel(film_cpu::V(value*alpha),alpha);
  Json adjustment={{"hdrAmount",100}};auto cpu=film_cpu::local_tone(flat,adjustment,1,true),gpu=compute(flat,operation("hdr",adjustment),{});
  double out=film_cpu::straight(gpu.pixels[8*32+16]).x,expected=film_cpu::straight(cpu.pixels[8*32+16]).x;
  require(gpu.pixels[0].a==flat.pixels[0].a,"GPU HDR 改變覆蓋率");
  require(std::abs(out-expected)<std::max(3e-11,value*1e-4),"HDR 極暗階調 CPU／GPU 不一致");
  if(value==0)require(out==0,"GPU HDR 抬升固定黑位");
  if(value>0 && value<=1e-5)require(std::abs(out-1.52*value)<value*.001+3e-11,"GPU HDR 原點斜率不正確");
 }
 for(const auto *style:{"original","filmEktachrome100"}) {
  Json adjustment={{"shadowIntensity",65},{"midtoneIntensity",65},{"highlightIntensity",65}};
  Image opaque(32,16);for(auto &p:opaque.pixels)p=film_cpu::pixel(color,1);
  auto reference=film_cpu::tone_zones(opaque,adjustment,1,false,style,data);
  for(double alpha:{.001,.25,.5,1.}) {
   Image partial=opaque;for(auto &p:partial.pixels)p=film_cpu::pixel(color*alpha,alpha);
   auto request=operation("toneZones",adjustment);request["style"]=style;
   auto cpu=film_cpu::tone_zones(partial,adjustment,1,false,style,data),gpu=compute(partial,request,{});
   for(size_t i=0;i<partial.pixels.size();++i) {
    require(gpu.pixels[i].a==partial.pixels[i].a,"分區調色改變 alpha");
    for(int c=0;c<3;++c){double expected=film_cpu::straight(reference.pixels[i])[c];require(std::abs(film_cpu::straight(cpu.pixels[i])[c]-expected)<1e-5,"CPU 分區調色依賴 alpha");require(std::abs(film_cpu::straight(gpu.pixels[i])[c]-expected)<1e-5,"GPU 分區調色依賴 alpha");}
   }
  }
 }
 auto reduced=film_cpu::denoise(source,1);double before=0,after=0;for(size_t y=10;y<85;++y)for(size_t x=10;x<110;++x){size_t i=y*width+x;before+=std::pow(source.pixels[i].r-source.pixels[i-1].r,2);after+=std::pow(reduced.pixels[i].r-reduced.pixels[i-1].r,2);}require(after<before*.5,"降噪未降低高頻噪聲");
 auto noBlur=film_cpu::background_blur(source,subject,depth,0,true);require(noBlur.pixels.size()==source.pixels.size() && std::memcmp(noBlur.pixels.data(),source.pixels.data(),source.pixels.size()*sizeof(Pixel))==0,"零強度仍套用散景");
 bool focus=false;auto mask=filmdevelop::depth_blur_mask(subject,&depth,.8,&focus);require(focus && mask.pixels[height/2*width+width/2].r==0,"景深焦平面未保持清晰");
 auto blurred=film_cpu::background_blur(source,subject,mask,.8,focus);require(std::abs(blurred.pixels[height/2*width+width/2].r-source.pixels[height/2*width+width/2].r)<1e-6,"主體中心被模糊");
 for(const auto &frame:{"whitePaperThin","whitePaperWide","whitePaperPolaroid","blackLine","filmStrip","cleanInset"}){
  auto a=neutral;a["frameEnabled"]=true;a["frameStyle"]=frame;auto framed=filmdevelop::decorate(source,a);filmdevelop::FrameGeometry expected(width,height,a);require(framed.width==expected.width && framed.height==expected.height,"外框尺寸不符");require(framed.width>width && framed.height>height,"外框未增加畫布");}
 for(const auto &date:{"numeric","slash","compact","japanese"}){auto a=neutral;a["dateEnabled"]=true;a["dateStyle"]=date;auto stamped=filmdevelop::decorate(source,a);require(stamped.width==width && stamped.height==height,"日期改變畫布尺寸");double change=0;for(size_t i=0;i<source.pixels.size();++i)change+=std::abs(stamped.pixels[i].r-source.pixels[i].r);require(change>.01,"日期沒有顯示");}
 std::cout<<Json{{"passed",true},{"cases",report},{"naturalSkinCases",skinCases},{"naturalSkinMaxError",skinMaximum},{"denoiseEnergyRatio",after/before},{"fadeCases",21},{"underexposedSkinCases",4},{"coverageDenoiseCases",3},{"hdrToeCases",24},{"toneZoneAlphaCases",8},{"frameCases",6},{"dateCases",4}}.dump()<<std::endl;
 return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<std::endl;return 1;}}
