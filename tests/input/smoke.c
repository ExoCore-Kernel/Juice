/* Juice external keyboard and XInput bridge smoke test. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <xinput.h>

typedef DWORD (WINAPI *xinput_get_state_fn)(DWORD, XINPUT_STATE *);

static BOOL key_down_seen, key_up_seen, controller_seen;
static xinput_get_state_fn get_xinput_state;
static HWND window;

static void write_marker(const WCHAR *name, const char *contents)
{
    WCHAR path[MAX_PATH];
    HANDLE file;
    DWORD written;

    wsprintfW(path, L"Z:\\var\\mobile\\Documents\\%s", name);
    file = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, contents, lstrlenA(contents), &written, NULL);
    CloseHandle(file);
}

static void update_completion(void)
{
    if (key_down_seen && key_up_seen)
        write_marker(L"Juice-HardwareKeyboard.ok",
                     "JUICE_HARDWARE_KEYBOARD_OK key=A down=1 up=1\n");
    if (key_down_seen && key_up_seen && controller_seen)
        write_marker(L"Juice-ExternalInput.ok",
                     "JUICE_EXTERNAL_INPUT_OK keyboard=hardware controller=xinput-v1\n");
    InvalidateRect(window, NULL, FALSE);
}

static void poll_controller(void)
{
    XINPUT_STATE state;
    char marker[256];

    if (!get_xinput_state || get_xinput_state(0, &state) != ERROR_SUCCESS) return;
    if (!(state.Gamepad.wButtons & XINPUT_GAMEPAD_A) ||
        state.Gamepad.bLeftTrigger != 96 || state.Gamepad.sThumbLX != 12345 ||
        state.Gamepad.sThumbRY != -23456) return;
    if (!controller_seen)
    {
        wsprintfA(marker,
                  "JUICE_GAMECONTROLLER_XINPUT_OK packet=%lu buttons=0x%x lt=%u lx=%d ry=%d\n",
                  state.dwPacketNumber, state.Gamepad.wButtons,
                  state.Gamepad.bLeftTrigger, state.Gamepad.sThumbLX,
                  state.Gamepad.sThumbRY);
        write_marker(L"Juice-GameController-XInput.ok", marker);
        controller_seen = TRUE;
        update_completion();
    }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    switch (message)
    {
    case WM_KEYDOWN:
        if (wparam == 'A') key_down_seen = TRUE;
        update_completion();
        return 0;
    case WM_KEYUP:
        if (wparam == 'A') key_up_seen = TRUE;
        update_completion();
        return 0;
    case WM_TIMER:
        poll_controller();
        return 0;
    case WM_PAINT:
    {
        static const WCHAR title[] = L"Juice External Input Smoke";
        WCHAR status[256];
        PAINTSTRUCT paint;
        RECT client;
        HDC dc = BeginPaint(hwnd, &paint);
        HBRUSH background = CreateSolidBrush(RGB(15, 25, 43));
        HBRUSH panel = CreateSolidBrush(RGB(239, 245, 252));
        GetClientRect(hwnd, &client);
        FillRect(dc, &client, background);
        SetRect(&client, 34, 92, client.right - 34, client.bottom - 38);
        FillRect(dc, &client, panel);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(255, 255, 255));
        SelectObject(dc, GetStockObject(DEFAULT_GUI_FONT));
        TextOutW(dc, 34, 38, title, ARRAYSIZE(title) - 1);
        wsprintfW(status,
                  L"Hardware keyboard A: %s / %s\r\n\r\n"
                  L"GameController -> XInput: %s\r\n\r\n"
                  L"Touch uses its independent, unchanged input path.",
                  key_down_seen ? L"DOWN" : L"waiting",
                  key_up_seen ? L"UP" : L"waiting",
                  controller_seen ? L"CONNECTED + STATE PASS" : L"waiting");
        SetTextColor(dc, RGB(24, 41, 65));
        DrawTextW(dc, status, -1, &client, DT_LEFT | DT_TOP | DT_WORDBREAK);
        DeleteObject(panel);
        DeleteObject(background);
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, WCHAR *command_line, int show)
{
    WNDCLASSW cls = {0};
    HMODULE xinput = LoadLibraryW(L"xinput1_4.dll");
    MSG message;

    if (xinput) get_xinput_state = (xinput_get_state_fn)GetProcAddress(xinput, "XInputGetState");
    cls.lpfnWndProc = window_proc;
    cls.hInstance = instance;
    cls.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    cls.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    cls.lpszClassName = L"JuiceExternalInputSmokeWindow";
    if (!RegisterClassW(&cls)) return 2;
    window = CreateWindowW(cls.lpszClassName, L"Juice Keyboard + Controller Test",
                           WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT,
                           760, 500, NULL, NULL, instance, NULL);
    if (!window) return 3;
    ShowWindow(window, SW_SHOW);
    UpdateWindow(window);
    SetForegroundWindow(window);
    SetFocus(window);
    SetTimer(window, 1, 50, NULL);
    while (GetMessageW(&message, NULL, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return (int)message.wParam;
}
