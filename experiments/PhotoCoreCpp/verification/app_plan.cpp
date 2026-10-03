// App C ABI 實際 GPU 計算圖：比對逐階段結果並驗證 CPU/GPU 傳輸次數。
#include "PhotoCompute.h"
#include <nlohmann/json.hpp>
#include <vector>
#include <stdexcept>
#include <iostream>
#include <memory>
#include <cmath>
using Json=nlohmann::json;
void require(bool condition,const char *message){if(!condition)throw std::runtime_error(message);}
int main(int argc,char **argv){try{
 require(argc==3,"需指定底片資料及 shader");require(photo_compute_abi()==2,"ABI 不符");
 char error[2048]{};
 std::unique_ptr<void,decltype(&photo_compute_destroy)> engine(photo_compute_create(argv[1],argv[2],error,sizeof(error)),photo_compute_destroy);
 require(bool(engine),error);
 constexpr unsigned w=96,h=64;
 std::vector<float> input(w*h*4),sequential(input.size()),output(input.size()),scratch(input.size());
 for(size_t i=0;i<input.size()/4;++i){float alpha=.2f+.8f*float(i%31)/30;
  input[i*4]=(.02f+.8f*float(i%97)/96)*alpha;input[i*4+1]=(.01f+.6f*float(i%83)/82)*alpha;input[i*4+2]=(.03f+.7f*float(i%79)/78)*alpha;input[i*4+3]=alpha;}
 Json effects={{"development_amount",65},{"coupler_amount",30},{"scanner_profile","neutral"},
 {"developer_chemistry",{{"contrast",1.15},{"grain",45},{"acutance",50}}}};
 Json nodes=Json::array();
 for(auto stage:{"development","chemistry","spectral","character"})
  nodes.push_back({{"source",nodes.size()},{"operation",{{"schema",1},{"stage",stage},{"effects",effects},{"strength",.6},{"monochrome",false},{"stock","filmPortra400"},{"originX",0},{"originY",0}}}});
 Json plan={{"schema",2},{"nodes",nodes}};
 auto run=[&](const Json &request,const std::vector<float> &src,std::vector<float> &dst){auto json=request.dump();return photo_compute_process(engine.get(),json.c_str(),src.data(),dst.data(),w,h,error,sizeof(error));};
 auto counters=[&](){PhotoComputeTransfers value{};require(photo_compute_transfers(engine.get(),&value)==0,"無法讀取傳輸統計");return value;};
 auto begin=counters();require(run(plan,input,output)==0,error);auto end=counters();
 require(end.uploads-begin.uploads==1 && end.downloads-begin.downloads==1,"計算圖中途發生 CPU 影像往返");
 require(end.uploaded_bytes-begin.uploaded_bytes==input.size()*sizeof(float) && end.downloaded_bytes-begin.downloaded_bytes==input.size()*sizeof(float),"傳輸大小不符");
 sequential=input;begin=counters();
 for(const auto &node:nodes){require(run(node.at("operation"),sequential,scratch)==0,error);sequential.swap(scratch);}
 end=counters();require(end.uploads-begin.uploads==4 && end.downloads-begin.downloads==4,"逐階段對照組未執行四次傳輸");
 double maxError=0;for(size_t i=0;i<output.size();++i)maxError=std::max(maxError,std::abs(double(output[i])-sequential[i]));
 require(maxError<1e-6,"計算圖改變階段結果");
 // 保留根影像供最後混合，驗證非線性序列之外的分支擁有權與 alpha。
 plan["nodes"].push_back({{"source",0},{"secondary",4},{"operation",{{"schema",1},{"stage","blend"},{"strength",.6}}}});
 require(run(plan,input,output)==0,error);
 for(size_t i=0;i<output.size();++i){float expected=.6f*sequential[i]+input[i]*(1-.6f);require(std::abs(output[i]-expected)<2e-6,"GPU 分支混合或 alpha 不符");}
 for(int i=0;i<20;++i){auto invalid=plan;invalid["nodes"][0]["source"]=99;require(run(invalid,input,scratch)!=0,"未拒絕向後相依");}
 require(run(plan,input,scratch)==0,error);
 require(output==scratch,"錯誤復原後結果不一致");
 // 相同處理狀態的強度插值必須完全保留影像，包含半透明。
 for(float amount:{0.f,.25f,.5f,.75f,1.f}) {
  Json same={{"schema",2},{"nodes",Json::array({{{"source",0},{"secondary",0},{"operation",{{"schema",1},{"stage","blend"},{"strength",amount}}}}})}};
  require(run(same,input,scratch)==0,error);
  for(size_t i=0;i<input.size();++i)require(std::abs(scratch[i]-input[i])<1e-6,"GPU 相同狀態混合改變色彩或 alpha");
 }
 std::cout<<"{\"passed\":true,\"plan_uploads\":1,\"plan_downloads\":1,\"sequential_uploads\":4,\"sequential_downloads\":4,\"max_float_error\":"<<maxError<<",\"invalid_graphs\":20}\n";
 return 0;
}catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}}
