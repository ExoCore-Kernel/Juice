/* Minimal native Windows ARM64 marker used to protect Juice's stable path. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

__declspec(noreturn) void mainCRTStartup(void)
{
    static const WCHAR default_marker_path[] =
        L"Z:\\var\\mobile\\Documents\\Juice-arm64-smoke.ok";
    static const char marker[] = "JUICE_ARM64_SMOKE_OK\r\n";
    WCHAR marker_path[1024];
    DWORD written = 0;
    HANDLE file;

    if (!GetEnvironmentVariableW(L"JUICE_ARM64_MARKER_WINDOWS", marker_path,
                                 sizeof(marker_path) / sizeof(marker_path[0])))
    {
        unsigned int i;
        for (i = 0; i < sizeof(default_marker_path) / sizeof(default_marker_path[0]); ++i)
            marker_path[i] = default_marker_path[i];
    }

    file = CreateFileW(marker_path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE)
    {
        WriteFile(file, marker, sizeof(marker) - 1, &written, NULL);
        CloseHandle(file);
    }
    ExitProcess(file == INVALID_HANDLE_VALUE ? 1 : 100);
}
