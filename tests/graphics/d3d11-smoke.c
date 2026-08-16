/* Juice Direct3D 11 / WineD3D Vulkan smoke test. Public-domain test code. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>

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

    file = CreateFileW(L"juice-d3d11-smoke.txt",
                       GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, text, string_length(text), &written, NULL);
    CloseHandle(file);
}

static __declspec(noreturn) int fail(const char *stage, HRESULT result)
{
    char marker[256];
    char *end = append_text(marker, "JUICE_D3D11_SMOKE_FAIL stage=");
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
    typedef HRESULT (WINAPI *create_device_fn)(IDXGIAdapter *, D3D_DRIVER_TYPE, HMODULE, UINT,
            const D3D_FEATURE_LEVEL *, UINT, UINT, ID3D11Device **, D3D_FEATURE_LEVEL *,
            ID3D11DeviceContext **);
    static const D3D_FEATURE_LEVEL requested_levels[] =
    {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3,
    };
    HMODULE module;
    create_device_fn create_device;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    ID3D11Buffer *gpu = NULL, *readback = NULL;
    D3D11_BUFFER_DESC gpu_desc = {0}, readback_desc = {0};
    D3D11_SUBRESOURCE_DATA initial_data = {0};
    D3D11_MAPPED_SUBRESOURCE mapped;
    D3D_FEATURE_LEVEL selected_level;
    HRESULT result;
    unsigned int i;

    stage("JUICE_D3D11_STAGE load-library");
    module = LoadLibraryW(L"d3d11.dll");
    if (!module) return fail("LoadLibrary(d3d11)", E_FAIL);
    create_device = (create_device_fn)GetProcAddress(module, "D3D11CreateDevice");
    if (!create_device) return fail("D3D11CreateDevice-proc", E_NOINTERFACE);
    stage("JUICE_D3D11_STAGE create-device-enter");
    result = create_device(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0,
            requested_levels, sizeof(requested_levels) / sizeof(requested_levels[0]),
            D3D11_SDK_VERSION, &device, &selected_level, &context);
    if (FAILED(result)) return fail("D3D11CreateDevice", result);
    stage("JUICE_D3D11_STAGE create-device-complete");

    for (i = 0; i < sizeof(expected); i++) expected[i] = (unsigned char)((i * 37u + 23u) & 0xffu);
    gpu_desc.ByteWidth = sizeof(expected);
    gpu_desc.Usage = D3D11_USAGE_DEFAULT;
    initial_data.pSysMem = expected;
    stage("JUICE_D3D11_STAGE create-gpu-buffer");
    result = ID3D11Device_CreateBuffer(device, &gpu_desc, &initial_data, &gpu);
    if (FAILED(result)) return fail("CreateGpuBuffer", result);

    readback_desc.ByteWidth = sizeof(expected);
    readback_desc.Usage = D3D11_USAGE_STAGING;
    readback_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    stage("JUICE_D3D11_STAGE create-readback-buffer");
    result = ID3D11Device_CreateBuffer(device, &readback_desc, NULL, &readback);
    if (FAILED(result)) return fail("CreateReadbackBuffer", result);

    stage("JUICE_D3D11_STAGE gpu-copy-enter");
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)readback, (ID3D11Resource *)gpu);
    ID3D11DeviceContext_Flush(context);
    result = ID3D11DeviceContext_Map(context, (ID3D11Resource *)readback, 0,
            D3D11_MAP_READ, 0, &mapped);
    if (FAILED(result)) return fail("MapReadback", result);
    stage("JUICE_D3D11_STAGE gpu-copy-complete");
    for (i = 0; i < sizeof(expected); i++)
        if (((unsigned char *)mapped.pData)[i] != expected[i])
            return fail("GpuCopyMismatch", E_FAIL);
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)readback, 0);

    {
        char marker[256];
        char *end = append_text(marker, "JUICE_D3D11_SMOKE_OK bytes=4096 feature_level=0x");
        end = append_hex32(end, (unsigned long)selected_level);
        end = append_text(end, " backend=wined3d-vulkan-moltenvk\r\n");
        *end = 0;
        write_marker(marker);
        stage("JUICE_D3D11_STAGE marker-written");
    }
    ID3D11Buffer_Release(readback);
    ID3D11Buffer_Release(gpu);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    FreeLibrary(module);
    ExitProcess(0);
}
