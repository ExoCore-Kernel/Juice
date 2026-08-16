#ifndef JUICE_IOS_MAP_TRYFIXED_H
#define JUICE_IOS_MAP_TRYFIXED_H

/*
 * Darwin Wine normally uses mach_vm_map() to reserve an exact candidate
 * address before MAP_FIXED replaces it. Juice cannot use that macOS-only
 * source path on iOS, while plain mmap(address, ...) is only a hint and can
 * return a different address. Wine nevertheless needs a collision-safe way
 * to test whether an exact address can be used.
 *
 * This header is force-included only for ntdll/unix/virtual.c. Defining a
 * private MAP_TRYFIXED selects Wine's existing try-fixed branch.
 *
 * For normal ARM64 Grape, do not use the private mach_vm_allocate trap as a
 * preliminary reservation. On iOS that trap can reject otherwise harmless
 * candidate probes with Mach errors that look like ENOMEM to Wine. The free
 * area scanner then aborts instead of stepping to its next candidate.
 *
 * Instead, request the address as a normal mmap() hint. Darwin will use the
 * hint when it is available and relocate the mapping when it is not. Accept
 * the mapping only when the returned address exactly matches the requested
 * address; otherwise unmap the relocated mapping and report EEXIST so Wine's
 * scanner safely continues. This never overwrites an existing native mapping.
 *
 * Grape-X64 is different: its loader has already removed the executable's
 * __PAGEZERO mapping from [0x10000, 4 GiB), specifically so Wine can own that
 * address range. iPhoneOS can still reject ordinary low-address hint probes in
 * that former __PAGEZERO range even after deallocation, so for the explicitly
 * enabled experimental x64 runtime map that released low range directly with
 * MAP_FIXED. Before the loader release there cannot have been unrelated
 * mappings there because __PAGEZERO covered the whole range.
 */
#if defined(__APPLE__) && (defined(__aarch64__) || defined(__arm64__)) && \
    defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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
        int mmap_flags = flags & ~JUICE_MAP_TRYFIXED;

        /*
         * The x64 loader already deallocated this exact former-__PAGEZERO
         * range. Going through a hint mapping first is counterproductive on
         * iPhoneOS: the kernel may refuse or relocate low addresses that
         * mmap(MAP_FIXED) can claim once __PAGEZERO has been removed.
         */
        if (juice_ios_x64_low_range(address, size))
        {
            static unsigned long lowva_failures;
            static int reported_success;

            mapped = mmap(
                address,
                size,
                prot,
                mmap_flags | MAP_FIXED,
                fd,
                offset
            );
            if (mapped == MAP_FAILED)
            {
                unsigned long count = ++lowva_failures;

                /*
                 * Wine probes many candidate low addresses while looking for
                 * a usable WoW64 hole. Printing every rejected probe can flood
                 * Juice's UIKit log fast enough to make the app appear hung.
                 * Keep the beginning of the trace intact, then sample it.
                 */
                if (count <= 32 || (count & 0xff) == 0)
                    fprintf(stderr,
                            "[JuiceLowVA] MAP_FIXED failed count=%lu start=%p size=0x%zx prot=%x errno=%d\n",
                            count, address, size, prot, errno);
                if (count == 33)
                    fprintf(stderr,
                            "[JuiceLowVA] suppressing repeated MAP_FIXED failures; sampling every 256 probes\n");
            }
            else if (!reported_success)
            {
                reported_success = 1;
                fprintf(stderr,
                        "[JuiceLowVA] MAP_FIXED enabled start=%p size=0x%zx prot=%x failures=%lu\n",
                        address, size, prot, lowva_failures);
            }
            return mapped;
        }

        /*
         * Collision-safe exact-address probe for normal ARM64 Wine.
         * A non-MAP_FIXED mmap() never destroys an existing mapping. If the
         * requested hole is unavailable Darwin may return another address;
         * dispose of that temporary mapping and tell Wine the candidate was
         * occupied so try_map_free_area() advances instead of aborting.
         */
        mapped = mmap(address, size, prot, mmap_flags, fd, offset);
        if (mapped == MAP_FAILED) return MAP_FAILED;
        if (mapped == address) return mapped;

        munmap(mapped, size);
        errno = EEXIST;
        return MAP_FAILED;
    }

    return mmap(address, size, prot, flags, fd, offset);
}

#define mmap juice_ios_mmap_tryfixed

#endif /* iOS arm64 */
#endif /* JUICE_IOS_MAP_TRYFIXED_H */
