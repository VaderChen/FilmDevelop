// 使用正式 PhotoRAW C 介面解完整感光資料；不使用內嵌 JPEG。
#include "PhotoRAW.h"
#include "libraw/libraw.h"
#include <nlohmann/json.hpp>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
using json = nlohmann::json;
static uint64_t hashBytes(const void *data, size_t size) {
    auto bytes = static_cast<const unsigned char *>(data);
    uint64_t value = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < size; ++i) { value ^= bytes[i]; value *= UINT64_C(1099511628211); }
    return value;
}
int main(int argc, char **argv) {
    if (argc != 5) { std::cerr << "probe INPUT OUTPUT_JSON MAPPING_DIR HALF_SIZE\n"; return 2; }
    json result = {{"libraw", LibRaw::version()}, {"capabilities", LibRaw::capabilities()},
                   {"halfSize", std::string(argv[4]) == "1"}};
    auto start = std::chrono::steady_clock::now();
    try {
        std::ifstream input(std::filesystem::u8path(argv[1]), std::ios::binary);
        if (!input) throw std::runtime_error("cannot open source");
        std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(input)), {});
        PhotoRAWMetadata metadata{};
        int status = photo_raw_metadata(bytes.data(), bytes.size(), &metadata);
        result["metadataStatus"] = status;
        if (!status) result["metadata"] = {{"make",metadata.make},{"model",metadata.model},
            {"width",metadata.width},{"height",metadata.height},{"orientation",metadata.orientation}};
        PhotoRAWPixels pixels{};
        status = photo_raw_decode(bytes.data(), bytes.size(), result["halfSize"].get<bool>(), argv[3], &pixels);
        result["status"] = status;
        if (status) result["error"] = photo_raw_error();
        else {
            const size_t count = size_t(pixels.width) * pixels.height;
            result["width"] = pixels.width; result["height"] = pixels.height;
            result["mappingApplied"] = pixels.mapping_applied;
            result["linearHashFNV1a"] = std::to_string(hashBytes(pixels.linear_rgba, count * 4 * sizeof(float)));
            result["displayHashFNV1a"] = std::to_string(hashBytes(pixels.display_rgb, count * 3));
            size_t nonfinite = 0; double sum[3]{}, squares[3]{};
            for (size_t i = 0; i < count; ++i) for (int c = 0; c < 3; ++c) {
                double v = pixels.linear_rgba[4*i+c];
                if (!std::isfinite(v)) ++nonfinite; else { sum[c] += v; squares[c] += v*v; }
            }
            result["nonfinite"] = nonfinite;
            result["mean"] = {sum[0]/count,sum[1]/count,sum[2]/count};
            result["meanSquares"] = {squares[0]/count,squares[1]/count,squares[2]/count};
            // 完整像素雜湊不同時，用固定 64×64 感光影像取樣量化差異。
            json samples = json::array(), display = json::array();
            for (int y = 0; y < 64; ++y) for (int x = 0; x < 64; ++x) {
                size_t i = size_t((2*y+1)*pixels.height/128)*pixels.width + (2*x+1)*pixels.width/128;
                for (int c = 0; c < 3; ++c) { samples.push_back(pixels.linear_rgba[4*i+c]); display.push_back(pixels.display_rgb[3*i+c]); }
            }
            result["linearSamples"] = std::move(samples); result["displaySamples"] = std::move(display);
            photo_raw_free(&pixels);
        }
    } catch (const std::exception &e) { result["status"] = -999; result["error"] = e.what(); }
    result["seconds"] = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
    std::ofstream output(std::filesystem::u8path(argv[2]));
    output << result.dump() << '\n';
    return output ? 0 : 3;
}
