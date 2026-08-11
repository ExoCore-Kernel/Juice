/* Asynchronous Win32-to-UIKit control bridge. LGPL-2.1-or-later. */
#if 0
#pragma makedep unix
#endif

#include "config.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winternl.h"
#include "wine/debug.h"
#include "wine/unixlib.h"
#include "control.h"
#include "control_protocol.h"

WINE_DEFAULT_DEBUG_CHANNEL(iosdrv);

static pthread_mutex_t control_lock = PTHREAD_MUTEX_INITIALIZER;
static int import_fd = -1;
static DWORD import_request_id;
static size_t response_used;
static struct juice_control_message response;
static DWORD request_sequence;

static BOOL write_all( int fd, const void *data, size_t size )
{
    const char *ptr = data;
    while (size)
    {
        ssize_t count = write( fd, ptr, size );
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return FALSE;
        ptr += count;
        size -= count;
    }
    return TRUE;
}

static void close_import(void)
{
    if (import_fd >= 0) close( import_fd );
    import_fd = -1;
    import_request_id = 0;
    response_used = 0;
    memset( &response, 0, sizeof(response) );
}

static int connect_control_socket(void)
{
    const char *path = getenv( "JUICE_IOS_CONTROL_SOCKET" );
    struct sockaddr_un addr;
    int fd;

    if (!path || !*path || strlen(path) >= sizeof(addr.sun_path)) return -1;
    memset( &addr, 0, sizeof(addr) );
    addr.sun_family = AF_UNIX;
    strcpy( addr.sun_path, path );
    if ((fd = socket( AF_UNIX, SOCK_STREAM, 0 )) < 0) return -1;
    if (connect( fd, (struct sockaddr *)&addr, sizeof(addr) ) < 0)
    {
        close( fd );
        return -1;
    }
    return fd;
}

static void copy_utf8_to_wide( WCHAR *destination, size_t capacity, const char *source )
{
    int count;

    if (!capacity) return;
    destination[0] = 0;
    if (!source || !*source) return;
    count = ntdll_umbstowcs( source, strlen(source), destination, capacity - 1 );
    if (count < 0) count = 0;
    destination[count] = 0;
}

static void copy_wide_to_utf8( char *destination, size_t capacity, const WCHAR *source )
{
    int count;

    if (!capacity) return;
    destination[0] = 0;
    if (!source || !*source) return;
    count = ntdll_wcstoumbs( source, wcslen(source), destination, capacity - 1, FALSE );
    if (count < 0) count = 0;
    destination[count] = 0;
}

static BOOL valid_message( const struct juice_control_message *message, UINT type )
{
    return message->magic == JUICE_CONTROL_MAGIC &&
           message->version == JUICE_CONTROL_VERSION &&
           message->size == sizeof(*message) && message->type == type;
}

static NTSTATUS begin_file_import( void *args )
{
    struct wineios_begin_params *params = args;
    struct juice_control_message message;
    int flags;

    params->status = JUICE_IOS_STATUS_ERROR;
    params->request_id = 0;
    if (params->version != JUICE_IOS_API_VERSION) return STATUS_REVISION_MISMATCH;

    pthread_mutex_lock( &control_lock );
    if (import_fd >= 0)
    {
        pthread_mutex_unlock( &control_lock );
        return STATUS_DEVICE_BUSY;
    }
    if ((import_fd = connect_control_socket()) < 0)
    {
        pthread_mutex_unlock( &control_lock );
        return STATUS_DEVICE_NOT_CONNECTED;
    }

    memset( &message, 0, sizeof(message) );
    message.magic = JUICE_CONTROL_MAGIC;
    message.version = JUICE_CONTROL_VERSION;
    message.type = JUICE_CONTROL_IMPORT_REQUEST;
    message.size = sizeof(message);
    message.request_id = ((DWORD)getpid() << 16) ^ ++request_sequence;
    message.status = JUICE_CONTROL_STATUS_PENDING;
    message.flags = params->filters;
    if (!write_all( import_fd, &message, sizeof(message) ))
    {
        close_import();
        pthread_mutex_unlock( &control_lock );
        return STATUS_DEVICE_NOT_CONNECTED;
    }

    flags = fcntl( import_fd, F_GETFL, 0 );
    if (flags >= 0) fcntl( import_fd, F_SETFL, flags | O_NONBLOCK );
    import_request_id = message.request_id;
    params->request_id = message.request_id;
    params->status = JUICE_IOS_STATUS_PENDING;
    TRACE( "file import request %u filters %#x\n", params->request_id, params->filters );
    pthread_mutex_unlock( &control_lock );
    return STATUS_SUCCESS;
}

static NTSTATUS poll_file_import( void *args )
{
    struct wineios_poll_params *params = args;

    params->status = JUICE_IOS_STATUS_ERROR;
    params->path[0] = params->detail[0] = 0;
    if (params->version != JUICE_IOS_API_VERSION) return STATUS_REVISION_MISMATCH;

    pthread_mutex_lock( &control_lock );
    if (import_fd < 0 || params->request_id != import_request_id)
    {
        copy_utf8_to_wide( params->detail, ARRAY_SIZE(params->detail), "No matching import request." );
        pthread_mutex_unlock( &control_lock );
        return STATUS_SUCCESS;
    }

    while (response_used < sizeof(response))
    {
        ssize_t count = recv( import_fd, (char *)&response + response_used,
                              sizeof(response) - response_used, 0 );
        if (count > 0)
        {
            response_used += count;
            continue;
        }
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
        {
            params->status = JUICE_IOS_STATUS_PENDING;
            pthread_mutex_unlock( &control_lock );
            return STATUS_SUCCESS;
        }
        copy_utf8_to_wide( params->detail, ARRAY_SIZE(params->detail),
                           "The Juice host closed the control channel." );
        close_import();
        pthread_mutex_unlock( &control_lock );
        return STATUS_SUCCESS;
    }

    if (!valid_message( &response, JUICE_CONTROL_IMPORT_RESPONSE ) ||
        response.request_id != params->request_id)
    {
        copy_utf8_to_wide( params->detail, ARRAY_SIZE(params->detail),
                           "Invalid response from the Juice host." );
        close_import();
        pthread_mutex_unlock( &control_lock );
        return STATUS_SUCCESS;
    }

    params->status = response.status;
    copy_utf8_to_wide( params->path, ARRAY_SIZE(params->path), response.path );
    copy_utf8_to_wide( params->detail, ARRAY_SIZE(params->detail), response.detail );
    close_import();
    pthread_mutex_unlock( &control_lock );
    return STATUS_SUCCESS;
}

static NTSTATUS host_action( void *args )
{
    struct wineios_action_params *params = args;
    struct juice_control_message message;
    int fd;

    params->status = JUICE_IOS_STATUS_ERROR;
    if (params->version != JUICE_IOS_API_VERSION) return STATUS_REVISION_MISMATCH;
    if ((fd = connect_control_socket()) < 0) return STATUS_DEVICE_NOT_CONNECTED;

    memset( &message, 0, sizeof(message) );
    message.magic = JUICE_CONTROL_MAGIC;
    message.version = JUICE_CONTROL_VERSION;
    message.type = JUICE_CONTROL_HOST_ACTION;
    message.size = sizeof(message);
    message.request_id = ((DWORD)getpid() << 16) ^ ++request_sequence;
    message.status = JUICE_CONTROL_STATUS_PENDING;
    message.flags = params->action;
    copy_wide_to_utf8( message.path, ARRAY_SIZE(message.path), params->path );
    if (!write_all( fd, &message, sizeof(message) ))
    {
        close( fd );
        return STATUS_DEVICE_NOT_CONNECTED;
    }
    close( fd );
    params->status = JUICE_IOS_STATUS_COMPLETE;
    return STATUS_SUCCESS;
}

const unixlib_entry_t __wine_unix_call_funcs[] =
{
    iosdrv_unix_init,
    begin_file_import,
    poll_file_import,
    host_action
};

C_ASSERT( ARRAY_SIZE(__wine_unix_call_funcs) == unix_funcs_count );

#ifdef _WIN64
const unixlib_entry_t __wine_unix_call_wow64_funcs[] =
{
    iosdrv_unix_init,
    begin_file_import,
    poll_file_import,
    host_action
};

C_ASSERT( ARRAY_SIZE(__wine_unix_call_wow64_funcs) == unix_funcs_count );
#endif
