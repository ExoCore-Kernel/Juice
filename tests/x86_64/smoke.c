/*
 * Minimal real x86_64 Windows GUI program used to prove Juice's user-mode
 * ARM64EC/FEX translation path on an iOS device.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

__declspec(noreturn) void mainCRTStartup(void)
{
    static const WCHAR default_marker_path[] =
        L"Z:\\var\\mobile\\Documents\\Juice-x86_64-smoke.ok";
    static const char marker[] = "JUICE_X86_64_SMOKE_OK\r\n";
    typedef int (WINAPI *message_box_w_fn)(HWND, LPCWSTR, LPCWSTR, UINT);
    DWORD written = 0;
    WCHAR marker_path[1024];
    WCHAR headless[2];
    HANDLE file;

    if (!GetEnvironmentVariableW(L"JUICE_X64_MARKER_WINDOWS", marker_path,
                                 sizeof(marker_path) / sizeof(marker_path[0])))
    {
        unsigned int i;
        for (i = 0; i < sizeof(default_marker_path) / sizeof(default_marker_path[0]); ++i)
            marker_path[i] = default_marker_path[i];
    }

    /* Prove translated AMD64 reached kernel32 before loading any GUI driver. */
    file = CreateFileW(marker_path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file != INVALID_HANDLE_VALUE)
    {
        WriteFile(file, marker, sizeof(marker) - 1, &written, NULL);
        CloseHandle(file);
    }

    if (!GetEnvironmentVariableW(L"JUICE_X64_SMOKE_HEADLESS", headless,
                                 sizeof(headless) / sizeof(headless[0])))
    {
        HMODULE user32 = LoadLibraryW(L"user32.dll");
        message_box_w_fn message_box = user32 ?
            (message_box_w_fn)(void *)GetProcAddress(user32, "MessageBoxW") : NULL;
        if (message_box)
            message_box(NULL,
                        L"Real x86_64 Windows code reached user32 through Wine.",
                        L"Juice x86_64 translation works",
                        MB_OK | MB_ICONINFORMATION);
    }
    ExitProcess(file == INVALID_HANDLE_VALUE ? 1 : 100);
}
