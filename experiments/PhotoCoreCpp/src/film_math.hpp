#pragma once
#include "photocore/core.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <functional>

namespace photocore::film_cpu {
struct V {
    double x = 0, y = 0, z = 0;
    V() = default;
    V(double a) : x(a), y(a), z(a) {}
    V(double a, double b, double c) : x(a), y(b), z(c) {}
    double &operator[](int i) {
        return i == 0 ? x : (i == 1 ? y : z);
    }
    double operator[](int i) const {
        return i == 0 ? x : (i == 1 ? y : z);
    }
};
inline V operator+(V a, V b) {
    return {a.x + b.x, a.y + b.y, a.z + b.z};
}
inline V operator-(V a, V b) {
    return {a.x - b.x, a.y - b.y, a.z - b.z};
}
inline V operator-(V a) {
    return {-a.x, -a.y, -a.z};
}
inline V operator*(V a, V b) {
    return {a.x * b.x, a.y * b.y, a.z * b.z};
}
inline V operator/(V a, V b) {
    return {a.x / b.x, a.y / b.y, a.z / b.z};
}
inline V &operator+=(V &a, V b) {
    a = a + b;
    return a;
}
inline V &operator-=(V &a, V b) {
    a = a - b;
    return a;
}
inline V &operator*=(V &a, V b) {
    a = a * b;
    return a;
}
inline V &operator/=(V &a, V b) {
    a = a / b;
    return a;
}
inline double dot(V a, V b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
inline V cross(V a, V b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline V map(V a, double (*f)(double)) {
    return {f(a.x), f(a.y), f(a.z)};
}
inline V max(V a, V b) {
    return {std::max(a.x, b.x), std::max(a.y, b.y), std::max(a.z, b.z)};
}
inline V min(V a, V b) {
    return {std::min(a.x, b.x), std::min(a.y, b.y), std::min(a.z, b.z)};
}
inline V clamp(V a, V lo, V hi) {
    return min(max(a, lo), hi);
}
inline V exp(V a) {
    return map(a, std::exp);
}
inline V log(V a) {
    return map(a, std::log);
}
inline V log2(V a) {
    return map(a, std::log2);
}
inline V log10(V a) {
    return map(a, std::log10);
}
inline V pow(V a, double p) {
    return {std::pow(a.x, p), std::pow(a.y, p), std::pow(a.z, p)};
}
inline V mix(V a, V b, double t) {
    return a + (b - a) * t;
}
inline double smooth(double a, double b, double x) {
    const double t = std::clamp((x - a) / (b - a), 0., 1.);
    return t * t * (3 - 2 * t);
}
inline V rgb(Pixel p) {
    return {p.r, p.g, p.b};
}
inline V straight(Pixel p) {
    return p.a > 0 ? rgb(p) / p.a : V(0);
}
inline Pixel pixel(V v, float a = 1) {
    return {float(v.x), float(v.y), float(v.z), a};
}
constexpr std::array<double, 3> luminance{.21263900587151027, .7151686787677559, .07219231536073371};
const V w{.2126, .7152, .0722}, exact_w{luminance[0], luminance[1], luminance[2]};
using Matrix = std::array<V, 3>;
inline V multiply(const Matrix &m, V v) {
    return {dot(m[0], v), dot(m[1], v), dot(m[2], v)};
}
template <class Function> Image transform(const Image &in, const Function &fn) {
    Image out(in.width, in.height);
    for (std::size_t y = 0; y < in.height; ++y)
        for (std::size_t x = 0; x < in.width; ++x)
            out.pixels[y * in.width + x] = fn(in.pixels[y * in.width + x], x, y);
    return out;
}
// 僅限每個輸出依賴自己的輸入像素；鄰域濾波仍使用獨立來源。
template <class Function> Image transform_owned(Image in, const Function &fn) {
    for (std::size_t y = 0; y < in.height; ++y)
        for (std::size_t x = 0; x < in.width; ++x)
            in.pixels[y * in.width + x] = fn(in.pixels[y * in.width + x], x, y);
    return in;
}
Image gaussian(Image in, double sigma);
Image resize_lanczos(const Image &in, double scale);
V bilinear(const Image &in, double x, double y);
V fit_chroma(V rgb, double y);
V lab_luminance(V rgb, double y, double scale);
} // namespace photocore::film_cpu
