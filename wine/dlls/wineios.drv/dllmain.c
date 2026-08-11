/* Wine iOS driver entry point. LGPL-2.1-or-later. */
#include <stdarg.h>
#include "windef.h"
#include "winbase.h"
#include "wine/unixlib.h"
#include "control.h"

DWORD WINAPI JuiceIOSBeginFileImport( DWORD filters, DWORD *request_id )
{
    struct wineios_begin_params params = {JUICE_IOS_API_VERSION, filters, 0, JUICE_IOS_STATUS_ERROR};
    NTSTATUS status;

    if (!request_id) return JUICE_IOS_STATUS_ERROR;
    status = WINE_UNIX_CALL( unix_begin_file_import, &params );
    if (status) return JUICE_IOS_STATUS_ERROR;
    *request_id = params.request_id;
    return params.status;
}

DWORD WINAPI JuiceIOSPollFileImport( DWORD request_id, struct juice_ios_import_result *result )
{
    struct wineios_poll_params params = {JUICE_IOS_API_VERSION, request_id,
                                         JUICE_IOS_STATUS_ERROR, 0};
    NTSTATUS status;

    if (!result || result->size < sizeof(*result)) return JUICE_IOS_STATUS_ERROR;
    status = WINE_UNIX_CALL( unix_poll_file_import, &params );
    if (status) return JUICE_IOS_STATUS_ERROR;
    result->version = JUICE_IOS_API_VERSION;
    result->request_id = request_id;
    result->status = params.status;
    lstrcpynW( result->path, params.path, ARRAY_SIZE(result->path) );
    lstrcpynW( result->detail, params.detail, ARRAY_SIZE(result->detail) );
    return params.status;
}

DWORD WINAPI JuiceIOSHostAction( DWORD action, const WCHAR *path )
{
    struct wineios_action_params params = {JUICE_IOS_API_VERSION, action,
                                           JUICE_IOS_STATUS_ERROR, 0};
    NTSTATUS status;

    if (path) lstrcpynW( params.path, path, ARRAY_SIZE(params.path) );
    status = WINE_UNIX_CALL( unix_host_action, &params );
    return status ? JUICE_IOS_STATUS_ERROR : params.status;
}

BOOL WINAPI DllMain( HINSTANCE instance, DWORD reason, void *reserved )
{
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls( instance );
    if (__wine_init_unix_call()) return FALSE;
    return !WINE_UNIX_CALL( unix_init, NULL );
}
