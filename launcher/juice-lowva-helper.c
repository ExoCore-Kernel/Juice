#include <dlfcn.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

/*
 * Juice Grape-X64 needs a 32-bit Windows address space, but arm64 iOS exec
 * enforces a hard page-zero by raising vm_map::min_offset to roughly 4 GiB.
 * Removing the PAGEZERO mapping from userspace is therefore insufficient:
 * vm_map still rejects fixed allocations below min_offset with ENOMEM.
 *
 * This intentionally tiny helper runs as root on a jailbroken device and
 * uses Dopamine's libjailbreak primitives to lower ONLY the target Wine
 * process' vm_map minimum. The Wine process is blocked waiting for us while
 * this happens and immediately performs a userspace mmap probe afterwards.
 *
 * The Darwin 22 / XNU 8796 arm64 layout is:
 *   _vm_map.lock              0x00 (lck_rw_t is 16 bytes)
 *   _vm_map.hdr              0x10
 *   hdr.links.start/min      0x20
 *   hdr.links.end/max        0x28
 * and task->map is at 0x28 on the supported Dopamine/libjailbreak target.
 *
 * Important: XNU's Mach-O loader may raise min_offset beyond exactly 4 GiB
 * while establishing hard PAGEZERO. Therefore a legitimate live value can
 * be 0x100000000 + a page-aligned delta (the user's iOS 16.6 trace showed
 * 0x100aec000). Requiring exact equality to 4 GiB incorrectly rejected the
 * real vm_map before any write. We instead validate the actual XNU shape:
 * a page-aligned minimum at/above 4 GiB, below a sane page-aligned maximum.
 */

#define JUICE_TASK_MAP_OFFSET       0x28ull
#define JUICE_VM_MAP_HDR_OFFSET     0x10ull
#define JUICE_VM_HEADER_MIN_OFFSET  0x10ull
#define JUICE_VM_HEADER_MAX_OFFSET  0x18ull
#define JUICE_HARD_PAGEZERO         0x100000000ull
#define JUICE_LOWVA_MIN             0x10000ull
#define JUICE_MIN_ALIGNMENT         0x1000ull
#define JUICE_USER_MAP_MAX_SANITY   0x0001000000000000ull

typedef int (*jb_init_fn)(void);
typedef uint64_t (*proc_find_fn)(pid_t);
typedef uint64_t (*proc_task_fn)(uint64_t);
typedef uint64_t (*kread_ptr_fn)(uint64_t);
typedef uint64_t (*kread64_fn)(uint64_t);
typedef int (*kwrite64_fn)(uint64_t, uint64_t);

static void *sym(void *handle, const char *name)
{
    void *p = dlsym(handle, name);
    if (!p) fprintf(stderr, "JUICE_LOWVA_HELPER_ERROR stage=dlsym symbol=%s error=%s\n",
                    name, dlerror() ?: "unknown");
    return p;
}

static int valid_kernel_pointer(uint64_t p)
{
    /* Kernel pointers on the supported iOS 16 arm64 devices are canonical
       high addresses. Keep this deliberately broad; the live-field checks
       below are the authoritative guard before any write. */
    return p >= 0xffff000000000000ull;
}

static int page_aligned(uint64_t value)
{
    return (value & (JUICE_MIN_ALIGNMENT - 1)) == 0;
}

int main(int argc, char **argv)
{
    pid_t pid;
    struct utsname u = {0};
    int uname_status;
    void *lib;
    jb_init_fn jb_init;
    proc_find_fn proc_find;
    proc_task_fn proc_task;
    kread_ptr_fn kread_ptr;
    kread64_fn kread64;
    kwrite64_fn kwrite64;
    uint64_t proc, task, map, min_field, max_field, old_min, old_max, verify;
    int rc;

    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <pid>\n", argv[0]);
        return 64;
    }
    pid = (pid_t)strtol(argv[1], NULL, 10);
    if (pid <= 1)
    {
        fprintf(stderr, "JUICE_LOWVA_HELPER_ERROR stage=args pid=%d\n", pid);
        return 64;
    }

    /* A root-persona/setuid-root invocation can start with ruid=mobile and
       euid=root. Dopamine's primitive initializer deliberately requires real
       uid 0, so commit all uid slots to root first. */
    if (getuid() != 0 && geteuid() == 0 && setuid(0) != 0)
    {
        fprintf(stderr, "JUICE_LOWVA_HELPER_ERROR stage=setuid errno=%d\n", errno);
        return 77;
    }
    if (getuid() != 0)
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_ERROR stage=privilege uid=%d euid=%d hint=root-persona\n",
                getuid(), geteuid());
        return 77;
    }

    uname_status = uname(&u);
    if (uname_status != 0 || strncmp(u.release, "22.", 3))
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_ERROR stage=os release=%s expected=Darwin-22.x\n",
                uname_status == 0 ? u.release : "unknown");
        return 78;
    }

    lib = dlopen("/var/jb/usr/lib/libjailbreak.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_NOW | RTLD_LOCAL);
    if (!lib)
    {
        fprintf(stderr, "JUICE_LOWVA_HELPER_ERROR stage=dlopen error=%s\n",
                dlerror() ?: "unknown");
        return 69;
    }

    jb_init = (jb_init_fn)sym(lib, "jbclient_initialize_primitives");
    proc_find = (proc_find_fn)sym(lib, "proc_find");
    proc_task = (proc_task_fn)sym(lib, "proc_task");
    kread_ptr = (kread_ptr_fn)sym(lib, "kread_ptr");
    kread64 = (kread64_fn)sym(lib, "kread64");
    kwrite64 = (kwrite64_fn)sym(lib, "kwrite64");
    if (!jb_init || !proc_find || !proc_task || !kread_ptr || !kread64 || !kwrite64)
    {
        dlclose(lib);
        return 69;
    }

    rc = jb_init();
    if (rc)
    {
        fprintf(stderr, "JUICE_LOWVA_HELPER_ERROR stage=krw-init status=%d\n", rc);
        dlclose(lib);
        return 70;
    }

    proc = proc_find(pid);
    task = proc ? proc_task(proc) : 0;
    if (!valid_kernel_pointer(proc) || !valid_kernel_pointer(task))
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_ERROR stage=proc pid=%d proc=0x%" PRIx64 " task=0x%" PRIx64 "\n",
                pid, proc, task);
        dlclose(lib);
        return 71;
    }

    map = kread_ptr(task + JUICE_TASK_MAP_OFFSET);
    if (!valid_kernel_pointer(map))
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_ERROR stage=map task=0x%" PRIx64 " map=0x%" PRIx64 "\n",
                task, map);
        dlclose(lib);
        return 72;
    }

    min_field = map + JUICE_VM_MAP_HDR_OFFSET + JUICE_VM_HEADER_MIN_OFFSET;
    max_field = map + JUICE_VM_MAP_HDR_OFFSET + JUICE_VM_HEADER_MAX_OFFSET;
    old_min = kread64(min_field);
    old_max = kread64(max_field);

    /* XNU may slide/raise the hard PAGEZERO boundary. Do not require
       old_min == 4 GiB: require the structural invariants that identify a
       sensible user vm_map instead. This keeps the kernel write narrowly
       guarded while accepting real iOS 16.6 maps such as 0x100aec000. */
    if (old_max <= JUICE_HARD_PAGEZERO || old_max > JUICE_USER_MAP_MAX_SANITY ||
        !page_aligned(old_max) ||
        !((old_min == JUICE_LOWVA_MIN) ||
          (old_min >= JUICE_HARD_PAGEZERO && old_min < old_max && page_aligned(old_min))))
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_ERROR stage=validate map=0x%" PRIx64
                " min=0x%" PRIx64 " max=0x%" PRIx64 "\n",
                map, old_min, old_max);
        dlclose(lib);
        return 73;
    }

    if (old_min == JUICE_LOWVA_MIN)
    {
        fprintf(stderr,
                "JUICE_LOWVA_KERNEL_MIN_OK pid=%d task=0x%" PRIx64 " map=0x%" PRIx64
                " old=0x%" PRIx64 " new=0x%" PRIx64 " max=0x%" PRIx64 " already=1\n",
                pid, task, map, old_min, old_min, old_max);
        dlclose(lib);
        return 0;
    }

    rc = kwrite64(min_field, JUICE_LOWVA_MIN);
    verify = kread64(min_field);
    if (rc || verify != JUICE_LOWVA_MIN)
    {
        fprintf(stderr,
                "JUICE_LOWVA_HELPER_ERROR stage=write status=%d verify=0x%" PRIx64 " field=0x%" PRIx64 "\n",
                rc, verify, min_field);
        dlclose(lib);
        return 74;
    }

    fprintf(stderr,
            "JUICE_LOWVA_KERNEL_MIN_OK pid=%d task=0x%" PRIx64 " map=0x%" PRIx64
            " old=0x%" PRIx64 " new=0x%" PRIx64 " max=0x%" PRIx64 " already=0\n",
            pid, task, map, old_min, verify, old_max);
    dlclose(lib);
    return 0;
}
