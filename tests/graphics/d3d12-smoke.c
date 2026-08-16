/* Juice Direct3D 12 command-queue smoke test. Public-domain test code. */
#define COBJMACROS
#define INITGUID
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stdint.h>

static unsigned char expected[4096];

static void stage(const char *text)
{
    OutputDebugStringA(text);
    OutputDebugStringA("\n");
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

static char *append_hex32(char *output, unsigned long value)
{
    static const char digits[] = "0123456789abcdef";
    int shift;
    for (shift = 28; shift >= 0; shift -= 4) *output++ = digits[(value >> shift) & 15];
    return output;
}

static void write_marker(const char *text)
{
    HANDLE file;
    DWORD written;
    file = CreateFileW(L"juice-d3d12-smoke.txt",
                       GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, text, string_length(text), &written, NULL);
    CloseHandle(file);
}

static __declspec(noreturn) int fail(const char *stage, HRESULT result)
{
    char marker[256];
    char *end = append_text(marker, "JUICE_D3D12_SMOKE_FAIL stage=");
    end = append_text(end, stage);
    end = append_text(end, " hr=0x");
    end = append_hex32(end, (unsigned long)result);
    end = append_text(end, "\r\n");
    *end = 0;
    write_marker(marker);
    ExitProcess(1);
}

int mainCRTStartup(void)
{
    typedef HRESULT (WINAPI *create_device_fn)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    HMODULE d3d12_module;
    create_device_fn create_device;
    ID3D12Device *device = NULL;
    ID3D12CommandQueue *queue = NULL;
    ID3D12CommandAllocator *allocator = NULL;
    ID3D12GraphicsCommandList *list = NULL;
    ID3D12Resource *upload = NULL, *gpu = NULL, *readback = NULL;
    ID3D12Fence *fence = NULL;
    D3D12_COMMAND_QUEUE_DESC queue_desc = {0};
    D3D12_HEAP_PROPERTIES upload_heap = {0}, default_heap = {0}, readback_heap = {0};
    D3D12_RESOURCE_DESC buffer_desc = {0};
    D3D12_RESOURCE_BARRIER barrier = {0};
    unsigned char *mapped;
    D3D12_RANGE read_range = {0, sizeof(expected)};
    HRESULT result;
    unsigned int i;

    stage("JUICE_D3D12_STAGE load-library");
    d3d12_module = LoadLibraryW(L"d3d12.dll");
    if (!d3d12_module) return fail("LoadLibrary(d3d12)", E_FAIL);
    create_device = (create_device_fn)GetProcAddress(d3d12_module, "D3D12CreateDevice");
    if (!create_device) return fail("D3D12CreateDevice-proc", E_NOINTERFACE);
    stage("JUICE_D3D12_STAGE create-device-enter");
    result = create_device(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&device);
    if (FAILED(result)) return fail("D3D12CreateDevice", result);
    stage("JUICE_D3D12_STAGE create-device-complete");

    queue_desc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    result = ID3D12Device_CreateCommandQueue(device, &queue_desc, &IID_ID3D12CommandQueue, (void **)&queue);
    if (FAILED(result)) return fail("CreateCommandQueue", result);
    result = ID3D12Device_CreateCommandAllocator(device, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                                  &IID_ID3D12CommandAllocator, (void **)&allocator);
    if (FAILED(result)) return fail("CreateCommandAllocator", result);
    result = ID3D12Device_CreateCommandList(device, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator, NULL,
                                             &IID_ID3D12GraphicsCommandList, (void **)&list);
    if (FAILED(result)) return fail("CreateCommandList", result);

    upload_heap.Type = D3D12_HEAP_TYPE_UPLOAD;
    default_heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    readback_heap.Type = D3D12_HEAP_TYPE_READBACK;
    upload_heap.CPUPageProperty = default_heap.CPUPageProperty = readback_heap.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
    upload_heap.MemoryPoolPreference = default_heap.MemoryPoolPreference = readback_heap.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
    upload_heap.CreationNodeMask = default_heap.CreationNodeMask = readback_heap.CreationNodeMask = 1;
    upload_heap.VisibleNodeMask = default_heap.VisibleNodeMask = readback_heap.VisibleNodeMask = 1;
    buffer_desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    buffer_desc.Width = sizeof(expected);
    buffer_desc.Height = 1;
    buffer_desc.DepthOrArraySize = 1;
    buffer_desc.MipLevels = 1;
    buffer_desc.SampleDesc.Count = 1;
    buffer_desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;

    result = ID3D12Device_CreateCommittedResource(device, &upload_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
                                                   D3D12_RESOURCE_STATE_GENERIC_READ, NULL,
                                                   &IID_ID3D12Resource, (void **)&upload);
    if (FAILED(result)) return fail("CreateUploadBuffer", result);
    result = ID3D12Device_CreateCommittedResource(device, &default_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
                                                   D3D12_RESOURCE_STATE_COPY_DEST, NULL,
                                                   &IID_ID3D12Resource, (void **)&gpu);
    if (FAILED(result)) return fail("CreateGpuBuffer", result);
    result = ID3D12Device_CreateCommittedResource(device, &readback_heap, D3D12_HEAP_FLAG_NONE, &buffer_desc,
                                                   D3D12_RESOURCE_STATE_COPY_DEST, NULL,
                                                   &IID_ID3D12Resource, (void **)&readback);
    if (FAILED(result)) return fail("CreateReadbackBuffer", result);

    for (i = 0; i < sizeof(expected); i++) expected[i] = (unsigned char)((i * 29u + 17u) & 0xffu);
    result = ID3D12Resource_Map(upload, 0, NULL, (void **)&mapped);
    if (FAILED(result)) return fail("MapUpload", result);
    for (i = 0; i < sizeof(expected); i++) mapped[i] = expected[i];
    ID3D12Resource_Unmap(upload, 0, NULL);
    ID3D12GraphicsCommandList_CopyBufferRegion(list, gpu, 0, upload, 0, sizeof(expected));
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = gpu;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &barrier);
    ID3D12GraphicsCommandList_CopyBufferRegion(list, readback, 0, gpu, 0, sizeof(expected));
    result = ID3D12GraphicsCommandList_Close(list);
    if (FAILED(result)) return fail("CloseCommandList", result);
    {
        ID3D12CommandList *lists[] = {(ID3D12CommandList *)list};
        stage("JUICE_D3D12_STAGE execute-command-list");
        ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
    }
    result = ID3D12Device_CreateFence(device, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence);
    if (FAILED(result)) return fail("CreateFence", result);
    result = ID3D12CommandQueue_Signal(queue, fence, 1);
    if (FAILED(result)) return fail("QueueSignal", result);
    for (i = 0; i < 100000000u; i++)
        if (ID3D12Fence_GetCompletedValue(fence) >= 1) break;
    if (i == 100000000u) return fail("FenceTimeout", E_FAIL);

    stage("JUICE_D3D12_STAGE fence-complete");
    result = ID3D12Resource_Map(readback, 0, &read_range, (void **)&mapped);
    if (FAILED(result)) return fail("MapReadback", result);
    for (i = 0; i < sizeof(expected); i++)
        if (mapped[i] != expected[i]) return fail("GpuCopyMismatch", E_FAIL);
    ID3D12Resource_Unmap(readback, 0, NULL);

    write_marker("JUICE_D3D12_SMOKE_OK bytes=4096 fence=1 backend=wine-vkd3d-moltenvk\r\n");
    stage("JUICE_D3D12_STAGE marker-written");

    ID3D12Fence_Release(fence);
    ID3D12Resource_Release(readback);
    ID3D12Resource_Release(gpu);
    ID3D12Resource_Release(upload);
    ID3D12GraphicsCommandList_Release(list);
    ID3D12CommandAllocator_Release(allocator);
    ID3D12CommandQueue_Release(queue);
    ID3D12Device_Release(device);
    ExitProcess(0);
}
