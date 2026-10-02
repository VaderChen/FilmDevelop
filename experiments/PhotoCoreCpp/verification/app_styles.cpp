// 使用真正的 Swift 引擎金樣本，比對 Windows 與測試主機共用的完整配方管線。
#include "PhotoCompute.h"
#include "render_pipeline.hpp"
#include <fstream>
#include <filesystem>
#include <iostream>
#include <memory>
#include <chrono>
using namespace photocore;
using Json=nlohmann::json;
int main(int argc,char **argv){try{
 if(argc<5)throw std::runtime_error("需資料、shader、Go 配方目錄、Swift 金樣本目錄，可加 cpu 或單一配方");
 const bool cpu=argc>5 && std::string(argv[5])=="cpu";
 std::string only=argc>6?argv[6]:"";
 char error[2048]{};
 std::unique_ptr<void,decltype(&photo_compute_destroy)> engine(cpu?nullptr:photo_compute_create(argv[1],argv[2],error,sizeof(error)),photo_compute_destroy);
 if(!cpu && !engine)throw std::runtime_error(error);
 film_cpu::Database data(argv[1]);std::ifstream file(argv[3]);Json styles;file>>styles;
 Json catalog,mono,neutral,report=Json::array();bool passed=true;
 for(const auto &style:styles.at("styles")) {
  std::string id=style.at("id");if(!catalog.contains(id))catalog[id]=style.at("adjustment");mono[id]=style.at("isMonochrome");
  if(id=="original" && neutral.is_null())neutral=style.at("adjustment");
 }
 auto folder=std::filesystem::path(argv[4]);std::string inputName;Image input(1,1);
 filmdevelop::ComputeImage compute;
 if(!cpu)compute=[&](const Image &src,const Json &plan,const std::vector<Image> &auxiliary){
  std::vector<PhotoComputeImageView> views;for(const auto &image:auxiliary)views.push_back({reinterpret_cast<const float *>(image.pixels.data()),uint32_t(image.width),uint32_t(image.height)});
  Image out(src.width,src.height);auto request=plan.dump();
  if(photo_compute_process_inputs(engine.get(),request.c_str(),reinterpret_cast<const float*>(src.pixels.data()),reinterpret_cast<float*>(out.pixels.data()),src.width,src.height,views.data(),uint32_t(views.size()),error,sizeof(error)))throw std::runtime_error(error);
  return out;
 };
 auto srgb=[](double x){x=std::clamp(x,0.,1.);return x<=.0031308?12.92*x:1.055*std::pow(x,1/2.4)-.055;};
 for(const auto &style:styles.at("styles")) {
  std::string id=style.at("id"), name=style.value("case",id);if(!only.empty() && name!=only)continue;
  auto nextInput=style.value("input",std::string("input.pfm"));
  if(nextInput!=inputName){input=read_pfm((folder/nextInput).string());inputName=nextInput;}
  filmdevelop::contract::RenderJob job;
  job.recipe.style=id;job.recipe.adjustment=style.at("adjustment");job.preview=true;
  std::vector<filmdevelop::RepairPatch> patches;
  if(style.contains("repairPatches")) {
   for(size_t i=0;i<style.at("repairPatches").size();++i) {
    const auto &p=style.at("repairPatches").at(i),&files=style.at("patchPixels").at(i);
    patches.push_back({p.at("x"),p.at("y"),p.at("width"),p.at("height"),p.at("linearGain"),
     read_pfm((folder/files.at("image").get<std::string>()).string()),read_pfm((folder/files.at("mask").get<std::string>()).string())});
   }
  }
  auto start=std::chrono::steady_clock::now();
  auto result=filmdevelop::render_style(input,input,job,neutral,catalog,mono,data,compute,patches);
  auto expected=read_pfm((folder/(name+".pfm")).string());double maximum=0,squared=0,mean=0;
  if(result.width!=expected.width || result.height!=expected.height)throw std::runtime_error("尺寸不符");
  std::vector<double> errors;
  for(size_t i=0;i<result.pixels.size();++i)for(int c=0;c<3;++c) {
   auto a=film_cpu::rgb(result.pixels[i]),b=film_cpu::rgb(expected.pixels[i]);
   double delta=std::abs(srgb(a[c])-srgb(b[c]));maximum=std::max(maximum,delta);mean+=delta;squared+=delta*delta;errors.push_back(delta);
  }
  std::sort(errors.begin(),errors.end());double count=double(errors.size());
  Json item={{"style",name},{"maxError",maximum},{"p99",errors[size_t(count*.99)]},{"mean",mean/count},{"rmse",std::sqrt(squared/count)},
    {"seconds",std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()}};
  item["passed"] = maximum <= .035 && item["p99"].get<double>() <= .004 && item["rmse"].get<double>() <= .001;
  passed = passed && item["passed"].get<bool>();
  report.push_back(item);std::cout<<item.dump()<<std::endl;
  // PFM 沒有 alpha；參考 PNG 也以預乘 RGB 寫入，診斷圖明確合成於黑底。
  for(auto &p:result.pixels)p.a=1;
  write_pfm((folder/(name+(cpu?"-cpu.pfm":"-cpp.pfm"))).string(),result);
 }
 std::ofstream(folder/(cpu?"cpu-report.json":"cpp-report.json"))<<report.dump(2)<<'\n';
 if(!passed)throw std::runtime_error("Swift 完整配方金樣本差異超限");
 return 0;
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}}
