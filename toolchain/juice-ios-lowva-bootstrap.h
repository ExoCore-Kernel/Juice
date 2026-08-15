#ifndef JUICE_IOS_LOWVA_BOOTSTRAP_H
#define JUICE_IOS_LOWVA_BOOTSTRAP_H

#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__)) && \
    defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
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
 * hard PAGEZERO at exec time. Legacy Win32 needs genuine low virtual addresses,
 * so removing the PAGEZERO mapping alone is insufficient: the task VM minimum
 * also has to be lowered before Wine starts its WoW64 allocator.
 *
 * Juice packages the helper beside each runtime. On TrollStore-style builds the
 * Wine loader can launch that bundled helper as uid/gid 0 through the platform
 * persona spawn API. An externally installed setuid helper remains supported as
 * a compatibility fallback.
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

static inline int juice_lowva_bundled_helper(char *buffer, size_t capacity)
{
    static const char loader_suffix[] = "/build/wine-ios/loader/wine";
    static const char helper_suffix[] = "/tools/juice-lowva-helper";
    uint32_t path_size;
    char *suffix;
    size_t root_len;

    if (!buffer || capacity < 2 || capacity > UINT32_MAX) return 0;
    path_size = (uint32_t)capacity;
    if (_NSGetExecutablePath(buffer, &path_size) != 0) return 0;

    suffix = strstr(buffer, loader_suffix);
    if (!suffix || suffix[strlen(loader_suffix)] != '\0') return 0;
    *suffix = '\0';

    root_len = strlen(buffer);
    if (root_len + sizeof(helper_suffix) > capacity) return 0;
    memcpy(buffer + root_len, helper_suffix, sizeof(helper_suffix));
    return access(buffer, X_OK) == 0;
}

static inline const char *juice_lowva_helper_path(char *bundle_path, size_t bundle_capacity,
                                                   int *needs_root_persona)
{
    const char *override = getenv("JUICE_LOWVA_HELPER");

    if (needs_root_persona) *needs_root_persona = 0;
    if (override && override[0]) return override;

    if (access("/var/jb/usr/libexec/juice-lowva-helper", X_OK) == 0)
        return "/var/jb/usr/libexec/juice-lowva-helper";

    if (juice_lowva_bundled_helper(bundle_path, bundle_capacity))
    {
        if (needs_root_persona) *needs_root_persona = getuid() != 0;
        return bundle_path;
    }
    return NULL;
}

typedef int (*juice_persona_set_fn)(posix_spawnattr_t *, uid_t, uint32_t);
typedef int (*juice_persona_id_fn)(posix_spawnattr_t *, uid_t);

static inline int juice_lowva_spawn(pid_t *pid, const char *helper, char *const argv[],
                                    int as_root_persona)
{
    posix_spawnattr_t attributes;
    juice_persona_set_fn set_persona;
    juice_persona_id_fn set_uid, set_gid;
    int result;

    if (!as_root_persona)
        return posix_spawn(pid, helper, NULL, NULL, argv, environ);

    set_persona = (juice_persona_set_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    set_uid = (juice_persona_id_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    set_gid = (juice_persona_id_fn)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!set_persona || !set_uid || !set_gid)
    {
        fprintf(stderr, "JUICE_LOWVA_ROOT_SPAWN_UNAVAILABLE reason=persona-api-missing\n");
        return ENOTSUP;
    }

    result = posix_spawnattr_init(&attributes);
    if (result) return result;

    /* Persona 99 is the generic override persona used for root helper spawns.
       The loader is signed with com.apple.private.persona-mgmt specifically for
       this experimental Win32 bootstrap. */
    result = set_persona(&attributes, (uid_t)99, 1u);
    if (!result) result = set_uid(&attributes, (uid_t)0);
    if (!result) result = set_gid(&attributes, (uid_t)0);
    if (!result) result = posix_spawn(pid, helper, NULL, &attributes, argv, environ);
    posix_spawnattr_destroy(&attributes);
    return result;
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
    char bundled_helper[PATH_MAX];
    const char *helper;
    char pid_text[32];
    char *argv[3];
    pid_t helper_pid = -1;
    int needs_root_persona = 0;
    int spawn_status, status = 0;

    if (!juice_lowva_enabled()) return;

    helper = juice_lowva_helper_path(bundled_helper, sizeof(bundled_helper),
                                     &needs_root_persona);
    if (!helper)
    {
        fprintf(stderr,
                "JUICE_LOWVA_FATAL reason=helper-missing checked=/var/jb/usr/libexec-and-bundled-runtime\n");
        _exit(78);
    }

    snprintf(pid_text, sizeof(pid_text), "%d", getpid());
    argv[0] = (char *)helper;
    argv[1] = pid_text;
    argv[2] = NULL;

    fprintf(stderr,
            "JUICE_LOWVA_HELPER_BEGIN path=%s target_pid=%d root_persona=%d\n",
            helper, getpid(), needs_root_persona);
    spawn_status = juice_lowva_spawn(&helper_pid, helper, argv, needs_root_persona);
    if (spawn_status)
    {
        fprintf(stderr,
                "JUICE_LOWVA_FATAL reason=helper-spawn-failed status=%d errno=%d path=%s root_persona=%d\n",
                spawn_status, errno, helper, needs_root_persona);
        _exit(78);
    }

    while (waitpid(helper_pid, &status, 0) < 0)
    {
        if (errno == EINTR) continue;
        fprintf(stderr, "JUICE_LOWVA_FATAL reason=helper-wait-failed errno=%d\n", errno);
        _exit(78);
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    {
        fprintf(stderr,
                "JUICE_LOWVA_FATAL reason=helper-failed status=0x%x exited=%d code=%d signal=%d\n",
                status, WIFEXITED(status), WIFEXITED(status) ? WEXITSTATUS(status) : -1,
                WIFSIGNALED(status) ? WTERMSIG(status) : 0);
        _exit(78);
    }

    fprintf(stderr, "JUICE_LOWVA_HELPER_OK target_pid=%d\n", getpid());

    /* A successful privileged operation is not enough evidence by itself.
       Prove that the userspace VM API can now actually claim a sub-4GiB page
       before Wine is allowed to start probing its WoW64 address space. */
    if (juice_lowva_probe() != 0)
    {
        fprintf(stderr,
                "JUICE_LOWVA_FATAL reason=kernel-min-changed-but-low-mmap-still-rejected\n");
        _exit(78);
    }

    setenv("JUICE_LOWVA_READY", "1", 1);
    fprintf(stderr, "JUICE_LOWVA_READY target_pid=%d\n", getpid());
}

#endif /* iOS arm64 */
#endif /* JUICE_IOS_LOWVA_BOOTSTRAP_H */
