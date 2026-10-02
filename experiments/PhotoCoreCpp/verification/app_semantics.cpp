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
 auto reduced=film_cpu::denoise(source,1);double before=0,after=0;for(size_t y=10;y<85;++y)for(size_t x=10;x<110;++x){size_t i=y*width+x;before+=std::pow(source.pixels[i].r-source.pixels[i-1].r,2);after+=std::pow(reduced.pixels[i].r-reduced.pixels[i-1].r,2);}require(after<before*.5,"降噪未降低高頻噪聲");
 auto noBlur=film_cpu::background_blur(source,subject,depth,0,true);require(noBlur.pixels.size()==source.pixels.size() && std::memcmp(noBlur.pixels.data(),source.pixels.data(),source.pixels.size()*sizeof(Pixel))==0,"零強度仍套用散景");
 bool focus=false;auto mask=filmdevelop::depth_blur_mask(subject,&depth,.8,&focus);require(focus && mask.pixels[height/2*width+width/2].r==0,"景深焦平面未保持清晰");
 auto blurred=film_cpu::background_blur(source,subject,mask,.8,focus);require(std::abs(blurred.pixels[height/2*width+width/2].r-source.pixels[height/2*width+width/2].r)<1e-6,"主體中心被模糊");
 for(const auto &frame:{"whitePaperThin","whitePaperWide","whitePaperPolaroid","blackLine","filmStrip","cleanInset"}){
  auto a=neutral;a["frameEnabled"]=true;a["frameStyle"]=frame;auto framed=filmdevelop::decorate(source,a);filmdevelop::FrameGeometry expected(width,height,a);require(framed.width==expected.width && framed.height==expected.height,"外框尺寸不符");require(framed.width>width && framed.height>height,"外框未增加畫布");}
 for(const auto &date:{"numeric","slash","compact","japanese"}){auto a=neutral;a["dateEnabled"]=true;a["dateStyle"]=date;auto stamped=filmdevelop::decorate(source,a);require(stamped.width==width && stamped.height==height,"日期改變畫布尺寸");double change=0;for(size_t i=0;i<source.pixels.size();++i)change+=std::abs(stamped.pixels[i].r-source.pixels[i].r);require(change>.01,"日期沒有顯示");}
 std::cout<<Json{{"passed",true},{"cases",report},{"denoiseEnergyRatio",after/before},{"frameCases",6},{"dateCases",4}}.dump()<<std::endl;
 return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<std::endl;return 1;}}
