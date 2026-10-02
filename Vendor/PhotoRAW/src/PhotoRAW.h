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
// 只識別 RAW 與讀取 EXIF，不解馬賽克、不依賴顯影支援。
int photo_raw_metadata(const unsigned char *data, size_t length, PhotoRAWMetadata *result);
// 依照完整解碼的方向與像素比例回報輸出尺寸，不解馬賽克。
int photo_raw_dimensions(const unsigned char *data, size_t length, unsigned *width, unsigned *height);
// Linear RGB is Float32 storage of LibRaw's clipped RGB16 output, not HDR.
// Calls are serialized inside the library, including all LibRaw destruction.
int photo_raw_decode(const unsigned char *data, size_t length, int half_size,
                     const char *mapping_directory, PhotoRAWPixels *result);
void photo_raw_free(PhotoRAWPixels *result);
const char *photo_raw_error(void);
#ifdef __cplusplus
}
#endif
