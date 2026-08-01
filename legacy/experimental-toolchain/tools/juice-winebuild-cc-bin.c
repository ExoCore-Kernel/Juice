#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static const char python_path[] = "/var/jb/usr/bin/python3";
static const char helper_path[] =
    "/var/jb/var/mobile/Juice/tools/juice-pack-incbins.py";
static const char clang_path[] = "/var/jb/usr/bin/clang";

static int has_suffix(const char *text, const char *suffix)
{
    size_t text_len;
    size_t suffix_len;

    if (!text || !suffix) return 0;

    text_len = strlen(text);
    suffix_len = strlen(suffix);

    if (text_len < suffix_len) return 0;

    return !strcmp(text + text_len - suffix_len, suffix);
}

static int run_packer(const char *assembly)
{
    pid_t pid;
    int spawn_error;
    int wait_status;
    char *packer_argv[] = {
        (char *)python_path,
        (char *)helper_path,
        (char *)assembly,
        NULL
    };

    spawn_error = posix_spawn(
        &pid,
        python_path,
        NULL,
        NULL,
        packer_argv,
        environ
    );

    if (spawn_error)
    {
        fprintf(
            stderr,
            "juice-winebuild-cc: could not launch packer: %s\n",
            strerror(spawn_error)
        );
        return 1;
    }

    do
    {
        if (waitpid(pid, &wait_status, 0) >= 0) break;
    }
    while (errno == EINTR);

    if (WIFEXITED(wait_status))
    {
        if (WEXITSTATUS(wait_status) == 0) return 0;

        fprintf(
            stderr,
            "juice-winebuild-cc: packer exited with status %d\n",
            WEXITSTATUS(wait_status)
        );
        return 1;
    }

    if (WIFSIGNALED(wait_status))
    {
        fprintf(
            stderr,
            "juice-winebuild-cc: packer was killed by signal %d\n",
            WTERMSIG(wait_status)
        );
        return 1;
    }

    fprintf(stderr, "juice-winebuild-cc: packer failed\n");
    return 1;
}

int main(int argc, char **argv)
{
    const char *assembly = NULL;
    char **clang_argv;
    int i;

    for (i = 1; i < argc; i++)
    {
        if ((has_suffix(argv[i], ".s") || has_suffix(argv[i], ".S")) &&
            access(argv[i], R_OK) == 0)
        {
            assembly = argv[i];
        }
    }

    if (assembly && run_packer(assembly))
        return 1;

    clang_argv = calloc((size_t)argc + 1, sizeof(*clang_argv));

    if (!clang_argv)
    {
        fprintf(stderr, "juice-winebuild-cc: out of memory\n");
        return 1;
    }

    clang_argv[0] = (char *)clang_path;

    for (i = 1; i < argc; i++)
        clang_argv[i] = argv[i];

    clang_argv[argc] = NULL;

    execve(clang_path, clang_argv, environ);

    fprintf(
        stderr,
        "juice-winebuild-cc: could not launch clang: %s\n",
        strerror(errno)
    );

    free(clang_argv);
    return 127;
}
