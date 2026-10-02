#include "inference.hpp"
#include <ggml-backend.h>
#include <llama.h>
#include <mtmd.h>
#include <mtmd-helper.h>
#include <algorithm>
#include <cstring>
#include <thread>
namespace filmdevelop {
namespace {
std::string chat(llama_model *model,const contract::InferenceRequest &request) {
    std::string user=request.userPrompt;
    const char *marker=mtmd_default_marker();
    for(size_t at=0;(at=user.find("<image>",at))!=std::string::npos;at+=std::strlen(marker))user.replace(at,7,marker);
    const char *format=llama_model_chat_template(model,nullptr);
    if(format && std::strstr(format,"<|turn>") && std::strstr(format,"<turn|>"))
        return "<|turn>system\n"+request.systemPrompt+"<turn|>\n<|turn>user\n"+user+"<turn|>\n<|turn>model\n";
    if(format) {
        llama_chat_message messages[]{{"system",request.systemPrompt.c_str()},{"user",user.c_str()}};
        std::vector<char> buffer(std::max<size_t>(4096,(request.systemPrompt.size()+user.size())*4));
        int size=llama_chat_apply_template(format,messages,2,true,buffer.data(),int(buffer.size()));
        if(size>=0) {
            if(size>=int(buffer.size())){buffer.resize(size_t(size)+1);size=llama_chat_apply_template(format,messages,2,true,buffer.data(),int(buffer.size()));}
            if(size>=0 && size<int(buffer.size()))return {buffer.data(),size_t(size)};
        }
    }
    return "System:\n"+request.systemPrompt+"\nUser:\n"+user+"\nAssistant:\n";
}
Json generate(const contract::InferenceRequest &request,const std::vector<unsigned char> &image,bool gpu,bool mmap,const std::function<void(double)> &progress) {
    int threads=int(std::max(1u,std::thread::hardware_concurrency()/2));
    auto mp=llama_model_default_params();mp.n_gpu_layers=gpu?999:0;mp.use_mmap=mmap;mp.use_mlock=false;
    std::unique_ptr<llama_model,decltype(&llama_model_free)> model(llama_model_load_from_file(request.modelPath.c_str(),mp),llama_model_free);
    if(!model)throw Failure("modelLoadFailed","模型無法載入；請確認檔案與可用記憶體");
    progress(.1);
    auto vp=mtmd_context_params_default();vp.use_gpu=gpu;vp.n_threads=threads;vp.print_timings=false;vp.warmup=false;
    std::unique_ptr<mtmd_context,decltype(&mtmd_free)> vision(mtmd_init_from_file(request.projectorPath.c_str(),model.get(),vp),mtmd_free);
    if(!vision || !mtmd_support_vision(vision.get()))throw Failure("projectorLoadFailed","視覺模型無法載入或與主模型不符");
    auto cp=llama_context_default_params();cp.n_ctx=uint32_t(request.contextLimit);cp.n_batch=512;cp.n_ubatch=512;cp.n_seq_max=1;cp.n_threads=cp.n_threads_batch=threads;cp.offload_kqv=gpu;
    std::unique_ptr<llama_context,decltype(&llama_free)> context(llama_init_from_model(model.get(),cp),llama_free);
    if(!context)throw Failure("contextCreateFailed","無法建立推論工作");
    std::unique_ptr<mtmd_bitmap,decltype(&mtmd_bitmap_free)> bitmap(mtmd_helper_bitmap_init_from_buf(vision.get(),image.data(),image.size()),mtmd_bitmap_free);
    if(!bitmap)throw Failure("imageDecodeFailed","推論照片無法解析");
    mtmd_bitmap_set_id(bitmap.get(),"photo-style-source");
    std::unique_ptr<mtmd_input_chunks,decltype(&mtmd_input_chunks_free)> chunks(mtmd_input_chunks_init(),mtmd_input_chunks_free);
    const auto prompt=chat(model.get(),request);mtmd_input_text text{prompt.c_str(),true,true};const mtmd_bitmap *bitmaps[]{bitmap.get()};
    if(mtmd_tokenize(vision.get(),chunks.get(),&text,bitmaps,1))throw Failure("imageTokenizationFailed","無法建立照片與提示詞的模型輸入");
    if(mtmd_helper_get_n_tokens(chunks.get())>size_t(request.contextLimit-request.maxTokens))throw Failure("promptTooLong","提示詞與照片超過模型上下文限制");
    progress(.2);llama_pos past=0;
    if(mtmd_helper_eval_chunks(vision.get(),context.get(),chunks.get(),0,0,512,true,&past))throw Failure("generationFailed","照片編碼或提示詞推論失敗");
    const auto *vocab=llama_model_get_vocab(model.get());
    std::unique_ptr<llama_sampler,decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()),llama_sampler_free);
    auto grammar=llama_sampler_init_grammar(vocab,request.grammar.c_str(),"root");
    if(!grammar)throw Failure("grammarCreateFailed","模型輸出契約無法建立");
    llama_sampler_chain_add(sampler.get(),grammar);llama_sampler_chain_add(sampler.get(),llama_sampler_init_greedy());
    std::string generated;int depth=0;bool started=false,quoted=false,escaped=false;
    for(int64_t i=0;i<request.maxTokens;++i) {
        auto token=llama_sampler_sample(sampler.get(),context.get(),-1);
        if(llama_vocab_is_eog(vocab,token))break;
        std::vector<char> piece(128);int size=llama_token_to_piece(vocab,token,piece.data(),int(piece.size()),0,true);
        if(size<0){piece.resize(size_t(-size));size=llama_token_to_piece(vocab,token,piece.data(),int(piece.size()),0,true);}
        if(size<0)throw Failure("generationFailed","模型 token 無法解析");
        generated.append(piece.data(),size_t(size));
        for(int j=0;j<size;++j) {
            char c=piece[j];if(escaped){escaped=false;continue;}if(c=='\\' && quoted){escaped=true;continue;}if(c=='"'){quoted=!quoted;continue;}if(quoted)continue;
            if(c=='{'){started=true;++depth;}else if(c=='}')--depth;
        }
        if(started && depth<=0)break;
        if(i%32==0)progress(.25+.7*double(i)/request.maxTokens);
        auto batch=llama_batch_get_one(&token,1);if(llama_decode(context.get(),batch))throw Failure("generationFailed","模型生成失敗");
    }
    if(!started || depth!=0 || quoted)throw Failure("generationFailed","模型未產生完整配方，請調整提示詞後重試");
    auto object=Json::parse(generated);if(!object.is_object())throw Failure("generationFailed","模型輸出格式不符");
    progress(1);
    return {{"text",generated},{"computeRoute",gpu?"vulkan":"cpu"}};
}
}
Json infer_photo(const contract::InferenceRequest &request,const std::filesystem::path &folder,const std::function<void(double)> &progress) {
    if(request.format!="gguf" || request.maxTokens<1 || request.maxTokens>4096 || request.contextLimit<4096 || request.contextLimit>16384 || request.grammar.empty())throw Failure("invalidRequest","推論參數無效");
    auto image=unbase64(request.imageData);
    static const bool initialized=[&] {
        ggml_backend_load((folder/L"ggml-cpu.dll").u8string().c_str());
        ggml_backend_load((folder/L"ggml-vulkan.dll").u8string().c_str());
        llama_backend_init();return true;
    }();(void)initialized;
    if(!ggml_backend_dev_count())throw Failure("backendUnavailable","找不到可用的模型運算核心");
    bool gpu=false;for(size_t i=0;i<ggml_backend_dev_count();++i)if(ggml_backend_dev_type(ggml_backend_dev_get(i))==GGML_BACKEND_DEVICE_TYPE_GPU)gpu=true;
    std::string error;
    for(auto attempt:std::vector<std::pair<bool,bool>>{{gpu,true},{false,true},{false,false}}) {
        try{return generate(request,image,attempt.first,attempt.second,progress);}
        catch(const std::exception &e){error=e.what();const auto *failure=dynamic_cast<const Failure *>(&e);if(failure && (failure->code=="promptTooLong" || failure->code=="grammarCreateFailed" || failure->code=="imageDecodeFailed"))throw;}
    }
    throw Failure("generationFailed",error);
}
}
