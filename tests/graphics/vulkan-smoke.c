/* Juice Vulkan/WSI smoke test. Public-domain test code. */
#define WIN32_LEAN_AND_MEAN
#define VK_USE_PLATFORM_WIN32_KHR
#define VK_NO_PROTOTYPES
#include <windows.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#define LOAD_INSTANCE(name) PFN_##name name = (PFN_##name)get_instance_proc(instance, #name)
#define LOAD_DEVICE(name) PFN_##name name = (PFN_##name)get_device_proc(device, #name)

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_DESTROY) PostQuitMessage(0);
    return DefWindowProcW(window, message, wparam, lparam);
}

static DWORD string_length(const char *text)
{
    DWORD length = 0;
    while (text[length]) length++;
    return length;
}

static char *append_text(char *output, const char *text)
{
    while (*text) *output++ = *text++;
    return output;
}

static char *append_uint32(char *output, uint32_t value)
{
    char digits[10];
    unsigned int count = 0;

    do
    {
        digits[count++] = '0' + value % 10;
        value /= 10;
    } while (value);
    while (count) *output++ = digits[--count];
    return output;
}

static char *append_hex32(char *output, uint32_t value)
{
    static const char digits[] = "0123456789abcdef";
    int shift;

    for (shift = 28; shift >= 0; shift -= 4) *output++ = digits[(value >> shift) & 15];
    return output;
}

static void log_text(const char *text)
{
    DWORD written;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (output && output != INVALID_HANDLE_VALUE)
        WriteFile(output, text, string_length(text), &written, NULL);
}

static void write_marker(const char *text)
{
    HANDLE file;
    DWORD written;

    file = CreateFileW(L"juice-vulkan-smoke.txt",
                       GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, text, string_length(text), &written, NULL);
    CloseHandle(file);
}

static __declspec(noreturn) int fail(const char *stage, VkResult result)
{
    char text[256];
    char *end = append_text(text, "JUICE_VULKAN_SMOKE_FAIL stage=");
    end = append_text(end, stage);
    end = append_text(end, " result=0x");
    end = append_hex32(end, (uint32_t)result);
    end = append_text(end, "\r\n");
    *end = 0;
    log_text(text);
    write_marker(text);
#ifdef JUICE_GRAPHICS_DEBUG_HOLD
    Sleep(30000);
#endif
    ExitProcess(1);
}

int mainCRTStartup(void)
{
    HINSTANCE module = GetModuleHandleW(NULL);
    WNDCLASSW wc = {0};
    HWND window;
    HMODULE vulkan;
    PFN_vkGetInstanceProcAddr get_instance_proc;
    PFN_vkCreateInstance create_instance;
    VkApplicationInfo app_info = {VK_STRUCTURE_TYPE_APPLICATION_INFO};
    const char *instance_extensions[] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_WIN32_SURFACE_EXTENSION_NAME};
    VkInstanceCreateInfo instance_info = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    VkInstance instance = VK_NULL_HANDLE;
    VkWin32SurfaceCreateInfoKHR surface_info = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR};
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkPhysicalDevice physical_devices[8];
    uint32_t physical_count = 8, queue_count, queue_index = UINT32_MAX, i;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkQueueFamilyProperties queue_properties[32];
    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
    const char *device_extensions[] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    VkDeviceCreateInfo device_info = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
    VkDevice device = VK_NULL_HANDLE;
    PFN_vkGetDeviceProcAddr get_device_proc;
    VkQueue queue = VK_NULL_HANDLE;
    VkSurfaceCapabilitiesKHR capabilities;
    VkSurfaceFormatKHR formats[32], format;
    uint32_t format_count = 32;
    VkExtent2D extent;
    VkSwapchainCreateInfoKHR swapchain_info = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkImage images[8];
    VkCommandBuffer commands[8];
    unsigned char image_seen[8] = {0};
    uint32_t image_count = 8;
    VkCommandPoolCreateInfo pool_info = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    VkCommandPool pool = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo allocate_info = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    VkSemaphoreCreateInfo semaphore_info = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    VkSemaphore acquired = VK_NULL_HANDLE, rendered = VK_NULL_HANDLE;
    VkResult result;
    MSG message;
    unsigned int frame;

    wc.lpfnWndProc = window_proc;
    wc.hInstance = module;
    wc.lpszClassName = L"JuiceVulkanSmoke";
    wc.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    RegisterClassW(&wc);
    window = CreateWindowW(wc.lpszClassName, L"Juice Vulkan + MoltenVK smoke",
                           WS_OVERLAPPEDWINDOW | WS_VISIBLE, 60, 60, 720, 460,
                           NULL, NULL, module, NULL);
    if (!window) return fail("CreateWindow", VK_ERROR_INITIALIZATION_FAILED);

    vulkan = LoadLibraryW(L"vulkan-1.dll");
    if (!vulkan) return fail("LoadLibrary(vulkan-1)", VK_ERROR_INITIALIZATION_FAILED);
    get_instance_proc = (PFN_vkGetInstanceProcAddr)GetProcAddress(vulkan, "vkGetInstanceProcAddr");
    if (!get_instance_proc) return fail("vkGetInstanceProcAddr", VK_ERROR_INITIALIZATION_FAILED);
    create_instance = (PFN_vkCreateInstance)get_instance_proc(VK_NULL_HANDLE, "vkCreateInstance");
    if (!create_instance) return fail("vkCreateInstance-proc", VK_ERROR_INITIALIZATION_FAILED);

    app_info.pApplicationName = "Juice Vulkan smoke";
    app_info.applicationVersion = 1;
    app_info.pEngineName = "Juice";
    app_info.engineVersion = 1;
    app_info.apiVersion = VK_API_VERSION_1_0;
    instance_info.pApplicationInfo = &app_info;
    instance_info.enabledExtensionCount = 2;
    instance_info.ppEnabledExtensionNames = instance_extensions;
    if ((result = create_instance(&instance_info, NULL, &instance)) != VK_SUCCESS)
        return fail("vkCreateInstance", result);

    LOAD_INSTANCE(vkDestroyInstance);
    LOAD_INSTANCE(vkCreateWin32SurfaceKHR);
    LOAD_INSTANCE(vkDestroySurfaceKHR);
    LOAD_INSTANCE(vkEnumeratePhysicalDevices);
    LOAD_INSTANCE(vkGetPhysicalDeviceQueueFamilyProperties);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfaceSupportKHR);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    LOAD_INSTANCE(vkGetPhysicalDeviceSurfaceFormatsKHR);
    LOAD_INSTANCE(vkCreateDevice);
    get_device_proc = (PFN_vkGetDeviceProcAddr)get_instance_proc(instance, "vkGetDeviceProcAddr");
    if (!vkCreateWin32SurfaceKHR || !vkEnumeratePhysicalDevices || !vkCreateDevice || !get_device_proc)
        return fail("instance-procs", VK_ERROR_EXTENSION_NOT_PRESENT);

    surface_info.hinstance = module;
    surface_info.hwnd = window;
    if ((result = vkCreateWin32SurfaceKHR(instance, &surface_info, NULL, &surface)) != VK_SUCCESS)
        return fail("vkCreateWin32SurfaceKHR", result);
    if ((result = vkEnumeratePhysicalDevices(instance, &physical_count, physical_devices)) != VK_SUCCESS || !physical_count)
        return fail("vkEnumeratePhysicalDevices", result);

    for (i = 0; i < physical_count && queue_index == UINT32_MAX; i++)
    {
        uint32_t index;
        VkBool32 supported;
        queue_count = 32;
        vkGetPhysicalDeviceQueueFamilyProperties(physical_devices[i], &queue_count, queue_properties);
        for (index = 0; index < queue_count; index++)
        {
            supported = VK_FALSE;
            vkGetPhysicalDeviceSurfaceSupportKHR(physical_devices[i], index, surface, &supported);
            if ((queue_properties[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) && supported)
            {
                physical = physical_devices[i];
                queue_index = index;
                break;
            }
        }
    }
    if (!physical) return fail("present-queue", VK_ERROR_FEATURE_NOT_PRESENT);

    queue_info.queueFamilyIndex = queue_index;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &priority;
    device_info.queueCreateInfoCount = 1;
    device_info.pQueueCreateInfos = &queue_info;
    device_info.enabledExtensionCount = 1;
    device_info.ppEnabledExtensionNames = device_extensions;
    if ((result = vkCreateDevice(physical, &device_info, NULL, &device)) != VK_SUCCESS)
        return fail("vkCreateDevice", result);

    LOAD_DEVICE(vkDestroyDevice);
    LOAD_DEVICE(vkGetDeviceQueue);
    LOAD_DEVICE(vkCreateSwapchainKHR);
    LOAD_DEVICE(vkDestroySwapchainKHR);
    LOAD_DEVICE(vkGetSwapchainImagesKHR);
    LOAD_DEVICE(vkCreateCommandPool);
    LOAD_DEVICE(vkDestroyCommandPool);
    LOAD_DEVICE(vkAllocateCommandBuffers);
    LOAD_DEVICE(vkResetCommandBuffer);
    LOAD_DEVICE(vkBeginCommandBuffer);
    LOAD_DEVICE(vkCmdPipelineBarrier);
    LOAD_DEVICE(vkCmdClearColorImage);
    LOAD_DEVICE(vkEndCommandBuffer);
    LOAD_DEVICE(vkCreateSemaphore);
    LOAD_DEVICE(vkDestroySemaphore);
    LOAD_DEVICE(vkAcquireNextImageKHR);
    LOAD_DEVICE(vkQueueSubmit);
    LOAD_DEVICE(vkQueuePresentKHR);
    LOAD_DEVICE(vkQueueWaitIdle);
    if (!vkCreateSwapchainKHR || !vkQueuePresentKHR) return fail("device-procs", VK_ERROR_EXTENSION_NOT_PRESENT);
    vkGetDeviceQueue(device, queue_index, 0, &queue);

    if ((result = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &capabilities)) != VK_SUCCESS)
        return fail("surface-capabilities", result);
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, formats);
    if ((result != VK_SUCCESS && result != VK_INCOMPLETE) || !format_count)
        return fail("surface-formats", result);
    format = formats[0];
    if (format.format == VK_FORMAT_UNDEFINED)
    {
        format.format = VK_FORMAT_B8G8R8A8_UNORM;
        format.colorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    }
    extent = capabilities.currentExtent;
    if (extent.width == UINT32_MAX)
    {
        extent.width = 704;
        extent.height = 400;
        if (extent.width < capabilities.minImageExtent.width) extent.width = capabilities.minImageExtent.width;
        if (extent.height < capabilities.minImageExtent.height) extent.height = capabilities.minImageExtent.height;
        if (extent.width > capabilities.maxImageExtent.width) extent.width = capabilities.maxImageExtent.width;
        if (extent.height > capabilities.maxImageExtent.height) extent.height = capabilities.maxImageExtent.height;
    }
    swapchain_info.surface = surface;
    swapchain_info.minImageCount = capabilities.minImageCount + (capabilities.minImageCount < capabilities.maxImageCount || !capabilities.maxImageCount);
    if (capabilities.maxImageCount && swapchain_info.minImageCount > capabilities.maxImageCount)
        swapchain_info.minImageCount = capabilities.maxImageCount;
    swapchain_info.imageFormat = format.format;
    swapchain_info.imageColorSpace = format.colorSpace;
    swapchain_info.imageExtent = extent;
    swapchain_info.imageArrayLayers = 1;
    swapchain_info.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    swapchain_info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    swapchain_info.preTransform = capabilities.currentTransform;
    swapchain_info.compositeAlpha = (capabilities.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
                                     ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
                                     : (VkCompositeAlphaFlagBitsKHR)(capabilities.supportedCompositeAlpha &
                                       (0u - capabilities.supportedCompositeAlpha));
    swapchain_info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    swapchain_info.clipped = VK_TRUE;
    if ((result = vkCreateSwapchainKHR(device, &swapchain_info, NULL, &swapchain)) != VK_SUCCESS)
        return fail("vkCreateSwapchainKHR", result);
    if ((result = vkGetSwapchainImagesKHR(device, swapchain, &image_count, images)) != VK_SUCCESS || !image_count || image_count > 8)
        return fail("vkGetSwapchainImagesKHR", result);

    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = queue_index;
    if ((result = vkCreateCommandPool(device, &pool_info, NULL, &pool)) != VK_SUCCESS)
        return fail("vkCreateCommandPool", result);
    allocate_info.commandPool = pool;
    allocate_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate_info.commandBufferCount = image_count;
    if ((result = vkAllocateCommandBuffers(device, &allocate_info, commands)) != VK_SUCCESS)
        return fail("vkAllocateCommandBuffers", result);
    if ((result = vkCreateSemaphore(device, &semaphore_info, NULL, &acquired)) != VK_SUCCESS ||
        (result = vkCreateSemaphore(device, &semaphore_info, NULL, &rendered)) != VK_SUCCESS)
        return fail("vkCreateSemaphore", result);

    for (frame = 0; frame < 120; frame++)
    {
        uint32_t image_index;
        VkCommandBufferBeginInfo begin = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        VkClearColorValue color = {{0.12f + (frame % 30) / 150.0f, 0.04f, 0.42f, 1.0f}};
        VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo submit = {VK_STRUCTURE_TYPE_SUBMIT_INFO};
        VkPresentInfoKHR present = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};

        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        result = vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &image_index);
        if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return fail("vkAcquireNextImageKHR", result);
        vkResetCommandBuffer(commands[image_index], 0);
        vkBeginCommandBuffer(commands[image_index], &begin);
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.oldLayout = image_seen[image_index] ? VK_IMAGE_LAYOUT_PRESENT_SRC_KHR : VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = images[image_index];
        barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(commands[image_index], VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
        vkCmdClearColorImage(commands[image_index], images[image_index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                             &color, 1, &barrier.subresourceRange);
        barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = 0;
        barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        vkCmdPipelineBarrier(commands[image_index], VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
        if ((result = vkEndCommandBuffer(commands[image_index])) != VK_SUCCESS) return fail("vkEndCommandBuffer", result);
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &acquired;
        submit.pWaitDstStageMask = &wait_stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &commands[image_index];
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &rendered;
        if ((result = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)) != VK_SUCCESS) return fail("vkQueueSubmit", result);
        present.waitSemaphoreCount = 1;
        present.pWaitSemaphores = &rendered;
        present.swapchainCount = 1;
        present.pSwapchains = &swapchain;
        present.pImageIndices = &image_index;
        result = vkQueuePresentKHR(queue, &present);
        if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return fail("vkQueuePresentKHR", result);
        image_seen[image_index] = 1;
        Sleep(25);
    }
    log_text("JUICE_VULKAN_STAGE queue-wait-enter\r\n");
    vkQueueWaitIdle(queue);
    log_text("JUICE_VULKAN_STAGE queue-wait-complete\r\n");
    {
        char marker[256];
        char *end = append_text(marker, "JUICE_VULKAN_SMOKE_OK frames=");
        end = append_uint32(end, frame);
        end = append_text(end, " width=");
        end = append_uint32(end, extent.width);
        end = append_text(end, " height=");
        end = append_uint32(end, extent.height);
        end = append_text(end, " format=");
        end = append_uint32(end, format.format);
        end = append_text(end, "\r\n");
        *end = 0;
        log_text(marker);
        write_marker(marker);
        log_text("JUICE_VULKAN_STAGE marker-written\r\n");
    }
    Sleep(2500);

    vkDestroySemaphore(device, rendered, NULL);
    vkDestroySemaphore(device, acquired, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyInstance(instance, NULL);
    ExitProcess(0);
}
