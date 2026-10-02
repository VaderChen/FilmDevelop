#include "codec.hpp"
#include "PhotoRAW.h"
#include "film_internal.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <fstream>
#include <limits>
#include <memory>
#include <set>
#include <sstream>
#include <wincrypt.h>
#include <webp/encode.h>
#include <webp/decode.h>
#include <webp/mux.h>

namespace filmdevelop {
void checked(HRESULT result, const char *message) {
  if (FAILED(result)) {
    std::ostringstream code;
    code << std::hex << static_cast<unsigned long>(result);
    throw Failure("nativeFailure",
                  std::string(message) + "（0x" + code.str() + "）");
  }
}
std::wstring wide(const std::string &value) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                              nullptr, 0);
  if (!n)
    throw Failure("invalidRequest", "路徑不是有效 UTF-8");
  std::wstring result(n, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.c_str(), -1,
                      result.data(), n);
  result.pop_back();
  return result;
}
std::string utf8(const std::wstring &value) {
  int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(), -1,
                              nullptr, 0, nullptr, nullptr);
  if (!n)
    throw Failure("invalidRequest", "系統路徑無法轉換為 UTF-8");
  std::string result(n, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.c_str(), -1,
                      result.data(), n, nullptr, nullptr);
  result.pop_back();
  return result;
}
std::string base64(const std::vector<unsigned char> &bytes) {
  DWORD size = 0;
  if (!CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr,
                            &size))
    throw Failure("encodeFailed", "無法編碼預覽資料");
  std::string value(size, '\0');
  if (!CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                            CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                            value.data(), &size))
    throw Failure("encodeFailed", "無法編碼預覽資料");
  value.resize(size);
  return value;
}
std::vector<unsigned char> unbase64(const std::string &text) {
  if(text.size()>64*1024*1024)throw Failure("invalidRequest","影像資料過大");
  DWORD size=0;
  if(!CryptStringToBinaryA(text.data(),DWORD(text.size()),CRYPT_STRING_BASE64|CRYPT_STRING_STRICT,nullptr,&size,nullptr,nullptr) || !size)throw Failure("invalidRequest","影像 Base64 資料不符");
  std::vector<unsigned char> bytes(size);
  if(!CryptStringToBinaryA(text.data(),DWORD(text.size()),CRYPT_STRING_BASE64|CRYPT_STRING_STRICT,bytes.data(),&size,nullptr,nullptr))throw Failure("invalidRequest","影像 Base64 解码失敗");
  bytes.resize(size);return bytes;
}
namespace {
std::filesystem::path engineFolder() {
  std::wstring path(32768,L'\0');DWORD length=GetModuleFileNameW(nullptr,path.data(),DWORD(path.size()));
  if(!length || length>=path.size())throw Failure("nativeFailure","無法定位原生模組");
  path.resize(length);return std::filesystem::path(path).parent_path();
}
const std::set<std::wstring> rawExtensions{
    L".3fr", L".arw", L".cr2", L".cr3", L".crw", L".dng", L".erf", L".fff", L".iiq",
    L".kdc", L".mef", L".mos", L".mrw", L".nef", L".nrw", L".orf", L".pef",
    L".raf", L".raw", L".rw2", L".rwl", L".sr2", L".srf", L".srw", L".x3f"};
std::wstring lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return std::towlower(c); });
  return value;
}
bool isRawFile(const std::string &path) {
  const auto extension=lower(std::filesystem::path(wide(path)).extension().wstring());
  if(rawExtensions.count(extension))return true;
  if(extension!=L".tif" && extension!=L".tiff")return false;
  // 舊式相機可使用 .tif 裝 RAW；只有成功識別感光資料才改走 RAW。
  std::ifstream file(std::filesystem::u8path(path),std::ios::binary|std::ios::ate);
  if(!file || file.tellg()<=0 || file.tellg()>1024LL*1024*1024)return false;
  std::vector<unsigned char> bytes(static_cast<size_t>(file.tellg()));
  file.seekg(0);file.read(reinterpret_cast<char *>(bytes.data()),bytes.size());
  PhotoRAWMetadata metadata{};
  return file && photo_raw_metadata(bytes.data(),bytes.size(),&metadata)==0;
}
unsigned orientationOf(IWICBitmapFrameDecode *frame) {
  Com<IWICMetadataQueryReader> reader;
  if (FAILED(frame->GetMetadataQueryReader(&reader)))
    return 1;
  for (auto key : {L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
    PROPVARIANT value{};
    HRESULT result = reader->GetMetadataByName(key, &value);
    unsigned orientation =
        SUCCEEDED(result) && value.vt == VT_UI2 ? value.uiVal : 1;
    PropVariantClear(&value);
    if (SUCCEEDED(result) && orientation >= 1 && orientation <= 8)
      return orientation;
  }
  return 1;
}
void dimensions(IWICBitmapSource *source, UINT &w, UINT &h) {
  checked(source->GetSize(&w, &h), "無法讀取影像尺寸");
  // 含配置與 CopyPixels 的 UINT 邊界；拒絕異常尺寸再配置記憶體。
  if (!w || !h || uint64_t(w) * h > 160000000 ||
      uint64_t(w) * h * 16 > UINT_MAX)
    throw Failure("invalidImage", "影像尺寸超出可處理範圍");
}
double fromSRGB(double v) {
  return v <= .04045 ? v / 12.92 : std::pow((v + .055) / 1.055, 2.4);
}
double toSRGB(double v) {
  return v <= .0031308 ? v * 12.92 : 1.055 * std::pow(v, 1 / 2.4) - .055;
}
Decoded softwareRAW(const std::string &path, unsigned maxPixel, bool thumbnail,
                    bool fallback) {
  std::ifstream stream(std::filesystem::u8path(path),
                       std::ios::binary | std::ios::ate);
  if (!stream || stream.tellg() <= 0 || stream.tellg() > 1024LL * 1024 * 1024)
    throw Failure("decodeFailed", "RAW 來源無法讀取或過大");
  std::vector<unsigned char> bytes(static_cast<size_t>(stream.tellg()));
  stream.seekg(0);
  stream.read(reinterpret_cast<char *>(bytes.data()), bytes.size());
  if (!stream)
    throw Failure("decodeFailed", "RAW 來源讀取不完整");
  std::wstring module(32768, L'\0');
  DWORD n = GetModuleFileNameW(nullptr, module.data(),
                               static_cast<DWORD>(module.size()));
  if (!n || n >= module.size())
    throw Failure("decodeFailed", "無法定位 RAW 色彩資料");
  module.resize(n);
  const auto mapping =
      (std::filesystem::path(module).parent_path() / L"RAWMapping").u8string();
  PhotoRAWPixels pixels{};
  if (photo_raw_decode(bytes.data(), bytes.size(), thumbnail ? 1 : 0,
                       mapping.c_str(), &pixels) != 0)
    throw Failure("decodeFailed",
                  std::string("RAW 解析失敗：") + photo_raw_error());
  struct PixelsLifetime {
    PhotoRAWPixels *p;
    ~PixelsLifetime() { photo_raw_free(p); }
  } lifetime{&pixels};
  if (pixels.width <= 0 || pixels.height <= 0 ||
      uint64_t(pixels.width) * pixels.height > 160000000 || !pixels.linear_rgba)
    throw Failure("decodeFailed", "RAW 尺寸或像素不符");
  photocore::Image image(pixels.width, pixels.height);
  for (size_t i = 0; i < image.pixels.size(); ++i)
    image.pixels[i] = {pixels.linear_rgba[i * 4], pixels.linear_rgba[i * 4 + 1],
                       pixels.linear_rgba[i * 4 + 2],
                       pixels.linear_rgba[i * 4 + 3]};
  // 底片接收線性解碼；原片／比較另存相機顯示映射，避免在底片前套用顯示曲線。
  photocore::Image original = image;
  if (pixels.display_rgb)
    for (size_t i = 0; i < image.pixels.size(); ++i)
      original.pixels[i] = {float(fromSRGB(pixels.display_rgb[i * 3] / 255.)),
                         float(fromSRGB(pixels.display_rgb[i * 3 + 1] / 255.)),
                         float(fromSRGB(pixels.display_rgb[i * 3 + 2] / 255.)),
                         1};
  if (maxPixel && std::max(image.width, image.height) > maxPixel)
    image = resized(image, maxPixel);
  if (maxPixel) original = resized(original, maxPixel);
  Decoded result{std::move(image), true, 1, false, "software", fallback, std::move(original)};
  if (thumbnail) result.image = *result.original;
  return result;
}
} // namespace
Codec::Codec() {
  checked(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                           CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)),
          "無法建立 Windows 影像元件");
}
Json Codec::capabilities() {
  Json decoders = Json::array();
  std::set<std::string> raw;
  Com<IEnumUnknown> enumerator;
  checked(factory->CreateComponentEnumerator(
              WICDecoder, WICComponentEnumerateDefault, &enumerator),
          "無法偵測系統解析器");
  Com<IUnknown> item;
  while (enumerator->Next(1, &item, nullptr) == S_OK) {
    Com<IWICBitmapDecoderInfo> info;
    if (SUCCEEDED(item.As(&info))) {
      UINT size = 0;
      info->GetFileExtensions(0, nullptr, &size);
      std::wstring extensions(size, L'\0');
      if (size &&
          SUCCEEDED(info->GetFileExtensions(size, extensions.data(), &size))) {
        Com<IWICBitmapDecoder> probe;
        const bool available = SUCCEEDED(info->CreateInstance(&probe));
        extensions.resize(wcslen(extensions.c_str()));
        std::wstringstream parts(lower(extensions));
        std::wstring extension;
        while (std::getline(parts, extension, L','))
          if (available && rawExtensions.count(extension))
            raw.insert(utf8(extension));
        info->GetFriendlyName(0, nullptr, &size);
        std::wstring name(size, L'\0');
        if (size && SUCCEEDED(info->GetFriendlyName(size, name.data(), &size)))
          name.resize(wcslen(name.c_str()));
        decoders.push_back({{"name", utf8(name)},
                            {"extensions", utf8(extensions)},
                            {"available", available}});
      }
    }
    item.Reset();
  }
  return {{"imageDecoders", decoders},
          {"rawExtensions", raw},
          {"rawDecoders", Json::array({"system", "software"})},
          {"systemRAWAvailable", !raw.empty()},
          {"rawDecoderLabels",
           {{"system", raw.empty() ? "系統自動解析（LibRaw）" : "系統自動解析"},
            {"software", "內建軟體解析（LibRaw）"}}},
          {"rawDecoderMessage", ""}};
}
Decoded Codec::decode(const std::string &path, unsigned maxPixel,
                      bool thumbnail, const std::string &backend) {
  if (backend != "system" && backend != "software")
    throw Failure("invalidRequest", "RAW 解析選項不符");
  const bool raw = isRawFile(path);
  if (raw && backend == "software")
    return softwareRAW(path, maxPixel, thumbnail, false);
  try {
    return decodeWIC(path, maxPixel, thumbnail);
  } catch (const Failure &) {
    if (!raw) {
      if(lower(std::filesystem::path(wide(path)).extension().wstring())==L".webp")return decodeWebP(path,maxPixel);
      throw;
    }
    return softwareRAW(path, maxPixel, thumbnail, true);
  }
}
Decoded Codec::decodeWIC(const std::string &path, unsigned maxPixel,
                         bool thumbnail) {
  const auto filename = wide(path);
  const bool raw = isRawFile(path);
  Com<IWICBitmapDecoder> decoder;
  HRESULT status = factory->CreateDecoderFromFilename(
      filename.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
      &decoder);
  if (FAILED(status))
    throw Failure(
        "decodeFailed",
        raw ? "系統 RAW 解析器無法開啟此相機檔案；請確認 Windows RAW "
              "影像擴充功能與相機支援。"
            : "Windows "
              "影像解析器無法開啟來源照片；檔案可能已損壞或格式不受支援。");
  if (raw && !thumbnail) {
    GUID container{};
    checked(decoder->GetContainerFormat(&container), "無法識別 RAW 解碼器");
    // NEF/DNG 等容器內可有完整或小型 JPEG。一般 TIFF/JPEG 解碼器
    // 讀到它們不代表 RAW 成功，應交給共用 LibRaw，而非用於編輯。
    if (IsEqualGUID(container, GUID_ContainerFormatTiff) ||
        IsEqualGUID(container, GUID_ContainerFormatJpeg) ||
        IsEqualGUID(container, GUID_ContainerFormatPng) ||
        IsEqualGUID(container, GUID_ContainerFormatBmp) ||
        IsEqualGUID(container, GUID_ContainerFormatGif) ||
        IsEqualGUID(container, GUID_ContainerFormatIco))
      throw Failure("decodeFailed", "系統僅能讀取 RAW 容器的預覽，改用內建 RAW 解析。");
  }
  return decodeFrame(std::move(decoder),maxPixel,thumbnail,raw);
}
photocore::Image Codec::decodeData(const std::vector<unsigned char> &bytes,bool mask) {
  if(bytes.empty() || bytes.size()>64*1024*1024)throw Failure("decodeFailed","影像資料長度不符");
  Com<IWICStream> stream;checked(factory->CreateStream(&stream),"無法建立影像讀取串流");
  checked(stream->InitializeFromMemory(const_cast<BYTE *>(bytes.data()),DWORD(bytes.size())),"無法讀取影像資料");
  Com<IWICBitmapDecoder> decoder;
  checked(factory->CreateDecoderFromStream(stream.Get(),nullptr,WICDecodeMetadataCacheOnDemand,&decoder),"影像貼片無法解碼");
  return decodeFrame(std::move(decoder),0,false,false,mask).image;
}
Decoded Codec::decodeFrame(Com<IWICBitmapDecoder> decoder,unsigned maxPixel,bool thumbnail,bool raw,bool mask) {
  Com<IWICBitmapFrameDecode> frame;
  checked(decoder->GetFrame(0, &frame), "無法讀取照片影格");
  if (raw && !thumbnail) {
    // WIC 的容器識別並不保證正在顯影感光資料。依 WIC RAW 契約，
    // 正式 RAW codec 必須提供 IWICDevelopRaw。
    // 只暴露內嵌 JPEG 的相容 codec 仍可供列表使用，編輯則回退 LibRaw。
    // MinGW 的 wincodec.h 尚無此介面宣告；只查詢支援性，使用 IUnknown
    // 管理 COM 生命週期，避免手刻或假設其方法的 vtable。
    constexpr GUID rawDevelopment{0xfbec5e44,0xf7be,0x4b65,{0xb7,0xf8,0xc0,0xc8,0x1f,0xef,0x02,0x6d}};
    Com<IUnknown> develop;
    checked(frame->QueryInterface(rawDevelopment,
            reinterpret_cast<void **>(develop.GetAddressOf())),
            "系統解析器未提供 RAW 顯影介面");
  }
  Com<IWICBitmapSource> source = frame;
  if (thumbnail) {
    Com<IWICBitmapSource> embedded;
    if (SUCCEEDED(frame->GetThumbnail(&embedded)))
      source = embedded;
  }
  const unsigned orientation = orientationOf(frame.Get());
  // 使用檔案 ICC／Exif 色彩描述轉成 sRGB，再轉為共同的線性浮點像素。
  bool managed = false;
  UINT count = 0;
  if (!mask && SUCCEEDED(frame->GetColorContexts(0, nullptr, &count)) && count > 0 &&
      count < 64) {
    std::vector<Com<IWICColorContext>> contexts(count);
    std::vector<IWICColorContext *> pointers;
    for (auto &context : contexts) {
      checked(factory->CreateColorContext(&context), "無法建立色彩描述");
      pointers.push_back(context.Get());
    }
    checked(frame->GetColorContexts(count, pointers.data(), &count),
            "無法讀取色彩描述");
    for (const auto &context : contexts) {
      WICColorContextType type{};
      context->GetType(&type);
      if (type != WICColorContextProfile &&
          type != WICColorContextExifColorSpace)
        continue;
      if (type == WICColorContextExifColorSpace) {
        UINT space = 0;
        context->GetExifColorSpace(&space);
        if (space == 0xffff)
          continue;
      }
      Com<IWICColorContext> target;
      checked(factory->CreateColorContext(&target), "無法建立 sRGB 描述");
      checked(target->InitializeFromExifColorSpace(1), "無法設定 sRGB 描述");
      Com<IWICColorTransform> transform;
      checked(factory->CreateColorTransformer(&transform), "無法建立 ICC 轉換");
      checked(transform->Initialize(source.Get(), context.Get(), target.Get(),
                                    GUID_WICPixelFormat64bppRGBA),
              "照片 ICC 色彩轉換失敗");
      source = transform;
      managed = true;
      break;
    }
  }
  if (orientation != 1) {
    constexpr unsigned transforms[]{
        0,
        0,
        WICBitmapTransformFlipHorizontal,
        WICBitmapTransformRotate180,
        WICBitmapTransformFlipVertical,
        WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal,
        WICBitmapTransformRotate90,
        WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal,
        WICBitmapTransformRotate270};
    Com<IWICBitmapFlipRotator> rotate;
    checked(factory->CreateBitmapFlipRotator(&rotate), "無法建立方向校正");
    checked(
        rotate->Initialize(source.Get(), static_cast<WICBitmapTransformOptions>(
                                             transforms[orientation])),
        "無法套用 EXIF 方向");
    source = rotate;
  }
  return {decodePixels(source,maxPixel,mask),raw,orientation,managed,raw ? "system" : "not-raw",false,std::nullopt};
}
photocore::Image Codec::decodePixels(Com<IWICBitmapSource> source,unsigned maxPixel,bool mask) {
  UINT w = 0, h = 0;
  dimensions(source.Get(), w, h);
  if (maxPixel && std::max(w, h) > maxPixel) {
    const double scale = double(maxPixel) / std::max(w, h);
    Com<IWICBitmapScaler> scaler;
    checked(factory->CreateBitmapScaler(&scaler), "無法建立影像縮放");
    checked(scaler->Initialize(source.Get(),
                               std::max(1u, UINT(std::round(w * scale))),
                               std::max(1u, UINT(std::round(h * scale))),
                               WICBitmapInterpolationModeFant),
            "無法縮放照片");
    source = scaler;
  }
  dimensions(source.Get(), w, h);
  Com<IWICFormatConverter> converter;
  checked(factory->CreateFormatConverter(&converter), "無法建立像素轉換");
  checked(converter->Initialize(source.Get(), GUID_WICPixelFormat64bppRGBA,
                                WICBitmapDitherTypeNone, nullptr, 0,
                                WICBitmapPaletteTypeCustom),
          "無法轉換照片像素");
  std::vector<uint16_t> pixels(size_t(w) * h * 4);
  checked(converter->CopyPixels(nullptr, w * 8,
                                static_cast<UINT>(pixels.size() * 2),
                                reinterpret_cast<BYTE *>(pixels.data())),
          "無法解析照片像素");
  photocore::Image image(w, h);
  for (size_t i = 0; i < image.pixels.size(); ++i) {
    const float a = pixels[i * 4 + 3] / 65535.f;
    auto component=[&](size_t c){double value=pixels[i*4+c]/65535.;return float((mask?value:fromSRGB(value))*a);};
    image.pixels[i] = {component(0),component(1),component(2),a};
  }
  return image;
}
namespace {
struct WebPFile {
  std::vector<unsigned char> bytes;
  WebPBitstreamFeatures features{};
  std::unique_ptr<WebPMux,decltype(&WebPMuxDelete)> mux{nullptr,WebPMuxDelete};
  unsigned orientation=1;
  explicit WebPFile(const std::string &path) {
    std::ifstream stream(std::filesystem::u8path(path),std::ios::binary|std::ios::ate);
    if(!stream || stream.tellg()<=0 || stream.tellg()>1024LL*1024*1024)throw Failure("decodeFailed","WebP 來源無法讀取或過大");
    bytes.resize(size_t(stream.tellg()));stream.seekg(0);stream.read(reinterpret_cast<char *>(bytes.data()),bytes.size());
    if(!stream || WebPGetFeatures(bytes.data(),bytes.size(),&features)!=VP8_STATUS_OK || features.width<=0 || features.height<=0 || uint64_t(features.width)*features.height>160000000)throw Failure("decodeFailed","WebP 影像格式或尺寸不符");
    WebPData data{bytes.data(),bytes.size()};mux.reset(WebPMuxCreate(&data,0));
    if(features.has_animation)throw Failure("unsupportedFormat","照片編輯尚不支援動畫 WebP");
    WebPData exif{};
    if(mux && WebPMuxGetChunk(mux.get(),"EXIF",&exif)==WEBP_MUX_OK) {
      const unsigned char *p=exif.bytes;size_t n=exif.size;
      if(n>=6 && std::memcmp(p,"Exif\0\0",6)==0){p+=6;n-=6;}
      if(n>=8 && ((p[0]=='I' && p[1]=='I') || (p[0]=='M' && p[1]=='M'))) {
        bool le=p[0]=='I';
        auto u16=[&](size_t at)->uint32_t {if(at>n || n-at<2)return 0;return le?uint32_t(p[at])|(uint32_t(p[at+1])<<8):(uint32_t(p[at])<<8)|p[at+1];};
        auto u32=[&](size_t at)->uint32_t {if(at>n || n-at<4)return 0;return le?u16(at)|(u16(at+2)<<16):(u16(at)<<16)|u16(at+2);};
        size_t at=u32(4);
        if(u16(2)==42 && at>=8 && at<n && n-at>=2) {
          unsigned count=u16(at);at+=2;
          for(unsigned i=0;i<count && at<=n && n-at>=12;++i,at+=12)
            if(u16(at)==274 && u16(at+2)==3 && u32(at+4)==1){unsigned v=u16(at+8);if(v>=1 && v<=8)orientation=v;break;}
        }
      }
    }
  }
  WebPData profile()const{WebPData result{};if(mux)WebPMuxGetChunk(mux.get(),"ICCP",&result);return result;}
};
}
Decoded Codec::decodeWebP(const std::string &path,unsigned maxPixel) {
  WebPFile file(path);int width=0,height=0;
  std::unique_ptr<uint8_t,decltype(&WebPFree)> pixels(WebPDecodeRGBA(file.bytes.data(),file.bytes.size(),&width,&height),WebPFree);
  if(!pixels)throw Failure("decodeFailed","WebP 像素解析失敗");
  Com<IWICBitmap> bitmap;
  checked(factory->CreateBitmapFromMemory(UINT(width),UINT(height),GUID_WICPixelFormat32bppRGBA,UINT(width*4),UINT(uint64_t(width)*height*4),pixels.get(),&bitmap),"無法建立 WebP 影像");
  Com<IWICBitmapSource> source=bitmap;bool managed=false;
  const auto profile=file.profile();
  if(profile.size) {
    Com<IWICColorContext> context,target;Com<IWICColorTransform> transform;
    checked(factory->CreateColorContext(&context),"無法建立 WebP 色彩描述");
    checked(context->InitializeFromMemory(profile.bytes,UINT(profile.size)),"WebP ICC 描述不符");
    checked(factory->CreateColorContext(&target),"無法建立 sRGB 描述");
    checked(target->InitializeFromExifColorSpace(1),"無法設定 sRGB 描述");
    checked(factory->CreateColorTransformer(&transform),"無法建立 WebP ICC 轉換");
    checked(transform->Initialize(source.Get(),context.Get(),target.Get(),GUID_WICPixelFormat64bppRGBA),"WebP ICC 色彩轉換失敗");
    source=transform;managed=true;
  }
  if(file.orientation!=1) {
    constexpr unsigned transforms[]{0,0,WICBitmapTransformFlipHorizontal,WICBitmapTransformRotate180,WICBitmapTransformFlipVertical,WICBitmapTransformRotate90|WICBitmapTransformFlipHorizontal,WICBitmapTransformRotate90,WICBitmapTransformRotate270|WICBitmapTransformFlipHorizontal,WICBitmapTransformRotate270};
    Com<IWICBitmapFlipRotator> rotate;checked(factory->CreateBitmapFlipRotator(&rotate),"無法建立 WebP 方向校正");
    checked(rotate->Initialize(source.Get(),static_cast<WICBitmapTransformOptions>(transforms[file.orientation])),"無法套用 WebP 方向");source=rotate;
  }
  return {decodePixels(source,maxPixel,false),false,file.orientation,managed,"not-raw",false,std::nullopt};
}
Json Codec::metadata(const std::string &path) {
  Json rawMetadata;
  if(lower(std::filesystem::path(wide(path)).extension().wstring())==L".webp") {
    WebPFile file(path);unsigned w=file.features.width,h=file.features.height;if(file.orientation>=5)std::swap(w,h);
    return {{"PixelWidth",w},{"PixelHeight",h},{"Orientation",file.orientation},{"BitsPerPixel",32},{"Decoder","libwebp"},{"ColorProfiles",file.profile().size?1:0}};
  }
  if(isRawFile(path)) {
    std::ifstream file(std::filesystem::u8path(path),std::ios::binary|std::ios::ate);
    if(file && file.tellg()>0 && file.tellg()<=1024LL*1024*1024) {
      std::vector<unsigned char> bytes(static_cast<size_t>(file.tellg()));file.seekg(0);file.read(reinterpret_cast<char *>(bytes.data()),bytes.size());
      PhotoRAWMetadata metadata{};
      if(file && photo_raw_metadata(bytes.data(),bytes.size(),&metadata)==0) {
        Json result{{"PixelWidth",metadata.width},{"PixelHeight",metadata.height},{"Orientation",metadata.orientation},{"Decoder","LibRaw metadata"}};
        for(auto entry:{std::make_pair("Make",metadata.make),std::make_pair("Model",metadata.model),std::make_pair("LensMake",metadata.lens_make),std::make_pair("LensModel",metadata.lens),std::make_pair("LensSerialNumber",metadata.lens_serial),std::make_pair("DateTimeOriginal",metadata.captured_at)})if(entry.second[0])result[entry.first]=entry.second;
        for(auto entry:{std::make_pair("ISOSpeedRatings",metadata.iso),std::make_pair("ExposureTime",metadata.exposure),std::make_pair("FNumber",metadata.aperture),std::make_pair("FocalLength",metadata.focal_length),std::make_pair("FocalLenIn35mmFilm",metadata.focal_length_35mm)})if(std::isfinite(entry.second) && entry.second>0)result[entry.first]=entry.second;
        rawMetadata=std::move(result);
      }
    }
  }
  // RAW 的 IFD0 常是縮圖；不可讓一般 WIC 影格蓋掉感光尺寸與 EXIF。
  if(rawMetadata.is_object())return rawMetadata;
  try {
  Com<IWICBitmapDecoder> decoder;
  checked(factory->CreateDecoderFromFilename(
              wide(path).c_str(), nullptr, GENERIC_READ,
              WICDecodeMetadataCacheOnDemand, &decoder),
          "無法讀取照片資訊");
  Com<IWICBitmapFrameDecode> frame;
  checked(decoder->GetFrame(0, &frame), "無法讀取照片影格");
  UINT w = 0, h = 0;
  dimensions(frame.Get(), w, h);
  unsigned orientation = orientationOf(frame.Get());
  if (orientation >= 5)
    std::swap(w, h);
  WICPixelFormatGUID pixelFormat{};
  checked(frame->GetPixelFormat(&pixelFormat), "無法讀取像素格式");
  Com<IWICComponentInfo> info;
  checked(factory->CreateComponentInfo(pixelFormat, &info), "無法取得像素資訊");
  Com<IWICPixelFormatInfo> pixel;
  checked(info.As(&pixel), "無法取得像素格式資訊");
  UINT bits = 0;
  checked(pixel->GetBitsPerPixel(&bits), "無法讀取位元深度");
  Json result=rawMetadata.is_object()?rawMetadata:Json::object();
  result.update({{"PixelWidth", w},
          {"PixelHeight", h},
          {"Orientation", orientation},
          {"BitsPerPixel", bits},
          {"Decoder", "Windows WIC"}});
  Com<IWICMetadataQueryReader> reader;
  if(SUCCEEDED(frame->GetMetadataQueryReader(&reader))) {
    struct Tag{const char *name;unsigned id;bool exif;bool rational;};
    const Tag tags[]{
      {"Make",271,false,false},{"Model",272,false,false},{"Software",305,false,false},{"DateTime",306,false,false},
      {"ExposureTime",33434,true,true},{"FNumber",33437,true,true},{"ExposureProgram",34850,true,false},{"ISOSpeedRatings",34855,true,false},
      {"DateTimeOriginal",36867,true,false},{"DateTimeDigitized",36868,true,false},{"ShutterSpeedValue",37377,true,true},{"ApertureValue",37378,true,true},
      {"BrightnessValue",37379,true,true},{"ExposureBiasValue",37380,true,true},{"MeteringMode",37383,true,false},{"Flash",37385,true,false},
      {"FocalLength",37386,true,true},{"ColorSpace",40961,true,false},{"WhiteBalance",41987,true,false},{"FocalLenIn35mmFilm",41989,true,false},
      {"BodySerialNumber",42033,true,false},{"LensMake",42035,true,false},{"LensModel",42036,true,false},{"LensSerialNumber",42037,true,false}};
    for(const auto &tag:tags)for(auto prefix:{L"/app1/ifd/",L"/ifd/"}) {
      std::wstring query=prefix;if(tag.exif)query+=L"exif/";query+=L"{ushort="+std::to_wstring(tag.id)+L"}";
      PROPVARIANT value{};
      HRESULT status=reader->GetMetadataByName(query.c_str(),&value);
      if(SUCCEEDED(status)) {
        if(tag.rational && value.vt==VT_UI8) {
          auto numerator=uint32_t(value.uhVal.QuadPart),denominator=uint32_t(value.uhVal.QuadPart>>32);
          if(denominator)result[tag.name]=double(numerator)/denominator;
        } else if(tag.rational && value.vt==VT_I8) {
          auto numerator=int32_t(value.hVal.QuadPart),denominator=int32_t(value.hVal.QuadPart>>32);
          if(denominator)result[tag.name]=double(numerator)/denominator;
        } else if(value.vt==VT_LPSTR && value.pszVal)result[tag.name]=value.pszVal;
        else if(value.vt==VT_LPWSTR && value.pwszVal)result[tag.name]=utf8(value.pwszVal);
        else if(value.vt==VT_UI2)result[tag.name]=value.uiVal;
        else if(value.vt==VT_UI4)result[tag.name]=value.ulVal;
        else if(value.vt==VT_UI1)result[tag.name]=value.bVal;
        else if(value.vt==(VT_VECTOR|VT_UI2) && value.caui.cElems)result[tag.name]=value.caui.pElems[0];
      }
      PropVariantClear(&value);
      if(result.contains(tag.name))break;
    }
  }
  UINT colors=0;
  if(SUCCEEDED(frame->GetColorContexts(0,nullptr,&colors)))result["ColorProfiles"]=colors;
  return result;
  } catch(const Failure &) {
    if(rawMetadata.is_object())return rawMetadata;
    throw;
  }
}
photocore::Image resized(const photocore::Image &image, unsigned maxPixel) {
  if (!maxPixel || std::max(image.width, image.height) <= maxPixel)
    return image;
  const double scale = double(maxPixel) / std::max(image.width, image.height);
  auto result = photocore::film_cpu::resize_lanczos(image, scale);
  const auto width = std::max(std::size_t(1), std::size_t(std::lround(image.width * scale)));
  const auto height = std::max(std::size_t(1), std::size_t(std::lround(image.height * scale)));
  if (result.width == width && result.height == height)
    return result;
  // Swift 的預覽／匯出採四捨五入尺寸；Lanczos 內部保留向上取整的範圍。
  // 依 Core Image 左下原點裁切，避免非整數比例多出一列／欄及改變取樣位置。
  photocore::Image output(width, height);
  for (std::size_t y = 0; y < height; ++y)
    std::copy_n(result.pixels.begin() + (y + result.height - height) * result.width,
                width, output.pixels.begin() + y * width);
  return output;
}
std::vector<unsigned char> Codec::encode(const photocore::Image &image,
                                         const std::string &format,
                                         unsigned bitDepth, double quality,
                                         unsigned compression,
                                         const std::string &colorSpace,
                                         bool webPLossless) {
  if(exportSpaces.is_null()) {
    const auto folder=engineFolder()/L"film-data"/L"color";
    std::ifstream manifest(folder/L"spaces.json");
    if(!manifest)throw Failure("encodeFailed","缺少匯出色彩描述");
    manifest>>exportSpaces;
    for(const auto &entry:exportSpaces.items()) {
      auto file=entry.value().at("file").get<std::string>();
      if(std::filesystem::path(file).filename()!=file)throw Failure("encodeFailed","色彩描述路徑不符");
      std::ifstream stream(folder/std::filesystem::u8path(file),std::ios::binary|std::ios::ate);
      if(!stream || stream.tellg()<128 || stream.tellg()>1024*1024)throw Failure("encodeFailed","色彩描述長度不符");
      auto &data=exportProfiles[entry.key()];data.resize(size_t(stream.tellg()));stream.seekg(0);stream.read(reinterpret_cast<char *>(data.data()),data.size());
      if(!stream)throw Failure("encodeFailed","色彩描述讀取不完整");
    }
  }
  if(!exportSpaces.contains(colorSpace))throw Failure("unsupportedParameter","不支援此匯出色彩空間");
  const auto &profile=exportProfiles.at(colorSpace);
  const auto matrix=photocore::film_cpu::matrix(exportSpaces.at(colorSpace).at("matrix"));
  const double gamma=exportSpaces.at(colorSpace).at("gamma");
  GUID container{};
  if (format == "jpeg" && bitDepth == 8)
    container = GUID_ContainerFormatJpeg;
  else if (format == "png" && (bitDepth == 8 || bitDepth == 16))
    container = GUID_ContainerFormatPng;
  else if (format == "tiff" && (bitDepth == 8 || bitDepth == 16))
    container = GUID_ContainerFormatTiff;
  else if (format == "webp" && bitDepth == 8) {}
  else
    throw Failure("unsupportedFormat",
                  "JPEG／WebP 須為 8 bit；PNG／TIFF 可使用 8／16 bit");
  if (!std::isfinite(quality) || quality < 0 || quality > 1 ||
      (compression != 1 && compression != 5))
    throw Failure("invalidRequest", "輸出參數不符");
  std::vector<BYTE> bytes(image.pixels.size() * 4 * (bitDepth / 8));
  for (size_t i = 0; i < image.pixels.size(); ++i) {
    const auto p=image.pixels[i];
    // 與 Swift PNG 8 bit 相同：透明邊界合成於預覽的黑底，16 bit 保留 alpha。
    double a=format=="png" && bitDepth==8?1:std::clamp(double(p.a),0.,1.);
    auto rgb=photocore::film_cpu::multiply(matrix,a>0?photocore::film_cpu::rgb(p)/a:photocore::film_cpu::V(0));
    std::array<double,4> rgba{rgb.x,rgb.y,rgb.z,a};
    for(size_t c=0;c<4;++c) {
      double value=rgba[c];
      if(c<3)value=gamma>0?std::pow(std::max(value,0.),1/gamma):toSRGB(value);
      if(!std::isfinite(value))throw Failure("encodeFailed","成品含非有限色彩數值");
      value=std::clamp(value,0.,1.);
      if(bitDepth==16){uint16_t word=uint16_t(std::round(value*65535));memcpy(bytes.data()+(i*4+c)*2,&word,2);}
      else bytes[i*4+c]=BYTE(std::round(value*255));
    }
  }
  if(format=="webp") {
    uint8_t *encoded=nullptr;
    size_t size=webPLossless?WebPEncodeLosslessRGBA(bytes.data(),int(image.width),int(image.height),int(image.width*4),&encoded):
      WebPEncodeRGBA(bytes.data(),int(image.width),int(image.height),int(image.width*4),float(quality*100),&encoded);
    if(!size || !encoded)throw Failure("encodeFailed","WebP 編碼失敗");
    std::unique_ptr<uint8_t,decltype(&WebPFree)> pixels(encoded,WebPFree);
    WebPData bitstream{encoded,size},icc{profile.data(),profile.size()},output{};
    std::unique_ptr<WebPMux,decltype(&WebPMuxDelete)> mux(WebPMuxCreate(&bitstream,1),WebPMuxDelete);
    if(!mux || WebPMuxSetChunk(mux.get(),"ICCP",&icc,1)!=WEBP_MUX_OK || WebPMuxAssemble(mux.get(),&output)!=WEBP_MUX_OK)throw Failure("encodeFailed","WebP 色彩描述封裝失敗");
    std::vector<unsigned char> result(output.bytes,output.bytes+output.size);WebPDataClear(&output);return result;
  }
  Com<IStream> stream;
  checked(CreateStreamOnHGlobal(nullptr, TRUE, &stream), "無法建立編碼串流");
  Com<IWICBitmapEncoder> encoder;
  checked(factory->CreateEncoder(container, nullptr, &encoder),
          "無法建立系統編碼器");
  checked(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache),
          "無法初始化編碼器");
  Com<IWICBitmapFrameEncode> frame;
  Com<IPropertyBag2> options;
  checked(encoder->CreateNewFrame(&frame, &options), "無法建立成品影格");
  PROPBAG2 property{};
  VARIANT value{};
  if (format == "jpeg") {
    property.pstrName = const_cast<wchar_t *>(L"ImageQuality");
    value.vt = VT_R4;
    value.fltVal = static_cast<float>(quality);
    checked(options->Write(1, &property, &value), "無法設定 JPEG 品質");
  }
  if (format == "tiff") {
    property.pstrName = const_cast<wchar_t *>(L"TiffCompressionMethod");
    value.vt = VT_UI1;
    value.bVal =
        compression == 5 ? WICTiffCompressionLZW : WICTiffCompressionNone;
    checked(options->Write(1, &property, &value), "無法設定 TIFF 壓縮");
  }
  checked(frame->Initialize(options.Get()), "無法初始化成品影格");
  Com<IWICColorContext> colorContext;
  checked(factory->CreateColorContext(&colorContext),"無法建立匯出色彩描述");
  checked(colorContext->InitializeFromMemory(profile.data(),UINT(profile.size())),"無法載入匯出 ICC");
  IWICColorContext *context=colorContext.Get();
  checked(frame->SetColorContexts(1,&context),"無法嵌入匯出 ICC");
  checked(frame->SetSize(static_cast<UINT>(image.width),
                         static_cast<UINT>(image.height)),
          "無法設定成品尺寸");
  const GUID inputFormat = bitDepth == 16 ? GUID_WICPixelFormat64bppRGBA
                                          : GUID_WICPixelFormat32bppRGBA;
  GUID pixelFormat =
      format == "jpeg" ? GUID_WICPixelFormat24bppBGR : inputFormat;
  checked(frame->SetPixelFormat(&pixelFormat), "無法設定成品位元深度");
  if (bitDepth == 16 && pixelFormat != GUID_WICPixelFormat64bppRGBA &&
      pixelFormat != GUID_WICPixelFormat48bppRGB)
    throw Failure("encodeFailed", "系統編碼器無法保持 16 bit 成品");
  Com<IWICBitmap> bitmap;
  checked(factory->CreateBitmapFromMemory(
              static_cast<UINT>(image.width), static_cast<UINT>(image.height),
              inputFormat, static_cast<UINT>(image.width * 4 * (bitDepth / 8)),
              static_cast<UINT>(bytes.size()), bytes.data(), &bitmap),
          "無法建立編碼像素");
  Com<IWICFormatConverter> converter;
  checked(factory->CreateFormatConverter(&converter), "無法建立成品格式轉換");
  checked(converter->Initialize(bitmap.Get(), pixelFormat,
                                WICBitmapDitherTypeNone, nullptr, 0,
                                WICBitmapPaletteTypeCustom),
          "無法轉換成品格式");
  checked(frame->WriteSource(converter.Get(), nullptr), "無法編碼成品");
  checked(frame->Commit(), "無法完成成品影格");
  checked(encoder->Commit(), "無法完成成品檔案");
  STATSTG stat{};
  checked(stream->Stat(&stat, STATFLAG_NONAME), "無法讀取編碼長度");
  if (stat.cbSize.QuadPart > UINT_MAX)
    throw Failure("encodeFailed", "成品編碼過大");
  LARGE_INTEGER zero{};
  checked(stream->Seek(zero, STREAM_SEEK_SET, nullptr), "無法重設編碼串流");
  std::vector<unsigned char> output(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG read = 0;
  checked(stream->Read(output.data(), static_cast<ULONG>(output.size()), &read),
          "無法讀取成品");
  if (read != output.size())
    throw Failure("encodeFailed", "成品串流不完整");
  return output;
}
} // namespace filmdevelop
