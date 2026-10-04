#pragma once
#include "film_internal.hpp"
#include <optional>

namespace filmdevelop {
// 位移為原圖寬／高減一的比例，節點位置保留編輯解析度的末端短格。
struct LiquifyMesh {
    size_t referenceWidth=0,referenceHeight=0,spacing=0,columns=0,rows=0;
    std::vector<float> dx,dy;
    // 每列保存非零 cell 的連續區段，驗證後與位移一起唯讀重用。
    std::vector<std::vector<std::pair<size_t,size_t>>> activeRows;
    bool identity=true;
    explicit LiquifyMesh(const nlohmann::json &value) {
        if(value.is_null())return;
        auto integer=[&](const char *key,size_t lo,size_t hi) {
            const auto &v=value.at(key);
            if(!v.is_number_integer())throw std::invalid_argument("液化網格尺寸格式不符");
            auto n=v.get<int64_t>();if(n<int64_t(lo)||n>int64_t(hi))throw std::invalid_argument("液化網格尺寸超出範圍");return size_t(n);
        };
        integer("version",1,1);referenceWidth=integer("referenceWidth",2,1024);referenceHeight=integer("referenceHeight",2,1024);
        spacing=integer("spacing",2,16);columns=integer("columns",2,513);rows=integer("rows",2,513);
        if(columns!=(referenceWidth-2)/spacing+2 || rows!=(referenceHeight-2)/spacing+2)throw std::invalid_argument("液化網格節點數不符");
        const auto &xs=value.at("dx"),&ys=value.at("dy");
        if(!xs.is_array() || !ys.is_array() || xs.size()!=columns*rows || ys.size()!=columns*rows)throw std::invalid_argument("液化位移陣列長度不符");
        dx.reserve(columns*rows);dy.reserve(columns*rows);
        for(size_t i=0;i<columns*rows;++i) {
            if(!xs[i].is_number() || !ys[i].is_number())throw std::invalid_argument("液化位移格式不符");
            const double x=xs[i].get<double>(),y=ys[i].get<double>();
            if(!std::isfinite(x)||!std::isfinite(y)||std::abs(x)>1||std::abs(y)>1)throw std::invalid_argument("液化位移非有限值或超出範圍");
            const size_t ix=i%columns,iy=i/columns;
            const double px=double(std::min(ix*spacing,referenceWidth-1))/(referenceWidth-1),py=double(std::min(iy*spacing,referenceHeight-1))/(referenceHeight-1);
            if(px+x < -1e-6 || px+x>1+1e-6 || py+y < -1e-6 || py+y>1+1e-6 ||
               ((ix==0||iy==0||ix==columns-1||iy==rows-1)&&(std::abs(x)>1e-6||std::abs(y)>1e-6)))throw std::invalid_argument("液化網格超出原圖或改動固定邊界");
            dx.push_back(float(x));dy.push_back(float(y));identity=identity && x==0 && y==0;
        }
        // 全零網格的 Jacobian 恆為一，前面的格式／邊界驗證仍完整執行。
        if(identity)return;
        activeRows.resize(rows-1);
        auto position=[&](size_t ix,size_t iy) {size_t i=iy*columns+ix;return std::array<double,2>{double(std::min(ix*spacing,referenceWidth-1))+double(dx[i])*(referenceWidth-1),double(std::min(iy*spacing,referenceHeight-1))+double(dy[i])*(referenceHeight-1)};};
        auto cross=[](auto a,auto b,auto c,auto d) {return (b[0]-a[0])*(d[1]-c[1])-(b[1]-a[1])*(d[0]-c[0]);};
        for(size_t y=0;y+1<rows;++y)for(size_t x=0;x+1<columns;++x) {
            const auto a=position(x,y),b=position(x+1,y),c=position(x,y+1),d=position(x+1,y+1);
            const double hx=std::min((x+1)*spacing,referenceWidth-1)-x*spacing,hy=std::min((y+1)*spacing,referenceHeight-1)-y*spacing;
            const double threshold=.049*hx*hy;
            if(cross(a,b,a,c)<threshold || cross(a,b,b,d)<threshold || cross(c,d,a,c)<threshold || cross(c,d,b,d)<threshold)throw std::invalid_argument("液化網格翻折或壓縮過度");
            const size_t index=y*columns+x;
            const bool active=dx[index]!=0 || dy[index]!=0 || dx[index+1]!=0 || dy[index+1]!=0 ||
                dx[index+columns]!=0 || dy[index+columns]!=0 || dx[index+columns+1]!=0 || dy[index+columns+1]!=0;
            if(active) {
                auto &spans=activeRows[y];
                if(!spans.empty() && spans.back().second==x)spans.back().second=x+1;
                else spans.emplace_back(x,x+1);
            }
        }
    }
    std::array<double,2> displacement(double u,double v) const {
        const double x=std::clamp(u,0.,1.)*(referenceWidth-1),y=std::clamp(v,0.,1.)*(referenceHeight-1);
        const size_t ix=std::min(columns-2,size_t(x/spacing)),iy=std::min(rows-2,size_t(y/spacing));
        const double fx=(x-ix*spacing)/(std::min((ix+1)*spacing,referenceWidth-1)-ix*spacing),fy=(y-iy*spacing)/(std::min((iy+1)*spacing,referenceHeight-1)-iy*spacing);
        const size_t a=iy*columns+ix,b=a+1,c=a+columns,d=c+1;
        auto sample=[&](const auto &values) {return (values[a]*(1-fx)+values[b]*fx)*(1-fy)+(values[c]*(1-fx)+values[d]*fx)*fy;};
        return {sample(dx),sample(dy)};
    }
};
inline photocore::Image apply_liquify(photocore::Image source,const LiquifyMesh &mesh) {
    if(mesh.identity || source.width<2 || source.height<2)return source;
    struct AxisSample {size_t cell;double fraction;};
    auto axis=[](size_t pixel,size_t extent,size_t reference,size_t spacing,size_t count) {
        const double position=std::clamp(double(pixel)/(extent-1),0.,1.)*(reference-1);
        const size_t cell=std::min(count-2,size_t(position/spacing));
        return AxisSample{cell,(position-cell*spacing)/(std::min((cell+1)*spacing,reference-1)-cell*spacing)};
    };
    std::vector<AxisSample> horizontal(source.width);
    std::vector<size_t> firstPixel(mesh.columns,source.width);
    for(size_t x=0;x<source.width;++x) {
        horizontal[x]=axis(x,source.width,mesh.referenceWidth,mesh.spacing,mesh.columns);
        firstPixel[horizontal[x].cell]=std::min(firstPixel[horizontal[x].cell],x);
    }
    for(size_t cell=mesh.columns-1;cell>0;--cell)firstPixel[cell-1]=std::min(firstPixel[cell-1],firstPixel[cell]);
    std::vector<AxisSample> vertical(source.height);
    std::vector<size_t> offsets(source.height+1,0);
    for(size_t y=0;y<source.height;++y) {
        vertical[y]=axis(y,source.height,mesh.referenceHeight,mesh.spacing,mesh.rows);
        size_t count=0;
        for(const auto &span:mesh.activeRows[vertical[y].cell])count+=firstPixel[span.second]-firstPixel[span.first];
        offsets[y+1]=offsets[y]+count;
    }
    if(offsets.back()==0)return source;
    // 稀疏筆畫只暫存受影響像素；所有取樣完成才回寫，避免前一個像素污染後續讀取。
    const bool sparse=offsets.back()<source.pixels.size()/2;
    std::vector<photocore::Pixel> modified;
    std::optional<photocore::Image> result;
    if(sparse)modified.resize(offsets.back());else result.emplace(source);
    photocore::film_cpu::parallel_rows(source.height,source.width,[&](size_t y) {
        const auto row=vertical[y];const double fy=row.fraction;
        auto *target=sparse?modified.data()+offsets[y]:result->pixels.data()+y*source.width;
        for(const auto &span:mesh.activeRows[row.cell]) {
          if(!sparse)target=result->pixels.data()+y*source.width+firstPixel[span.first];
          for(size_t x=firstPixel[span.first];x<firstPixel[span.second];++x) {
            const auto h=horizontal[x];const double fx=h.fraction;
            const size_t ma=row.cell*mesh.columns+h.cell,mb=ma+1,mc=ma+mesh.columns,md=mc+1;
            auto displacement=[&](const auto &values) {return (values[ma]*(1-fx)+values[mb]*fx)*(1-fy)+(values[mc]*(1-fx)+values[md]*fx)*fy;};
            const std::array<double,2> delta{displacement(mesh.dx),displacement(mesh.dy)};
            const size_t index=y*source.width+x;
            if(delta[0]==0 && delta[1]==0) {*target++=source.pixels[index];continue;}
            const double sx=std::clamp(double(x)+delta[0]*(source.width-1),0.,double(source.width-1)),sy=std::clamp(double(y)+delta[1]*(source.height-1),0.,double(source.height-1));
            const size_t x0=size_t(sx),y0=size_t(sy),x1=std::min(x0+1,source.width-1),y1=std::min(y0+1,source.height-1);
            const double u=sx-x0,v=sy-y0;
            const auto a=source.pixels[y0*source.width+x0],b=source.pixels[y0*source.width+x1],c=source.pixels[y1*source.width+x0],d=source.pixels[y1*source.width+x1];
            auto sample=[&](float photocore::Pixel::*channel) {return float(((a.*channel)*(1-u)+(b.*channel)*u)*(1-v)+((c.*channel)*(1-u)+(d.*channel)*u)*v);};
            *target++={sample(&photocore::Pixel::r),sample(&photocore::Pixel::g),sample(&photocore::Pixel::b),sample(&photocore::Pixel::a)};
          }
        }
    });
    if(!sparse)return std::move(*result);
    photocore::film_cpu::parallel_rows(source.height,source.width,[&](size_t y) {
        size_t offset=offsets[y];
        for(const auto &span:mesh.activeRows[vertical[y].cell]) {
            const size_t count=firstPixel[span.second]-firstPixel[span.first];
            std::copy_n(modified.data()+offset,count,source.pixels.data()+y*source.width+firstPixel[span.first]);offset+=count;
        }
    });
    return source;
}
}
