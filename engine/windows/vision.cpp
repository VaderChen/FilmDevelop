#include "vision.hpp"
#include "skin_math.hpp"
namespace filmdevelop {
using namespace photocore;
using namespace photocore::film_cpu;
namespace {
double srgb(double v){v=std::clamp(v,0.,1.);return v<=.0031308?12.92*v:1.055*std::pow(v,1/2.4)-.055;}
Image displayImage(const Image &source) {return transform(source,[](Pixel p,size_t,size_t){auto v=straight(p);for(int c=0;c<3;++c)v[c]=std::round(srgb(v[c])*255)/255;return pixel(v,1);});}
Tensor imageTensor(const Image &source,const std::string &name,bool face=false,bool maxNormalize=false) {
    size_t area=source.width*source.height;Tensor input{name,{1,3,int64_t(source.height),int64_t(source.width)},std::vector<float>(area*3)};
    double maximum=1;if(maxNormalize){maximum=0;for(auto p:source.pixels)maximum=std::max({maximum,double(p.r),double(p.g),double(p.b)});maximum=std::max(maximum,1./255);}
    const V mean{.485,.456,.406},sigma{.229,.224,.225};
    for(size_t i=0;i<area;++i){auto v=rgb(source.pixels[i])/maximum;for(int c=0;c<3;++c)input.values[c*area+i]=float(face?(v[c]*255-127)/128:(v[c]-mean[c])/sigma[c]);}
    return input;
}
Image scalar(const Tensor &value) {
    if(value.shape.size()<3 || value.shape.size()>4 || value.shape[0]!=1 || (value.shape.size()==4 && value.shape[1]!=1))throw Failure("invalidModel","視覺模型輸出尺寸不符");
    size_t width=value.shape.back(),height=value.shape[value.shape.size()-2];
    if(!width || !height || width*height!=value.values.size())throw Failure("invalidModel","視覺模型輸出數量不符");
    Image result(width,height);for(size_t i=0;i<result.pixels.size();++i){float v=value.values[i];if(!std::isfinite(v))throw Failure("invalidModel","視覺模型輸出非有限值");result.pixels[i]={v,v,v,1};}return result;
}
}
NeuralRuntime &Vision::runtime(const std::string &name){auto &v=runtimes[name];if(!v)v=std::make_unique<NeuralRuntime>(folder);return *v;}
std::optional<Image> Vision::subject(const Image &source) {
    const auto model=folder/L"vision-models"/L"u2netp.onnx";auto &engine=runtime("subject");auto info=engine.prepare(model);
    auto image=sample_coefficients(displayImage(source),320,320);auto result=engine.run(model,{imageTensor(image,info.at("inputs").at(0).at("name"),false,true)});
    if(result.empty())throw Failure("invalidModel","主體模型沒有輸出");
    auto mask=scalar(result[0]);double low=1e10,high=-1e10;
    for(auto p:mask.pixels){low=std::min(low,double(p.r));high=std::max(high,double(p.r));}
    if(high-low<.0001)return std::nullopt;
    double sum=0;for(auto &p:mask.pixels){double v=std::clamp((p.r-low)/(high-low),0.,1.);sum+=v;p=pixel(V(v),1);}
    if(sum/mask.pixels.size()<.0005)return std::nullopt;
    return mask;
}
Image Vision::depth(const Image &source) {
    const auto model=folder/L"vision-models"/L"depth-anything-v2-small.onnx";auto &engine=runtime("depth");auto info=engine.prepare(model);
    const auto displayed=displayImage(source);constexpr int edge=518;double scale=std::min(edge/double(source.width),edge/double(source.height));
    double width=source.width*scale,height=source.height*scale,left=(edge-width)*.5,top=(edge-height)*.5;
    Image input(edge,edge);
    for(int y=0;y<edge;++y)for(int x=0;x<edge;++x)input.pixels[y*edge+x]=pixel(bilinear(displayed,(x+.5-left)/scale-.5,(y+.5-top)/scale-.5),1);
    auto result=engine.run(model,{imageTensor(input,info.at("inputs").at(0).at("name"))});if(result.size()!=1)throw Failure("invalidModel","景深模型輸出數量不符");auto map=scalar(result[0]);
    // 移除等比例縮放時的補邊，保留原照片的座標。
    size_t outputWidth=std::max(1L,std::lround(width)),outputHeight=std::max(1L,std::lround(height));Image depth(outputWidth,outputHeight);
    for(size_t y=0;y<outputHeight;++y)for(size_t x=0;x<outputWidth;++x)depth.pixels[y*outputWidth+x]=pixel(bilinear(map,(left+(x+.5)*width/outputWidth)*map.width/edge-.5,(top+(y+.5)*height/outputHeight)*map.height/edge-.5),1);
    return depth;
}
std::vector<FaceBox> Vision::faces(const Image &source) {
    const auto model=folder/L"vision-models"/L"ultraface.onnx";auto &engine=runtime("faces");auto info=engine.prepare(model);
    auto image=sample_coefficients(displayImage(source),320,240);auto outputs=engine.run(model,{imageTensor(image,info.at("inputs").at(0).at("name"),true)});
    const Tensor *scores=nullptr,*boxes=nullptr;for(const auto &value:outputs){if(value.shape.size()==3 && value.shape.back()==2)scores=&value;if(value.shape.size()==3 && value.shape.back()==4)boxes=&value;}
    if(!scores || !boxes || scores->shape[0]!=1 || boxes->shape[0]!=1 || scores->values.size()%2 || boxes->values.size()%4 || scores->values.size()/2!=boxes->values.size()/4)throw Failure("invalidModel","人臉模型輸出格式不符");
    for(const auto *tensor:{scores,boxes})for(float value:tensor->values)if(!std::isfinite(value))throw Failure("invalidModel","人臉模型輸出非有限值");
    std::vector<FaceBox> candidates,result;for(size_t i=0;i<scores->values.size()/2;++i)if(scores->values[i*2+1]>=.7){auto b=boxes->values.data()+i*4;FaceBox box{std::clamp(double(b[0]),0.,1.),std::clamp(double(b[1]),0.,1.),std::clamp(double(b[2]),0.,1.),std::clamp(double(b[3]),0.,1.),scores->values[i*2+1]};if(box.right>box.left && box.bottom>box.top)candidates.push_back(box);}
    auto area=[](FaceBox b){return (b.right-b.left)*(b.bottom-b.top);};std::sort(candidates.begin(),candidates.end(),[](auto a,auto b){return a.score>b.score;});
    for(auto box:candidates){bool duplicate=false;for(auto other:result){double intersection=std::max(0.,std::min(box.right,other.right)-std::max(box.left,other.left))*std::max(0.,std::min(box.bottom,other.bottom)-std::max(box.top,other.top));if(intersection/(area(box)+area(other)-intersection)>.3){duplicate=true;break;}}if(!duplicate)result.push_back(box);if(result.size()>=64)break;}
    std::sort(result.begin(),result.end(),[&](auto a,auto b){return area(a)>area(b);});if(result.size()>8)result.resize(8);return result;
}
}
