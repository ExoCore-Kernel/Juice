/*
 * Juice iOS wrapper for Wine's OpenGL Unix-side implementation.
 *
 * ARM64EC/FEX can transiently lose the PE-side x18 TEB carrier while
 * crossing a Unix-call boundary.  The native Wine side has restored x18 by
 * the time the call arrives, but the explicit TEB argument may already have
 * been materialised as NULL.  Wine's OpenGL thread_attach() immediately
 * stores null_opengl_funcs into TEB::glTable, so that stale argument becomes
 * a write to address offsetof(TEB, glTable) (0x1238 on Win64).
 *
 * Compile the upstream implementation under a private name and expose a
 * narrow wrapper which recovers only a missing thread-attach TEB.  This does
 * not turn unrelated application null dereferences into TEB accesses.
 *
 * LGPL-2.1-or-later, matching the included Wine source.
 */

/* Wine's makedep requires config.h to be a literal top-level include in each
 * translation unit; the include inside unix_wgl.c is not sufficient when that
 * source is compiled through this wrapper. */
#include "config.h"

#define thread_attach juice_opengl_thread_attach_impl
#include "unix_wgl.c"
#undef thread_attach

NTSTATUS thread_attach( void *args )
{
    TEB *teb = args;

#ifdef __APPLE__
    if (!teb)
    {
        teb = NtCurrentTeb();
        WARN( "Juice recovered null OpenGL thread-attach TEB from native state: %p.\n", teb );
    }
#endif

    if (!teb) return STATUS_UNSUCCESSFUL;
    return juice_opengl_thread_attach_impl( teb );
}
