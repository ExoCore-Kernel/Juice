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
 * private MAP_TRYFIXED selects Wine's existing try-fixed branch. The mmap
 * wrapper strips that private flag, reserves the exact range with the public
 * same-address-space vm_allocate API, then uses MAP_FIXED only after Juice
 * owns that reservation. This avoids blindly replacing unrelated mappings.
 */
#if defined(__APPLE__) && defined(__aarch64__) && \
    defined(__ENVIRONMENT_IPHONE_OS_VERSION_MIN_REQUIRED__)

#include <errno.h>
#include <mach/kern_return.h>
#include <mach/mach_init.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <sys/types.h>

#define JUICE_MAP_TRYFIXED 0x40000000
#ifndef MAP_TRYFIXED
#define MAP_TRYFIXED JUICE_MAP_TRYFIXED
#endif

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
        vm_address_t reservation = (vm_address_t)address;
        kern_return_t result;
        void *mapped;

        result = vm_allocate(
            mach_task_self(),
            &reservation,
            (vm_size_t)size,
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
            vm_deallocate(mach_task_self(), reservation, (vm_size_t)size);
        return mapped;
    }

    return mmap(address, size, prot, flags, fd, offset);
}

#define mmap juice_ios_mmap_tryfixed

#endif /* iOS arm64 */
#endif /* JUICE_IOS_MAP_TRYFIXED_H */
