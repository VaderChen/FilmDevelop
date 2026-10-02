// 底片新增階段比對 CPU / Vulkan；透明度、晶體種子、常駐 DAG 都必須保留。
#include "PhotoCompute.h"
#include "film_internal.hpp"
#include <iostream>
#include <memory>
#include <chrono>
using namespace photocore;
using namespace photocore::film_cpu;
int main(int argc, char **argv) { try {
    if (argc != 3) throw std::runtime_error("需底片資料與 shader");
    char error[2048]{};
    std::unique_ptr<void, decltype(&photo_compute_destroy)> engine(photo_compute_create(argv[1], argv[2], error, sizeof(error)), photo_compute_destroy);
    if (!engine) throw std::runtime_error(error);
    Image input(127, 91);
    for (size_t i=0;i<input.pixels.size();++i) {
        double a = i%47 == 0 ? 0 : .2 + .8 * (i%31)/30;
        input.pixels[i] = {float((.02+.7*(i%127)/126)*a),float((.01+.55*(i/127)/90)*a),float((.03+.9*(i%23)/22)*a),float(a)};
    }
    Json effects={{"emulsion_mtf",40},{"bloom_amount",25},{"bloom_radius",.4},{"bloom_threshold",55},
        {"grain_size",4},{"grain_distribution",8},{"grain_clumping",23},{"grain_chroma",32},
        {"halation_amount",20},{"halation_radius",.15},{"halation_threshold",40}};
    Json adjustment={{"grain",40},{"highlightGrain",30}};
    Json nodes=Json::array();
    for (auto stage : {"lightScatter","emulsion"}) nodes.push_back({{"source",nodes.size()},
        {"operation",{{"schema",1},{"stage",stage},{"effects",effects},{"adjustment",adjustment},
                       {"strength",.5},{"monochrome",false},{"preview",true}}}});
    Image output(input.width,input.height);
    auto request=Json({{"schema",2},{"nodes",nodes}}).dump();
    auto start=std::chrono::steady_clock::now();
    if(photo_compute_process(engine.get(),request.c_str(),reinterpret_cast<float*>(input.pixels.data()),reinterpret_cast<float*>(output.pixels.data()),input.width,input.height,error,sizeof(error))) throw std::runtime_error(error);
    auto cpu=emulsion(light_scatter(input,Effects{effects},.5),Effects{effects},adjustment,.5,false,true);
    double maximum=0,total=0,alpha=0;
    for(size_t i=0;i<cpu.pixels.size();++i) {
        auto a=cpu.pixels[i], b=output.pixels[i];
        for(auto d:{a.r-b.r,a.g-b.g,a.b-b.b}) {maximum=std::max(maximum,std::abs(double(d)));total+=std::abs(d);}
        alpha=std::max(alpha,std::abs(double(b.a-input.pixels[i].a)));
    }
    PhotoComputeTransfers transfers{};photo_compute_transfers(engine.get(),&transfers);
    double mean=total/(cpu.pixels.size()*3);
    std::cout<<Json({{"maxError",maximum},{"meanError",mean},{"alphaError",alpha},{"uploads",transfers.uploads},{"downloads",transfers.downloads},
        {"seconds",std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()}}).dump()<<'\n';
    if (maximum>.003 || mean>.0001 || alpha>1e-6 || transfers.uploads!=1 || transfers.downloads!=1) throw std::runtime_error("光學／乳劑差異超過浮點與取樣容許範圍");
    return 0;
} catch(const std::exception &e) {std::cerr<<e.what()<<'\n';return 1;} }
