#pragma once
#include <libraw/libraw.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <memory>
#include <stdexcept>
#include <thread>
#include <vector>

namespace photoraw {
struct Free { void operator()(unsigned char* p) const { std::free(p); } };
struct Raster {
    int width=0,height=0,colors=0,bits=0;
    size_t data_size=0;
    std::unique_ptr<unsigned char,Free> storage;
    Raster()=default;
    Raster(int w,int h,int c,int b):width(w),height(h),colors(c),bits(b) {
        if(w<1||h<1||c<1||(b!=8&&b!=16&&b!=32)||
           size_t(w)>std::numeric_limits<size_t>::max()/size_t(h)/size_t(c)/size_t(b/8))
            throw std::runtime_error("Invalid raster size");
        data_size=size_t(w)*h*c*(b/8);
        storage.reset(static_cast<unsigned char*>(std::malloc(data_size)));
        if(!storage)throw std::bad_alloc();
    }
    unsigned char* data() const {return storage.get();}
};

template<class Work> void parallel(size_t count,unsigned workers,Work work) {
    workers=std::max(1u,std::min(workers,unsigned(std::min(count,size_t(4)))));
    std::vector<std::thread> threads;
    try {for(unsigned i=1;i<workers;++i)threads.emplace_back(work,count*i/workers,count*(i+1)/workers);}
    catch(...) {for(auto& t:threads)t.join();throw;}
    work(0,count/workers);
    for(auto& t:threads)t.join();
}

// Pinned to LibRaw 0.22.2. Only final packing is parallel: demosaic and the
// X-Trans single-thread safety policy are unchanged. Gamma setup follows
// LibRaw's copy_mem_image fixed-brightness contract. Other settings fall back
// to the public API. The source image is immutable while workers run.
class CpuRaw : public LibRaw {
public:
    Raster render(bool clippedFloat=false,bool fast=true) {
        int w,h,c,b;get_mem_image_format(&w,&h,&c,&b);
        if(c!=3||(b!=8&&b!=16)||(clippedFloat&&b!=16))
            throw std::runtime_error("Expected RGB8 or RGB16 bitmap");
        if(!imgdata.image || (imgdata.progress_flags & LIBRAW_PROGRESS_THUMB_MASK)<LIBRAW_PROGRESS_PRE_INTERPOLATE)
            throw std::runtime_error("RAW image not developed");
        Raster out(w,h,clippedFloat?4:c,clippedFloat?32:b);
        auto& s=imgdata.sizes;auto& p=imgdata.params;
        const bool normalSize=w==((s.flip&4)?s.height:s.width)&&h==((s.flip&4)?s.width:s.height);
        if(!fast||!p.no_auto_bright||p.highlight!=0||p.bright!=1||!normalSize) {
            if(!clippedFloat) {
                const int error=copy_mem_image(out.data(),w*c*(b/8),0);
                if(error)throw std::runtime_error(libraw_strerror(error));
            } else {
                Raster temporary(w,h,c,b);
                const int error=copy_mem_image(temporary.data(),w*c*(b/8),0);
                if(error)throw std::runtime_error(libraw_strerror(error));
                const auto* src=reinterpret_cast<const unsigned short*>(temporary.data());
                auto* dst=reinterpret_cast<float*>(out.data());
                for(size_t i=0;i<size_t(w)*h;++i){for(int channel=0;channel<3;++channel)dst[4*i+channel]=src[3*i+channel]/65535.f;dst[4*i+3]=1;}
            }
            return out;
        }
        if(libraw_internal_data.output_data.histogram)gamma_curve(p.gamm[0],p.gamm[1],2,65536);
        const auto* curve=imgdata.color.curve;
        const auto* source=imgdata.image;
        const int sw=s.width,sh=s.height,flip=s.flip;
        // Tiles keep transposed camera orientations in cache. Each tile owns
        // disjoint destination pixels; no floating-point reductions are shared.
        constexpr int tile=32;
        const int nx=(w+tile-1)/tile,ny=(h+tile-1)/tile;
        parallel(size_t(nx)*ny,4,[&](size_t begin,size_t end){
            for(size_t t=begin;t<end;++t) {
                const int x0=int(t%nx)*tile,y0=int(t/nx)*tile;
                for(int y=y0;y<std::min(y0+tile,h);++y)for(int x=x0;x<std::min(x0+tile,w);++x) {
                    int sx=(flip&4)?y:x,sy=(flip&4)?x:y;
                    if(flip&1)sx=sw-1-sx;if(flip&2)sy=sh-1-sy;
                    const auto& pixel=source[size_t(sy)*sw+sx];const size_t index=size_t(y)*w+x;
                    if(clippedFloat) {
                        auto* dst=reinterpret_cast<float*>(out.data())+index*4;
                        for(int channel=0;channel<3;++channel)dst[channel]=curve[pixel[channel]]/65535.f;
                        dst[3]=1;
                    } else if(b==8) {
                        auto* dst=out.data()+index*3;
                        for(int channel=0;channel<3;++channel)dst[channel]=curve[pixel[channel]]>>8;
                    } else {
                        auto* dst=reinterpret_cast<unsigned short*>(out.data())+index*3;
                        for(int channel=0;channel<3;++channel)dst[channel]=curve[pixel[channel]];
                    }
                }
            }
        });
        return out;
    }
};
} // namespace photoraw
