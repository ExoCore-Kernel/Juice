#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

static int has_suffix(const char *text, const char *suffix)
{
    size_t text_length;
    size_t suffix_length;

    if (!text || !suffix) return 0;
    text_length = strlen(text);
    suffix_length = strlen(suffix);
    return text_length >= suffix_length &&
           !strcmp(text + text_length - suffix_length, suffix);
}

static int default_packer_path(char *buffer, size_t size, const char *program)
{
    const char *slash = strrchr(program, '/');
    int length;

    if (!slash) return 0;
    length = snprintf(buffer, size, "%.*s/../../toolchain/juice-pack-incbins.py",
                      (int)(slash - program), program);
    return length > 0 && (size_t)length < size;
}

static int run_packer(const char *python, const char *packer,
                      const char *assembly)
{
    char *arguments[] = {
        (char *)python,
        (char *)packer,
        (char *)assembly,
        NULL
    };
    pid_t pid;
    pid_t waited;
    int error;
    int status;

    error = posix_spawn(&pid, python, NULL, NULL, arguments, environ);
    if (error)
    {
        fprintf(stderr, "juice-pe-clang: could not launch packer: %s\n",
                strerror(error));
        return 1;
    }

    do waited = waitpid(pid, &status, 0);
    while (waited < 0 && errno == EINTR);
    if (waited < 0)
    {
        fprintf(stderr, "juice-pe-clang: could not wait for packer: %s\n",
                strerror(errno));
        return 1;
    }

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
    if (WIFEXITED(status))
        fprintf(stderr, "juice-pe-clang: packer exited with status %d\n",
                WEXITSTATUS(status));
    else if (WIFSIGNALED(status))
        fprintf(stderr, "juice-pe-clang: packer was killed by signal %d\n",
                WTERMSIG(status));
    else
        fprintf(stderr, "juice-pe-clang: packer failed\n");
    return 1;
}

static char *packed_path_for_assembly(const char *assembly)
{
    static const char suffix[] = ".juice-packed-resources.bin";
    const char *slash = strrchr(assembly, '/');
    const char *basename = slash ? slash + 1 : assembly;
    size_t directory_length = slash ? (size_t)(slash - assembly + 1) : 0;
    size_t length = directory_length + 1 + strlen(basename) + sizeof(suffix);
    char *path = malloc(length);

    if (!path) return NULL;
    if (directory_length)
        snprintf(path, length, "%.*s.%s%s", (int)directory_length,
                 assembly, basename, suffix);
    else
        snprintf(path, length, ".%s%s", basename, suffix);
    return path;
}

static int run_compiler(const char *clang, char **arguments)
{
    pid_t pid;
    pid_t waited;
    int error;
    int status;

    error = posix_spawn(&pid, clang, NULL, NULL, arguments, environ);
    if (error)
    {
        fprintf(stderr, "juice-pe-clang: could not launch %s: %s\n",
                clang, strerror(error));
        return 127;
    }
    do waited = waitpid(pid, &status, 0);
    while (waited < 0 && errno == EINTR);
    if (waited < 0)
    {
        fprintf(stderr, "juice-pe-clang: could not wait for %s: %s\n",
                clang, strerror(errno));
        return 127;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 127;
}

int main(int argc, char **argv)
{
    const char *clang = getenv("JUICE_REAL_PE_CLANG");
    const char *python = getenv("JUICE_PYTHON");
    const char *packer = getenv("JUICE_INCBIN_PACKER");
    char default_packer[PATH_MAX];
    char **clang_arguments;
    char **packed_paths;
    int compiler_status;
    int index;

    if (!clang || !*clang) clang = "/var/jb/usr/bin/clang";
    if (!python || !*python) python = "/var/jb/usr/bin/python3";
    if (!packer || !*packer)
    {
        if (!default_packer_path(default_packer, sizeof(default_packer), argv[0]))
        {
            fprintf(stderr, "juice-pe-clang: set JUICE_INCBIN_PACKER when "
                    "invoking the wrapper without an absolute path\n");
            return 2;
        }
        packer = default_packer;
    }

    if (access(clang, X_OK) != 0)
    {
        fprintf(stderr, "juice-pe-clang: missing compiler %s: %s\n",
                clang, strerror(errno));
        return 2;
    }
    if (access(python, X_OK) != 0 || access(packer, R_OK) != 0)
    {
        fprintf(stderr, "juice-pe-clang: missing Python packer dependency\n");
        return 2;
    }

    packed_paths = calloc((size_t)argc, sizeof(*packed_paths));
    if (!packed_paths)
    {
        fprintf(stderr, "juice-pe-clang: out of memory\n");
        return 1;
    }

    for (index = 1; index < argc; index++)
    {
        if ((has_suffix(argv[index], ".s") || has_suffix(argv[index], ".S")) &&
            access(argv[index], R_OK) == 0)
        {
            packed_paths[index] = packed_path_for_assembly(argv[index]);
            if (!packed_paths[index] || run_packer(python, packer, argv[index]))
            {
                compiler_status = 1;
                goto cleanup;
            }
        }
    }

    clang_arguments = calloc((size_t)argc + 1, sizeof(*clang_arguments));
    if (!clang_arguments)
    {
        fprintf(stderr, "juice-pe-clang: out of memory\n");
        compiler_status = 1;
        goto cleanup;
    }
    clang_arguments[0] = (char *)clang;
    for (index = 1; index < argc; index++) clang_arguments[index] = argv[index];
    clang_arguments[argc] = NULL;

    compiler_status = run_compiler(clang, clang_arguments);
    free(clang_arguments);

cleanup:
    {
        const char *keep = getenv("JUICE_KEEP_PACKED_RESOURCES");
        if (!keep || !*keep || !strcmp(keep, "0"))
        {
            for (index = 1; index < argc; index++)
                if (packed_paths[index]) unlink(packed_paths[index]);
        }
    }
    for (index = 1; index < argc; index++) free(packed_paths[index]);
    free(packed_paths);
    return compiler_status;
}
