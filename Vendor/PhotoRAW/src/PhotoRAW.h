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
// Linear RGB is Float32 storage of LibRaw's clipped RGB16 output, not HDR.
// Calls are serialized inside the library, including all LibRaw destruction.
int photo_raw_decode(const unsigned char *data, size_t length, int half_size,
                     const char *mapping_directory, PhotoRAWPixels *result);
void photo_raw_free(PhotoRAWPixels *result);
const char *photo_raw_error(void);
#ifdef __cplusplus
}
#endif
