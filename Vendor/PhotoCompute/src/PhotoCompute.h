#pragma once
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32)
#define PHOTO_COMPUTE_API __declspec(dllexport)
#else
#define PHOTO_COMPUTE_API __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
// ABI 2：連續、頂列在前、預乘 RGBA Float32、extended-linear sRGB。
// schema 2 的有向無環計算圖只上傳／下載一次，中間影像由 GPU RAII 管理。
// 保留 schema 1 單階段請求供對照與獨立工具使用。
// 呼叫端持有輸入／輸出；不得重疊。每個 handle 的呼叫必須序列化。
PHOTO_COMPUTE_API uint32_t photo_compute_abi(void);
PHOTO_COMPUTE_API void *photo_compute_create(const char *data, const char *shader, char *error, size_t capacity);
PHOTO_COMPUTE_API int photo_compute_process(void *handle, const char *request, const float *input,
    float *output, uint32_t width, uint32_t height, char *error, size_t capacity);
PHOTO_COMPUTE_API void photo_compute_destroy(void *handle);
typedef struct PhotoComputeTransfers {
    uint64_t uploads, downloads, uploaded_bytes, downloaded_bytes;
} PhotoComputeTransfers;
// 從 engine 建立起累計的影像傳輸量，用於整合與效能驗證。
PHOTO_COMPUTE_API int photo_compute_transfers(void *handle, PhotoComputeTransfers *output);
#ifdef __cplusplus
}
#endif
