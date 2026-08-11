/* Public Juice Win32-to-iOS integration ABI. LGPL-2.1-or-later. */
#ifndef __JUICE_IOS_H
#define __JUICE_IOS_H

#include <windef.h>
#include <winbase.h>

#define JUICE_IOS_API_VERSION 1u
#define JUICE_IOS_PATH_CHARS 1024u
#define JUICE_IOS_DETAIL_CHARS 256u

#define JUICE_IOS_FILTER_MSI 0x01u
#define JUICE_IOS_FILTER_EXE 0x02u
#define JUICE_IOS_FILTER_ZIP 0x04u

#define JUICE_IOS_STATUS_PENDING 1u
#define JUICE_IOS_STATUS_COMPLETE 2u
#define JUICE_IOS_STATUS_CANCELLED 3u
#define JUICE_IOS_STATUS_ERROR 4u

#define JUICE_IOS_ACTION_SHOW_HOST_CONTROLS 1u
#define JUICE_IOS_ACTION_LAUNCH_PATH 2u
#define JUICE_IOS_ACTION_IMPORT_ZIP 3u

struct juice_ios_import_result
{
    DWORD size;
    DWORD version;
    DWORD request_id;
    DWORD status;
    WCHAR path[JUICE_IOS_PATH_CHARS];
    WCHAR detail[JUICE_IOS_DETAIL_CHARS];
};

typedef DWORD (WINAPI *juice_ios_begin_file_import_fn)(DWORD filters, DWORD *request_id);
typedef DWORD (WINAPI *juice_ios_poll_file_import_fn)(DWORD request_id,
                                                       struct juice_ios_import_result *result);
typedef DWORD (WINAPI *juice_ios_host_action_fn)(DWORD action, const WCHAR *path);

#endif
