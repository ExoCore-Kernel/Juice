#ifndef JUICE_IOS_LOWVA_BOOTSTRAP_H
#define JUICE_IOS_LOWVA_BOOTSTRAP_H

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__)) && \
    defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)

#include <errno.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

/*
 * Run before Wine main(). arm64 iOS has already accepted the normal 4 GiB
 * hard PAGEZERO at exec time. On a jailbreak, the optional Juice helper can
 * now lower only this child task's vm_map::min_offset to 64 KiB. We verify the
 * effect with a disposable fixed mmap before allowing Wine's WoW64 startup to
 * continue.
 *
 * This is gated by BOTH JUICE_EXPERIMENTAL_X64 and JUICE_EXPERIMENTAL_WIN32,
 * so ordinary ARM64 and 64-bit Grape-X64 launches are completely untouched.
 */
static inline int juice_lowva_enabled(void)
{
    const char *x64 = getenv("JUICE_EXPERIMENTAL_X64");
    const char *win32 = getenv("JUICE_EXPERIMENTAL_WIN32");
    return x64 && x64[0] == '1' && x64[1] == '\0' &&
           win32 && win32[0] == '1' && win32[1] == '\0';
}

static inline const char *juice_lowva_helper_path(void)
{
    const char *override = getenv("JUICE_LOWVA_HELPER");
    if (override && override[0]) return override;
    if (access("/var/jb/usr/libexec/juice-lowva-helper", X_OK) == 0)
        return "/var/jb/usr/libexec/juice-lowva-helper";
    return NULL;
}

static inline int juice_lowva_probe(void)
{
    const uintptr_t address = 0x20000ull;
    size_t size = 0x4000;
    void *mapped;

    mapped = mmap((void *)address, size, PROT_NONE,
                  MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (mapped == MAP_FAILED)
    {
        fprintf(stderr,
                "JUICE_LOWVA_KERNEL_PROBE_FAILED address=0x%llx size=0x%zx errno=%d\n",
                (unsigned long long)address, size, errno);
        return -1;
    }
    if ((uintptr_t)mapped != address)
    {
        fprintf(stderr,
                "JUICE_LOWVA_KERNEL_PROBE_WRONG_ADDRESS requested=0x%llx got=%p\n",
                (unsigned long long)address, mapped);
        munmap(mapped, size);
        return -1;
    }

    munmap(mapped, size);
    fprintf(stderr,
            "JUICE_LOWVA_KERNEL_PROBE_OK address=0x%llx size=0x%zx\n",
            (unsigned long long)address, size);
    return 0;
}

__attribute__((constructor))
static void juice_ios_lowva_bootstrap(void)
{
    const char *helper;
    char pid_text[32];
    char *argv[3];
    pid_t helper_pid = -1;
    int spawn_status, status = 0;

    if (!juice_lowva_enabled()) return;

    helper = juice_lowva_helper_path();
    if (!helper)
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_MISSING expected=/var/jb/usr/libexec/juice-lowva-helper\n");
        return;
    }

    snprintf(pid_text, sizeof(pid_text), "%d", getpid());
    argv[0] = (char *)helper;
    argv[1] = pid_text;
    argv[2] = NULL;

    fprintf(stderr, "JUICE_LOWVA_HELPER_BEGIN path=%s target_pid=%d\n",
            helper, getpid());
    spawn_status = posix_spawn(&helper_pid, helper, NULL, NULL, argv, environ);
    if (spawn_status)
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_SPAWN_FAILED status=%d errno=%d path=%s\n",
                spawn_status, errno, helper);
        return;
    }

    while (waitpid(helper_pid, &status, 0) < 0)
    {
        if (errno == EINTR) continue;
        fprintf(stderr, "JUICE_LOWVA_HELPER_WAIT_FAILED errno=%d\n", errno);
        return;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_FAILED status=0x%x exited=%d code=%d signal=%d\n",
                status, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1,
                WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        return;
    }

    fprintf(stderr, "JUICE_LOWVA_HELPER_OK target_pid=%d\n", getpid());

    /* A successful kernel write is not enough evidence by itself. Prove that
       the userspace VM API can now actually claim a sub-4GiB page. */
    if (juice_lowva_probe() != 0)
    {
        fprintf(stderr,
                "JUICE_LOWVA_FATAL reason=kernel-min-changed-but-low-mmap-still-rejected\n");
        _exit(78);
    }
}

#endif /* iOS arm64 */
#endif /* JUICE_IOS_LOWVA_BOOTSTRAP_H */
