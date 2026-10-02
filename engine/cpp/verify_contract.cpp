#include "Contract.generated.hpp"
#include <iostream>

using namespace filmdevelop::contract;
using Json = nlohmann::json;

// 此工具只驗證跨語言序列化，不宣告具備完整 Windows 渲染能力。
static Json roundtrip(const Json& input) {
    const auto request = input.get<Request>();
    if (request.version != version) throw std::invalid_argument("不支援的引擎版本");
    if (request.method == "render") return Json(request.payload.get<RenderJob>());
    if (request.method == "editRecipe") return Json(request.payload.get<EditorRequest>());
    if (request.method == "normalizeRecipe") return Json(request.payload.get<Recipe>());
    throw std::invalid_argument("不支援的契約 Smoke 操作");
}

int main(int argc, char** argv) {
    std::string id;
    try {
        if (argc == 2 && std::string(argv[1]) == "--self-test") {
            Recipe recipe{1,"filmPortra400",{{"schemaVersion",12},{"exposure",12.5}},Json::array(),false};
            RenderJob job{{u8"C:\\照片\\底片.nef","software",true},
                          {u8"C:\\照片\\輸出.png","png",16,"sRGB",.95,0,false,1},
                          recipe,"vulkan",false,2048};
            Json request = Request{version,"smoke","render",Json(job)};
            if (roundtrip(request) != Json(job)) throw std::runtime_error("完整配方往返失敗");
            int rejected = 0;
            for (int test=0; test<5; ++test) {
                Json bad = request;
                if (test==0) bad["version"]=2;
                if (test==1) bad["version"]=1.5;
                if (test==2) bad["unexpected"]=true;
                if (test==3) bad["payload"]["output"].erase("bitDepth");
                if (test==4) bad["payload"]["preview"]="false";
                try { (void)roundtrip(bad); } catch (const std::exception&) { ++rejected; }
            }
            if (rejected!=5) throw std::runtime_error("契約錯誤未被拒絕");
            std::cout << u8"C++ 契約 Smoke 通過：Unicode、完整配方往返、版本與型別拒絕\n";
            return 0;
        }
        std::string data;
        char byte;
        while (std::cin.get(byte)) {
            if (data.size() >= maxMessageBytes) throw std::invalid_argument("請求超過大小限制");
            data.push_back(byte);
        }
        const auto request = Json::parse(data);
        id = request.value("id",std::string{});
        const auto payload = roundtrip(request);
        std::cout << Json(Response{version,id,"result",payload,std::nullopt}).dump() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cout << Json(Response{version,id,"error",nullptr,EngineError{"invalidContract",error.what()}}).dump() << '\n';
        return 1;
    }
}
