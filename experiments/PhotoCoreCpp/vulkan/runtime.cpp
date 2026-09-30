#include "runtime.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vulkan/vulkan.h>

namespace photocore::vk {
namespace {
void check(VkResult result, const char *operation) {
    if (result != VK_SUCCESS)
        throw std::runtime_error(std::string(operation) + "：VkResult=" + std::to_string(result));
}
bool named(const std::vector<VkExtensionProperties> &list, const char *name) {
    return std::any_of(list.begin(), list.end(),
                       [&](const auto &v) { return std::strcmp(v.extensionName, name) == 0; });
}
std::vector<VkExtensionProperties> extensions(VkPhysicalDevice physical = {}) {
    uint32_t count = 0;
    if (physical)
        check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr), "列出裝置擴充");
    else
        check(vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr), "列出 Instance 擴充");
    std::vector<VkExtensionProperties> result(count);
    if (physical)
        check(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, result.data()), "讀取裝置擴充");
    else
        check(vkEnumerateInstanceExtensionProperties(nullptr, &count, result.data()), "讀取 Instance 擴充");
    return result;
}
} // namespace
struct Buffer {
    VkDevice device{};
    VkBuffer buffer{};
    VkDeviceMemory memory{};
    void *mapped = nullptr;
    bool coherent = false;
    VkDeviceSize bytes = 0;
    std::shared_ptr<std::array<std::size_t, 2>> accounting;
    Buffer(VkDevice d, VkPhysicalDevice physical, VkDeviceSize size,
           std::shared_ptr<std::array<std::size_t, 2>> tracker)
        : device(d), accounting(std::move(tracker)) {
        try {
            VkBufferCreateInfo info{};
            info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
            info.size = size;
            info.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
            info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            check(vkCreateBuffer(device, &info, nullptr, &buffer), "建立儲存緩衝區");
            VkMemoryRequirements requirements;
            vkGetBufferMemoryRequirements(device, buffer, &requirements);
            VkPhysicalDeviceMemoryProperties properties;
            vkGetPhysicalDeviceMemoryProperties(physical, &properties);
            uint32_t chosen = UINT32_MAX;
            for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
                auto flags = properties.memoryTypes[i].propertyFlags;
                if ((requirements.memoryTypeBits & (1u << i)) &&
                    (flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) {
                    chosen = i;
                    if (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)
                        break;
                }
            }
            if (chosen == UINT32_MAX)
                throw std::runtime_error("找不到 Host-visible 記憶體");
            coherent =
                (properties.memoryTypes[chosen].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
            VkMemoryAllocateInfo allocation{};
            allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocation.allocationSize = requirements.size;
            allocation.memoryTypeIndex = chosen;
            check(vkAllocateMemory(device, &allocation, nullptr, &memory), "配置 GPU 記憶體");
            bytes = requirements.size;
            (*accounting)[0] += bytes;
            (*accounting)[1] = std::max((*accounting)[1], (*accounting)[0]);
            check(vkBindBufferMemory(device, buffer, memory, 0), "綁定 GPU 記憶體");
            check(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped), "映射 GPU 記憶體");
        } catch (...) {
            release();
            throw;
        }
    }
    Buffer(const Buffer &) = delete;
    ~Buffer() {
        release();
    }
    void release() {
        if (mapped)
            vkUnmapMemory(device, memory);
        if (buffer)
            vkDestroyBuffer(device, buffer, nullptr);
        if (memory)
            vkFreeMemory(device, memory, nullptr);
        (*accounting)[0] -= bytes;
        bytes = 0;
        mapped = nullptr;
        buffer = {};
        memory = {};
    }
    void sync(bool toDevice) {
        if (coherent)
            return;
        VkMappedMemoryRange range{};
        range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = memory;
        range.offset = 0;
        range.size = VK_WHOLE_SIZE;
        if (toDevice)
            check(vkFlushMappedMemoryRanges(device, 1, &range), "Flush GPU 輸入");
        else
            check(vkInvalidateMappedMemoryRanges(device, 1, &range), "Invalidate GPU 輸出");
    }
};
struct Context::State {
    std::shared_ptr<std::array<std::size_t, 2>> accounting = std::make_shared<std::array<std::size_t, 2>>();
    VkInstance instance{};
    VkDebugUtilsMessengerEXT messenger{};
    VkPhysicalDevice physical{};
    VkDevice device{};
    VkQueue queue{};
    uint32_t family = 0, timestampBits = 0;
    VkPhysicalDeviceProperties properties{};
    VkPhysicalDeviceFeatures features{};
    VkDescriptorSetLayout descriptors{};
    VkPipelineLayout layout{};
    VkPipeline pipeline{};
    VkDescriptorPool descriptorPool{};
    VkCommandPool commandPool{};
    VkFence fence{};
    VkQueryPool queries{};
    std::atomic<unsigned> errors{0}, warnings{0};
    static VKAPI_ATTR VkBool32 VKAPI_CALL message(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
                                                  VkDebugUtilsMessageTypeFlagsEXT,
                                                  const VkDebugUtilsMessengerCallbackDataEXT *data,
                                                  void *user) {
        auto &state = *static_cast<State *>(user);
        if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT)
            ++state.errors;
        if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT)
            ++state.warnings;
        std::cerr << "Vulkan 驗證：" << data->pMessage << '\n';
        return VK_FALSE;
    }
    ~State() {
        if (device) {
            vkDeviceWaitIdle(device);
            if (queries)
                vkDestroyQueryPool(device, queries, nullptr);
            if (fence)
                vkDestroyFence(device, fence, nullptr);
            if (commandPool)
                vkDestroyCommandPool(device, commandPool, nullptr);
            if (descriptorPool)
                vkDestroyDescriptorPool(device, descriptorPool, nullptr);
            if (pipeline)
                vkDestroyPipeline(device, pipeline, nullptr);
            if (layout)
                vkDestroyPipelineLayout(device, layout, nullptr);
            if (descriptors)
                vkDestroyDescriptorSetLayout(device, descriptors, nullptr);
            vkDestroyDevice(device, nullptr);
        }
        if (messenger) {
            auto destroy = reinterpret_cast<PFN_vkDestroyDebugUtilsMessengerEXT>(
                vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT"));
            if (destroy)
                destroy(instance, messenger, nullptr);
        }
        if (instance)
            vkDestroyInstance(instance, nullptr);
    }
};
Context::Context(const std::string &shader, bool validationEnabled) : state_(std::make_unique<State>()) {
    auto &s = *state_;
    const auto available = extensions();
    std::vector<const char *> enabled;
    if (validationEnabled && !named(available, VK_EXT_DEBUG_UTILS_EXTENSION_NAME))
        throw std::runtime_error("缺少 Vulkan debug utils");
    if (validationEnabled)
        enabled.push_back(VK_EXT_DEBUG_UTILS_EXTENSION_NAME);
    VkInstanceCreateFlags flags = 0;
    if (named(available, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME)) {
        enabled.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    uint32_t count = 0;
    check(vkEnumerateInstanceLayerProperties(&count, nullptr), "列出驗證層");
    std::vector<VkLayerProperties> layers(count);
    check(vkEnumerateInstanceLayerProperties(&count, layers.data()), "讀取驗證層");
    const char *layer = "VK_LAYER_KHRONOS_validation";
    if (validationEnabled && std::none_of(layers.begin(), layers.end(),
                     [&](const auto &v) { return std::strcmp(v.layerName, layer) == 0; }))
        throw std::runtime_error("Smoke 必須啟用 VK_LAYER_KHRONOS_validation；請確認 VK_LAYER_PATH");
    VkDebugUtilsMessengerCreateInfoEXT debug{};
    debug.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    debug.messageSeverity =
        VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    debug.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                        VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                        VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    debug.pfnUserCallback = State::message;
    debug.pUserData = &s;
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "PhotoCore Vulkan Smoke";
    app.apiVersion = VK_API_VERSION_1_1;
    VkValidationFeatureEnableEXT syncValidation = VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT;
    VkValidationFeaturesEXT validation{};
    validation.sType = VK_STRUCTURE_TYPE_VALIDATION_FEATURES_EXT;
    validation.pNext = &debug;
    validation.enabledValidationFeatureCount = 1;
    validation.pEnabledValidationFeatures = &syncValidation;
    if (validationEnabled)
        enabled.push_back(VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME);
    VkInstanceCreateInfo instance{};
    instance.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    instance.pNext = validationEnabled ? &validation : nullptr;
#if defined(PHOTOCORE_APP_MOLTENVK)
    const uint32_t fastMath = 0;
    VkLayerSettingEXT setting{"MoltenVK", "MVK_CONFIG_FAST_MATH_ENABLED", VK_LAYER_SETTING_TYPE_UINT32_EXT, 1, &fastMath};
    VkLayerSettingsCreateInfoEXT settings{};
    settings.sType = VK_STRUCTURE_TYPE_LAYER_SETTINGS_CREATE_INFO_EXT;
    settings.pNext = instance.pNext;
    settings.settingCount = 1;
    settings.pSettings = &setting;
    if (!named(available, VK_EXT_LAYER_SETTINGS_EXTENSION_NAME))
        throw std::runtime_error("MoltenVK 不支援必要的精度設定");
    enabled.push_back(VK_EXT_LAYER_SETTINGS_EXTENSION_NAME);
    instance.pNext = &settings;
#endif
    instance.flags = flags;
    instance.pApplicationInfo = &app;
    instance.enabledExtensionCount = uint32_t(enabled.size());
    instance.ppEnabledExtensionNames = enabled.data();
    instance.enabledLayerCount = validationEnabled ? 1 : 0;
    instance.ppEnabledLayerNames = validationEnabled ? &layer : nullptr;
    check(vkCreateInstance(&instance, nullptr, &s.instance), "建立 Vulkan Instance");
    if (validationEnabled) {
        auto createDebug = reinterpret_cast<PFN_vkCreateDebugUtilsMessengerEXT>(
            vkGetInstanceProcAddr(s.instance, "vkCreateDebugUtilsMessengerEXT"));
        if (!createDebug)
            throw std::runtime_error("無法載入 Debug Messenger");
        check(createDebug(s.instance, &debug, nullptr, &s.messenger), "建立 Debug Messenger");
    }
    check(vkEnumeratePhysicalDevices(s.instance, &count, nullptr), "列出 GPU");
    std::vector<VkPhysicalDevice> devices(count);
    check(vkEnumeratePhysicalDevices(s.instance, &count, devices.data()), "讀取 GPU");
    for (auto physical : devices) {
        VkPhysicalDeviceProperties properties;
        vkGetPhysicalDeviceProperties(physical, &properties);
        if (properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU)
            continue;
        uint32_t families = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, nullptr);
        std::vector<VkQueueFamilyProperties> queues(families);
        vkGetPhysicalDeviceQueueFamilyProperties(physical, &families, queues.data());
        for (uint32_t i = 0; i < families; ++i)
            if (queues[i].queueFlags & VK_QUEUE_COMPUTE_BIT) {
                s.physical = physical;
                s.properties = properties;
                s.family = i;
                s.timestampBits = queues[i].timestampValidBits;
                break;
            }
        if (s.physical)
            break;
    }
    if (!s.physical)
        throw std::runtime_error("沒有硬體 Vulkan Compute GPU；Smoke 不接受 CPU 替代");
    vkGetPhysicalDeviceFeatures(s.physical, &s.features);
    if (s.properties.limits.maxComputeWorkGroupInvocations < 64 ||
        s.properties.limits.maxComputeWorkGroupSize[0] < 64)
        throw std::runtime_error("GPU workgroup 容量不足");
    auto deviceExtensions = extensions(s.physical);
    std::vector<const char *> selected;
    if (named(deviceExtensions, "VK_KHR_portability_subset"))
        selected.push_back("VK_KHR_portability_subset");
    float priority = 1;
    VkDeviceQueueCreateInfo queue{};
    queue.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue.queueFamilyIndex = s.family;
    queue.queueCount = 1;
    queue.pQueuePriorities = &priority;
    VkDeviceCreateInfo device{};
    device.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    device.queueCreateInfoCount = 1;
    device.pQueueCreateInfos = &queue;
    device.enabledExtensionCount = uint32_t(selected.size());
    device.ppEnabledExtensionNames = selected.data();
    check(vkCreateDevice(s.physical, &device, nullptr, &s.device), "建立 Compute Device");
    vkGetDeviceQueue(s.device, s.family, 0, &s.queue);
    std::array<VkDescriptorSetLayoutBinding, 7> bindings{};
    for (uint32_t i = 0; i < 7; ++i) {
        bindings[i].binding = i;
        bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bindings[i].descriptorCount = 1;
        bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo descriptor{};
    descriptor.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    descriptor.bindingCount = 7;
    descriptor.pBindings = bindings.data();
    check(vkCreateDescriptorSetLayout(s.device, &descriptor, nullptr, &s.descriptors),
          "建立 descriptor layout");
    VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT, 0, 32};
    VkPipelineLayoutCreateInfo layout{};
    layout.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout.setLayoutCount = 1;
    layout.pSetLayouts = &s.descriptors;
    layout.pushConstantRangeCount = 1;
    layout.pPushConstantRanges = &push;
    check(vkCreatePipelineLayout(s.device, &layout, nullptr, &s.layout), "建立 pipeline layout");
    std::ifstream file(std::filesystem::u8path(shader), std::ios::binary | std::ios::ate);
    if (!file || file.tellg() <= 0 || std::streamoff(file.tellg()) % 4)
        throw std::runtime_error("SPIR-V 檔案無效");
    std::vector<uint32_t> code(std::size_t(file.tellg()) / 4);
    file.seekg(0);
    file.read(reinterpret_cast<char *>(code.data()), std::streamsize(code.size() * 4));
    if (!file || code[0] != 0x07230203)
        throw std::runtime_error("SPIR-V 標頭無效");
    VkShaderModuleCreateInfo moduleInfo{};
    moduleInfo.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    moduleInfo.codeSize = code.size() * 4;
    moduleInfo.pCode = code.data();
    VkShaderModule module{};
    check(vkCreateShaderModule(s.device, &moduleInfo, nullptr, &module), "建立 Shader");
    VkComputePipelineCreateInfo pipeline{};
    pipeline.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipeline.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    pipeline.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT;
    pipeline.stage.module = module;
    pipeline.stage.pName = "main";
    pipeline.layout = s.layout;
    auto result = vkCreateComputePipelines(s.device, {}, 1, &pipeline, nullptr, &s.pipeline);
    vkDestroyShaderModule(s.device, module, nullptr);
    check(result, "建立 Compute Pipeline");
    VkDescriptorPoolSize size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 7};
    VkDescriptorPoolCreateInfo pool{};
    pool.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool.maxSets = 1;
    pool.poolSizeCount = 1;
    pool.pPoolSizes = &size;
    check(vkCreateDescriptorPool(s.device, &pool, nullptr, &s.descriptorPool), "建立 Descriptor Pool");
    VkCommandPoolCreateInfo commands{};
    commands.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    commands.queueFamilyIndex = s.family;
    check(vkCreateCommandPool(s.device, &commands, nullptr, &s.commandPool), "建立 Command Pool");
    VkFenceCreateInfo fence{};
    fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    check(vkCreateFence(s.device, &fence, nullptr, &s.fence), "建立 Fence");
    if (s.timestampBits) {
        VkQueryPoolCreateInfo queries{};
        queries.sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO;
        queries.queryType = VK_QUERY_TYPE_TIMESTAMP;
        queries.queryCount = 2;
        check(vkCreateQueryPool(s.device, &queries, nullptr, &s.queries), "建立 Timestamp Query");
    }
    if (errors())
        throw std::runtime_error("Vulkan 初始化驗證失敗");
}
Context::~Context() = default;
std::string Context::device_name() const {
    return state_->properties.deviceName;
}
unsigned Context::errors() const {
    return state_->errors.load();
}
unsigned Context::warnings() const {
    return state_->warnings.load();
}
std::size_t Context::peak_buffer_bytes() const {
    return (*state_->accounting)[1];
}
Surface Context::create(std::size_t width, std::size_t height) {
    if (!width || !height || width > UINT32_MAX / height ||
        width * height > state_->properties.limits.maxStorageBufferRange / 16)
        throw std::invalid_argument("GPU 影像尺寸超過 storage buffer 限制");
    return {
        width, height,
        std::make_shared<Buffer>(state_->device, state_->physical, width * height * 16, state_->accounting)};
}
Surface Context::upload(const Image &image) {
    if (image.width * image.height != image.pixels.size())
        throw std::invalid_argument("影像尺寸不符");
    auto result = create(image.width, image.height);
    std::memcpy(result.buffer->mapped, image.pixels.data(), image.pixels.size() * sizeof(Pixel));
    result.buffer->sync(true);
    ++image_uploads;
    uploaded_bytes += image.pixels.size() * sizeof(Pixel);
    return result;
}
Surface Context::upload_floats(const std::vector<float> &values) {
    auto result = create(std::max<std::size_t>(1, (values.size() + 3) / 4), 1);
    std::memset(result.buffer->mapped, 0, result.width * 16);
    std::memcpy(result.buffer->mapped, values.data(), values.size() * 4);
    result.buffer->sync(true);
    return result;
}
Image Context::download(const Surface &surface) {
    surface.buffer->sync(false);
    Image result(surface.width, surface.height);
    std::memcpy(result.pixels.data(), surface.buffer->mapped, result.pixels.size() * sizeof(Pixel));
    ++image_downloads;
    downloaded_bytes += result.pixels.size() * sizeof(Pixel);
    return result;
}
void Context::dispatch(unsigned op, const Surface &a, const Surface &b, const Surface &c,
                       const Surface &output, const Surface &second, const std::vector<float> &parameters,
                       const Surface &table, unsigned axis, const std::string &label) {
    auto start = std::chrono::steady_clock::now();
    auto &s = *state_;
    auto params = upload_floats(parameters);
    const std::array<Surface, 7> surfaces{a, b, c, output, second, params, table};
    check(vkResetDescriptorPool(s.device, s.descriptorPool, 0), "重設 descriptors");
    VkDescriptorSetAllocateInfo allocate{};
    allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocate.descriptorPool = s.descriptorPool;
    allocate.descriptorSetCount = 1;
    allocate.pSetLayouts = &s.descriptors;
    VkDescriptorSet descriptor{};
    check(vkAllocateDescriptorSets(s.device, &allocate, &descriptor), "配置 descriptors");
    std::array<VkDescriptorBufferInfo, 7> infos{};
    std::array<VkWriteDescriptorSet, 7> writes{};
    for (uint32_t i = 0; i < 7; ++i) {
        infos[i] = {surfaces[i].buffer->buffer, 0, surfaces[i].width * surfaces[i].height * 16};
        writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[i].dstSet = descriptor;
        writes[i].dstBinding = i;
        writes[i].descriptorCount = 1;
        writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[i].pBufferInfo = &infos[i];
    }
    vkUpdateDescriptorSets(s.device, 7, writes.data(), 0, nullptr);
    check(vkResetCommandPool(s.device, s.commandPool, 0), "重設 command pool");
    VkCommandBufferAllocateInfo command{};
    command.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    command.commandPool = s.commandPool;
    command.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    command.commandBufferCount = 1;
    VkCommandBuffer cmd{};
    check(vkAllocateCommandBuffers(s.device, &command, &cmd), "配置 command buffer");
    // 重設 pool 只重設 command 狀態，不會釋放已配置的 handle。
    // 正常完成與 Begin/End/Submit/Wait/Query 的例外都須歸還配置。
    struct CommandBufferLease {
        VkDevice device;
        VkCommandPool pool;
        VkCommandBuffer command;
        ~CommandBufferLease() { vkFreeCommandBuffers(device, pool, 1, &command); }
    } lease{s.device, s.commandPool, cmd};
    VkCommandBufferBeginInfo begin{};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    check(vkBeginCommandBuffer(cmd, &begin), "開始 command buffer");
    if (s.queries) {
        vkCmdResetQueryPool(cmd, s.queries, 0, 2);
        vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, s.queries, 0);
    }
    VkMemoryBarrier barrier{};
    barrier.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    barrier.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, nullptr, 0, nullptr);
    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, s.pipeline);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, s.layout, 0, 1, &descriptor, 0, nullptr);
    const uint32_t count = uint32_t(output.width * output.height);
    uint32_t dispatches = 0;
    const uint64_t batch = uint64_t(s.properties.limits.maxComputeWorkGroupCount[0]) * 64;
    for (uint64_t offset = 0; offset < count; offset += batch) {
        std::array<uint32_t, 8> push{op,
                                     count,
                                     uint32_t(output.width),
                                     uint32_t(output.height),
                                     uint32_t(a.width),
                                     uint32_t(a.height),
                                     axis,
                                     uint32_t(offset)};
        vkCmdPushConstants(cmd, s.layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, 32, push.data());
        vkCmdDispatch(cmd, uint32_t((std::min<uint64_t>(count - offset, batch) + 63) / 64), 1, 1);
        ++dispatches;
    }
    barrier.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT | VK_ACCESS_SHADER_READ_BIT;
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT | VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0,
                         nullptr, 0, nullptr);
    if (s.queries)
        vkCmdWriteTimestamp(cmd, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, s.queries, 1);
    check(vkEndCommandBuffer(cmd), "結束 command buffer");
    check(vkResetFences(s.device, 1, &s.fence), "重設 fence");
    VkSubmitInfo submit{};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cmd;
    check(vkQueueSubmit(s.queue, 1, &submit, s.fence), "提交 compute");
    auto waited = vkWaitForFences(s.device, 1, &s.fence, VK_TRUE, 60'000'000'000ULL);
    if (waited != VK_SUCCESS) {
        vkDeviceWaitIdle(s.device);
        check(waited, "等待 GPU");
    }
    double gpuMs = -1;
    if (s.queries) {
        uint64_t stamps[2];
        check(vkGetQueryPoolResults(s.device, s.queries, 0, 2, sizeof(stamps), stamps, sizeof(uint64_t),
                                    VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT),
              "讀取 timestamp");
        uint64_t elapsed = stamps[1] - stamps[0];
        if (s.timestampBits < 64)
            elapsed &= (uint64_t(1) << s.timestampBits) - 1;
        gpuMs = double(elapsed) * s.properties.limits.timestampPeriod / 1e6;
    }
    if (errors())
        throw std::runtime_error("Vulkan 驗證失敗");
    stats.push_back(
        {label, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count(),
         gpuMs, dispatches});
}
} // namespace photocore::vk
