#include "film_math.hpp"
#include <atomic>
#include <cstring>
#include <future>
#include <iostream>
#include <stdexcept>

using namespace photocore;
using namespace photocore::film_cpu;
static void require(bool value) { if (!value) throw std::runtime_error("列平行處理驗證失敗"); }
int main() {
    // 真實像素函數與串行 oracle 逐位元比較，包含非整齊尺寸與透明度。
    Image input(513, 129), expected(513, 129);
    for (std::size_t i = 0; i < input.pixels.size(); ++i)
        input.pixels[i] = {float(i % 257) / 200, float(i % 127) / 100, float(i % 83) / 70, float(i % 5) / 4};
    auto operation = [](Pixel p, std::size_t x, std::size_t y) {
        return pixel(pow(max(rgb(p), 0), 1.13) + double((x + y) % 7) / 300, p.a);
    };
    for (std::size_t y = 0; y < input.height; ++y)
        for (std::size_t x = 0; x < input.width; ++x)
            expected.pixels[y * input.width + x] = operation(input.pixels[y * input.width + x], x, y);
    auto verify = [&] {
        for (int iteration = 0; iteration < 4; ++iteration) {
            auto out = transform(input, operation), owned = transform_owned(input, operation);
            require(std::memcmp(out.pixels.data(), expected.pixels.data(), expected.pixels.size() * sizeof(Pixel)) == 0);
            require(std::memcmp(owned.pixels.data(), expected.pixels.data(), expected.pixels.size() * sizeof(Pixel)) == 0);
        }
    };
    auto first = std::async(std::launch::async, verify), second = std::async(std::launch::async, verify);
    first.get(); second.get();
    std::atomic<unsigned> nested{0};
    parallel_rows(128, 512, [&](std::size_t) {
        parallel_rows(64, 512, [&](std::size_t) { ++nested; });
    });
    require(nested == 128 * 64);
    bool propagated = false;
    try { parallel_rows(128, 512, [](std::size_t y) { if (y == 7) throw std::runtime_error("expected"); }); }
    catch (const std::runtime_error &error) { propagated = std::string(error.what()) == "expected"; }
    require(propagated);
    verify(); // 錯誤後仍可繼續接受下一批工作。
    unsigned small = 0;
    parallel_rows(0, 512, [&](std::size_t) { ++small; });
    parallel_rows(3, 1, [&](std::size_t) { ++small; });
    require(small == 3);
    std::cout << "列平行處理：像素、並行呼叫、巢狀呼叫、錯誤復原通過\n";
}
