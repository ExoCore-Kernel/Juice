#ifndef __WINE_IOS_CONTROL_H
#define __WINE_IOS_CONTROL_H

#include "juiceios.h"

enum wineios_unix_funcs
{
    unix_init,
    unix_begin_file_import,
    unix_poll_file_import,
    unix_host_action,
    unix_funcs_count
};

struct wineios_begin_params
{
    DWORD version;
    DWORD filters;
    DWORD request_id;
    DWORD status;
};

struct wineios_poll_params
{
    DWORD version;
    DWORD request_id;
    DWORD status;
    DWORD reserved;
    WCHAR path[JUICE_IOS_PATH_CHARS];
    WCHAR detail[JUICE_IOS_DETAIL_CHARS];
};

struct wineios_action_params
{
    DWORD version;
    DWORD action;
    DWORD status;
    DWORD reserved;
    WCHAR path[JUICE_IOS_PATH_CHARS];
};

NTSTATUS iosdrv_unix_init( void *args );

#endif
