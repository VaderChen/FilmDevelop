// 僅供 Windows Smoke 的失敗注入；不封裝進產品。
#include "PhotoCompute.h"
#include <cstdlib>
#include <cstring>
static bool mode(const char *value) {
    const auto setting = std::getenv("FILMDEVELOP_TEST_GPU_FAULT");
    return setting && std::strcmp(setting,value)==0;
}
uint32_t photo_compute_abi() { return 2; }
void *photo_compute_create(const char *,const char *,char *,size_t) { return reinterpret_cast<void*>(1); }
void photo_compute_destroy(void *) {}
int photo_compute_device_info(void *,PhotoComputeDeviceInfo *info) {
    *info={mode("old-loader") ? 1u<<22 : (1u<<22)|(1u<<12),
           mode("old-device") ? 1u<<22 : (1u<<22)|(1u<<12),{}};
    std::strcpy(info->name,"Smoke fault GPU");return 0;
}
int photo_compute_process(void *,const char *,const float *input,float *output,
                          uint32_t width,uint32_t height,char *error,size_t capacity) {
    if(mode("bad-probe") || (mode("render-failure") && width>2)) {
        if(capacity) {std::strncpy(error,"Smoke GPU failure",capacity-1);error[capacity-1]=0;}
        return 1;
    }
    std::memcpy(output,input,size_t(width)*height*4*sizeof(float));return 0;
}
int photo_compute_process_inputs(void *engine,const char *plan,const float *input,float *output,
                                 uint32_t width,uint32_t height,const PhotoComputeImageView *,
                                 uint32_t,char *error,size_t capacity) {
    return photo_compute_process(engine,plan,input,output,width,height,error,capacity);
}
