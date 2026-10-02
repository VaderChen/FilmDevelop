#pragma once
#include "photocore/core.hpp"
#include <filesystem>
#include <nlohmann/json.hpp>
#include <string>
#include <optional>
#include <map>
#include <vector>
#include <wincodec.h>
#include <windows.h>
#include <wrl/client.h>

namespace filmdevelop {
using Json = nlohmann::json;
template <class T> using Com = Microsoft::WRL::ComPtr<T>;
struct Failure : std::runtime_error {
  std::string code;
  Failure(std::string c, std::string m)
      : std::runtime_error(m), code(std::move(c)) {}
};
void checked(HRESULT result, const char *message);
std::wstring wide(const std::string &value);
std::string utf8(const std::wstring &value);
std::string base64(const std::vector<unsigned char> &bytes);
std::vector<unsigned char> unbase64(const std::string &text);
struct Decoded {
  photocore::Image image;
  bool raw = false;
  unsigned orientation = 1;
  bool colorManaged = false;
  std::string backend = "not-raw";
  bool systemFallback = false;
  std::optional<photocore::Image> original;
};
class Codec {
  Com<IWICImagingFactory> factory;
  Json exportSpaces;
  std::map<std::string, std::vector<unsigned char>> exportProfiles;
  Decoded decodeWIC(const std::string &path, unsigned maxPixel, bool thumbnail);
  Decoded decodeWebP(const std::string &path, unsigned maxPixel);
  photocore::Image decodePixels(Com<IWICBitmapSource> source, unsigned maxPixel, bool mask);
  Decoded decodeFrame(Com<IWICBitmapDecoder> decoder, unsigned maxPixel, bool thumbnail, bool raw, bool mask = false);

public:
  Codec();
  Json capabilities();
  Decoded decode(const std::string &path, unsigned maxPixel = 0,
                 bool thumbnail = false, const std::string &backend = "system");
  Json metadata(const std::string &path);
  photocore::Image decodeData(const std::vector<unsigned char> &bytes, bool mask = false);
  std::vector<unsigned char> encode(const photocore::Image &image,
                                    const std::string &format,
                                    unsigned bitDepth, double quality,
                                    unsigned tiffCompression = 1,
                                    const std::string &colorSpace = "sRGB",
                                    bool webPLossless = false);
};
photocore::Image resized(const photocore::Image &image, unsigned maxPixel);
} // namespace filmdevelop
