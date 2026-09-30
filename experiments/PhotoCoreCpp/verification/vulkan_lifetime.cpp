// 真實 Vulkan runtime 的故障注入：攔截公開 API，計算仍存活的資源。
// 不複製運算邏輯，不在產品加入測試專用失敗開關。
#include <vulkan/vulkan.h>
#include <map>
#include <set>
#include <iostream>
#include <string>
namespace audit {
enum class Failure { none, begin, end, query };
Failure failure = Failure::none;
std::set<VkCommandBuffer> commands;
std::map<VkDeviceMemory,VkDeviceSize> memory;
unsigned devices=0;
VkResult allocateCommands(VkDevice d,const VkCommandBufferAllocateInfo *i,VkCommandBuffer *out){
 auto r=vkAllocateCommandBuffers(d,i,out);if(r==VK_SUCCESS)for(unsigned j=0;j<i->commandBufferCount;++j)commands.insert(out[j]);return r;
}
void freeCommands(VkDevice d,VkCommandPool p,uint32_t n,const VkCommandBuffer *b){
 for(unsigned j=0;j<n;++j)commands.erase(b[j]);vkFreeCommandBuffers(d,p,n,b);
}
void destroyPool(VkDevice d,VkCommandPool p,const VkAllocationCallbacks *a){vkDestroyCommandPool(d,p,a);commands.clear();}
VkResult allocateMemory(VkDevice d,const VkMemoryAllocateInfo *i,const VkAllocationCallbacks *a,VkDeviceMemory *m){
 auto r=vkAllocateMemory(d,i,a,m);if(r==VK_SUCCESS)memory[*m]=i->allocationSize;return r;
}
void freeMemory(VkDevice d,VkDeviceMemory m,const VkAllocationCallbacks *a){memory.erase(m);vkFreeMemory(d,m,a);}
VkResult createDevice(VkPhysicalDevice d,const VkDeviceCreateInfo *i,const VkAllocationCallbacks *a,VkDevice *out){
 auto r=vkCreateDevice(d,i,a,out);if(r==VK_SUCCESS)++devices;return r;
}
void destroyDevice(VkDevice d,const VkAllocationCallbacks *a){vkDestroyDevice(d,a);--devices;}
VkResult begin(VkCommandBuffer b,const VkCommandBufferBeginInfo *i){return failure==Failure::begin?VK_ERROR_OUT_OF_HOST_MEMORY:vkBeginCommandBuffer(b,i);}
VkResult end(VkCommandBuffer b){return failure==Failure::end?VK_ERROR_OUT_OF_HOST_MEMORY:vkEndCommandBuffer(b);}
VkResult query(VkDevice d,VkQueryPool p,uint32_t f,uint32_t n,size_t size,void *v,VkDeviceSize stride,VkQueryResultFlags flags){
 return failure==Failure::query?VK_ERROR_OUT_OF_HOST_MEMORY:vkGetQueryPoolResults(d,p,f,n,size,v,stride,flags);
}
size_t bytes(){size_t n=0;for(const auto &v:memory)n+=v.second;return n;}
}
#define vkAllocateCommandBuffers audit::allocateCommands
#define vkFreeCommandBuffers audit::freeCommands
#define vkDestroyCommandPool audit::destroyPool
#define vkAllocateMemory audit::allocateMemory
#define vkFreeMemory audit::freeMemory
#define vkCreateDevice audit::createDevice
#define vkDestroyDevice audit::destroyDevice
#define vkBeginCommandBuffer audit::begin
#define vkEndCommandBuffer audit::end
#define vkGetQueryPoolResults audit::query
#include "../vulkan/runtime.cpp"
int main(int argc,char **argv){
 try{
  if(argc!=2)throw std::runtime_error("需提供 shader 路徑");
  unsigned failed=0,errors=0,warnings=0;size_t retained=0;
  for(int cycle=0;cycle<3;++cycle){
   {
    photocore::vk::Context context(argv[1]);
    auto source=context.create(32,24),output=context.create(32,24),table=context.upload_floats({0});
    const auto baseline=audit::bytes();
    for(auto mode:{audit::Failure::begin,audit::Failure::end,audit::Failure::query}){
     audit::failure=mode;
     for(int i=0;i<20;++i){
      try{context.dispatch(1,source,source,source,output,output,{},table,0,"fault");throw std::logic_error("未觸發預期失敗");}
      catch(const std::logic_error&){throw;}
      catch(const std::runtime_error&){++failed;}
      if(audit::bytes()!=baseline)throw std::runtime_error("失敗後 GPU 配置未歸還");
     }
     retained=std::max(retained,audit::commands.size());
    }
    audit::failure=audit::Failure::none;
    for(int i=0;i<100;++i){context.stats.clear();context.dispatch(1,source,source,source,output,output,{},table,0,"recovery");}
    retained=std::max(retained,audit::commands.size());
    errors+=context.errors();warnings+=context.warnings();
   }
   if(audit::bytes() || !audit::commands.empty() || audit::devices)throw std::runtime_error("context 解構後資源未歸還");
  }
  // 初始化進行到建立 device 後才找不到 shader，須清理所有已建資源。
  for(int i=0;i<10;++i){try{photocore::vk::Context bad("/missing/photocore-shader.spv");}catch(const std::runtime_error&){}
    if(audit::bytes() || audit::devices)throw std::runtime_error("初始化失敗後資源未歸還");}
  std::cout<<"{\"injected_failures\":"<<failed<<",\"retained_commands_after_failure\":"<<retained
    <<",\"live_gpu_bytes_after_destroy\":"<<audit::bytes()<<",\"live_devices\":"<<audit::devices
    <<",\"validation_errors\":"<<errors<<",\"validation_warnings\":"<<warnings<<"}\n";
  return retained || errors || warnings ? 1:0;
 }catch(const std::exception &e){std::cerr<<e.what()<<'\n';return 2;}
}
