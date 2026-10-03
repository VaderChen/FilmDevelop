#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PhotoRAWPixels {
    float *linear_rgba;
    unsigned char *display_rgb;
    int width, height;
    int mapping_applied;
} PhotoRAWPixels;
typedef struct PhotoRAWMetadata {
    unsigned width, height, orientation;
    double iso, exposure, aperture, focal_length, focal_length_35mm;
    char make[64], model[64], lens_make[128], lens[128], lens_serial[128];
    char captured_at[32];
} PhotoRAWMetadata;
typedef struct PhotoRAWInfo {
    unsigned width, height;
    int supported, dng, mosaic;
} PhotoRAWInfo;
// 辨認實際感光資料及解碼器能力；不以副檔名或內嵌預覽推斷支援。
int photo_raw_probe(const unsigned char *data, size_t length, PhotoRAWInfo *result);
// 只識別 RAW 與讀取 EXIF，不解馬賽克、不依賴顯影支援。
int photo_raw_metadata(const unsigned char *data, size_t length, PhotoRAWMetadata *result);
// 依照完整解碼的方向與像素比例回報輸出尺寸，不解馬賽克。
int photo_raw_dimensions(const unsigned char *data, size_t length, unsigned *width, unsigned *height);
// Linear RGB is Float32 storage of LibRaw's clipped RGB16 output, not HDR.
// Calls are serialized inside the library, including all LibRaw destruction.
// -2 表示已辨認的 RAW 壓縮方式缺少解碼器；其他錯誤回傳 -1。
int photo_raw_decode(const unsigned char *data, size_t length, int half_size,
                     const char *mapping_directory, PhotoRAWPixels *result);
void photo_raw_free(PhotoRAWPixels *result);
const char *photo_raw_error(void);
#ifdef __cplusplus
}
#endif
