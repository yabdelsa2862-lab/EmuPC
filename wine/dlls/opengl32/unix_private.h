/*
 *    Copyright (c) 2000 Lionel Ulmer
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA
 */
#ifndef __WINE_OPENGL32_UNIX_PRIVATE_H
#define __WINE_OPENGL32_UNIX_PRIVATE_H

#include <stdarg.h>
#include <stddef.h>
#include <stdlib.h>
#include <pthread.h>

#include "ntstatus.h"
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "wingdi.h"
#include "ntgdi.h"

#include "wine/opengl_driver.h"
#include "unix_thunks.h"

struct registry_entry
{
    const char *name;      /* name of the extension */
    const char *extension; /* name of the GL/WGL extension */
    size_t offset;         /* offset in the opengl_funcs table */
};

extern const struct registry_entry extension_registry[];
extern const int extension_registry_size;

extern struct opengl_funcs null_opengl_funcs;

static inline const struct opengl_funcs *get_dc_funcs( HDC hdc )
{
    DWORD has_opengl;

    if (NtGdiGetDCDword( hdc, NtGdiHasOpenGL, &has_opengl ) && has_opengl)
        return __wine_get_opengl_driver( WINE_OPENGL_DRIVER_VERSION );

    RtlSetLastWin32Error( ERROR_INVALID_HANDLE );
    return &null_opengl_funcs;
}

static inline const struct opengl_funcs *get_pbuffer_funcs( HPBUFFERARB client_pbuffer )
{
    struct opengl_client_pbuffer *client = opengl_client_pbuffer_from_client( client_pbuffer );
    return client_pbuffer ? (struct opengl_funcs *)(UINT_PTR)client->unix_funcs : NULL;
}

static inline const struct opengl_funcs *get_context_funcs( HGLRC client_context )
{
    struct opengl_client_context *client = opengl_client_context_from_client( client_context );
    return client_context ? (struct opengl_funcs *)(UINT_PTR)client->unix_funcs : NULL;
}

static inline GLsync get_unix_sync( GLsync sync )
{
    return (GLsync)(UINT_PTR)sync->unix_handle;
}

#ifdef _WIN64

/* Madeira: guest addresses are converted with ios_wow_host_ptr() (wine/unixlib.h),
 * which is ULongToPtr everywhere but iOS. A host pointer inside the guest window
 * goes back to the guest by plain truncation: the window base is 4 GB aligned. */
static inline void *copy_wow64_ptr32s( UINT_PTR address, ULONG count )
{
    ULONG *ptrs = ios_wow_host_ptr( address );
    void **tmp;

    if (!ptrs || !(tmp = calloc( count, sizeof(*tmp) ))) return NULL;
    while (count--) tmp[count] = ios_wow_host_ptr( ptrs[count] );
    return tmp;
}

/* A pointer parameter that is an offset into the buffer bound at `binding` when
 * there is one, and a pointer to guest memory otherwise. Guest memory never lies
 * in the first 64 KB, so smaller values are offsets (or NULL) without asking. */
extern void *wow64_query_buffer_ptr( TEB *teb, ULONG value );

static inline void *wow64_buffer_ptr( TEB *teb, GLenum binding, ULONG value )
{
    const struct opengl_funcs *funcs = teb->glTable;
    GLint name = 0;

    if (binding == GL_QUERY_BUFFER_BINDING) return wow64_query_buffer_ptr( teb, value );
    if (value < 0x10000) return ULongToPtr( value );
    if (funcs && funcs->p_glGetIntegerv) funcs->p_glGetIntegerv( binding, &name );
    return name ? ULongToPtr( value ) : ios_wow_host_ptr( value );
}

static inline void *copy_wow64_buffer_ptr32s( TEB *teb, GLenum binding, UINT_PTR address, ULONG count )
{
    const struct opengl_funcs *funcs = teb->glTable;
    ULONG *ptrs = ios_wow_host_ptr( address );
    GLint name = 0;
    void **tmp;

    if (!ptrs || !(tmp = calloc( count, sizeof(*tmp) ))) return NULL;
    if (funcs && funcs->p_glGetIntegerv) funcs->p_glGetIntegerv( binding, &name );
    while (count--) tmp[count] = name ? ULongToPtr( ptrs[count] ) : ios_wow_host_ptr( ptrs[count] );
    return tmp;
}

#ifdef WINE_IOS
/* Madeira: 32-bit GL/WGL calls through these thunks, read by the winios GL
 * driver's perf line (build/win32u-unix/opengl_ios.c). Weak: 0 when absent.
 * ml1343: also counted per thunk (by its __func__) for the driver's stall
 * report, which lists the entry points a stalled 32-bit caller keeps calling. */
extern unsigned int madeira_gl_wow64_calls __attribute__((weak));
extern void madeira_gl_count_call( const char *thunk ) __attribute__((weak));
#endif

#define get_teb64( teb32 ) get_teb64_from( (teb32), __func__ )

static inline TEB *get_teb64_from( ULONG teb32, const char *caller )
{
#ifdef WINE_IOS
    if (&madeira_gl_wow64_calls) __atomic_fetch_add( &madeira_gl_wow64_calls, 1, __ATOMIC_RELAXED );
    if (madeira_gl_count_call) madeira_gl_count_call( caller );
#endif
    TEB32 *teb32_ptr = ios_wow_host_ptr( teb32 );
    return (TEB *)((char *)teb32_ptr + teb32_ptr->WowTebOffset);
}

extern struct buffer *invalidate_buffer_name( TEB *teb, GLuint name );
extern struct buffer *invalidate_buffer_target( TEB *teb, GLenum target );
extern void free_buffer( const struct opengl_funcs *funcs, struct buffer *buffer );
extern NTSTATUS return_wow64_string( const void *str, PTR32 *wow64_str );

#endif

extern pthread_mutex_t wgl_lock;

extern NTSTATUS process_attach( void *args );
extern NTSTATUS thread_attach( void *args );
extern NTSTATUS process_detach( void *args );
extern NTSTATUS get_pixel_formats( void *args );
extern void set_context_attribute( TEB *teb, GLenum name, const void *value, size_t size );
extern void set_current_fbo( TEB *teb, GLenum target, GLuint framebuffer );
extern GLuint get_default_fbo( TEB *teb, GLenum target );
extern void push_default_fbo( TEB *teb );
extern void pop_default_fbo( TEB *teb );
extern void resolve_default_fbo( TEB *teb, BOOL read );

#endif /* __WINE_OPENGL32_UNIX_PRIVATE_H */
