#include <stddef.h>
#include <libkern/OSCacheControl.h>

/*
 * Clang's __builtin___clear_cache may lower to the compiler-rt style
 * __clear_cache(begin, end) helper when cross-linking with cctools-port.
 * iOS exposes sys_icache_invalidate() in libc instead, so provide the
 * expected helper without depending on a compiler runtime library.
 */
void __clear_cache(char *begin, char *end)
{
    if (end > begin) sys_icache_invalidate(begin, (size_t)(end - begin));
}
