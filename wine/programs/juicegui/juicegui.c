/*
 * Juice desktop shell for Grape.
 *
 * This program is Juice-original code and intentionally uses only Win32/GDI
 * APIs so the ARM64 binary stays small and exercises the same Wine window path
 * as installed applications.
 */

#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <string.h>
#include <wchar.h>
#include "juiceios.h"

#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
#define MAX_APPS 256

#define IDC_APP_LIST 1001
#define IDC_MENU 1002
#define IDC_LAUNCH 1003
#define IDC_INSTALL 1004
#define IDC_FILES 1005
#define IDC_REFRESH 1006
#define IDC_UNINSTALL 1007
#define IDC_HOST 1008
#define IDT_IMPORT 2001
#define IDT_REFRESH 2002
#define IDT_REPAINT 2003

#define IDM_WINE_MINE 3001
#define IDM_INSTALL 3002
#define IDM_FILES 3003
#define IDM_REFRESH 3004
#define IDM_EXPERIMENTAL_INFO 3005
#define IDM_RELOAD_WALLPAPER 3006
#define IDM_WALLPAPER_INFO 3007

#ifndef IMAGE_FILE_MACHINE_ARM64
#define IMAGE_FILE_MACHINE_ARM64 0xaa64
#endif
#ifndef IMAGE_FILE_MACHINE_ARM64EC
#define IMAGE_FILE_MACHINE_ARM64EC 0xa641
#endif

struct app_entry
{
    WCHAR name[160];
    WCHAR path[1024];
    WCHAR arguments[512];
    WCHAR uninstall[1024];
    WORD machine;
    BOOL experimental;
};

static HWND main_window;
static HWND app_list;
static HWND menu_button;
static HWND launch_button;
static HWND install_button;
static HWND files_button;
static HWND refresh_button;
static HWND uninstall_button;
static HWND host_button;
static HFONT title_font;
static HFONT body_font;
static HFONT icon_font;
static HBRUSH desktop_brush;
static HBRUSH app_list_brush;
static HBITMAP wallpaper_bitmap;
static int wallpaper_width;
static int wallpaper_height;
static WCHAR wallpaper_path[1024];
static HMODULE bridge_module;
static juice_ios_begin_file_import_fn begin_file_import;
static juice_ios_poll_file_import_fn poll_file_import;
static juice_ios_host_action_fn host_action;
static DWORD import_request_id;
static struct app_entry apps[MAX_APPS];
static unsigned int app_count;
static WCHAR status_text[512] =
    L"Wine ARM64 is ready. x86-64 execution is experimental.";

static const WCHAR default_wallpaper_path[] =
    L"Z:\\var\\mobile\\Documents\\JuiceData\\Wallpaper.bmp";

static BOOL query_string( HKEY key, const WCHAR *name, WCHAR *value, DWORD capacity );

static void copy_string( WCHAR *destination, size_t capacity, const WCHAR *source )
{
    if (!capacity) return;
    if (!source) source = L"";
    lstrcpynW( destination, source, capacity );
}

static void set_status( const WCHAR *text )
{
    copy_string( status_text, ARRAY_LEN(status_text), text );
    if (main_window) InvalidateRect( main_window, NULL, FALSE );
}

static void show_error( const WCHAR *title, const WCHAR *message )
{
    set_status( message );
    MessageBoxW( main_window, message, title, MB_OK | MB_ICONERROR );
}

static void unload_wallpaper(void)
{
    if (wallpaper_bitmap) DeleteObject( wallpaper_bitmap );
    wallpaper_bitmap = NULL;
    wallpaper_width = wallpaper_height = 0;
}

static BOOL try_load_wallpaper( const WCHAR *path )
{
    BITMAP bitmap;

    if (!path || !*path) return FALSE;
    wallpaper_bitmap = LoadImageW( NULL, path, IMAGE_BITMAP, 0, 0,
                                   LR_LOADFROMFILE | LR_CREATEDIBSECTION );
    if (!wallpaper_bitmap) return FALSE;
    if (!GetObjectW( wallpaper_bitmap, sizeof(bitmap), &bitmap ) ||
        bitmap.bmWidth <= 0 || bitmap.bmHeight <= 0)
    {
        unload_wallpaper();
        return FALSE;
    }
    wallpaper_width = bitmap.bmWidth;
    wallpaper_height = bitmap.bmHeight;
    copy_string( wallpaper_path, ARRAY_LEN(wallpaper_path), path );
    return TRUE;
}

static BOOL load_wallpaper(void)
{
    HKEY key;
    WCHAR configured[1024];

    unload_wallpaper();
    wallpaper_path[0] = 0;
    configured[0] = 0;
    if (RegOpenKeyExW( HKEY_CURRENT_USER, L"Software\\Juice\\Desktop", 0,
                       KEY_READ, &key ) == ERROR_SUCCESS)
    {
        query_string( key, L"Wallpaper", configured, ARRAY_LEN(configured) );
        RegCloseKey( key );
    }
    if (configured[0] && try_load_wallpaper( configured )) return TRUE;
    return try_load_wallpaper( default_wallpaper_path );
}

static void paint_builtin_wallpaper( HDC dc, const RECT *client )
{
    RECT band = *client;
    HBRUSH grape_brush;
    HPEN pen;
    HGDIOBJ old_dc_brush;
    HGDIOBJ old_pen;
    HGDIOBJ old_brush;
    int index;
    int bands = 12;

    /* A deterministic GDI-only fallback keeps the desktop attractive even
     * before the user supplies Wallpaper.bmp. */
    old_dc_brush = SelectObject( dc, GetStockObject( DC_BRUSH ) );
    for (index = 0; index < bands; index++)
    {
        int red = 12 + index / 2;
        int green = 34 + index * 4;
        int blue = 65 + index * 6;
        band.top = client->top + (client->bottom - client->top) * index / bands;
        band.bottom = client->top + (client->bottom - client->top) * (index + 1) / bands;
        SetDCBrushColor( dc, RGB(red, green, blue) );
        FillRect( dc, &band, GetStockObject( DC_BRUSH ) );
    }
    SelectObject( dc, old_dc_brush );

    pen = CreatePen( PS_SOLID, 5, RGB(208, 225, 245) );
    grape_brush = CreateSolidBrush( RGB(91, 55, 139) );
    old_pen = SelectObject( dc, pen );
    old_brush = SelectObject( dc, grape_brush );
    Ellipse( dc, client->right - 238, 75, client->right - 90, 223 );
    Ellipse( dc, client->right - 330, 175, client->right - 182, 323 );
    Ellipse( dc, client->right - 178, 234, client->right - 30, 382 );
    Ellipse( dc, client->right - 280, 330, client->right - 132, 478 );
    SelectObject( dc, old_brush );
    SelectObject( dc, old_pen );
    DeleteObject( grape_brush );
    DeleteObject( pen );
}

static void paint_wallpaper( HDC dc, const RECT *client )
{
    HDC memory_dc;
    HGDIOBJ previous;
    int source_x = 0, source_y = 0;
    int source_width = wallpaper_width, source_height = wallpaper_height;
    int target_width = client->right - client->left;
    int target_height = client->bottom - client->top;

    if (!wallpaper_bitmap || !wallpaper_width || !wallpaper_height)
    {
        paint_builtin_wallpaper( dc, client );
        return;
    }

    if ((LONGLONG)wallpaper_width * target_height >
        (LONGLONG)wallpaper_height * target_width)
    {
        source_width = MulDiv( wallpaper_height, target_width, target_height );
        source_x = (wallpaper_width - source_width) / 2;
    }
    else
    {
        source_height = MulDiv( wallpaper_width, target_height, target_width );
        source_y = (wallpaper_height - source_height) / 2;
    }
    memory_dc = CreateCompatibleDC( dc );
    previous = SelectObject( memory_dc, wallpaper_bitmap );
    SetStretchBltMode( dc, HALFTONE );
    StretchBlt( dc, client->left, client->top, target_width, target_height,
                memory_dc, source_x, source_y, source_width, source_height, SRCCOPY );
    SelectObject( memory_dc, previous );
    DeleteDC( memory_dc );
}

static BOOL query_string( HKEY key, const WCHAR *name, WCHAR *value, DWORD capacity )
{
    DWORD type = 0;
    DWORD size = capacity * sizeof(WCHAR);
    LONG status;

    value[0] = 0;
    status = RegQueryValueExW( key, name, NULL, &type, (BYTE *)value, &size );
    if (status != ERROR_SUCCESS || (type != REG_SZ && type != REG_EXPAND_SZ)) return FALSE;
    value[capacity - 1] = 0;
    if (type == REG_EXPAND_SZ)
    {
        WCHAR expanded[1024];
        if (ExpandEnvironmentStringsW( value, expanded, ARRAY_LEN(expanded) ))
            copy_string( value, capacity, expanded );
    }
    return TRUE;
}

static DWORD query_dword( HKEY key, const WCHAR *name, DWORD fallback )
{
    DWORD value = fallback;
    DWORD type = 0;
    DWORD size = sizeof(value);
    if (RegQueryValueExW( key, name, NULL, &type, (BYTE *)&value, &size ) != ERROR_SUCCESS ||
        type != REG_DWORD) return fallback;
    return value;
}

static void executable_from_command( const WCHAR *command, WCHAR *path, size_t capacity )
{
    const WCHAR *start = command;
    const WCHAR *end;
    WCHAR expanded[1024];

    path[0] = 0;
    if (!command || !*command) return;
    while (*start == L' ' || *start == L'\t') start++;
    if (*start == L'"')
    {
        start++;
        end = wcschr( start, L'"' );
    }
    else
    {
        end = wcsstr( start, L".exe" );
        if (end) end += 4;
        else
        {
            end = start;
            while (*end && *end != L' ' && *end != L'\t' && *end != L',') end++;
        }
    }
    if (!end) end = start + lstrlenW(start);
    if ((size_t)(end - start) >= capacity) end = start + capacity - 1;
    memcpy( path, start, (end - start) * sizeof(WCHAR) );
    path[end - start] = 0;
    if (ExpandEnvironmentStringsW( path, expanded, ARRAY_LEN(expanded) ))
        copy_string( path, capacity, expanded );
    end = wcsrchr( path, L',' );
    if (end) path[end - path] = 0;
}

static WORD pe_machine( const WCHAR *candidate )
{
    WCHAR path[1024];
    WCHAR resolved[1024];
    HANDLE file;
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 nt;
    DWORD count;
    LARGE_INTEGER offset;

    executable_from_command( candidate, path, ARRAY_LEN(path) );
    if (!path[0]) return 0;
    if (SearchPathW( NULL, path, NULL, ARRAY_LEN(resolved), resolved, NULL ))
        copy_string( path, ARRAY_LEN(path), resolved );

    file = CreateFileW( path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
    if (file == INVALID_HANDLE_VALUE) return 0;
    if (!ReadFile( file, &dos, sizeof(dos), &count, NULL ) || count != sizeof(dos) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE)
    {
        CloseHandle( file );
        return 0;
    }
    offset.QuadPart = dos.e_lfanew;
    if (offset.QuadPart < 0 || offset.QuadPart > 16 * 1024 * 1024 ||
        !SetFilePointerEx( file, offset, NULL, FILE_BEGIN ) ||
        !ReadFile( file, &nt, sizeof(nt), &count, NULL ) ||
        count < sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) || nt.Signature != IMAGE_NT_SIGNATURE)
    {
        CloseHandle( file );
        return 0;
    }
    CloseHandle( file );
    return nt.FileHeader.Machine;
}

static BOOL same_entry( const WCHAR *name, const WCHAR *path )
{
    unsigned int index;
    for (index = 0; index < app_count; index++)
    {
        if (path && *path && apps[index].path[0] && !lstrcmpiW( apps[index].path, path )) return TRUE;
        if ((!path || !*path) && !lstrcmpiW( apps[index].name, name )) return TRUE;
    }
    return FALSE;
}

static void add_entry( const WCHAR *name, const WCHAR *path, const WCHAR *arguments,
                       const WCHAR *uninstall, WORD machine )
{
    struct app_entry *entry;

    if (!name || !*name || app_count >= MAX_APPS || same_entry( name, path )) return;
    entry = &apps[app_count++];
    memset( entry, 0, sizeof(*entry) );
    copy_string( entry->name, ARRAY_LEN(entry->name), name );
    copy_string( entry->path, ARRAY_LEN(entry->path), path );
    copy_string( entry->arguments, ARRAY_LEN(entry->arguments), arguments );
    copy_string( entry->uninstall, ARRAY_LEN(entry->uninstall), uninstall );
    entry->machine = machine ? machine : pe_machine(path);
    entry->experimental = entry->machine == IMAGE_FILE_MACHINE_AMD64 ||
                          entry->machine == IMAGE_FILE_MACHINE_ARM64EC;
}

static void enumerate_key( HKEY root, const WCHAR *base, BOOL juice_catalog )
{
    HKEY key;
    DWORD index = 0;

    if (RegOpenKeyExW( root, base, 0, KEY_READ, &key ) != ERROR_SUCCESS) return;
    for (;;)
    {
        WCHAR subkey_name[256];
        DWORD subkey_length = ARRAY_LEN(subkey_name);
        HKEY subkey;
        WCHAR name[160], path[1024], arguments[512], uninstall[1024];
        WORD machine = 0;
        LONG status;

        status = RegEnumKeyExW( key, index++, subkey_name, &subkey_length, NULL, NULL, NULL, NULL );
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) continue;
        if (RegOpenKeyExW( key, subkey_name, 0, KEY_READ, &subkey ) != ERROR_SUCCESS) continue;

        name[0] = path[0] = arguments[0] = uninstall[0] = 0;
        if (juice_catalog)
        {
            query_string( subkey, L"Name", name, ARRAY_LEN(name) );
            query_string( subkey, L"Path", path, ARRAY_LEN(path) );
            query_string( subkey, L"Arguments", arguments, ARRAY_LEN(arguments) );
            query_string( subkey, L"Uninstall", uninstall, ARRAY_LEN(uninstall) );
            machine = (WORD)query_dword( subkey, L"Machine", 0 );
        }
        else
        {
            query_string( subkey, L"DisplayName", name, ARRAY_LEN(name) );
            if (!query_string( subkey, L"JuiceLaunchPath", path, ARRAY_LEN(path) ))
                query_string( subkey, L"DisplayIcon", path, ARRAY_LEN(path) );
            query_string( subkey, L"UninstallString", uninstall, ARRAY_LEN(uninstall) );
        }
        RegCloseKey( subkey );
        add_entry( name, path, arguments, uninstall, machine );
    }
    RegCloseKey( key );
}

static void seed_catalog(void)
{
    HKEY key;
    DWORD disposition;
    DWORD machine = IMAGE_FILE_MACHINE_ARM64;
    const WCHAR name[] = L"WineMine";
    const WCHAR path[] = L"winemine.exe";

    if (RegCreateKeyExW( HKEY_CURRENT_USER, L"Software\\Juice\\Applications\\WineMine", 0,
                         NULL, 0, KEY_WRITE, NULL, &key, &disposition ) != ERROR_SUCCESS) return;
    RegSetValueExW( key, L"Name", 0, REG_SZ, (const BYTE *)name, sizeof(name) );
    RegSetValueExW( key, L"Path", 0, REG_SZ, (const BYTE *)path, sizeof(path) );
    RegSetValueExW( key, L"Machine", 0, REG_DWORD, (const BYTE *)&machine, sizeof(machine) );
    RegCloseKey( key );

    machine = IMAGE_FILE_MACHINE_AMD64;
    if (RegCreateKeyExW( HKEY_CURRENT_USER,
                         L"Software\\Juice\\Applications\\X8664Smoke", 0,
                         NULL, 0, KEY_WRITE, NULL, &key, &disposition ) == ERROR_SUCCESS)
    {
        static const WCHAR x64_name[] = L"Juice x86-64 Smoke Test";
        static const WCHAR x64_path[] = L"x86_64-smoke.exe";
        RegSetValueExW( key, L"Name", 0, REG_SZ, (const BYTE *)x64_name,
                        sizeof(x64_name) );
        RegSetValueExW( key, L"Path", 0, REG_SZ, (const BYTE *)x64_path,
                        sizeof(x64_path) );
        RegSetValueExW( key, L"Machine", 0, REG_DWORD, (const BYTE *)&machine,
                        sizeof(machine) );
        RegCloseKey( key );
    }
}

static void refresh_apps(void)
{
    unsigned int index;
    WCHAR label[256];

    app_count = 0;
    SendMessageW( app_list, LB_RESETCONTENT, 0, 0 );
    enumerate_key( HKEY_CURRENT_USER, L"Software\\Juice\\Applications", TRUE );
    enumerate_key( HKEY_CURRENT_USER,
                   L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", FALSE );
    enumerate_key( HKEY_LOCAL_MACHINE,
                   L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall", FALSE );

    for (index = 0; index < app_count; index++)
    {
        if (apps[index].experimental)
            wsprintfW( label, L"[Experimental x86-64] %s", apps[index].name );
        else
            copy_string( label, ARRAY_LEN(label), apps[index].name );
        SendMessageW( app_list, LB_ADDSTRING, 0, (LPARAM)label );
    }
    if (app_count) SendMessageW( app_list, LB_SETCURSEL, 0, 0 );
    wsprintfW( label, L"%u installed application%s", app_count, app_count == 1 ? L"" : L"s" );
    set_status( label );
}

static BOOL launch_command( const WCHAR *path, const WCHAR *arguments )
{
    WCHAR command[4096];
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;
    BOOL result;

    if (!path || !*path) return FALSE;
    if (arguments && *arguments)
        wsprintfW( command, L"\"%s\" %s", path, arguments );
    else
        wsprintfW( command, L"\"%s\"", path );
    result = CreateProcessW( NULL, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process );
    if (result)
    {
        CloseHandle( process.hThread );
        CloseHandle( process.hProcess );
    }
    return result;
}

static BOOL launch_raw_command( const WCHAR *command )
{
    WCHAR mutable_command[4096];
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;
    BOOL result;

    copy_string( mutable_command, ARRAY_LEN(mutable_command), command );
    result = CreateProcessW( NULL, mutable_command, NULL, NULL, FALSE, 0,
                             NULL, NULL, &startup, &process );
    if (result)
    {
        CloseHandle( process.hThread );
        CloseHandle( process.hProcess );
    }
    return result;
}

static void launch_path( const WCHAR *path, const WCHAR *arguments, WORD known_machine )
{
    WORD machine = known_machine ? known_machine : pe_machine(path);
    WCHAR message[512];

    if (machine == IMAGE_FILE_MACHINE_AMD64 || machine == IMAGE_FILE_MACHINE_ARM64EC)
    {
        if (!host_action ||
            host_action( JUICE_IOS_ACTION_LAUNCH_PATH, path ) != JUICE_IOS_STATUS_COMPLETE)
        {
            show_error( L"Experimental x86-64",
                        L"The x86-64 host route is unavailable. Enable the experimental runtime in Juice." );
            return;
        }
        wsprintfW( message, L"Experimental x86-64 launch requested: %s", path );
        set_status( message );
        return;
    }
    if (machine && machine != IMAGE_FILE_MACHINE_ARM64)
    {
        show_error( L"Unsupported application",
                    L"Juice currently supports Windows ARM64 and experimental x86-64 executables." );
        return;
    }
    if (!launch_command( path, arguments ))
    {
        wsprintfW( message, L"Could not launch %s (error %lu).", path, GetLastError() );
        show_error( L"Launch failed", message );
        return;
    }
    wsprintfW( message, L"Launched %s", path );
    set_status( message );
}

static struct app_entry *selected_app(void)
{
    LRESULT selection = SendMessageW( app_list, LB_GETCURSEL, 0, 0 );
    if (selection == LB_ERR || (unsigned int)selection >= app_count) return NULL;
    return &apps[selection];
}

static void launch_selected(void)
{
    struct app_entry *entry = selected_app();
    if (!entry) return;
    if (!entry->path[0])
    {
        show_error( L"No launch command",
                    L"This installed application did not register a launch executable." );
        return;
    }
    launch_path( entry->path, entry->arguments, entry->machine );
}

static void uninstall_selected(void)
{
    struct app_entry *entry = selected_app();
    if (!entry) return;
    if (!entry->uninstall[0])
    {
        show_error( L"No uninstaller", L"This application did not register an uninstall command." );
        return;
    }
    if (MessageBoxW( main_window, L"Uninstall the selected application?", L"Juice",
                     MB_YESNO | MB_ICONQUESTION ) != IDYES) return;
    if (!launch_raw_command( entry->uninstall ))
        show_error( L"Uninstall failed", L"Wine could not start the registered uninstaller." );
    else
    {
        set_status( L"Uninstaller started." );
        SetTimer( main_window, IDT_REFRESH, 3000, NULL );
    }
}

static void open_imported_files(void)
{
    if ((INT_PTR)ShellExecuteW( main_window, L"open", L"explorer.exe",
                                L"Z:\\var\\mobile\\Documents\\JuiceData\\Imported",
                                NULL, SW_SHOWNORMAL ) <= 32)
        show_error( L"Files", L"Could not open the imported-files directory." );
}

static void handle_imported_path( const WCHAR *path )
{
    const WCHAR *extension = wcsrchr( path, L'.' );
    WCHAR arguments[1400];

    if (extension && !lstrcmpiW( extension, L".msi" ))
    {
        wsprintfW( arguments, L"/i \"%s\"", path );
        if (!launch_command( L"msiexec.exe", arguments ))
            show_error( L"MSI installer", L"Wine could not start msiexec." );
        else
        {
            set_status( L"MSI installation started." );
            SetTimer( main_window, IDT_REFRESH, 4000, NULL );
        }
        return;
    }
    if (extension && !lstrcmpiW( extension, L".exe" ))
    {
        launch_path( path, NULL, 0 );
        SetTimer( main_window, IDT_REFRESH, 4000, NULL );
        return;
    }
    if (extension && !lstrcmpiW( extension, L".zip" ))
    {
        if (!host_action ||
            host_action( JUICE_IOS_ACTION_IMPORT_ZIP, path ) != JUICE_IOS_STATUS_COMPLETE)
            show_error( L"Portable ZIP", L"The safe ZIP importer is unavailable." );
        else
            set_status( L"Portable ZIP handed to the safe Juice importer." );
        return;
    }
    show_error( L"Unsupported installer", L"Choose an .msi, .exe, or .zip file." );
}

static void begin_install(void)
{
    DWORD status;

    if (!begin_file_import || !poll_file_import)
    {
        show_error( L"Install Application",
                    L"The versioned iOS file-picker bridge is unavailable." );
        return;
    }
    if (import_request_id)
    {
        set_status( L"An import request is already active." );
        return;
    }
    status = begin_file_import( JUICE_IOS_FILTER_MSI | JUICE_IOS_FILTER_EXE |
                                JUICE_IOS_FILTER_ZIP, &import_request_id );
    if (status != JUICE_IOS_STATUS_PENDING || !import_request_id)
    {
        import_request_id = 0;
        show_error( L"Install Application", L"Juice could not open the iOS file picker." );
        return;
    }
    set_status( L"Choose an MSI, setup executable, or portable ZIP in the iOS picker." );
    SetTimer( main_window, IDT_IMPORT, 150, NULL );
}

static void poll_import(void)
{
    struct juice_ios_import_result result;
    DWORD status;

    if (!import_request_id) return;
    memset( &result, 0, sizeof(result) );
    result.size = sizeof(result);
    status = poll_file_import( import_request_id, &result );
    if (status == JUICE_IOS_STATUS_PENDING) return;

    KillTimer( main_window, IDT_IMPORT );
    import_request_id = 0;
    if (status == JUICE_IOS_STATUS_COMPLETE && result.path[0])
    {
        set_status( L"File imported into the persistent Juice directory." );
        handle_imported_path( result.path );
    }
    else if (status == JUICE_IOS_STATUS_CANCELLED)
        set_status( L"Import cancelled." );
    else
        show_error( L"Import failed", result.detail[0] ? result.detail :
                    L"The iOS file picker did not return a usable Windows path." );
}

static void load_bridge(void)
{
    bridge_module = LoadLibraryW( L"wineios.drv" );
    if (!bridge_module) return;
    begin_file_import = (juice_ios_begin_file_import_fn)GetProcAddress(
        bridge_module, "JuiceIOSBeginFileImport" );
    poll_file_import = (juice_ios_poll_file_import_fn)GetProcAddress(
        bridge_module, "JuiceIOSPollFileImport" );
    host_action = (juice_ios_host_action_fn)GetProcAddress(
        bridge_module, "JuiceIOSHostAction" );
}

static void write_smoke_marker(void)
{
    HANDLE file = CreateFileW( L"Z:\\var\\mobile\\Documents\\Juice-JuiceGUI-smoke.ok",
                               GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, NULL );
    static const char marker[] = "JUICE_GUI_ARM64_OK\n";
    DWORD written;
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile( file, marker, sizeof(marker) - 1, &written, NULL );
    CloseHandle( file );
}

static void show_applications_menu(void)
{
    POINT point;
    RECT button_rect;
    HMENU menu = CreatePopupMenu();

    AppendMenuW( menu, MF_STRING, IDM_WINE_MINE, L"Launch WineMine" );
    AppendMenuW( menu, MF_STRING, IDM_INSTALL, L"Install Application..." );
    AppendMenuW( menu, MF_STRING, IDM_FILES, L"Files" );
    AppendMenuW( menu, MF_SEPARATOR, 0, NULL );
    AppendMenuW( menu, MF_STRING, IDM_REFRESH, L"Refresh applications" );
    AppendMenuW( menu, MF_STRING, IDM_RELOAD_WALLPAPER, L"Reload wallpaper" );
    AppendMenuW( menu, MF_STRING, IDM_WALLPAPER_INFO, L"Custom wallpaper help" );
    AppendMenuW( menu, MF_SEPARATOR, 0, NULL );
    AppendMenuW( menu, MF_STRING, IDM_EXPERIMENTAL_INFO,
                 L"x86-64 translation (experimental)" );
    GetWindowRect( menu_button, &button_rect );
    point.x = button_rect.left;
    point.y = button_rect.top;
    TrackPopupMenu( menu, TPM_LEFTALIGN | TPM_BOTTOMALIGN, point.x, point.y, 0,
                    main_window, NULL );
    DestroyMenu( menu );
}

static void layout_controls( int width, int height )
{
    int taskbar_y = height - 58;
    int content_top = 92;
    int list_width = width > 800 ? 330 : width / 3;
    int gap = 6;
    int button_width = (width - 7 * gap) / 6;

    MoveWindow( host_button, width - 54, 12, 38, 32, TRUE );
    MoveWindow( app_list, 20, content_top, list_width, taskbar_y - content_top - 20, TRUE );
    MoveWindow( menu_button, gap, taskbar_y + 8, button_width, 40, TRUE );
    MoveWindow( launch_button, gap * 2 + button_width, taskbar_y + 8,
                button_width, 40, TRUE );
    MoveWindow( install_button, gap * 3 + button_width * 2, taskbar_y + 8,
                button_width, 40, TRUE );
    MoveWindow( files_button, gap * 4 + button_width * 3, taskbar_y + 8,
                button_width, 40, TRUE );
    MoveWindow( refresh_button, gap * 5 + button_width * 4, taskbar_y + 8,
                button_width, 40, TRUE );
    MoveWindow( uninstall_button, gap * 6 + button_width * 5, taskbar_y + 8,
                button_width, 40, TRUE );
}

static void create_controls( HWND window )
{
    body_font = CreateFontW( -18, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI" );
    title_font = CreateFontW( -29, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                              CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI" );
    icon_font = CreateFontW( -28, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                             DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI" );

    menu_button = CreateWindowW( L"BUTTON", L"Juice", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                 0, 0, 0, 0, window, (HMENU)IDC_MENU, NULL, NULL );
    host_button = CreateWindowW( L"BUTTON", L"...", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                                 0, 0, 0, 0, window, (HMENU)IDC_HOST, NULL, NULL );
    app_list = CreateWindowExW( 0, L"LISTBOX", NULL,
                                WS_CHILD | WS_VISIBLE | WS_VSCROLL | LBS_NOTIFY |
                                LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS,
                                0, 0, 0, 0, window,
                                (HMENU)IDC_APP_LIST, NULL, NULL );
    launch_button = CreateWindowW( L"BUTTON", L"Launch", WS_CHILD | WS_VISIBLE,
                                   0, 0, 0, 0, window, (HMENU)IDC_LAUNCH, NULL, NULL );
    install_button = CreateWindowW( L"BUTTON", L"Install App", WS_CHILD | WS_VISIBLE,
                                    0, 0, 0, 0, window, (HMENU)IDC_INSTALL, NULL, NULL );
    files_button = CreateWindowW( L"BUTTON", L"Files", WS_CHILD | WS_VISIBLE,
                                  0, 0, 0, 0, window, (HMENU)IDC_FILES, NULL, NULL );
    refresh_button = CreateWindowW( L"BUTTON", L"Refresh", WS_CHILD | WS_VISIBLE,
                                    0, 0, 0, 0, window, (HMENU)IDC_REFRESH, NULL, NULL );
    uninstall_button = CreateWindowW( L"BUTTON", L"Uninstall", WS_CHILD | WS_VISIBLE,
                                      0, 0, 0, 0, window, (HMENU)IDC_UNINSTALL, NULL, NULL );

    SendMessageW( menu_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( host_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( app_list, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( launch_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( install_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( files_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( refresh_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( uninstall_button, WM_SETFONT, (WPARAM)body_font, TRUE );
    SendMessageW( app_list, LB_SETITEMHEIGHT, 0, 72 );
}

static LRESULT WINAPI window_proc( HWND window, UINT message, WPARAM wparam, LPARAM lparam )
{
    switch (message)
    {
    case WM_CREATE:
        load_wallpaper();
        create_controls( window );
        seed_catalog();
        load_bridge();
        refresh_apps();
        write_smoke_marker();
        SetTimer( window, IDT_REPAINT, 350, NULL );
        return 0;

    case WM_SIZE:
        layout_controls( LOWORD(lparam), HIWORD(lparam) );
        InvalidateRect( window, NULL, TRUE );
        return 0;

    case WM_ERASEBKGND:
        return 1;

    case WM_PAINT:
    {
        PAINTSTRUCT paint;
        RECT client;
        RECT header;
        RECT taskbar;
        RECT panel;
        RECT heading;
        int content_left;
        HDC dc = BeginPaint( window, &paint );
        HBRUSH header_brush = CreateSolidBrush( RGB(13, 29, 49) );
        HBRUSH taskbar_brush = CreateSolidBrush( RGB(10, 20, 34) );
        HBRUSH panel_brush = CreateSolidBrush( RGB(15, 37, 63) );
        HFONT previous;
        SetBkMode( dc, TRANSPARENT );
        GetClientRect( window, &client );
        paint_wallpaper( dc, &client );
        header = client;
        header.bottom = 58;
        FillRect( dc, &header, header_brush );
        taskbar = client;
        taskbar.top = taskbar.bottom - 58;
        FillRect( dc, &taskbar, taskbar_brush );

        heading.left = 20;
        heading.top = 8;
        heading.right = 126;
        heading.bottom = 50;
        previous = SelectObject( dc, title_font );
        SetTextColor( dc, RGB(255, 255, 255) );
        DrawTextW( dc, L"Juice", -1, &heading, DT_LEFT | DT_VCENTER | DT_SINGLELINE );
        heading.left = 138;
        heading.top = 14;
        heading.right = client.right - 72;
        heading.bottom = 48;
        SelectObject( dc, body_font );
        SetTextColor( dc, RGB(166, 205, 255) );
        DrawTextW( dc, L"Grape ARM64 desktop  \x2022  x86-64 via FEX is experimental",
                   -1, &heading, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS );

        heading.left = 20;
        heading.top = 64;
        heading.right = client.right > 800 ? 350 : client.right / 3 + 20;
        heading.bottom = 88;
        SetTextColor( dc, RGB(235, 244, 255) );
        DrawTextW( dc, L"Desktop applications", -1, &heading, DT_LEFT | DT_TOP );

        content_left = client.right > 800 ? 374 : client.right / 3 + 44;
        panel.left = content_left;
        panel.top = 92;
        panel.right = client.right - 24;
        panel.bottom = 338;
        FillRect( dc, &panel, panel_brush );
        heading = panel;
        InflateRect( &heading, -24, -18 );
        heading.bottom = heading.top + 44;
        SelectObject( dc, title_font );
        SetTextColor( dc, RGB(255, 255, 255) );
        DrawTextW( dc, L"Welcome to Juice", -1, &heading, DT_LEFT | DT_TOP );
        heading.left = panel.left + 24;
        heading.top = panel.top + 74;
        heading.right = panel.right - 24;
        heading.bottom = heading.top + 54;
        SelectObject( dc, body_font );
        SetTextColor( dc, RGB(113, 196, 255) );
        DrawTextW( dc, status_text, -1, &heading, DT_LEFT | DT_TOP | DT_WORDBREAK );
        heading = panel;
        InflateRect( &heading, -24, -18 );
        heading.top += 124;
        heading.bottom = panel.bottom - 18;
        SetTextColor( dc, RGB(202, 220, 242) );
        DrawTextW( dc,
                   L"Double-click a shortcut or select it and choose Launch.\n\n"
                   L"Install accepts MSI, setup EXE, and portable ZIP packages. "
                   L"ARM64 apps run directly; x86-64 apps use the isolated "
                   L"experimental FEX translator.",
                   -1, &heading, DT_LEFT | DT_TOP | DT_WORDBREAK );

        heading.left = content_left;
        heading.top = 360;
        heading.right = client.right - 24;
        heading.bottom = heading.top + 80;
        SetTextColor( dc, RGB(225, 237, 250) );
        DrawTextW( dc, wallpaper_bitmap ?
                   L"Custom wallpaper active. Use Juice > Reload wallpaper after replacing it." :
                   L"Customise this desktop by adding Wallpaper.bmp to JuiceData, then use "
                   L"Juice > Reload wallpaper.",
                   -1, &heading, DT_LEFT | DT_TOP | DT_WORDBREAK );
        SelectObject( dc, previous );
        DeleteObject( panel_brush );
        DeleteObject( taskbar_brush );
        DeleteObject( header_brush );
        EndPaint( window, &paint );
        return 0;
    }

    case WM_CTLCOLORLISTBOX:
        SetBkColor( (HDC)wparam, RGB(12, 30, 54) );
        SetTextColor( (HDC)wparam, RGB(240, 247, 255) );
        return (LRESULT)app_list_brush;

    case WM_DRAWITEM:
        if (wparam == IDC_APP_LIST)
        {
            DRAWITEMSTRUCT *draw = (DRAWITEMSTRUCT *)lparam;
            RECT item = draw->rcItem;
            RECT icon;
            RECT text_rect;
            WCHAR initial[2] = {L'J', 0};
            HGDIOBJ old_brush;
            HGDIOBJ old_pen;
            HFONT old_font;
            COLORREF background;
            COLORREF accent;

            if (draw->itemID == (UINT)-1 || draw->itemID >= app_count) return TRUE;
            background = draw->itemState & ODS_SELECTED ? RGB(45, 103, 166) : RGB(12, 30, 54);
            accent = apps[draw->itemID].experimental ? RGB(150, 91, 205) : RGB(44, 150, 142);
            SetDCBrushColor( draw->hDC, background );
            FillRect( draw->hDC, &item, GetStockObject( DC_BRUSH ) );

            icon = item;
            InflateRect( &icon, -10, -10 );
            icon.right = icon.left + 52;
            SetDCPenColor( draw->hDC, RGB(215, 231, 249) );
            SetDCBrushColor( draw->hDC, accent );
            old_pen = SelectObject( draw->hDC, GetStockObject( DC_PEN ) );
            old_brush = SelectObject( draw->hDC, GetStockObject( DC_BRUSH ) );
            RoundRect( draw->hDC, icon.left, icon.top, icon.right, icon.bottom, 12, 12 );
            if (apps[draw->itemID].name[0]) initial[0] = apps[draw->itemID].name[0];
            SetBkMode( draw->hDC, TRANSPARENT );
            SetTextColor( draw->hDC, RGB(255, 255, 255) );
            old_font = SelectObject( draw->hDC, icon_font );
            DrawTextW( draw->hDC, initial, -1, &icon,
                       DT_CENTER | DT_VCENTER | DT_SINGLELINE );

            text_rect = item;
            text_rect.left = icon.right + 12;
            text_rect.right -= 8;
            text_rect.top += 13;
            SelectObject( draw->hDC, body_font );
            DrawTextW( draw->hDC, apps[draw->itemID].name, -1, &text_rect,
                       DT_LEFT | DT_TOP | DT_SINGLELINE | DT_END_ELLIPSIS );
            if (apps[draw->itemID].experimental)
            {
                text_rect.top += 28;
                SetTextColor( draw->hDC, RGB(222, 190, 255) );
                DrawTextW( draw->hDC, L"x86-64 experimental", -1, &text_rect,
                           DT_LEFT | DT_TOP | DT_SINGLELINE );
            }
            SelectObject( draw->hDC, old_font );
            SelectObject( draw->hDC, old_brush );
            SelectObject( draw->hDC, old_pen );
            if (draw->itemState & ODS_FOCUS) DrawFocusRect( draw->hDC, &item );
            return TRUE;
        }
        break;

    case WM_TIMER:
        if (wparam == IDT_IMPORT) poll_import();
        else if (wparam == IDT_REFRESH)
        {
            KillTimer( window, IDT_REFRESH );
            refresh_apps();
        }
        else if (wparam == IDT_REPAINT)
        {
            KillTimer( window, IDT_REPAINT );
            RedrawWindow( window, NULL, NULL,
                          RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW );
        }
        return 0;

    case WM_COMMAND:
        switch (LOWORD(wparam))
        {
        case IDC_MENU:
            show_applications_menu();
            break;
        case IDC_LAUNCH:
            launch_selected();
            break;
        case IDC_INSTALL:
            begin_install();
            break;
        case IDC_FILES:
            open_imported_files();
            break;
        case IDC_REFRESH:
            refresh_apps();
            load_wallpaper();
            InvalidateRect( window, NULL, TRUE );
            break;
        case IDC_UNINSTALL:
            uninstall_selected();
            break;
        case IDC_HOST:
            if (!host_action ||
                host_action( JUICE_IOS_ACTION_SHOW_HOST_CONTROLS, NULL ) !=
                JUICE_IOS_STATUS_COMPLETE)
                show_error( L"Juice controls", L"The native Juice controls are unavailable." );
            break;
        case IDC_APP_LIST:
            if (HIWORD(wparam) == LBN_DBLCLK) launch_selected();
            break;
        case IDM_WINE_MINE:
            launch_path( L"winemine.exe", NULL, IMAGE_FILE_MACHINE_ARM64 );
            break;
        case IDM_INSTALL:
            begin_install();
            break;
        case IDM_FILES:
            open_imported_files();
            break;
        case IDM_REFRESH:
            refresh_apps();
            break;
        case IDM_RELOAD_WALLPAPER:
            if (load_wallpaper())
                set_status( L"Custom wallpaper loaded." );
            else
                set_status( L"Wallpaper.bmp was not found; using the built-in Juice background." );
            InvalidateRect( window, NULL, TRUE );
            break;
        case IDM_WALLPAPER_INFO:
            MessageBoxW( window,
                         L"Copy a Windows BMP image to:\n\n"
                         L"Z:\\var\\mobile\\Documents\\JuiceData\\Wallpaper.bmp\n\n"
                         L"Then choose Juice > Reload wallpaper. Advanced users can set "
                         L"HKCU\\Software\\Juice\\Desktop\\Wallpaper to another Windows path. "
                         L"The image is centre-cropped to fill the desktop.",
                         L"Custom Juice wallpaper", MB_OK | MB_ICONINFORMATION );
            break;
        case IDM_EXPERIMENTAL_INFO:
            MessageBoxW( window,
                         L"x86-64 applications are translated through Hangover/FEX without "
                         L"a virtual machine. This path is experimental and isolated from "
                         L"the verified ARM64 prefix.",
                         L"Experimental x86-64", MB_OK | MB_ICONINFORMATION );
            break;
        }
        return 0;

    case WM_CLOSE:
        if (MessageBoxW( window, L"Close the Juice desktop?", L"Juice",
                         MB_YESNO | MB_ICONQUESTION ) == IDYES)
            DestroyWindow( window );
        return 0;

    case WM_DESTROY:
        PostQuitMessage( 0 );
        return 0;
    }
    return DefWindowProcW( window, message, wparam, lparam );
}

int WINAPI wWinMain( HINSTANCE instance, HINSTANCE previous, WCHAR *command_line, int show )
{
    WNDCLASSEXW window_class;
    MSG message;
    int width = GetSystemMetrics( SM_CXSCREEN );
    int height = GetSystemMetrics( SM_CYSCREEN );

    desktop_brush = CreateSolidBrush( RGB(20, 51, 86) );
    app_list_brush = CreateSolidBrush( RGB(12, 30, 54) );
    memset( &window_class, 0, sizeof(window_class) );
    window_class.cbSize = sizeof(window_class);
    window_class.hInstance = instance;
    window_class.lpfnWndProc = window_proc;
    window_class.hCursor = LoadCursorW( NULL, (const WCHAR *)IDC_ARROW );
    window_class.hIcon = LoadIconW( NULL, (const WCHAR *)IDI_APPLICATION );
    window_class.hbrBackground = desktop_brush;
    window_class.lpszClassName = L"JuiceDesktopWindow";
    if (!RegisterClassExW( &window_class )) return 2;

    main_window = CreateWindowExW( 0, window_class.lpszClassName, L"Juice Desktop",
                                   WS_POPUP | WS_CLIPCHILDREN, 0, 0, width, height,
                                   NULL, NULL, instance, NULL );
    if (!main_window) return 3;
    ShowWindow( main_window, SW_SHOWMAXIMIZED );
    UpdateWindow( main_window );

    while (GetMessageW( &message, NULL, 0, 0 ) > 0)
    {
        TranslateMessage( &message );
        DispatchMessageW( &message );
    }

    if (bridge_module) FreeLibrary( bridge_module );
    unload_wallpaper();
    if (title_font) DeleteObject( title_font );
    if (body_font) DeleteObject( body_font );
    if (icon_font) DeleteObject( icon_font );
    if (app_list_brush) DeleteObject( app_list_brush );
    if (desktop_brush) DeleteObject( desktop_brush );
    return (int)message.wParam;
}
