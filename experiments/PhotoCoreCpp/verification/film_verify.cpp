#include "film_internal.hpp"
#include "photocore/film.hpp"
#include <iostream>
#include <limits>
#include <stdexcept>

using namespace photocore;
using namespace photocore::film_cpu;
namespace {
void check(bool value, const char *message) {
    if (!value)
        throw std::runtime_error(message);
}
bool same(const Image &a, const Image &b) {
    if (a.width != b.width || a.height != b.height || a.pixels.size() != b.pixels.size())
        return false;
    for (std::size_t i = 0; i < a.pixels.size(); ++i) {
        auto p = a.pixels[i], q = b.pixels[i];
        if (p.r != q.r || p.g != q.g || p.b != q.b || p.a != q.a)
            return false;
    }
    return true;
}
} // namespace
int main() {
    try {
        Image input(47, 33);
        for (std::size_t i = 0; i < input.pixels.size(); ++i) {
            const float alpha = i % 5 == 0 ? .5f : 1;
            input.pixels[i] = {float(i % 31) / 7 * alpha, float(i % 13) / 13 * alpha, -.01f * alpha, alpha};
        }
        const auto original = input;
        Effects neutral{Json::object()};
        check(same(develop(input, neutral, 1), input), "零顯影必須略過");
        check(same(chemistry(input, neutral, 1, false), input), "中性藥水必須略過");
        Effects active{{{"development_amount", 100},
                        {"development_time", 100},
                        {"developer_temperature", 40},
                        {"developer_activity", 200},
                        {"development_diffusion", 1},
                        {"development_agitation", 0}}};
        check(same(develop(input, active, 0), input), "強度零不得產生顯影");
        auto output = develop(input, active, 1);
        for (std::size_t i = 0; i < input.pixels.size(); ++i) {
            auto p = output.pixels[i];
            check(p.a == input.pixels[i].a, "顯影改變 alpha");
            for (float v : {p.r, p.g, p.b})
                check(std::isfinite(v), "顯影出現非有限值");
            check(p.b < 0, "顯影不得裁去負通道");
        }
        Image flat(31, 29);
        std::fill(flat.pixels.begin(), flat.pixels.end(), Pixel{.18f, .18f, .18f, 1});
        auto developed = develop(flat, active, 1);
        for (auto p : developed.pixels)
            check(std::abs(p.r - .18f) < 2e-6 && p.r == p.g && p.g == p.b, "均勻中性場不應因擴散漂移");
        auto blurred = gaussian(flat, 3.7);
        check(same(flat, blurred), "邊界延展必須保留常數場");
        auto resized = resize_lanczos(flat, .63);
        for (auto p : resized.pixels)
            check(p.a > 0 && std::abs(p.r / p.a - .18f) < 1e-6, "Lanczos 預乘 alpha 的常數場還原錯誤");
        // 原生 CILanczosScaleTransform 的脈衝參考：大幅縮小採分段減半。
        // 容差涵蓋 GPU 取樣權重量化；一次直接縮放的最大誤差超過 .001。
        Image impulse(6048,128);
        for(std::size_t y=0;y<impulse.height;++y) for(std::size_t x=0;x<impulse.width;++x)
            impulse.pixels[y*impulse.width+x]={x==1000?1.f:0.f,0,0,1};
        auto small=resize_lanczos(impulse,768./6048);
        const float expected[]={.0032304958f,-.016996909f,.06944433f,.08572981f,-.018333439f,.004013817f};
        for(std::size_t i=0;i<6;++i)
            check(std::abs(small.pixels[8*small.width+124+i].r-expected[i])<.00035,"大幅 Lanczos 縮小與原生脈衝參考不符");
        active.json["developer_chemistry"] = {{"contrast", 1.2}, {"speedEV", .5},  {"compensation", 75},
                                              {"grain", 30},     {"acutance", 50}, {"red", 20},
                                              {"green", -20},    {"blue", 10}};
        auto treated = chemistry(input, active, 1, false);
        for (std::size_t i = 0; i < input.pixels.size(); ++i) {
            auto p = treated.pixels[i];
            check(p.a == input.pixels[i].a, "藥水改變 alpha");
            for (float v : {p.r, p.g, p.b})
                check(std::isfinite(v), "藥水出現非有限值");
        }
        check(same(input, original), "處理修改了原始輸入");
        Image precision(4096, 1);
        for (std::size_t i = 0; i < precision.width; ++i)
            precision.pixels[i] = {float(i) / 4095, float(i) / 4095, float(i) / 4095, 1};
        auto q = quantize_srgb16(precision);
        for (std::size_t i = 1; i < q.width; ++i)
            check(q.pixels[i].r > q.pixels[i - 1].r, "16-bit 匯出遺失 12-bit 階調");
        precision.pixels[0].a = .5;
        bool rejected = false;
        try {
            quantize_srgb16(precision);
        } catch (const std::invalid_argument &) {
            rejected = true;
        }
        check(rejected, "不可把透明成品偷偷當成不透明驗收");
        std::cout << "CPU 顯影／藥水／取樣／輸出數值不變量通過\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "底片 Smoke 失敗：" << e.what() << '\n';
        return 1;
    }
}
