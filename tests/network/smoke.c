/* Generic Windows networking smoke test for every Juice PE architecture. */
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <wininet.h>

static char report[1024];
static unsigned int report_length;
static WCHAR marker_path[1024];

static void append_text(const char *text)
{
    while (*text && report_length + 1 < sizeof(report))
        report[report_length++] = *text++;
    report[report_length] = 0;
}

static void append_number(DWORD value)
{
    char digits[16];
    unsigned int count = 0;
    do
    {
        digits[count++] = '0' + value % 10;
        value /= 10;
    } while (value && count < sizeof(digits));
    while (count) report[report_length++] = digits[--count];
    report[report_length] = 0;
}

static void write_report(void)
{
    HANDLE file;
    DWORD written;
    file = CreateFileW(marker_path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                       CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    WriteFile(file, report, report_length, &written, NULL);
    CloseHandle(file);
}

__declspec(noreturn) static void fail(const char *stage, DWORD error)
{
    report_length = 0;
    append_text("JUICE_NETWORK_SMOKE_FAIL stage=");
    append_text(stage);
    append_text(" error=");
    append_number(error);
    append_text(" wsa=");
    append_number((DWORD)WSAGetLastError());
    append_text("\r\n");
    write_report();
    WSACleanup();
    ExitProcess(1);
}

static void zero_memory(void *pointer, unsigned int size)
{
    unsigned char *bytes = pointer;
    while (size--) *bytes++ = 0;
}

static DWORD fetch_url(const WCHAR *url, DWORD flags, DWORD *bytes_read)
{
    HINTERNET session, request;
    DWORD status = 0, status_size = sizeof(status), read = 0;
    char data[512];

    session = InternetOpenW(L"JuiceNetworkSmoke/1.0",
                            INTERNET_OPEN_TYPE_DIRECT, NULL, NULL, 0);
    if (!session) fail("internet-open", GetLastError());
    request = InternetOpenUrlW(session, url, NULL, 0,
                               INTERNET_FLAG_RELOAD | INTERNET_FLAG_NO_CACHE_WRITE |
                               INTERNET_FLAG_NO_UI | flags, 0);
    if (!request)
    {
        DWORD error = GetLastError();
        InternetCloseHandle(session);
        fail(flags & INTERNET_FLAG_SECURE ? "https-open" : "http-open", error);
    }
    if (!HttpQueryInfoW(request, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER,
                        &status, &status_size, NULL))
    {
        DWORD error = GetLastError();
        InternetCloseHandle(request);
        InternetCloseHandle(session);
        fail(flags & INTERNET_FLAG_SECURE ? "https-status" : "http-status", error);
    }
    if (!InternetReadFile(request, data, sizeof(data), &read))
    {
        DWORD error = GetLastError();
        InternetCloseHandle(request);
        InternetCloseHandle(session);
        fail(flags & INTERNET_FLAG_SECURE ? "https-read" : "http-read", error);
    }
    InternetCloseHandle(request);
    InternetCloseHandle(session);
    if (status < 200 || status >= 400 || !read)
        fail(flags & INTERNET_FLAG_SECURE ? "https-response" : "http-response", status);
    *bytes_read = read;
    return status;
}

__declspec(noreturn) void mainCRTStartup(void)
{
    static const WCHAR default_marker[] =
        L"Z:\\var\\mobile\\Documents\\Juice-network-smoke.ok";
    WSADATA winsock;
    struct addrinfo hints, *addresses = NULL, *address;
    SOCKET socket_handle = INVALID_SOCKET;
    DWORD http_status, https_status, http_bytes, https_bytes;
    unsigned int i;
    int result;

    if (!GetEnvironmentVariableW(L"JUICE_NETWORK_MARKER_WINDOWS", marker_path,
                                 sizeof(marker_path) / sizeof(marker_path[0])))
    {
        for (i = 0; i < sizeof(default_marker) / sizeof(default_marker[0]); ++i)
            marker_path[i] = default_marker[i];
    }

    result = WSAStartup(MAKEWORD(2, 2), &winsock);
    if (result) fail("winsock-startup", (DWORD)result);
    zero_memory(&hints, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    result = getaddrinfo("example.com", "80", &hints, &addresses);
    if (result || !addresses) fail("dns", (DWORD)result);

    for (address = addresses; address; address = address->ai_next)
    {
        socket_handle = socket(address->ai_family, address->ai_socktype,
                               address->ai_protocol);
        if (socket_handle == INVALID_SOCKET) continue;
        if (!connect(socket_handle, address->ai_addr, (int)address->ai_addrlen)) break;
        closesocket(socket_handle);
        socket_handle = INVALID_SOCKET;
    }
    freeaddrinfo(addresses);
    if (socket_handle == INVALID_SOCKET) fail("tcp", (DWORD)WSAGetLastError());
    closesocket(socket_handle);

    http_status = fetch_url(L"http://example.com/", 0, &http_bytes);
    https_status = fetch_url(L"https://example.com/", INTERNET_FLAG_SECURE, &https_bytes);

    report_length = 0;
    append_text("JUICE_NETWORK_SMOKE_OK dns=1 tcp=1 http=");
    append_number(http_status);
    append_text(" http_bytes=");
    append_number(http_bytes);
    append_text(" https=");
    append_number(https_status);
    append_text(" https_bytes=");
    append_number(https_bytes);
    append_text("\r\n");
    write_report();
    WSACleanup();
    ExitProcess(100);
}
