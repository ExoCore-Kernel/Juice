/*
 * Deterministic GDI text and UIKit text-input smoke test for Juice/Grape.
 * Juice-original code.
 */

#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

#define ID_EDIT   1001
#define ID_BUTTON 1002
#define ID_STATUS 1003
#define EXPECTED_TEXT L"Juice input works 42"

static HWND main_window, edit_control, status_control;
static HFONT title_font, body_font, mono_font;
static BOOL render_marker_written, input_marker_written;
static UINT paint_count;

static void write_marker( const WCHAR *name, const char *contents )
{
    WCHAR path[MAX_PATH];
    HANDLE file;
    DWORD written;

    wsprintfW( path, L"Z:\\var\\mobile\\Documents\\%s", name );
    file = CreateFileW( path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                        FILE_ATTRIBUTE_NORMAL, NULL );
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile( file, contents, lstrlenA(contents), &written, NULL );
    CloseHandle( file );
}

static void verify_input(void)
{
    WCHAR value[256];

    GetWindowTextW( edit_control, value, ARRAYSIZE(value) );
    if (!wcscmp( value, EXPECTED_TEXT ))
    {
        SetWindowTextW( status_control, L"PASS: UIKit text reached the Win32 EDIT control." );
        if (!input_marker_written)
        {
            write_marker( L"Juice-Text-input.ok", "JUICE_TEXT_INPUT_OK value=Juice input works 42\n" );
            input_marker_written = TRUE;
        }
    }
    else SetWindowTextW( status_control, L"Waiting for the exact test phrase..." );
}

static void create_fonts(HWND hwnd)
{
    HDC dc = GetDC( hwnd );
    int dpi = GetDeviceCaps( dc, LOGPIXELSY );

    ReleaseDC( hwnd, dc );
    title_font = CreateFontW( -MulDiv( 30, dpi, 72 ), 0, 0, 0, FW_BOLD, FALSE, FALSE,
                              FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Arial" );
    body_font = CreateFontW( -MulDiv( 17, dpi, 72 ), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
                             FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Arial" );
    mono_font = CreateFontW( -MulDiv( 16, dpi, 72 ), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
                             FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             ANTIALIASED_QUALITY, FIXED_PITCH | FF_MODERN, L"Courier New" );
}

static void create_controls(HWND hwnd)
{
    HWND instruction, verify_button;

    instruction = CreateWindowW( L"STATIC",
                   L"Tap the edit field, then send: Juice input works 42",
                   WS_CHILD | WS_VISIBLE, 34, 302, 650, 28, hwnd, NULL, NULL, NULL );
    edit_control = CreateWindowExW( WS_EX_CLIENTEDGE, L"EDIT", L"",
                   WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
                   34, 338, 520, 42, hwnd, (HMENU)ID_EDIT, NULL, NULL );
    verify_button = CreateWindowW( L"BUTTON", L"Verify text",
                   WS_CHILD | WS_VISIBLE | WS_TABSTOP, 570, 338, 144, 42,
                   hwnd, (HMENU)ID_BUTTON, NULL, NULL );
    status_control = CreateWindowW( L"STATIC", L"Waiting for the exact test phrase...",
                   WS_CHILD | WS_VISIBLE, 34, 394, 680, 30,
                   hwnd, (HMENU)ID_STATUS, NULL, NULL );

    SendMessageW( instruction, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( edit_control, WM_SETFONT, (WPARAM)mono_font, TRUE );
    SendMessageW( verify_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( status_control, WM_SETFONT, (WPARAM)body_font, TRUE );
}

static void paint_window(HWND hwnd)
{
    static const WCHAR heading[] = L"Juice GDI Text Smoke";
    static const WCHAR sentence[] = L"TextOutW: The quick brown fox jumps over 13 lazy grapes.";
    static const WCHAR paragraph[] =
        L"DrawTextW wraps this paragraph inside a measured rectangle.\n"
        L"ASCII, punctuation, and spacing must all remain visible.\n"
        L"Unicode sample: caf\x00e9  \x03a9  \x2713";
    PAINTSTRUCT ps;
    HDC dc = BeginPaint( hwnd, &ps );
    RECT client, block;
    HBRUSH background = CreateSolidBrush( RGB(18, 30, 48) );
    HBRUSH panel = CreateSolidBrush( RGB(239, 244, 250) );
    HFONT previous;
    SIZE extent = {0};
    char marker[160];

    GetClientRect( hwnd, &client );
    FillRect( dc, &client, background );
    SetRect( &block, 28, 82, client.right - 28, 280 );
    FillRect( dc, &block, panel );
    FrameRect( dc, &block, GetStockObject(DKGRAY_BRUSH) );
    SetBkMode( dc, TRANSPARENT );

    previous = SelectObject( dc, title_font );
    SetTextColor( dc, RGB(255, 255, 255) );
    TextOutW( dc, 28, 24, heading, ARRAYSIZE(heading) - 1 );

    SelectObject( dc, body_font );
    SetTextColor( dc, RGB(24, 40, 64) );
    TextOutW( dc, 48, 104, sentence, ARRAYSIZE(sentence) - 1 );
    SetRect( &block, 48, 148, client.right - 48, 260 );
    DrawTextW( dc, paragraph, -1, &block, DT_LEFT | DT_TOP | DT_WORDBREAK | DT_NOPREFIX );

    SelectObject( dc, mono_font );
    SetTextColor( dc, RGB(149, 255, 189) );
    TextOutW( dc, 30, client.bottom - 58, EXPECTED_TEXT, ARRAYSIZE(EXPECTED_TEXT) - 1 );
    GetTextExtentPoint32W( dc, sentence, ARRAYSIZE(sentence) - 1, &extent );
    SelectObject( dc, previous );
    DeleteObject( panel );
    DeleteObject( background );
    EndPaint( hwnd, &ps );

    paint_count++;
    if (!render_marker_written && extent.cx > 100 && extent.cy > 8)
    {
        wsprintfA( marker, "JUICE_TEXT_GDI_OK extent=%ldx%ld paint=%u\n",
                   extent.cx, extent.cy, paint_count );
        write_marker( L"Juice-Text-render.ok", marker );
        render_marker_written = TRUE;
    }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam)
{
    switch (message)
    {
    case WM_CREATE:
        main_window = hwnd;
        return 0;
    case WM_COMMAND:
        if ((LOWORD(wparam) == ID_EDIT && HIWORD(wparam) == EN_CHANGE) ||
            LOWORD(wparam) == ID_BUTTON) verify_input();
        return 0;
    case WM_TIMER:
        InvalidateRect( hwnd, NULL, FALSE );
        if (paint_count >= 5) KillTimer( hwnd, 1 );
        return 0;
    case WM_PAINT:
        paint_window( hwnd );
        return 0;
    case WM_DESTROY:
        DeleteObject( title_font );
        DeleteObject( body_font );
        DeleteObject( mono_font );
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcW( hwnd, message, wparam, lparam );
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, WCHAR *command_line, int show)
{
    WNDCLASSW class = {0};
    MSG message;

    class.style = CS_HREDRAW | CS_VREDRAW;
    class.lpfnWndProc = window_proc;
    class.hInstance = instance;
    class.hCursor = LoadCursorW( NULL, (LPCWSTR)IDC_ARROW );
    class.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    class.lpszClassName = L"JuiceTextSmokeWindow";
    if (!RegisterClassW( &class )) return 2;

    main_window = CreateWindowW( class.lpszClassName, L"Juice Text Rendering & Input Smoke",
                                 WS_OVERLAPPEDWINDOW,
                                 CW_USEDEFAULT, CW_USEDEFAULT, 780, 520,
                                 NULL, NULL, instance, NULL );
    if (!main_window)
    {
        char failure[96];
        wsprintfA( failure, "JUICE_TEXT_CREATE_FAILED error=%lu\n", GetLastError() );
        write_marker( L"Juice-Text-create-failed.log", failure );
        return 3;
    }

    /* wineios.drv attaches the top-level surface as CreateWindowW returns.
     * Do not request a DC or construct child surfaces from WM_CREATE. */
    create_fonts( main_window );
    create_controls( main_window );
    write_marker( L"Juice-Text-create-stage.ok", "JUICE_TEXT_CREATE_COMPLETE_OK\n" );
    ShowWindow( main_window, SW_SHOW );
    UpdateWindow( main_window );
    SetFocus( edit_control );
    SetTimer( main_window, 1, 500, NULL );
    while (GetMessageW( &message, NULL, 0, 0 ) > 0)
    {
        TranslateMessage( &message );
        DispatchMessageW( &message );
    }
    return (int)message.wParam;
}
