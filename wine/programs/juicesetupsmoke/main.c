/*
 * Ordinary setup.exe smoke test for Juice/Grape.
 * Juice-original code; uses only ARM64 Win32 APIs.
 */

#define UNICODE
#define _UNICODE
#include <windows.h>
#include <wchar.h>

#define ARRAY_LEN(a) (sizeof(a) / sizeof((a)[0]))
#define JUICE_MACHINE_ARM64 0xaa64

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

static BOOL make_target_paths( WCHAR *directory, WCHAR *executable )
{
    WCHAR local[MAX_PATH];
    DWORD length;

    length = GetEnvironmentVariableW( L"LOCALAPPDATA", local, ARRAY_LEN(local) );
    if (!length || length >= ARRAY_LEN(local) - 32) return FALSE;
    wsprintfW( directory, L"%s\\Juice\\SetupSmoke", local );
    wsprintfW( executable, L"%s\\JuiceSetupSmoke.exe", directory );
    return TRUE;
}

static BOOL create_target_directory( const WCHAR *directory )
{
    WCHAR parent[MAX_PATH];
    WCHAR *separator;
    DWORD error;

    lstrcpynW( parent, directory, ARRAY_LEN(parent) );
    separator = wcsrchr( parent, '\\' );
    if (!separator) return FALSE;
    *separator = 0;
    if (!CreateDirectoryW( parent, NULL ))
    {
        error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) return FALSE;
    }
    if (!CreateDirectoryW( directory, NULL ))
    {
        error = GetLastError();
        if (error != ERROR_ALREADY_EXISTS) return FALSE;
    }
    return TRUE;
}

static BOOL set_string( HKEY key, const WCHAR *name, const WCHAR *value )
{
    return RegSetValueExW( key, name, 0, REG_SZ, (const BYTE *)value,
                           (lstrlenW(value) + 1) * sizeof(WCHAR) ) == ERROR_SUCCESS;
}

static BOOL register_application( const WCHAR *target )
{
    static const WCHAR key_name[] = L"Software\\Juice\\Applications\\SetupSmoke";
    HKEY key;
    DWORD disposition;
    DWORD machine = JUICE_MACHINE_ARM64;
    WCHAR uninstall[1200];

    if (RegCreateKeyExW( HKEY_CURRENT_USER, key_name, 0, NULL, 0, KEY_WRITE,
                         NULL, &key, &disposition ) != ERROR_SUCCESS) return FALSE;
    wsprintfW( uninstall, L"\"%s\" /uninstall", target );
    set_string( key, L"Name", L"Juice Setup Smoke" );
    set_string( key, L"Path", target );
    set_string( key, L"Arguments", L"/installed" );
    set_string( key, L"Uninstall", uninstall );
    RegSetValueExW( key, L"Machine", 0, REG_DWORD, (const BYTE *)&machine,
                    sizeof(machine) );
    RegCloseKey( key );
    return TRUE;
}

static BOOL start_installed( const WCHAR *target )
{
    WCHAR command[1400];
    STARTUPINFOW startup = {sizeof(startup)};
    PROCESS_INFORMATION process;

    wsprintfW( command, L"\"%s\" /installed", target );
    if (!CreateProcessW( NULL, command, NULL, NULL, FALSE, 0, NULL, NULL,
                         &startup, &process )) return FALSE;
    CloseHandle( process.hThread );
    CloseHandle( process.hProcess );
    return TRUE;
}

static int uninstall_application( const WCHAR *target )
{
    RegDeleteTreeW( HKEY_CURRENT_USER, L"Software\\Juice\\Applications\\SetupSmoke" );
    MoveFileExW( target, NULL, MOVEFILE_DELAY_UNTIL_REBOOT );
    write_marker( L"Juice-Setup-uninstall.ok", "JUICE_SETUP_UNINSTALL_OK\n" );
    MessageBoxW( NULL, L"Juice Setup Smoke was uninstalled.", L"Juice Setup",
                 MB_OK | MB_ICONINFORMATION );
    return 0;
}

int WINAPI wWinMain( HINSTANCE instance, HINSTANCE previous, WCHAR *command_line, int show )
{
    WCHAR source[MAX_PATH];
    WCHAR directory[MAX_PATH];
    WCHAR target[MAX_PATH];
    WCHAR message[1500];

    if (!make_target_paths( directory, target ))
    {
        MessageBoxW( NULL, L"LocalAppData is unavailable.", L"Juice Setup",
                     MB_OK | MB_ICONERROR );
        return 2;
    }
    if (wcsstr( command_line, L"/uninstall" )) return uninstall_application( target );
    if (wcsstr( command_line, L"/installed" ))
    {
        write_marker( L"Juice-Setup-launch.ok", "JUICE_SETUP_LAUNCH_OK\n" );
        MessageBoxW( NULL, L"The installed ARM64 setup smoke application works.",
                     L"Juice Setup Smoke", MB_OK | MB_ICONINFORMATION );
        return 0;
    }

    if (!GetModuleFileNameW( NULL, source, ARRAY_LEN(source) ) ||
        !create_target_directory( directory ))
    {
        MessageBoxW( NULL, L"Could not create the persistent install directory.",
                     L"Juice Setup", MB_OK | MB_ICONERROR );
        return 3;
    }
    if (!CopyFileW( source, target, FALSE ))
    {
        wsprintfW( message, L"Could not copy the application (error %lu).", GetLastError() );
        MessageBoxW( NULL, message, L"Juice Setup", MB_OK | MB_ICONERROR );
        return 4;
    }
    if (!register_application( target ))
    {
        MessageBoxW( NULL, L"Could not register the installed application.",
                     L"Juice Setup", MB_OK | MB_ICONERROR );
        return 5;
    }

    write_marker( L"Juice-Setup-install.ok", "JUICE_SETUP_INSTALL_OK\n" );
    if (!start_installed( target ))
    {
        MessageBoxW( NULL, L"Installed, but the launch smoke step failed.",
                     L"Juice Setup", MB_OK | MB_ICONERROR );
        return 6;
    }
    return 0;
}
