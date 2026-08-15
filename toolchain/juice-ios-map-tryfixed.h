#ifndef JUICE_IOS_MAP_TRYFIXED_H
#define JUICE_IOS_MAP_TRYFIXED_H

/*
 * Darwin Wine normally uses mach_vm_map() to reserve an exact candidate
 * address before MAP_FIXED replaces it. Juice cannot use that macOS-only
 * source path on iOS, while plain mmap(address, ...) is only a hint and can
 * return a different address. Wine's WoW64 low-address allocator requires the
 * requested address to be exact.
 *
 * This header is force-included only for ntdll/unix/virtual.c. Defining a
 * private MAP_TRYFIXED selects Wine's existing try-fixed branch.
 *
 * Normal ARM64 Grape keeps the collision-safe Mach reservation path below.
 * Grape-X64 is different: its loader has already removed the executable's
 * __PAGEZERO mapping from [0x10000, 4 GiB), specifically so Wine can own that
 * address range. iPhoneOS still rejects the preliminary mach_vm_allocate trap
 * in that former __PAGEZERO range even after deallocation, so for the
 * explicitly enabled experimental x64 runtime map that released low range
 * directly with MAP_FIXED. Before the loader release there cannot have been
 * unrelated mappings there because __PAGEZERO covered the whole range.
 *
 * Do not include <mach/mach.h> here. iPhoneOS mach_init.h declares a function
 * named host_page_size(), which collides with Wine's host_page_size variable.
 * mach_traps.h exposes the VM allocate/deallocate traps and task_self_trap()
 * without introducing that declaration.
 */
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__)) && \
    defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_traps.h>
#include <mach/vm_statistics.h>
#include <sys/mman.h>
#include <sys/types.h>

#define JUICE_MAP_TRYFIXED 0x40000000
#ifndef MAP_TRYFIXED
#define MAP_TRYFIXED JUICE_MAP_TRYFIXED
#endif

static inline int juice_ios_x64_low_range(void *address, size_t size)
{
    const char *enabled = getenv("JUICE_EXPERIMENTAL_X64");
    uintptr_t start = (uintptr_t)address;
    uintptr_t end = start + size;

    if (!enabled || enabled[0] != '1' || enabled[1] != '\0') return 0;
    if (end < start) return 0;
    return start >= 0x10000ull && end <= 0x100000000ull;
}

static inline void *juice_ios_mmap_tryfixed(
    void *address,
    size_t size,
    int prot,
    int flags,
    int fd,
    off_t offset
)
{
    if (flags & JUICE_MAP_TRYFIXED)
    {
        void *mapped;

        /*
         * The x64 loader already deallocated this exact former-__PAGEZERO
         * range. Going through mach_vm_allocate first is counterproductive on
         * iPhoneOS: the trap can reject low addresses that mmap(MAP_FIXED) is
         * able to claim once __PAGEZERO has been removed.
         */
        if (juice_ios_x64_low_range(address, size))
        {
            mapped = mmap(
                address,
                size,
                prot,
                (flags & ~JUICE_MAP_TRYFIXED) | MAP_FIXED,
                fd,
                offset
            );
            if (mapped == MAP_FAILED)
                fprintf(stderr,
                        "[JuiceLowVA] MAP_FIXED failed start=%p size=0x%zx prot=%x errno=%d\n",
                        address, size, prot, errno);
            else
            {
                static int reported_success;
                if (!reported_success)
                {
                    reported_success = 1;
                    fprintf(stderr,
                            "[JuiceLowVA] MAP_FIXED enabled start=%p size=0x%zx prot=%x\n",
                            address, size, prot);
                }
            }
            return mapped;
        }

        {
            mach_vm_offset_t reservation = (mach_vm_offset_t)(uintptr_t)address;
            kern_return_t result;

            result = _kernelrpc_mach_vm_allocate_trap(
                task_self_trap(),
                &reservation,
                (mach_vm_size_t)size,
                VM_FLAGS_FIXED
            );
            if (result != KERN_SUCCESS)
            {
                errno = result == KERN_NO_SPACE ? EEXIST : ENOMEM;
                return MAP_FAILED;
            }

            mapped = mmap(
                address,
                size,
                prot,
                (flags & ~JUICE_MAP_TRYFIXED) | MAP_FIXED,
                fd,
                offset
            );
            if (mapped == MAP_FAILED)
                _kernelrpc_mach_vm_deallocate_trap(
                    task_self_trap(), reservation, (mach_vm_size_t)size );
            return mapped;
        }
    }

    return mmap(address, size, prot, flags, fd, offset);
}

#define mmap juice_ios_mmap_tryfixed

#endif /* iOS arm64 */
#endif /* JUICE_IOS_MAP_TRYFIXED_H */
