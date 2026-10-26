#!/usr/bin/env python3
"""Exercise the production JIT head allocator with a deterministic clock.

Mach executable-page queries and process identity are modeled. Allocation,
quarantine checks, splitting, ledger updates and the wait loop are production C.
This does not establish device thread quiescence or test Mach mappings.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "build/ntdll-unix/virtual_ios.c").read_text()
start = source.index("static size_t ios_pool_alloc_range_layout(")
allocator = source[start:source.index("\n/* ml239:", start)]
start = source.index("struct ios_pool_image_layout\n")
layout_checks = source[start:source.index("/* iOS-Madeira: secondary user_VA", start)]
declarations = source[source.index("#define IOS_POOL_LEDGER_MAX"):source.index("/* ml224:")]

code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <errno.h>
'''
code += r'''
static pthread_mutex_t ios_pool_lock = PTHREAD_MUTEX_INITIALIZER;
'''
code += declarations
code += r'''
static size_t jit_pool_offset;
static int ios_pool_last_alloc_reused;
static void *ios_jit_rw_base_global = (void *)(uintptr_t)0x100000000ULL;
static struct { uintptr_t user_va, user_va_end, jit_rw_alias; } ios_jit_anon_aliases[8];
static int ios_jit_anon_alias_count;
static int ticks, frozen_clock, consume_pending, interrupted_sleep, retired;
static size_t poisoned_off;
static void *ios_jit_current_peb(void) { return (void *)(uintptr_t)0x1234; }
static time_t fake_time(time_t *out)
{
    time_t now = 100 + (frozen_clock ? 0 : ticks / 10);
    if (out) *out = now;
    return now;
}
static int fake_nanosleep(const struct timespec *ts, struct timespec *rem)
{
    (void)rem;
    assert(ts->tv_sec == 0 && ts->tv_nsec == 100 * 1000 * 1000);
    /* Another allocator/reclaimer must be able to take the lock while waiting. */
    assert(pthread_mutex_trylock(&ios_pool_lock) == 0);
    if (consume_pending) ios_pool_free_count = 0;
    pthread_mutex_unlock(&ios_pool_lock);
    ticks++;
    if (interrupted_sleep) { errno = EINTR; return -1; }
    return 0;
}
static void *ios_jit_rx_base_global = (void *)(uintptr_t)0x200000000ULL;
static int query_fail, query_gap, query_zero, query_readonly, port_count;
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
typedef unsigned mach_msg_type_number_t;
typedef unsigned mach_port_t;
typedef int kern_return_t;
typedef void *vm_region_info_t;
typedef struct { unsigned protection, max_protection; } vm_region_basic_info_data_64_t;
#define MACH_PORT_NULL 0
#define KERN_SUCCESS 0
#define VM_REGION_BASIC_INFO_COUNT_64 2
#define VM_REGION_BASIC_INFO_64 0
#define VM_PROT_READ 1
#define VM_PROT_WRITE 2
#define VM_PROT_EXECUTE 4
#define IMAGE_NT_SIGNATURE 0x4550
#define IMAGE_SCN_MEM_EXECUTE 0x20000000
#define IMAGE_SCN_MEM_WRITE 0x80000000
#define max(a,b) ((a) > (b) ? (a) : (b))
#define min(a,b) ((a) < (b) ? (a) : (b))
static int mach_task_self(void) { return 1; }
static int mach_vm_region(int task, mach_vm_address_t *addr, mach_vm_size_t *size,
                          int flavor, vm_region_info_t result, mach_msg_type_number_t *count,
                          mach_port_t *object)
{
    (void)task; (void)flavor; (void)count;
    if (query_fail) return 1;
    size_t off = *addr - (uintptr_t)ios_jit_rx_base_global;
    vm_region_basic_info_data_64_t *info = result;
    info->protection = off == poisoned_off ? (query_readonly ? 1 : 3) : 5;
    info->max_protection = off == poisoned_off ? 3 : 7;
    *size = query_zero ? 0 : 0x4000;
    if (query_gap) *addr += 0x4000;
    *object = 1; port_count++;
    return 0;
}
static void mach_port_deallocate(int task, mach_port_t object)
{
    (void)task; assert(object == 1); port_count--;
}
static int ios_pool_live_overlap(uintptr_t addr, size_t size, size_t *off, void **peb)
{
    size_t lo = addr - (uintptr_t)ios_jit_rw_base_global;
    for (int i = 0; i < ios_pool_ledger_count; ++i)
        if (lo < ios_pool_ledger[i].off + ios_pool_ledger[i].size &&
            lo + size > ios_pool_ledger[i].off)
        { *off = ios_pool_ledger[i].off; *peb = ios_pool_ledger[i].peb; return 1; }
    return 0;
}
static void ios_mono_alias_retire(uintptr_t addr) { assert(addr); retired++; }
#define time fake_time
#define nanosleep fake_nanosleep
'''
code += layout_checks + allocator
code += r'''
#undef time
#undef nanosleep
#define NONE ((size_t)-1)
static void reset(size_t bump)
{
    memset(ios_pool_freelist, 0, sizeof(ios_pool_freelist));
    memset(ios_pool_ledger, 0, sizeof(ios_pool_ledger));
    memset(ios_jit_anon_aliases, 0, sizeof(ios_jit_anon_aliases));
    ios_pool_free_count = ios_pool_ledger_count = ios_jit_anon_alias_count = 0;
    ticks = frozen_clock = consume_pending = interrupted_sleep = retired = 0;
    poisoned_off = NONE;
    assert(!port_count);
    query_fail = query_gap = query_zero = query_readonly = 0;
    jit_pool_offset = bump;
}
static void freed(size_t off, size_t size, time_t at)
{
    ios_pool_freelist[ios_pool_free_count++] = (struct ios_pool_free){off, size, at, 0};
}
static unsigned char image[0x20000];
static void put32(size_t off, unsigned value) { memcpy(image + off, &value, 4); }
static struct ios_pool_image_layout make_layout(void)
{
    struct ios_pool_image_layout layout;
    memset(image, 0, sizeof(image));
    image[0] = 'M'; image[1] = 'Z'; put32(0x3c, 0x80); put32(0x80, IMAGE_NT_SIGNATURE);
    image[0x86] = 2;
    put32(0x98 + 8, 0x9000); put32(0x98 + 12, 0x1000);
    put32(0x98 + 36, IMAGE_SCN_MEM_EXECUTE);
    put32(0xc0 + 8, 0x4000); put32(0xc0 + 12, 0xd000);
    put32(0xc0 + 36, IMAGE_SCN_MEM_WRITE);
    assert(ios_pool_image_layout_init(&layout, image, sizeof(image), 0x3000));
    return layout;
}
static void check_layout_reuse(void)
{
    struct ios_pool_image_layout layout = make_layout();
    const size_t allocation = 0x28000;
    reset(allocation); freed(0, allocation, 97); poisoned_off = 0x10000;
    /* A native DLL's deliberately RW data page is not a code-buffer candidate.
       Refusing that probe must retain the slot for a compatible image. */
    assert(ios_pool_alloc_range_ex(allocation, allocation, NONE, 0) == NONE);
    assert(ios_pool_free_count == 1);
    assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == 0);
    assert(!ticks && ios_pool_last_alloc_reused && ios_pool_ledger_count == 1);

    const size_t forbidden[] = {0, 0x4000, 0x18000, 0x20000, 0x24000};
    for (unsigned i = 0; i < sizeof(forbidden)/sizeof(forbidden[0]); i++)
    {
        reset(allocation); freed(0, allocation, 97); poisoned_off = forbidden[i];
        assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);
        assert(!ios_pool_ledger_count && ios_pool_free_count == 1);
    }
    /* Wrong placement, EXEC/WRITE section or code sharing the data page never
       permits a non-executable page to be used for incoming instructions. */
    reset(allocation); freed(0, allocation, 97); poisoned_off = 0x10000;
    layout.data_delta = 0;
    put32(0xc0 + 8, 0x1000);
    assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);
    layout = make_layout();
    put32(0xc0 + 36, IMAGE_SCN_MEM_WRITE | IMAGE_SCN_MEM_EXECUTE);
    assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);
    layout = make_layout(); put32(0x98 + 8, 0xd000);
    assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);
    layout = make_layout(); query_readonly = 1;
    assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);

    /* Mach query failures, holes and zero-length regions fail closed. */
    for (int failure = 0; failure < 3; failure++)
    {
        reset(allocation); freed(0, allocation, 97);
        query_fail = failure == 0; query_gap = failure == 1; query_zero = failure == 2;
        assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);
        assert(ios_pool_free_count == 1 && !ios_pool_ledger_count);
    }
    reset(allocation); freed(0, allocation, 97); poisoned_off = 0x10000;
    assert(!ios_pool_image_layout_init(&layout, image, 63, 0));
    assert(ios_pool_alloc_range_layout(allocation, allocation, NONE, 0, &layout) == NONE);
    put32(0x3c, 0xfffffff0);
    assert(!ios_pool_image_layout_init(&layout, image, sizeof(image), 0));
    layout = make_layout(); image[0x86] = 255; image[0x87] = 255;
    assert(!ios_pool_image_layout_init(&layout, image, sizeof(image), 0));
    layout = make_layout(); put32(0xc0 + 8, 0xffffffff);
    assert(!ios_pool_image_layout_init(&layout, image, sizeof(image), 0));

    /* Bad pages beyond a requested prefix must not waste its executable part. */
    reset(allocation); freed(0, allocation, 97); poisoned_off = 0x10000;
    assert(ios_pool_alloc_range_ex(0x8000, allocation, NONE, 0) == 0);
    assert(ios_pool_freelist[0].off == 0x8000);

    /* An incompatible ready slot must not suppress waiting for a good one. */
    reset(0x300000); freed(0, 0x100000, 97); freed(0x200000, 0x100000, 100);
    poisoned_off = 0;
    assert(ios_pool_alloc_range_ex(0x100000, 0x300000, NONE, 0) == 0x200000);
    assert(ticks == 30 && !port_count);
}
int main(void)
{
    check_layout_reuse();
    /* Observed service bootstrap: 688 MiB pool, nearly full head, freshly
       reclaimed installer DLL ranges. Neither DLL request reaches 32 MiB. */
    const size_t bump = 0x1ffcc000, limit = 0x2b000000 - 0xb024000;
    reset(bump);
    freed(0x1e428000, 0x118000, 100);
    freed(0x1e5b4000, 0x3c4000, 100);
    assert(ios_pool_alloc_range_ex(0xc8000, limit, NONE, 0) == 0x1e428000);
    assert(ticks == 30 && jit_pool_offset == bump && ios_pool_last_alloc_reused);
    assert(ios_pool_alloc_range_ex(0x300000, limit, NONE, 0) == 0x1e5b4000);
    assert(ticks == 30 && ios_pool_ledger_count == 2 && jit_pool_offset == bump);
    assert(ios_pool_ledger[0].peb == ios_jit_current_peb());

    /* A small request with bump capacity must not gain a startup delay. */
    reset(0x80000); freed(0, 0x40000, 100);
    assert(ios_pool_alloc_range_ex(0x40000, 0x100000, NONE, 0) == 0x80000);
    assert(!ticks && !ios_pool_last_alloc_reused);

    /* Existing large-image preference still waits, even with bump capacity. */
    reset(0x4000000); freed(0, 0x2000000, 100);
    assert(ios_pool_alloc_range_ex(0x2000000, 0x8000000, NONE, 0) == 0);
    assert(ticks == 30 && jit_pool_offset == 0x4000000);

    /* Ready memory needs no sleep; split exactly, retire stale aliases. */
    reset(bump); freed(0x100000, 0x40000, 97);
    ios_jit_anon_aliases[0].user_va = 0x8000;
    ios_jit_anon_aliases[0].user_va_end = 0xc000;
    ios_jit_anon_aliases[0].jit_rw_alias = (uintptr_t)ios_jit_rw_base_global + 0x100000;
    ios_jit_anon_alias_count = 1;
    assert(ios_pool_alloc_range_ex(0x40000, limit, NONE, 0) == 0x100000);
    assert(!ticks && !ios_pool_free_count && retired == 1);

    /* No fitting range: real exhaustion is immediate and consumes nothing. */
    reset(bump); freed(0, 0x4000, 100);
    assert(ios_pool_alloc_range_ex(0xc8000, limit, NONE, 0) == NONE);
    assert(!ticks && !ios_pool_ledger_count && jit_pool_offset == bump);

    /* The tail's freelist-only probe must not gain the small-request wait. */
    reset(bump); freed(0, 0x100000, 100);
    assert(ios_pool_alloc_range_ex(0x100000, 0, NONE, 0) == NONE);
    assert(!ticks);

    /* Respect branch reach, including pending ranges and bump addresses. */
    reset(0x1000000); freed(0, 0x100000, 100);
    assert(ios_pool_alloc_range_ex(0x40000, 0x1000000, 0x800000, 0x100000) == NONE);
    assert(!ticks);
    freed(0x800000, 0x40000, 100);
    assert(ios_pool_alloc_range_ex(0x40000, 0x2000000, 0x800000, 0x100000) == 0x800000);
    assert(ticks == 30);

    /* Waiting never bypasses executable-page or live-ledger guards. */
    reset(bump); freed(0, 0x100000, 100); poisoned_off = 0;
    assert(ios_pool_alloc_range_ex(0xc8000, limit, NONE, 0) == NONE);
    assert(ticks == 30 && !ios_pool_ledger_count);
    reset(bump); freed(0, 0x100000, 100);
    ios_pool_ledger[ios_pool_ledger_count++] = (struct ios_pool_alloc){0, 0x100000, (void *)1};
    assert(ios_pool_alloc_range_ex(0xc8000, limit, NONE, 0) == NONE);
    assert(ticks == 30 && ios_pool_ledger_count == 1);

    /* A clock stall/interrupted sleep cannot make the retry unbounded or
       hand out memory before the original quarantine condition is met. */
    reset(bump); freed(0, 0x100000, 100); frozen_clock = interrupted_sleep = 1;
    assert(ios_pool_alloc_range_ex(0xc8000, limit, NONE, 0) == NONE);
    assert(ticks == 40 && !ios_pool_ledger_count);
    reset(bump); freed(0, 0x100000, 100); consume_pending = 1;
    assert(ios_pool_alloc_range_ex(0xc8000, limit, NONE, 0) == NONE);
    assert(ticks == 1 && !ios_pool_ledger_count);

    /* Coalescing: free memory in several ADJACENT small ranges serves a larger request
       (GTA V launcher: 136 MiB free in 34 ranges, a 9.5 MiB load failed EXHAUSTED). */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x140000, 0x40000, 97); freed(0x180000, 0x40000, 97);
    assert(ios_pool_alloc_range_ex(0xc0000, limit, NONE, 0) == 0x100000);
    assert(!ios_pool_free_count && ios_pool_ledger_count == 1 && ios_pool_ledger[0].size == 0xc0000);
    assert(!ticks && ios_pool_last_alloc_reused && jit_pool_offset == limit);
    /* Only the pieces needed are joined; the rest stays as its own entry. */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x140000, 0x40000, 97); freed(0x180000, 0x40000, 97);
    assert(ios_pool_alloc_range_ex(0x80000, limit, NONE, 0) == 0x100000);
    assert(ios_pool_free_count == 1 && ios_pool_freelist[0].off == 0x180000 && ios_pool_freelist[0].size == 0x40000);
    /* Entries listed out of address order still join, and an overshoot leaves the remainder. */
    reset(limit); freed(0x1a0000, 0x60000, 97); freed(0x100000, 0x60000, 97); freed(0x160000, 0x40000, 97);
    assert(ios_pool_alloc_range_ex(0x90000, limit, NONE, 0) == 0x100000);
    assert(ios_pool_free_count == 2);
    /* Non-adjacent ranges are never joined. */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x200000, 0x40000, 97);
    assert(ios_pool_alloc_range_ex(0x80000, limit, NONE, 0) == NONE);
    assert(ios_pool_free_count == 2 && !ios_pool_ledger_count);
    /* A neighbour still inside its reuse grace is not joined. */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x140000, 0x40000, 100);
    assert(ios_pool_alloc_range_ex(0x80000, limit, NONE, 0) == NONE);
    assert(ios_pool_free_count == 2 && !ios_pool_ledger_count);
    /* A run whose start fails the executable-page check is not handed out or joined. */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x140000, 0x40000, 97); poisoned_off = 0x100000;
    assert(ios_pool_alloc_range_ex(0x80000, limit, NONE, 0) == NONE);
    assert(ios_pool_free_count == 2 && !ios_pool_ledger_count);
    /* The tail's freelist-only probe (pool_limit 0) never coalesces. */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x140000, 0x40000, 97);
    assert(ios_pool_alloc_range_ex(0x80000, 0, NONE, 0) == NONE && ios_pool_free_count == 2);
    /* A single entry that already fits is used as before (no join, first fit). */
    reset(limit); freed(0x100000, 0x40000, 97); freed(0x140000, 0x40000, 97); freed(0x400000, 0x80000, 97);
    assert(ios_pool_alloc_range_ex(0x80000, limit, NONE, 0) == 0x400000);
    assert(ios_pool_free_count == 2);
    puts("PASS: JIT pool bounded grace, small/large requests, exhaustion and reuse guards");
}
'''
with tempfile.TemporaryDirectory(prefix="madeira-pool-grace-") as tmp:
    cfile = Path(tmp) / "check.c"
    executable = Path(tmp) / "check"
    cfile.write_text(code)
    subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-D_POSIX_C_SOURCE=200809L",
                    "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
                    "-fno-omit-frame-pointer", "-pthread", str(cfile), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
