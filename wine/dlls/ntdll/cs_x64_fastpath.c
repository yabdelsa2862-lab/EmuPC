/*
 * ARM64EC: x64 fast paths for hot ntdll/kernelbase exports
 *
 * Copyright 2026 meshoklv
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

/* Included by loader.c (ARM64EC only).
 *
 * Every x64 call of an ARM64EC export goes through the export's x64 "fast
 * forward sequence" (FFS, in .hexpthk: mov rax,rsp; mov [rax+20h],rbx;
 * push rbp; pop rbp; jmp <EC>) and then leaves the emulator's JIT code for
 * native code and comes back: ~100 cycles of glue per call. Games call
 * EnterCriticalSection/LeaveCriticalSection millions of times a second
 * (Dark Souls III: ~3.3 M/s on the main thread), almost always uncontended.
 *
 * With MADEIRA_CS_X64=1 the FFS of RtlEnterCriticalSection,
 * RtlLeaveCriticalSection and RtlTryEnterCriticalSection is overwritten with
 * `jmp [rip]` to small x64 routines that do the uncontended / recursive cases
 * in x64 (translated once by the JIT, run inline) and jump to the original EC
 * function (the FFS's own target) for everything else: contention, waking a
 * waiter (RtlpUnWaitCriticalSection), errors. They use Wine's lock protocol
 * (LockCount -1 = free, +1 per owner and waiter), so x64 and EC callers can
 * share one section. ARM64EC callers are unaffected (they bind through the
 * redirection metadata, not the FFS bytes).
 *
 * With MADEIRA_TLS_X64=1 kernelbase's TlsGetValue FFS gets the same
 * treatment: index < 64 is read from TEB->TlsSlots in x64, the rest goes to
 * the EC function.
 *
 * Installed once, from load_arm64ec_module() after arm64ec_process_init():
 * the emulator is up and no x64 code has run yet. Any FFS whose bytes are not
 * the linker's pattern (someone hooked it already) is left alone.
 */

#include <stdbool.h>

/* The stubs hard-code the x64 layouts. */
C_ASSERT( offsetof(RTL_CRITICAL_SECTION, LockCount) == 0x08 );
C_ASSERT( offsetof(RTL_CRITICAL_SECTION, RecursionCount) == 0x0c );
C_ASSERT( offsetof(RTL_CRITICAL_SECTION, OwningThread) == 0x10 );
C_ASSERT( offsetof(TEB, ClientId.UniqueThread) == 0x48 );
C_ASSERT( offsetof(TEB, LastErrorValue) == 0x68 );
C_ASSERT( offsetof(TEB, TlsSlots) == 0x1480 );

/* lld's x64 entry for an ARM64EC export, up to the rel32 of the final jmp. */
static const BYTE x64_ffs_prefix[10] = { 0x48,0x8b,0xc4, 0x48,0x89,0x58,0x20, 0x55, 0x5d, 0xe9 };
#define X64_FFS_SIZE 14

/* RtlEnterCriticalSection, rcx = crit. Slot at +0x3c: EC RtlEnterCriticalSection. */
static const BYTE cs_enter_x64[] =
{
    0x65,0x8b,0x14,0x25,0x48,0x00,0x00,0x00,  /* mov edx, gs:[48h]  (TEB ClientId.UniqueThread) */
    0xb8,0xff,0xff,0xff,0xff,                 /* mov eax, -1 */
    0x45,0x31,0xc0,                           /* xor r8d, r8d */
    0xf0,0x44,0x0f,0xb1,0x41,0x08,            /* lock cmpxchg [rcx+8], r8d   LockCount -1 -> 0 */
    0x75,0x0e,                                /* jne recur */
    0x48,0x89,0x51,0x10,                      /* mov [rcx+10h], rdx          OwningThread */
    0xc7,0x41,0x0c,0x01,0x00,0x00,0x00,       /* mov dword [rcx+0Ch], 1      RecursionCount */
    0x31,0xc0, 0xc3,                          /* xor eax, eax; ret           STATUS_SUCCESS */
    0x48,0x39,0x51,0x10,                      /* recur: cmp [rcx+10h], rdx */
    0x75,0x0a,                                /* jne slow */
    0xf0,0xff,0x41,0x08,                      /* lock inc dword [rcx+8] */
    0xff,0x41,0x0c,                           /* inc dword [rcx+0Ch] */
    0x31,0xc0, 0xc3,                          /* xor eax, eax; ret */
    0xff,0x25,0x00,0x00,0x00,0x00,            /* slow: jmp [rip] */
    0,0,0,0,0,0,0,0,
};
#define CS_ENTER_SLOT 0x3c

/* RtlLeaveCriticalSection. Slots: +0x34 EC RtlpUnWaitCriticalSection, +0x42 EC RtlLeaveCriticalSection. */
static const BYTE cs_leave_x64[] =
{
    0x8b,0x41,0x0c,                           /* mov eax, [rcx+0Ch] */
    0x83,0xf8,0x01,                           /* cmp eax, 1 */
    0x7c,0x34,                                /* jl slow     (not acquired: Wine's ERR path) */
    0x75,0x18,                                /* jne recur   (> 1) */
    0x48,0xc7,0x41,0x10,0,0,0,0,              /* mov qword [rcx+10h], 0 */
    0xc7,0x41,0x0c,0,0,0,0,                   /* mov dword [rcx+0Ch], 0 */
    0xf0,0xff,0x49,0x08,                      /* lock dec dword [rcx+8] */
    0x79,0x0f,                                /* jns wake    (>= 0: someone is waiting) */
    0x31,0xc0, 0xc3,                          /* xor eax, eax; ret */
    0xff,0xc8,                                /* recur: dec eax */
    0x89,0x41,0x0c,                           /* mov [rcx+0Ch], eax */
    0xf0,0xff,0x49,0x08,                      /* lock dec dword [rcx+8] */
    0x31,0xc0, 0xc3,                          /* xor eax, eax; ret */
    0xff,0x25,0x00,0x00,0x00,0x00,            /* wake: jmp [rip] */
    0,0,0,0,0,0,0,0,
    0xff,0x25,0x00,0x00,0x00,0x00,            /* slow: jmp [rip] */
    0,0,0,0,0,0,0,0,
};
#define CS_LEAVE_WAKE_SLOT 0x34
#define CS_LEAVE_SLOW_SLOT 0x42

/* RtlTryEnterCriticalSection: complete in x64 (same logic as Wine's). */
static const BYTE cs_tryenter_x64[] =
{
    0x65,0x8b,0x14,0x25,0x48,0x00,0x00,0x00,  /* mov edx, gs:[48h] */
    0xb8,0xff,0xff,0xff,0xff,                 /* mov eax, -1 */
    0x45,0x31,0xc0,                           /* xor r8d, r8d */
    0xf0,0x44,0x0f,0xb1,0x41,0x08,            /* lock cmpxchg [rcx+8], r8d */
    0x75,0x11,                                /* jne recur */
    0x48,0x89,0x51,0x10,                      /* mov [rcx+10h], rdx */
    0xc7,0x41,0x0c,0x01,0x00,0x00,0x00,       /* mov dword [rcx+0Ch], 1 */
    0xb8,0x01,0x00,0x00,0x00, 0xc3,           /* mov eax, 1; ret */
    0x48,0x39,0x51,0x10,                      /* recur: cmp [rcx+10h], rdx */
    0x75,0x0d,                                /* jne fail */
    0xf0,0xff,0x41,0x08,                      /* lock inc dword [rcx+8] */
    0xff,0x41,0x0c,                           /* inc dword [rcx+0Ch] */
    0xb8,0x01,0x00,0x00,0x00, 0xc3,           /* mov eax, 1; ret */
    0x31,0xc0, 0xc3,                          /* fail: xor eax, eax; ret */
};

/* kernelbase TlsGetValue, ecx = index. Slot at +0x23: EC TlsGetValue. */
static const BYTE tls_get_x64[] =
{
    0x65,0xc7,0x04,0x25,0x68,0,0,0, 0,0,0,0,  /* mov dword gs:[68h], 0      SetLastError(0) */
    0x83,0xf9,0x40,                           /* cmp ecx, 64 */
    0x73,0x0c,                                /* jae slow */
    0x89,0xc8,                                /* mov eax, ecx */
    0x65,0x48,0x8b,0x04,0xc5,0x80,0x14,0,0,   /* mov rax, gs:[1480h + rax*8]  TlsSlots[index] */
    0xc3,                                     /* ret */
    0xff,0x25,0x00,0x00,0x00,0x00,            /* slow: jmp [rip] */
    0,0,0,0,0,0,0,0,
};
#define TLS_GET_SLOT 0x23

/* Byte counts checked against an assembler listing (clang -c, llvm-objdump). */
C_ASSERT( sizeof(cs_enter_x64) == 0x44 && CS_ENTER_SLOT + 8 == sizeof(cs_enter_x64) );
C_ASSERT( sizeof(cs_leave_x64) == 0x4a && CS_LEAVE_SLOW_SLOT + 8 == sizeof(cs_leave_x64) );
C_ASSERT( sizeof(cs_tryenter_x64) == 0x3f );
C_ASSERT( sizeof(tls_get_x64) == 0x2b && TLS_GET_SLOT + 8 == sizeof(tls_get_x64) );

/* Read once at startup. Unset means `dflt`; "1" on, anything else off. */
static BOOL flag( const WCHAR *name, BOOL dflt )
{
    UNICODE_STRING nm, val;
    WCHAR buf[8];

    RtlInitUnicodeString( &nm, name );
    val.Buffer = buf; val.Length = 0; val.MaximumLength = sizeof(buf);
    if (RtlQueryEnvironmentVariable_U( NULL, &nm, &val )) return dflt;
    return val.Length && buf[0] == '1';
}

static BOOL x64_fp_in_section( HMODULE module, const void *p, const char *name )
{
    const IMAGE_NT_HEADERS *nt = RtlImageNtHeader( module );
    const IMAGE_SECTION_HEADER *sec;
    ULONG_PTR rva = (const BYTE *)p - (const BYTE *)module;
    unsigned int i;

    if (!nt) return FALSE;
    sec = IMAGE_FIRST_SECTION( nt );
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++, sec++)
        if (!strncmp( (const char *)sec->Name, name, IMAGE_SIZEOF_SHORT_NAME ) &&
            rva >= sec->VirtualAddress && rva < sec->VirtualAddress + sec->Misc.VirtualSize)
            return TRUE;
    return FALSE;
}

/* The export's own address (no forwarders, no EC redirection): what an x64
 * importer is bound to. NULL unless it is an unmodified FFS. */
static BYTE *x64_fp_find_ffs( HMODULE module, const char *name, void **ec_target )
{
    const IMAGE_EXPORT_DIRECTORY *exp;
    const DWORD *names, *functions;
    const WORD *ordinals;
    ULONG size;
    DWORD i;

    if (!module) return NULL;
    if (!(exp = RtlImageDirectoryEntryToData( module, TRUE, IMAGE_DIRECTORY_ENTRY_EXPORT, &size ))) return NULL;
    names = (const DWORD *)((const BYTE *)module + exp->AddressOfNames);
    ordinals = (const WORD *)((const BYTE *)module + exp->AddressOfNameOrdinals);
    functions = (const DWORD *)((const BYTE *)module + exp->AddressOfFunctions);
    for (i = 0; i < exp->NumberOfNames; i++)
    {
        BYTE *ffs;
        DWORD rva;
        LONG rel;

        if (strcmp( (const char *)module + names[i], name )) continue;
        if (ordinals[i] >= exp->NumberOfFunctions) return NULL;
        rva = functions[ordinals[i]];
        if (rva >= (const BYTE *)exp - (const BYTE *)module &&
            rva < (const BYTE *)exp - (const BYTE *)module + size)
        {
            ERR( "[cs-x64] %s is a forwarder, not patched\n", name );
            return NULL;
        }
        ffs = (BYTE *)module + rva;
        if (!x64_fp_in_section( module, ffs, ".hexpthk" ) || memcmp( ffs, x64_ffs_prefix, sizeof(x64_ffs_prefix) ))
        {
            ERR( "[cs-x64] %s at %p is not the linker's x64 entry (%02x %02x %02x %02x %02x %02x): "
                 "already hooked? not patched\n", name, ffs, ffs[0], ffs[1], ffs[2], ffs[3], ffs[4], ffs[5] );
            return NULL;
        }
        memcpy( &rel, ffs + 10, sizeof(rel) );
        *ec_target = ffs + X64_FFS_SIZE + rel;
        if (!x64_fp_in_section( module, *ec_target, ".text" ))
        {
            ERR( "[cs-x64] %s: FFS target %p is not in .text, not patched\n", name, *ec_target );
            return NULL;
        }
        return ffs;
    }
    return NULL;
}

/* Overwrite an FFS with `jmp qword ptr [rip+0]; dq stub` (14 bytes, the FFS's size). */
static BOOL x64_fp_redirect( BYTE *ffs, const void *stub )
{
    BYTE code[X64_FFS_SIZE] = { 0xff, 0x25, 0, 0, 0, 0 };
    void *addr = ffs;
    SIZE_T size = X64_FFS_SIZE;
    ULONG old, tmp;
    NTSTATUS status;

    memcpy( code + 6, &stub, sizeof(stub) );
    if ((status = NtProtectVirtualMemory( GetCurrentProcess(), &addr, &size, PAGE_EXECUTE_READWRITE, &old )))
    {
        ERR( "[cs-x64] protect %p -> rwx failed %lx\n", ffs, status );
        return FALSE;
    }
    memcpy( ffs, code, sizeof(code) );
    addr = ffs; size = X64_FFS_SIZE;
    NtProtectVirtualMemory( GetCurrentProcess(), &addr, &size, old, &tmp );  /* iOS: syncs the pool copy */
    NtFlushInstructionCache( GetCurrentProcess(), ffs, X64_FFS_SIZE );      /* the emulator drops its blocks */
    return TRUE;
}

/* `slot`: offset of the 8-byte address after a `jmp [rip]`. */
static void x64_fp_fill_slot( BYTE *stub, unsigned int slot, void *target )
{
    memcpy( stub + slot, &target, sizeof(target) );
}

static void madeira_x64_fastpath_install(void)
{
    /* x64 fast path for EnterCriticalSection/LeaveCriticalSection/TryEnterCriticalSection.
     * Default off (experimental). 1: an uncontended or recursive critical section is taken and
     * released inside the x64 JIT code instead of a round trip into native ntdll (~100 cycles each,
     * millions of calls a second in Dark Souls III); contention still goes to Wine's code. Read when a 64-bit program starts. */
    BOOL cs = flag( L"MADEIRA_CS_X64", false );
    /* x64 fast path for TlsGetValue (kernelbase). Default off (experimental). 1: a TLS
     * index below 64 is read in the x64 JIT code, without a round trip into native code. Read when a 64-bit program starts. */
    BOOL tls = flag( L"MADEIRA_TLS_X64", false );
    BYTE *enter_ffs = NULL, *leave_ffs = NULL, *try_ffs = NULL, *unwait_ffs = NULL, *tls_ffs = NULL;
    void *enter_ec = NULL, *leave_ec = NULL, *try_ec = NULL, *unwait_ec = NULL, *tls_ec = NULL;
    BYTE *page = NULL;
    SIZE_T size = 0x1000;
    ULONG old;
    HMODULE ntdll = NULL, kernelbase = NULL, kernel32 = NULL;
    UNICODE_STRING us;

    if (!cs && !tls) return;

    RtlInitUnicodeString( &us, L"ntdll.dll" );
    LdrGetDllHandle( NULL, 0, &us, &ntdll );
    if (cs)
    {
        enter_ffs  = x64_fp_find_ffs( ntdll, "RtlEnterCriticalSection", &enter_ec );
        leave_ffs  = x64_fp_find_ffs( ntdll, "RtlLeaveCriticalSection", &leave_ec );
        try_ffs    = x64_fp_find_ffs( ntdll, "RtlTryEnterCriticalSection", &try_ec );
        unwait_ffs = x64_fp_find_ffs( ntdll, "RtlpUnWaitCriticalSection", &unwait_ec );
        /* All or nothing, so the log line describes one state. */
        if (!enter_ffs || !leave_ffs || !try_ffs || !unwait_ffs)
        {
            ERR( "[cs-x64] v1 not installed: enter=%p leave=%p try=%p unwait=%p\n",
                 enter_ffs, leave_ffs, try_ffs, unwait_ffs );
            cs = FALSE;
        }
    }
    if (tls)
    {
        RtlInitUnicodeString( &us, L"kernelbase.dll" );
        LdrGetDllHandle( NULL, 0, &us, &kernelbase );
        if (!(tls_ffs = x64_fp_find_ffs( kernelbase, "TlsGetValue", &tls_ec )))
        {
            ERR( "[tls-x64] v1 not installed: kernelbase=%p\n", kernelbase );
            tls = FALSE;
        }
    }
    if (!cs && !tls) return;

    if (NtAllocateVirtualMemory( GetCurrentProcess(), (void **)&page, 0, &size,
                                 MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE ))
    {
        ERR( "[cs-x64] v1 not installed: no memory for the stubs\n" );
        return;
    }
    memset( page, 0xcc, size );
    memcpy( page + 0x000, cs_enter_x64, sizeof(cs_enter_x64) );
    x64_fp_fill_slot( page + 0x000, CS_ENTER_SLOT, enter_ec );
    memcpy( page + 0x080, cs_leave_x64, sizeof(cs_leave_x64) );
    x64_fp_fill_slot( page + 0x080, CS_LEAVE_WAKE_SLOT, unwait_ec );
    x64_fp_fill_slot( page + 0x080, CS_LEAVE_SLOW_SLOT, leave_ec );
    memcpy( page + 0x100, cs_tryenter_x64, sizeof(cs_tryenter_x64) );
    memcpy( page + 0x180, tls_get_x64, sizeof(tls_get_x64) );
    x64_fp_fill_slot( page + 0x180, TLS_GET_SLOT, tls_ec );
    NtProtectVirtualMemory( GetCurrentProcess(), (void **)&page, &size, PAGE_EXECUTE_READ, &old );
    NtFlushInstructionCache( GetCurrentProcess(), page, size );

    if (cs)
    {
        /* Leave and TryEnter first: an Enter that took the new path must never meet the old Leave
         * (both protocols are the same, so this is belt and braces; no x64 code runs yet). */
        BOOL ok = x64_fp_redirect( leave_ffs, page + 0x080 ) &&
                  x64_fp_redirect( try_ffs, page + 0x100 ) &&
                  x64_fp_redirect( enter_ffs, page + 0x000 );
        ERR( "[cs-x64] v1 %s enter=%p->%p leave=%p->%p try=%p->%p (ec %p %p %p unwait %p) stubs=%p\n",
             ok ? "installed" : "PARTIAL", enter_ffs, page, leave_ffs, page + 0x80, try_ffs, page + 0x100,
             enter_ec, leave_ec, try_ec, unwait_ec, page );
    }
    if (tls)
    {
        BOOL ok = x64_fp_redirect( tls_ffs, page + 0x180 );
        void *k32_thunk_target = NULL;
        BYTE *k32;

        /* kernel32's TlsGetValue is an x64 `jmp [rip+x]` through its import of kernelbase's; it only
         * reaches the stub if that slot holds kernelbase's x64 entry. Report which. */
        RtlInitUnicodeString( &us, L"kernel32.dll" );
        LdrGetDllHandle( NULL, 0, &us, &kernel32 );
        if (kernel32 && (k32 = RtlFindExportedRoutineByName( kernel32, "TlsGetValue" )) &&
            k32[0] == 0xff && k32[1] == 0x25)
        {
            LONG rel;
            memcpy( &rel, k32 + 2, sizeof(rel) );
            k32_thunk_target = *(void **)(k32 + 6 + rel);
        }
        ERR( "[tls-x64] v1 %s TlsGetValue=%p->%p (ec %p); kernel32 thunk -> %p (%s)\n",
             ok ? "installed" : "FAILED", tls_ffs, page + 0x180, tls_ec, k32_thunk_target,
             k32_thunk_target == tls_ffs ? "covered" : "NOT covered: kernel32 callers keep the EC round trip" );
    }
}
