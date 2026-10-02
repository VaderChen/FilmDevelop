#include "neural.hpp"
#define ORT_API_MANUAL_INIT
#include <onnxruntime_cxx_api.h>
#include <cstring>
#include <dxgi1_2.h>
#include <algorithm>
#include <thread>
namespace filmdevelop {
struct NeuralRuntime::Impl {
    HMODULE library=nullptr;
    Ort::Env env{nullptr};
    Ort::Session session{nullptr};
    std::filesystem::path model;
    std::string backend="cpu";
    using AppendDML = OrtStatus *(ORT_API_CALL *)(OrtSessionOptions *,int);
    AppendDML appendDML=nullptr;
    std::vector<int> adapters;
    explicit Impl(const std::filesystem::path &folder) {
        library=LoadLibraryExW((folder/L"onnxruntime.dll").c_str(),nullptr,LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR|LOAD_LIBRARY_SEARCH_SYSTEM32);
        if(!library)throw Failure("modelUnavailable","無法載入 Windows 原生推論核心");
        const OrtApiBase *(ORT_API_CALL *entry)()=nullptr;
        auto address=GetProcAddress(library,"OrtGetApiBase");static_assert(sizeof(entry)==sizeof(address));std::memcpy(&entry,&address,sizeof(entry));
        const auto *api=entry?entry()->GetApi(ORT_API_VERSION):nullptr;
        if(!api){FreeLibrary(library);library=nullptr;throw Failure("modelUnavailable","原生推論介面版本不符");}
        Ort::InitApi(api);
        try {
            env=Ort::Env(ORT_LOGGING_LEVEL_ERROR,"FilmDevelop");
            // 此 C 匯出由釘選的官方 ORT 套件提供，無須將 DirectML C++ 介面綁入 MinGW。
            auto append=GetProcAddress(library,"OrtSessionOptionsAppendExecutionProvider_DML");std::memcpy(&appendDML,&append,sizeof(appendDML));
            if(appendDML) {
                Com<IDXGIFactory1> factory;
                if(SUCCEEDED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) {
                    std::vector<std::pair<size_t,int>> devices;
                    for(UINT i=0;;++i) {
                        Com<IDXGIAdapter1> adapter;
                        if(factory->EnumAdapters1(i,&adapter)==DXGI_ERROR_NOT_FOUND)break;
                        DXGI_ADAPTER_DESC1 description{};
                        if(adapter && SUCCEEDED(adapter->GetDesc1(&description)) && !(description.Flags&DXGI_ADAPTER_FLAG_SOFTWARE))devices.emplace_back(description.DedicatedVideoMemory,int(i));
                    }
                    std::stable_sort(devices.begin(),devices.end(),[](auto a,auto b){return a.first>b.first;});
                    for(auto device:devices)adapters.push_back(device.second);
                }
            }
        } catch(...) {env=Ort::Env(nullptr);FreeLibrary(library);library=nullptr;throw;}
    }
    // ORT 保有程序層級的執行緒／TLS；卸載 DLL 會破壞仍在展開中的 C++ 例外。
    // 工作使用獨立程序，DLL 交由 Windows 在程序結束時回收。
    ~Impl(){session=Ort::Session(nullptr);env=Ort::Env(nullptr);}
    void load(const std::filesystem::path &path,bool gpu) {
        Ort::SessionOptions options;
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        options.SetIntraOpNumThreads(std::max(1u,std::thread::hardware_concurrency()/2));
        options.DisableMemPattern();options.SetExecutionMode(ExecutionMode::ORT_SEQUENTIAL);
        if(gpu && appendDML)for(int adapter:adapters) {
            try {
                auto candidate=options.Clone();Ort::ThrowOnError(appendDML(candidate,adapter));
                session=Ort::Session(env,path.c_str(),candidate);backend="directml";model=path;return;
            } catch(const Ort::Exception &) {}
        }
        session=Ort::Session(env,path.c_str(),options);backend="cpu";model=path;
    }
    std::vector<Tensor> execute(const std::vector<Tensor> &inputs) {
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        std::vector<Ort::Value> values;std::vector<const char *> names;
        for(const auto &input:inputs) {
            size_t count=1;
            for(auto size:input.shape){if(size<=0 || size>160000000 || count>size_t(160000000/size))throw Failure("invalidRequest","推論張量尺寸不符");count*=size;}
            if(count!=input.values.size())throw Failure("invalidRequest","推論張量資料長度不符");
            values.push_back(Ort::Value::CreateTensor<float>(memory,const_cast<float *>(input.values.data()),input.values.size(),input.shape.data(),input.shape.size()));names.push_back(input.name.c_str());
        }
        Ort::AllocatorWithDefaultOptions allocator;
        std::vector<Ort::AllocatedStringPtr> allocated;std::vector<const char *> outputNames;
        for(size_t i=0;i<session.GetOutputCount();++i){allocated.push_back(session.GetOutputNameAllocated(i,allocator));outputNames.push_back(allocated.back().get());}
        auto outputs=session.Run(Ort::RunOptions{},names.data(),values.data(),values.size(),outputNames.data(),outputNames.size());
        std::vector<Tensor> result;
        for(size_t i=0;i<outputs.size();++i) {
            auto info=outputs[i].GetTensorTypeAndShapeInfo();
            if(info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || info.GetElementCount()>160000000)throw Failure("inferenceFailed","模型輸出不是有效浮點影像");
            auto pointer=outputs[i].GetTensorData<float>();result.push_back({outputNames[i],info.GetShape(),{pointer,pointer+info.GetElementCount()}});
        }
        return result;
    }
};
NeuralRuntime::NeuralRuntime(const std::filesystem::path &folder):impl(std::make_unique<Impl>(folder)){}
NeuralRuntime::~NeuralRuntime()=default;
Json NeuralRuntime::prepare(const std::filesystem::path &model) {
    if(model!=impl->model)impl->load(model,true);
    Ort::AllocatorWithDefaultOptions allocator;Json inputs=Json::array(),outputs=Json::array();
    for(size_t i=0;i<impl->session.GetInputCount();++i) {auto name=impl->session.GetInputNameAllocated(i,allocator);auto info=impl->session.GetInputTypeInfo(i);auto tensor=info.GetTensorTypeAndShapeInfo();inputs.push_back({{"name",name.get()},{"shape",tensor.GetShape()},{"type",tensor.GetElementType()}});}
    for(size_t i=0;i<impl->session.GetOutputCount();++i) {auto name=impl->session.GetOutputNameAllocated(i,allocator);auto info=impl->session.GetOutputTypeInfo(i);auto tensor=info.GetTensorTypeAndShapeInfo();outputs.push_back({{"name",name.get()},{"shape",tensor.GetShape()},{"type",tensor.GetElementType()}});}
    return {{"ready",true},{"computeRoute",impl->backend},{"inputs",inputs},{"outputs",outputs}};
}
std::vector<Tensor> NeuralRuntime::run(const std::filesystem::path &model,const std::vector<Tensor> &inputs) {
    if(model!=impl->model)impl->load(model,true);
    try{return impl->execute(inputs);}
    catch(const Ort::Exception &) {if(impl->backend!="directml")throw;impl->session=Ort::Session(nullptr);impl->load(model,false);return impl->execute(inputs);}
}
std::string NeuralRuntime::route()const{return impl->backend;}
}
