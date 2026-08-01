/* Wine iOS driver entry point. LGPL-2.1-or-later. */
#include <stdarg.h>
#include "windef.h"
#include "winbase.h"
#include "wine/unixlib.h"

BOOL WINAPI DllMain( HINSTANCE instance, DWORD reason, void *reserved )
{
    if (reason != DLL_PROCESS_ATTACH) return TRUE;
    DisableThreadLibraryCalls( instance );
    return !__wine_init_unix_call();
}
