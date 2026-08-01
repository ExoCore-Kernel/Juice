#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    char self[PATH_MAX], root[PATH_MAX], tracer[PATH_MAX], loader[PATH_MAX];
    char **child_argv;
    char *slash;
    int index;

    if (!realpath(argv[0], self))
    {
        perror("grape nested realpath");
        return 70;
    }
    if (snprintf(root, sizeof(root), "%s", self) >= (int)sizeof(root)) return 71;
    slash = strrchr(root, '/');
    if (!slash) return 72;
    *slash = '\0';                 /* .../Grape/tools */
    slash = strrchr(root, '/');
    if (!slash) return 73;
    *slash = '\0';                 /* .../Grape */

    if (snprintf(tracer, sizeof(tracer), "%s/tools/grape-trace-parent", root) >= (int)sizeof(tracer) ||
        snprintf(loader, sizeof(loader), "%s/build/wine-ios/loader/wine", root) >= (int)sizeof(loader))
        return 74;

    if (setenv("WINELOADER", self, 1))
    {
        perror("grape nested setenv");
        return 75;
    }

    child_argv = calloc((size_t)argc + 2, sizeof(*child_argv));
    if (!child_argv) return 76;
    child_argv[0] = tracer;
    child_argv[1] = loader;
    for (index = 1; index < argc; index++) child_argv[index + 1] = argv[index];

    execv(tracer, child_argv);
    perror("grape nested execv");
    return errno ? errno : 77;
}
