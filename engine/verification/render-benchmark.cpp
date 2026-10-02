// 純渲染計時：排除解碼、資料載入、誤差排序與輸出寫入，暖機後取七次中位數。
#include "render_pipeline.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
using namespace photocore;
using Json=nlohmann::json;
int main(int argc,char **argv) {try {
    if(argc!=4)throw std::runtime_error("需要資料、測例 JSON、參考影像目錄");
    film_cpu::Database data(argv[1]);Json cases;std::ifstream(argv[2])>>cases;
    Json catalog,mono,neutral;
    for(const auto &s:cases.at("styles")) {
        std::string id=s.at("id");if(!catalog.contains(id))catalog[id]=s.at("adjustment");mono[id]=s.at("isMonochrome");
        if(id=="original" && neutral.is_null())neutral=s.at("adjustment");
    }
    Json report=Json::array();double checksum=0;
    for(const auto &s:cases.at("styles")) {
        auto path=[&](const std::string &name){return std::string(argv[3])+"/"+name;};
        auto input=read_pfm(path(s.value("input",std::string("input.pfm"))));
        filmdevelop::contract::RenderJob job;job.preview=true;job.recipe.style=s.at("id");job.recipe.adjustment=s.at("adjustment");
        std::vector<filmdevelop::RepairPatch> patches;
        if(s.contains("repairPatches"))for(size_t i=0;i<s.at("repairPatches").size();++i) {
            auto p=s.at("repairPatches")[i],files=s.at("patchPixels")[i];
            patches.push_back({p.at("x"),p.at("y"),p.at("width"),p.at("height"),p.at("linearGain"),read_pfm(path(files.at("image"))),read_pfm(path(files.at("mask")))});
        }
        std::vector<double> durations;
        for(int i=0;i<10;++i) {
            auto start=std::chrono::steady_clock::now();
            auto output=filmdevelop::render_style(input,input,job,neutral,catalog,mono,data,{},patches);
            double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
            checksum+=output.pixels[output.pixels.size()/2].r;
            if(i>=3)durations.push_back(ms);
        }
        auto sorted=durations;std::sort(sorted.begin(),sorted.end());
        report.push_back({{"case",s.value("case",s.at("id").get<std::string>())},{"width",input.width},{"height",input.height},{"milliseconds",sorted[3]},{"samples",durations}});
    }
    std::cout<<Json{{"cases",report},{"checksum",checksum}}.dump(2)<<'\n';
    return 0;
} catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 1;}}
