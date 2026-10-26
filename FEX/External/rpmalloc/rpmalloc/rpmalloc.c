/* rpmalloc.c  -  Memory allocator  -  Public Domain  -  2016-2020 Mattias
 * Jansson
 *
 * This library provides a cross-platform lock free thread caching malloc
 * implementation in C11. The latest source code is always available at
 *
 * https://github.com/mjansson/rpmalloc
 *
 * This library is put in the public domain; you can redistribute it and/or
 * modify it without any restrictions.
 *
 */

#include "rpmalloc.h"

#include <errno.h>
#include <string.h>

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdatomic.h>

#if !defined(__has_builtin)
#define __has_builtin(b) 0
#endif

#if defined(__clang__)
#pragma clang diagnostic ignored "-Wunused-macros"
#pragma clang diagnostic ignored "-Wunused-function"
#if __has_warning("-Wreserved-identifier")
#pragma clang diagnostic ignored "-Wreserved-identifier"
#endif
#if __has_warning("-Wstatic-in-inline")
#pragma clang diagnostic ignored "-Wstatic-in-inline"
#endif
#if __has_warning("-Wunsafe-buffer-usage")
#pragma clang diagnostic ignored "-Wunsafe-buffer-usage"
#endif
#elif defined(__GNUC__)
#pragma GCC diagnostic ignored "-Wunused-macros"
#pragma GCC diagnostic ignored "-Wunused-function"
#endif

#if defined(_WIN32) || defined(__WIN32__) || defined(_WIN64)
#define PLATFORM_WINDOWS 1
#define PLATFORM_POSIX 0
#else
#define PLATFORM_WINDOWS 0
#define PLATFORM_POSIX 1
#endif

#if defined(_MSC_VER)
#define NOINLINE __declspec(noinline)
#else
#define NOINLINE __attribute__((noinline))
#endif

#if PLATFORM_WINDOWS
#include <windows.h>
#include <fibersapi.h>
#if defined(DYNAMIC_TLS_NO_FLS)
static DWORD tls_key = 0;
#else
static DWORD fls_key;
#endif
#endif
#if PLATFORM_POSIX
#include <sys/mman.h>
#include <sched.h>
#include <unistd.h>
#include <pthread.h>
static pthread_key_t pthread_key;
#ifdef __FreeBSD__
#include <sys/sysctl.h>
#define MAP_HUGETLB MAP_ALIGNED_SUPER
#ifndef PROT_MAX
#define PROT_MAX(f) 0
#endif
#else
#define PROT_MAX(f) 0
#endif
#ifdef __sun
extern int
madvise(caddr_t, size_t, int);
#endif
#ifndef MAP_UNINITIALIZED
#define MAP_UNINITIALIZED 0
#endif
#endif

#if defined(__linux__) || defined(__ANDROID__)
#include <sys/prctl.h>
#if !defined(PR_SET_VMA)
#define PR_SET_VMA 0x53564d41
#define PR_SET_VMA_ANON_NAME 0
#endif
#endif
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if !TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
#include <mach/mach_vm.h>
#include <mach/vm_statistics.h>
#endif
#include <pthread.h>
#endif
#if defined(__HAIKU__) || defined(__TINYC__)
#include <pthread.h>
#endif

#include <limits.h>
#if (INTPTR_MAX > INT32_MAX)
#define ARCH_64BIT 1
#define ARCH_32BIT 0
#else
#define ARCH_64BIT 0
#define ARCH_32BIT 1
#endif

#define pointer_offset(ptr, ofs) (void*)((char*)(ptr) + (ptrdiff_t)(ofs))
#define pointer_diff(first, second) (ptrdiff_t)((const char*)(first) - (const char*)(second))

////////////
///
/// Build time configurable limits
///
//////

#ifndef ENABLE_VALIDATE_ARGS
//! Enable validation of args to public entry points
#define ENABLE_VALIDATE_ARGS 0
#endif
#ifndef ENABLE_ASSERTS
//! Enable asserts
#define ENABLE_ASSERTS 0
#endif
#ifndef ENABLE_UNMAP
//! Enable unmapping memory pages
#define ENABLE_UNMAP 1
#endif
#ifndef ENABLE_DECOMMIT
//! Enable decommitting memory pages
#define ENABLE_DECOMMIT 1
#endif
#ifndef ENABLE_DYNAMIC_LINK
//! Enable building as dynamic library
#define ENABLE_DYNAMIC_LINK 0
#endif
#ifndef ENABLE_OVERRIDE
//! Enable standard library malloc/free/new/delete overrides
#define ENABLE_OVERRIDE 1
#endif
#ifndef ENABLE_STATISTICS
//! Enable statistics
#define ENABLE_STATISTICS 0
#endif

////////////
///
/// Built in size configurations
///
//////

#define PAGE_HEADER_SIZE 128
#define SPAN_HEADER_SIZE PAGE_HEADER_SIZE

#define SMALL_GRANULARITY 16

#define SMALL_BLOCK_SIZE_LIMIT (4 * 1024)
#define MEDIUM_BLOCK_SIZE_LIMIT (256 * 1024)
#define LARGE_BLOCK_SIZE_LIMIT (8 * 1024 * 1024)

#define SMALL_SIZE_CLASS_COUNT 73
#define MEDIUM_SIZE_CLASS_COUNT 24
#define LARGE_SIZE_CLASS_COUNT 20
#define SIZE_CLASS_COUNT (SMALL_SIZE_CLASS_COUNT + MEDIUM_SIZE_CLASS_COUNT + LARGE_SIZE_CLASS_COUNT)

#define SMALL_PAGE_SIZE_SHIFT 16
#define SMALL_PAGE_SIZE (1 << SMALL_PAGE_SIZE_SHIFT)
#define SMALL_PAGE_MASK (~((uintptr_t)SMALL_PAGE_SIZE - 1))
#define MEDIUM_PAGE_SIZE_SHIFT 22
#define MEDIUM_PAGE_SIZE (1 << MEDIUM_PAGE_SIZE_SHIFT)
#define MEDIUM_PAGE_MASK (~((uintptr_t)MEDIUM_PAGE_SIZE - 1))
#ifdef FEX_IOS_HOST
/* iOS-Mythic ml436 (#73): dropped 26 -> 24 to legalise 16MB spans (see the
 * SPAN_SIZE note below). Large-class ceiling falls 64MB -> 16MB; blocks in
 * (16MB, 64MB] shift to the huge path, which maps them at exact size — a VA
 * IMPROVEMENT over carving them from a 64MB span. */
#define LARGE_PAGE_SIZE_SHIFT 24
#else
#define LARGE_PAGE_SIZE_SHIFT 26
#endif
#define LARGE_PAGE_SIZE (1 << LARGE_PAGE_SIZE_SHIFT)
#define LARGE_PAGE_MASK (~((uintptr_t)LARGE_PAGE_SIZE - 1))

#ifdef FEX_IOS_HOST
/* iOS-Mythic ml332: 256MB spans are unaffordable in a 39-bit shared address space.
 *
 * os_mmap reserves size+alignment, so every span costs 512MB of VA, and rpmalloc's
 * per-thread heaps map one span per page type -- ml330 measured 69 spans / 35GB
 * reserved (~1% committed) inside the same 64GB window that CEF's PartitionAlloc
 * needs, until FEXCore CreateThread's aligned_alloc returned NULL (#43). Releasing
 * dead threads' spans is NOT the fix: the heap is shared across threads, and doing
 * so corrupted live containers (#54, ml329/ml331).
 *
 * 64MB is the floor (SPAN_SIZE / LARGE_PAGE_SIZE must be >= 1; LARGE_PAGE_SIZE_SHIFT
 * is 26) and cuts per-span VA 4x to 128MB. SPAN_MASK derives, span lookup arithmetic
 * is unchanged. */
/* iOS-Mythic ml436 (#73): 64MB -> 16MB, paired with LARGE_PAGE_SIZE_SHIFT 26 -> 24
 * above to keep SPAN_SIZE / LARGE_PAGE_SIZE >= 1. ml435's [span-census] proved the
 * FEX band fills by LIVE DEMAND, not leaks: 74 live guest threads x ~200MB
 * (2-3 x 64MB spans + code buffers) ~= the whole 16GB band, code-buffer allocation
 * then fails and Crashpad kills the webhelper AFTER BrowserReady. 16MB spans cut
 * the per-thread span footprint 4x (~48MB worst case); with the ml389 VA diet and
 * db 5392 exact-aligned maps this puts 74 threads at ~3.5GB. Exit-leak (12 heaps,
 * ~2GB) is secondary and partially covered by the ml435 ThreadTerm hardening. */
static const char ios_span16_marker[] __attribute__((used)) = "rpmalloc-span16 rev=ml436";
#define SPAN_SIZE (16 * 1024 * 1024)
#else
#define SPAN_SIZE (256 * 1024 * 1024)
#endif
#define SPAN_MASK (~((uintptr_t)(SPAN_SIZE - 1)))

////////////
///
/// Utility macros
///
//////

#if ENABLE_ASSERTS
#undef NDEBUG
#if defined(_MSC_VER) && !defined(_DEBUG)
#define _DEBUG
#endif
#include <assert.h>
#define RPMALLOC_TOSTRING_M(x) #x
#define RPMALLOC_TOSTRING(x) RPMALLOC_TOSTRING_M(x)
#define rpmalloc_assert(truth, message) \
	do {                                \
		if (!(truth)) {                 \
			assert((truth) && message); \
		}                               \
	} while (0)
#else
#define rpmalloc_assert(truth, message) \
	do {                                \
	} while (0)
#endif

#if defined(_MSC_VER)
#define rpmalloc_assume(cond) __assume(cond)
#elif defined(__clang__) && __has_builtin(__builtin_assume)
#define rpmalloc_assume(cond) __builtin_assume(cond)
#elif defined(__GNUC__)
#define rpmalloc_assume(cond)           \
	do {                                \
		if (!__builtin_expect(cond, 0)) \
			__builtin_unreachable();    \
	} while (0)
#else
#define rpmalloc_assume(cond) 0
#endif

////////////
///
/// Statistics
///
//////

#if ENABLE_STATISTICS

typedef struct rpmalloc_statistics_t {
	atomic_size_t page_mapped;
	atomic_size_t page_mapped_peak;
	atomic_size_t page_commit;
	atomic_size_t page_decommit;
	atomic_size_t page_active;
	atomic_size_t page_active_peak;
	atomic_size_t heap_count;
} rpmalloc_statistics_t;

static rpmalloc_statistics_t global_statistics;

#else

#endif

////////////
///
/// Low level abstractions
///
//////

static inline size_t
rpmalloc_clz(uintptr_t x) {
#if ARCH_64BIT
#if defined(_MSC_VER) && !defined(__clang__)
	return (size_t)_lzcnt_u64(x);
#else
	return (size_t)__builtin_clzll(x);
#endif
#else
#if defined(_MSC_VER) && !defined(__clang__)
	return (size_t)_lzcnt_u32(x);
#else
	return (size_t)__builtin_clzl(x);
#endif
#endif
}

static inline void
wait_spin(void) {
#if defined(_MSC_VER)
#if defined(_M_ARM64)
	__yield();
#else
	_mm_pause();
#endif
#elif (defined(__x86_64__) || defined(__i386__)) && !defined(_M_ARM64EC)
	__asm__ volatile("pause" ::: "memory");
#elif defined(__aarch64__) || (defined(__arm__) && __ARM_ARCH >= 7) || defined(_M_ARM64EC)
	__asm__ volatile("yield" ::: "memory");
#elif defined(__powerpc__) || defined(__powerpc64__)
	// No idea if ever been compiled in such archs but ... as precaution
	__asm__ volatile("or 27,27,27");
#elif defined(__sparc__)
	__asm__ volatile("rd %ccr, %g0 \n\trd %ccr, %g0 \n\trd %ccr, %g0");
#else
	struct timespec ts = {0};
	nanosleep(&ts, 0);
#endif
}

#if defined(__GNUC__) || defined(__clang__)

#define EXPECTED(x) __builtin_expect((x), 1)
#define UNEXPECTED(x) __builtin_expect((x), 0)

#else

#define EXPECTED(x) x
#define UNEXPECTED(x) x

#endif

/* iOS-Mythic ml611: allocation watch hook (see FEXCore/Source/Utils/AllocWatch.h).
 *
 * ml610's DFE crash traced to predecessor vectors holding the low 32 bits of
 * FEX-arena pointers — the shape of a freelist link written into storage that was
 * freed or re-issued while the CFG still referenced it. A canary cannot see that,
 * because rpmalloc writes the link into the block's CONTENTS. Only the allocator
 * knows, so the allocator has to say.
 *
 * ⚠️ This runs INSIDE malloc/free: FEX_AllocWatch_Event must never allocate, lock,
 * or format (it doesn't — fixed table, fixed ring, POD writes only). The gate is a
 * single predictable load that is zero unless something is actively watched, so
 * the ordinary path pays essentially nothing. */
extern volatile int FEX_AllocWatch_Armed;
extern void FEX_AllocWatch_Event(const void* ptr, unsigned int event);
#define FEX_WATCH_ALLOC 1u
#define FEX_WATCH_FREE 2u
#define FEX_WATCH_NOTE(p, e)                             \
	do {                                                 \
		if (UNEXPECTED(FEX_AllocWatch_Armed) && (p))     \
			FEX_AllocWatch_Event((p), (e));              \
	} while (0)

#if defined(__GNUC__) || defined(__clang__)
#ifdef __has_builtin
#if __has_builtin(__builtin_memcpy_inline)
#define memcpy_const(x, y, s) __builtin_memcpy_inline(x, y, s)
#else
#define memcpy_const(x, y, s)                                                                                   \
	do {                                                                                                        \
		_Static_assert(__builtin_choose_expr(__builtin_constant_p(s), 1, 0), "len must be a constant integer"); \
		memcpy(x, y, s);                                                                                        \
	} while (0)
#endif

#if __has_builtin(__builtin_memset_inline)
#define memset_const(x, y, s) __builtin_memset_inline(x, y, s)
#else
#define memset_const(x, y, s)                                                                                   \
	do {                                                                                                        \
		_Static_assert(__builtin_choose_expr(__builtin_constant_p(s), 1, 0), "len must be a constant integer"); \
		memset(x, y, s);                                                                                        \
	} while (0)
#endif
#endif
#endif

#ifndef memcpy_const
#define memcpy_const(x, y, s) memcpy(x, y, s)
#define memset_const(x, y, s) memset(x, y, s)
#endif

////////////
///
/// Data types
///
//////

//! A memory heap, per thread
typedef struct heap_t heap_t;
//! Span of memory pages
typedef struct span_t span_t;
//! Memory page
typedef struct page_t page_t;
//! Memory block
typedef struct block_t block_t;
//! Size class for a memory block
typedef struct size_class_t size_class_t;

//! Memory page type
typedef enum page_type_t {
	PAGE_SMALL,   // 64KiB
	PAGE_MEDIUM,  // 4MiB
	PAGE_LARGE,   // 64MiB
	PAGE_HUGE
} page_type_t;

//! Block size class
struct size_class_t {
	//! Size of blocks in this class
	uint32_t block_size;
	//! Number of blocks in each chunk
	uint32_t block_count;
};

//! A memory block
struct block_t {
	//! Next block in list
	block_t* next;
};

//! A page contains blocks of a given size
struct page_t {
	//! Size class of blocks
	uint32_t size_class;
	//! Block size
	uint32_t block_size;
	//! Block count
	uint32_t block_count;
	//! Block initialized count
	uint32_t block_initialized;
	//! Block used count
	uint32_t block_used;
	//! Page type
	page_type_t page_type;
	//! Flag set if part of heap full list
	uint32_t is_full : 1;
	//! Flag set if part of heap free list
	uint32_t is_free : 1;
	//! Flag set if blocks are zero initialied
	uint32_t is_zero : 1;
	//! Flag set if memory pages have been decommitted
	uint32_t is_decommitted : 1;
	//! Flag set if containing aligned blocks
	uint32_t has_aligned_block : 1;
	//! Fast combination flag for either huge, fully allocated or has aligned blocks
	uint32_t generic_free : 1;
	//! Local free list count
	uint32_t local_free_count;
	//! Local free list
	block_t* local_free;
	//! Owning heap
	heap_t* heap;
	//! Next page in list
	page_t* next;
	//! Previous page in list
	page_t* prev;
	//! Multithreaded free list, block index is in low 32 bit, list count is high 32 bit
	atomic_ullong thread_free;
};

//! A span contains pages of a given type
struct span_t {
	//! Page header
	page_t page;
	//! Owning heap
	heap_t* heap;
	//! Page address mask
	uintptr_t page_address_mask;
	//! Number of pages initialized
	uint32_t page_initialized;
	//! Number of pages in use
	uint32_t page_count;
	//! Number of bytes per page
	uint32_t page_size;
	//! Page type
	page_type_t page_type;
	//! Offset to start of mapped memory region
	uint32_t offset;
	//! Mapped size
	uint64_t mapped_size;
	//! Next span in list
	span_t* next;
};

// Control structure for a heap, either a thread heap or a first class heap if enabled
struct heap_t {
	//! Owning thread ID
	uintptr_t owner_thread;
	//! Heap local free list for small size classes
	block_t* local_free[SIZE_CLASS_COUNT];
	//! Available non-full pages for each size class
	page_t* page_available[SIZE_CLASS_COUNT];
	//! Free pages for each page type
	page_t* page_free[3];
	//! Free but still committed page count for each page tyoe
	uint32_t page_free_commit_count[3];
	//! Multithreaded free list
	atomic_uintptr_t thread_free[3];
	//! Available partially initialized spans for each page type
	span_t* span_partial[3];
	//! Spans in full use for each page type
	span_t* span_used[4];
	//! Next heap in queue
	heap_t* next;
	//! Previous heap in queue
	heap_t* prev;
	//! Heap ID
	uint32_t id;
	//! Finalization state flag
	uint32_t finalize;
	//! Memory map region offset
	uint32_t offset;
	//! Memory map size
	size_t mapped_size;
};

_Static_assert(sizeof(page_t) <= PAGE_HEADER_SIZE, "Invalid page header size");
_Static_assert(sizeof(span_t) <= SPAN_HEADER_SIZE, "Invalid span header size");
_Static_assert(sizeof(heap_t) <= 4096, "Invalid heap size");

////////////
///
/// Global data
///
//////

//! Fallback heap
static RPMALLOC_CACHE_ALIGNED heap_t global_heap_fallback;
//! Default heap
static heap_t* global_heap_default = &global_heap_fallback;
//! Available heaps
static heap_t* global_heap_queue;
//! In use heaps
static heap_t* global_heap_used;
//! Lock for heap queue
static atomic_uintptr_t global_heap_lock;
//! Heap ID counter
static atomic_uint global_heap_id = 1;
//! Initialized flag
static int global_rpmalloc_initialized;
//! Memory interface
static rpmalloc_interface_t* global_memory_interface;
//! Default memory interface
static rpmalloc_interface_t global_memory_interface_default;
//! Current configuration
static rpmalloc_config_t global_config = {
	.page_size = 0,
	.enable_huge_pages = 0,
	.disable_decommit = 0,
	.page_name = "FEXAllocator",
	.huge_page_name = "FEXAllocator",
	.unmap_on_finalize = 0,
};
//! Main thread ID
static uintptr_t global_main_thread_id;

typedef void* (*mmap_hook_type)( size_t size, size_t alignment, size_t* offset, size_t* mapped_size);
typedef void (*munmap_hook_type)(void* address, size_t offset, size_t mapped_size);

static void*
os_mmap(size_t size, size_t alignment, size_t* offset, size_t* mapped_size);
static void
os_munmap(void* address, size_t offset, size_t mapped_size);

mmap_hook_type rp_mmap_hook = os_mmap;
munmap_hook_type rp_munmap_hook = os_munmap;

static void*
trampoline_mmap(size_t size, size_t alignment, size_t* offset, size_t* mapped_size) {
  return rp_mmap_hook(size, alignment, offset, mapped_size);
}

static void
trampoline_munmap(void* address, size_t offset, size_t mapped_size) {
  return rp_munmap_hook(address, offset, mapped_size);
}

//! Size classes
#define SCLASS(n) \
	{ (n * SMALL_GRANULARITY), (SMALL_PAGE_SIZE - PAGE_HEADER_SIZE) / (n * SMALL_GRANULARITY) }
#define MCLASS(n) \
	{ (n * SMALL_GRANULARITY), (MEDIUM_PAGE_SIZE - PAGE_HEADER_SIZE) / (n * SMALL_GRANULARITY) }
#define LCLASS(n) \
	{ (n * SMALL_GRANULARITY), (LARGE_PAGE_SIZE - PAGE_HEADER_SIZE) / (n * SMALL_GRANULARITY) }
static const size_class_t global_size_class[SIZE_CLASS_COUNT] = {
    SCLASS(1),      SCLASS(1),      SCLASS(2),      SCLASS(3),      SCLASS(4),      SCLASS(5),      SCLASS(6),
    SCLASS(7),      SCLASS(8),      SCLASS(9),      SCLASS(10),     SCLASS(11),     SCLASS(12),     SCLASS(13),
    SCLASS(14),     SCLASS(15),     SCLASS(16),     SCLASS(17),     SCLASS(18),     SCLASS(19),     SCLASS(20),
    SCLASS(21),     SCLASS(22),     SCLASS(23),     SCLASS(24),     SCLASS(25),     SCLASS(26),     SCLASS(27),
    SCLASS(28),     SCLASS(29),     SCLASS(30),     SCLASS(31),     SCLASS(32),     SCLASS(33),     SCLASS(34),
    SCLASS(35),     SCLASS(36),     SCLASS(37),     SCLASS(38),     SCLASS(39),     SCLASS(40),     SCLASS(41),
    SCLASS(42),     SCLASS(43),     SCLASS(44),     SCLASS(45),     SCLASS(46),     SCLASS(47),     SCLASS(48),
    SCLASS(49),     SCLASS(50),     SCLASS(51),     SCLASS(52),     SCLASS(53),     SCLASS(54),     SCLASS(55),
    SCLASS(56),     SCLASS(57),     SCLASS(58),     SCLASS(59),     SCLASS(60),     SCLASS(61),     SCLASS(62),
    SCLASS(63),     SCLASS(64),     SCLASS(80),     SCLASS(96),     SCLASS(112),    SCLASS(128),    SCLASS(160),
    SCLASS(192),    SCLASS(224),    SCLASS(256),    MCLASS(320),    MCLASS(384),    MCLASS(448),    MCLASS(512),
    MCLASS(640),    MCLASS(768),    MCLASS(896),    MCLASS(1024),   MCLASS(1280),   MCLASS(1536),   MCLASS(1792),
    MCLASS(2048),   MCLASS(2560),   MCLASS(3072),   MCLASS(3584),   MCLASS(4096),   MCLASS(5120),   MCLASS(6144),
    MCLASS(7168),   MCLASS(8192),   MCLASS(10240),  MCLASS(12288),  MCLASS(14336),  MCLASS(16384),  LCLASS(20480),
    LCLASS(24576),  LCLASS(28672),  LCLASS(32768),  LCLASS(40960),  LCLASS(49152),  LCLASS(57344),  LCLASS(65536),
    LCLASS(81920),  LCLASS(98304),  LCLASS(114688), LCLASS(131072), LCLASS(163840), LCLASS(196608), LCLASS(229376),
    LCLASS(262144), LCLASS(327680), LCLASS(393216), LCLASS(458752), LCLASS(524288)};

//! Threshold number of pages for when free pages are decommitted
static uint32_t global_page_free_overflow[4] = {0, 0, 0, 0};

//! Number of pages to retain when free page threshold overflows
static uint32_t global_page_free_retain[4] = {0, 0, 0, 0};

//! OS huge page support
static int os_huge_pages;
//! OS memory map granularity
static size_t os_map_granularity;
//! OS memory page size
static size_t os_page_size;

////////////
///
/// Thread local heap and ID
///
//////

//! Current thread heap
#if defined(WIN32)
#define TLS_MODEL
#define _Thread_local __declspec(thread)
#elif defined(__ANDROID__)
#if __ANDROID_API__ >= 29 && \
    ((defined(__clang__) && (__clang_major__ >= 17)) || (defined(__NDK_MAJOR__) && (__NDK_MAJOR__ >= 26)))
#define TLS_MODEL __attribute__((tls_model("local-dynamic")))
#else
#define TLS_MODEL
#endif
#else
#define TLS_MODEL __attribute__((tls_model("initial-exec")))
// #define TLS_MODEL
#endif

#if !defined(DYNAMIC_TLS_NO_FLS)
static _Thread_local heap_t* global_thread_heap TLS_MODEL = &global_heap_fallback;
#endif

static heap_t*
heap_allocate(int first_class);

static void
heap_page_free_decommit(heap_t* heap, uint32_t page_type, uint32_t page_retain_count);

//! Fast thread ID
static inline uintptr_t
get_thread_id(void) {
#if defined(_WIN32) && defined(FEX_IOS_HOST)
	/* ml1046: THE THREAD ID MUST COME FROM A LOAD, NEVER FROM THE RAW REGISTER.
	 *
	 * NtCurrentTeb() on ARM64 is "read x18". On iOS the kernel zeroes x18 behind
	 * our back and the Mach exception handler repairs it LAZILY -- on the next
	 * TEB-relative load that faults (x18_fixes=2300+ per run). Reading the
	 * register never faults, so between the clobber and the repair this function
	 * returned 0, silently, and rpmalloc builds everything on it:
	 *
	 *   heap_lock_acquire():  CAS(global_heap_lock, 0 -> 0) "succeeds" and leaves
	 *                         the lock UNLOCKED, so a second thread walks in and
	 *                         both adopt the same orphan heap;
	 *   set_thread_heap():    owner_thread = 0 -- the old_owner=0x0 in every
	 *                         RPMALLOC-REPAIR breadcrumb since ml416;
	 *   page_is_thread_heap(): owner == id is 0 == 0 for ANY thread whose x18 is
	 *                         momentarily zero, which then frees into a foreign
	 *                         heap through the lock-free owner path.
	 *
	 * That is the writer behind the FEX-arena corruption family open since
	 * ml606/ml610 (DFE containers, a libc++ tree, page_available[], and on the
	 * iPhone 18 Pro rpfree+0x38 and a deque block pointer going NULL mid-pass).
	 * It also wedged ml1044/45's allocator lock: taken under one identity,
	 * released under another.
	 *
	 * TEB->Self lives at +0x30. With x18 == 0 the load touches address 0x30,
	 * faults, the handler restores x18 and the instruction re-executes -- so the
	 * value that comes back is always the real TEB. `volatile` keeps the compiler
	 * from folding it back into a register read. */
	return (uintptr_t)(*(void* volatile*)((char*)NtCurrentTeb() + 0x30));
#elif defined(_WIN32)
	return (uintptr_t)((void*)NtCurrentTeb());
#elif !defined(__APPLE__) && !defined(__CYGWIN__) &&                                                \
    ((defined(__clang__) && (__clang_major__ >= 7)) || ((defined(__GNUC__) && (__GNUC__ >= 5)))) && \
    (defined(__aarch64__) || defined(__x86_64__) || defined(__loongarch__))  // Unsure of other archs, needs testing
	void* thp = __builtin_thread_pointer();
	return (uintptr_t)thp;
#else
	uintptr_t tid;
#if defined(__i386__)
	__asm__("movl %%gs:0, %0" : "=r"(tid) : :);
#elif defined(__x86_64__)
#if defined(__MACH__)
	__asm__("movq %%gs:0, %0" : "=r"(tid) : :);
#else
	__asm__("movq %%fs:0, %0" : "=r"(tid) : :);
#endif
#elif defined(__arm__)
	__asm__ volatile("mrc p15, 0, %0, c13, c0, 3" : "=r"(tid));
#elif defined(__aarch64__)
#if defined(__MACH__)
	// tpidr_el0 likely unused, always return 0 on iOS
	__asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tid));
#else
	__asm__ volatile("mrs %0, tpidr_el0" : "=r"(tid));
#endif
#elif defined(DYNAMIC_TLS_NO_FLS)
#error Not implemented for dynamic TLS.
#else
	tid = (uintptr_t)&global_thread_heap;
#endif
	return tid;
#endif
}

#if defined(DYNAMIC_TLS_NO_FLS)
//! Set the current thread heap
static void
set_thread_heap(heap_t* heap) {
	if (heap && (heap->id != 0)) {
		rpmalloc_assert(heap->id != 0, "Default heap being used");
		heap->owner_thread = get_thread_id();
	}
#if PLATFORM_WINDOWS
	TlsSetValue(tls_key, heap);
#else
	pthread_setspecific(pthread_key, heap);
#endif
}

//! Get the current thread heap
static inline heap_t*
get_thread_heap(void) {
  void *result = TlsGetValue(tls_key);
  if (!result) {
    result = &global_heap_fallback;
  }
  return result;
}
#else
//! Set the current thread heap
static void
set_thread_heap(heap_t* heap) {
	global_thread_heap = heap;
	if (heap && (heap->id != 0)) {
		rpmalloc_assert(heap->id != 0, "Default heap being used");
		heap->owner_thread = get_thread_id();
	}
#if PLATFORM_WINDOWS
	FlsSetValue(fls_key, heap);
#else
	pthread_setspecific(pthread_key, heap);
#endif
}

//! Get the current thread heap
static inline heap_t*
get_thread_heap(void) {
	return global_thread_heap;
}
#endif

static heap_t*
get_thread_heap_allocate(void) {
	heap_t* heap = heap_allocate(0);
	set_thread_heap(heap);
	return heap;
}

//! Get the size class from given size in bytes for tiny blocks (below 16 times the minimum granularity)
static inline uint32_t
get_size_class_tiny(size_t size) {
	return (((uint32_t)size + (SMALL_GRANULARITY - 1)) / SMALL_GRANULARITY);
}

//! Get the size class from given size in bytes
static inline uint32_t
get_size_class(size_t size) {
	uintptr_t minblock_count = (size + (SMALL_GRANULARITY - 1)) / SMALL_GRANULARITY;
	// For sizes up to 64 times the minimum granularity (i.e 1024 bytes) the size class is equal to number of such
	// blocks
	if (size <= (SMALL_GRANULARITY * 64)) {
		rpmalloc_assert(global_size_class[minblock_count].block_size >= size, "Size class misconfiguration");
		return (uint32_t)(minblock_count ? minblock_count : 1);
	}
	--minblock_count;
	// Calculate position of most significant bit, since minblock_count now guaranteed to be > 64 this position is
	// guaranteed to be >= 6
#if ARCH_64BIT
	const uint32_t most_significant_bit = (uint32_t)(63 - (int)rpmalloc_clz(minblock_count));
#else
	const uint32_t most_significant_bit = (uint32_t)(31 - (int)rpmalloc_clz(minblock_count));
#endif
	// Class sizes are of the bit format [..]000xxx000[..] where we already have the position of the most significant
	// bit, now calculate the subclass from the remaining two bits
	const uint32_t subclass_bits = (minblock_count >> (most_significant_bit - 2)) & 0x03;
	const uint32_t class_idx = (uint32_t)((most_significant_bit << 2) + subclass_bits) + 41;
	rpmalloc_assert((class_idx >= SIZE_CLASS_COUNT) || (global_size_class[class_idx].block_size >= size),
	                "Size class misconfiguration");
	rpmalloc_assert((class_idx >= SIZE_CLASS_COUNT) || (global_size_class[class_idx - 1].block_size < size),
	                "Size class misconfiguration");
	return class_idx;
}

static inline page_type_t
get_page_type(uint32_t size_class) {
	if (size_class < SMALL_SIZE_CLASS_COUNT)
		return PAGE_SMALL;
	else if (size_class < (SMALL_SIZE_CLASS_COUNT + MEDIUM_SIZE_CLASS_COUNT))
		return PAGE_MEDIUM;
	else if (size_class < SIZE_CLASS_COUNT)
		return PAGE_LARGE;
	return PAGE_HUGE;
}

static inline size_t
get_page_aligned_size(size_t size) {
	size_t unalign = size % global_config.page_size;
	if (unalign)
		size += global_config.page_size - unalign;
	return size;
}

////////////
///
/// OS entry points
///
//////

static void
os_set_page_name(void* address, size_t size) {
#if defined(__linux__) || defined(__ANDROID__)
	const char* name = os_huge_pages ? global_config.huge_page_name : global_config.page_name;
	if ((address == MAP_FAILED) || !name)
		return;
	// If the kernel does not support CONFIG_ANON_VMA_NAME or if the call fails
	// (e.g. invalid name) it is a no-op basically.
	(void)prctl(PR_SET_VMA, PR_SET_VMA_ANON_NAME, (uintptr_t)address, size, (uintptr_t)name);
#else
	(void)sizeof(size);
	(void)sizeof(address);
#endif
}

#ifdef FEX_IOS_HOST
/* iOS-Mythic ml706: ONE VA-layout profile, selected before rpmalloc's FIRST
 * mapping and published to every other consumer.
 *
 * The FEX host band was a compile-time constant in FOUR places: os_mmap below,
 * ios_block_ptr_ok, FEXCore::Allocator::VirtualAlloc and CallRetStack. On iOS
 * 26.x the usable VA ceiling is 64GB rather than 512GB, so [0x7c,0x80) sits
 * entirely above it and wine rejects the request during PARAMETER VALIDATION
 * (limit_low >= user_space_limit) without attempting a single placement -- it
 * is not an mmap refusal, nothing is ever mapped. Each site then retried
 * UNCONSTRAINED, and rpmalloc -- which runs before arm64ec_process_init,
 * before SetupHooks and before FEX logging exists -- placed its spans and heap
 * metadata in the GUEST band (0x158920000, 0x159000000; wine's own
 * [commit-zero] labels them GUEST). Metadata was corrupted almost immediately,
 * ThreadState never materialised, x28 stayed 0, and every x86-64 process died
 * before its first guest instruction. Native ARM64 was unaffected because it
 * never needs this arena, which made it look device-specific.
 *
 * Selected HERE because this is the earliest allocator in the process, and
 * reported through a bare WriteFile because it is the only output channel
 * alive this early: VirtualName is a no-op until SetupHooks, and FEX's
 * LogManager does not exist yet. Deliberately does NOT use ios_rpm_emit --
 * that opens a file, and CreateFileA can allocate, which would re-enter
 * rpmalloc during its own initialisation. */
uintptr_t ios_fex_band_base = 0;
/* ml751: deferred beacon buffer -- see ios_va_emit(). Written before the EC TEB
 * exists, so it must stay a dumb byte array; flushed later from Module.cpp. */
char ios_va_log[4096];
int ios_va_log_len = 0;
uintptr_t ios_fex_band_end = 0;

/* MADEIRA: the dual-mapped JIT pool's RX range, [rx, end).
 *
 * Nothing here selects or allocates it -- the pool is created by the app before Wine starts and
 * published through WINE_IOS_JIT_RX / WINE_IOS_JIT_SIZE. The CPU module (ARM64EC/Module.cpp,
 * WOW64/Module.cpp) fills these in at process init, next to FEXCore::DualMap::WriteOffset, and
 * FEXCore::Allocator::VirtualAlloc uses them to REFUSE an executable allocation that did not come
 * from the pool: every JIT write goes to `address + WriteOffset`, which is only mapped for pool
 * addresses, so a non-pool code buffer writes into unmapped memory on its first emit.
 *
 * They live here, beside ios_fex_band_base, purely so that every FEX binary that links FEXCore has
 * a definition without each one needing its own. Zero means "not published yet" and disables the
 * check rather than failing allocations. */
uintptr_t ios_fex_jit_pool_rx = 0;
uintptr_t ios_fex_jit_pool_end = 0;

typedef PVOID(WINAPI* ios_valloc2_t)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER*, ULONG);

static void
ios_va_emit(const char* buf, int len) {
	unsigned long w;
	int room;
	WriteFile(GetStdHandle((unsigned long)-12), buf, (unsigned long)len, &w, 0);

	/* ml751: DEFER. Do not call ANY logging API from here.
	 *
	 * The WriteFile above targets the Win32 STD_ERROR_HANDLE, which on iOS
	 * reaches nothing we capture -- which is why every [va-profile] beacon is
	 * absent from the device logs although the selector plainly runs. ml750
	 * tried to fix that with OutputDebugStringA and CRASHED EVERY LAUNCH:
	 * x18=0x0, NULL dereference, no build-id line at all. This runs during
	 * rpmalloc's allocator init, BEFORE the ARM64EC TEB exists, and
	 * OutputDebugStringA reaches into ntdll and touches it. WriteFile survived
	 * only because it was failing silently.
	 *
	 * So append to a plain static buffer -- memcpy and an integer, no syscall,
	 * no TEB, no lock, no allocation -- and let Module.cpp flush it once LogMan
	 * is up, which is the same place the build-id line prints successfully. */
	room = (int)sizeof(ios_va_log) - 1 - ios_va_log_len;
	if (room > 0) {
		int n = len < room ? len : room;
		memcpy(ios_va_log + ios_va_log_len, buf, (size_t)n);
		ios_va_log_len += n;
		ios_va_log[ios_va_log_len] = 0;
	}
}

static int
ios_va_cat(char* buf, int i, const char* s) {
	while (*s)
		buf[i++] = *s++;
	return i;
}

static int
ios_va_hex(char* buf, int i, uintptr_t v) {
	const char* hexd = "0123456789abcdef";
	int shift = 60, started = 0;
	buf[i++] = '0';
	buf[i++] = 'x';
	for (; shift >= 0; shift -= 4) {
		int d = (int)((v >> shift) & 0xf);
		if (d || started || !shift) {
			buf[i++] = hexd[d];
			started = 1;
		}
	}
	return i;
}

static void
ios_fex_band_select(ios_valloc2_t valloc2) {
	/* MADEIRA ml1600/ml1630: in the WOW64 (32-bit guest) build, cand[1] is
	 * [48 GB, 60 GB), was 8 GB: the 64 GB regime's slice ran dry under a
	 * launcher's browser helper (new-thread allocations at 0xdf6xxxxxx, then FEX
	 * wrote through a failed one at 0x1000). A placement range, not a
	 * reservation, still below that map's end (63 GB).
	 *
	 * The ARM64EC build (64-bit processes) keeps upstream's [48 GB, 56 GB)
	 * exactly: that placement is what existing 64-bit titles run with, and the
	 * wider slice has only been exercised with 32-bit guests. The distinction
	 * is made at compile time -- the two CPU modules are separate builds -- and
	 * never at run time: this selector runs before the ARM64EC TEB exists, where
	 * GetEnvironmentVariableA faults (upstream ml797 note). */
#if defined(__arm64ec__) || defined(_M_ARM64EC)
#define IOS_FEX_BAND_64G_END 0x0dffffffffULL /* upstream: [48 GB, 56 GB) */
#else
#define IOS_FEX_BAND_64G_END 0x0effffffffULL /* WOW64 build: [48 GB, 60 GB) */
#endif
	static const uintptr_t cand[][2] = {
		/* 512GB regime (iOS 27): the established layout. Must stay clear of
		 * CEF's four 16GB PartitionAlloc pools at [0x74,0x7c) -- see the ml325
		 * correction in AllocatorHooks.h. */
		{0x7c00000000ULL, 0x7fffffffffULL},
		/* Constrained 64GB regime (iOS 26.x): a host-only slice at 48-56GB,
		 * inside the low free hole and below the GPU carveout at [64G,448G).
		 * Sized for simple guests; CEF's pools need separate placement work. */
		{0x0c00000000ULL, IOS_FEX_BAND_64G_END},
	};
	SYSTEM_INFO si;
	/* ml787: was char[224] and the NO BAND verdict below ALREADY overflowed it by
	 * one byte (87 bytes of ml706 text + 138 of ml755 = 225 written into 224), on
	 * the one path that runs when everything has gone wrong. The two strings are
	 * appended into the same buffer before a single emit, so size for the pair. */
	char buf[512];
	int i, c;


	memset(&si, 0, sizeof(si));
	GetSystemInfo(&si);
	/* ml787: label what this number IS.
	 *
	 * lpMaximumApplicationAddress is the limit Windows ADVERTISES; it is not
	 * this task's map ceiling, and on iOS the two differ by orders of
	 * magnitude -- 128TiB advertised against a 63GiB kernel ceiling. Printing
	 * it bare invited exactly that misreading, and a placement proposal was
	 * built on address space the task can never map. */
	/* ml793 step 3: CONSUME a published arena instead of selecting.
	 *
	 * When the host process has reserved a range for us, running the selector
	 * as well is how both sides came to believe different ranges were theirs:
	 * one held 8GB while the other picked an overlapping window and had LESS
	 * room than with no reservation at all (19 threads against 35). Validation
	 * of a published range lives in ntdll now -- see ml797 below. */
	/* ml797: the arena arrives as PRE-SET GLOBALS, never read from here.
	 *
	 * This function runs during rpmalloc init, BEFORE the ARM64EC TEB exists
	 * (x18=0), and before ucrtbase's DllMain has initialised lock_table[17].
	 * Both obvious channels are therefore fatal, and both were tried:
	 *
	 *   getenv()                 -> ucrtbase _lock(17) recurses on an
	 *                               uninitialised lock table until the stack is
	 *                               gone. ml793 shipped this and killed EVERY
	 *                               launch, x64 cube included, with a stack
	 *                               overflow at ucrtbase+0x3a138.
	 *   GetEnvironmentVariableA  -> reaches RtlAcquirePebLock, which reads the
	 *                               TEB. Same shape as ml750's OutputDebugStringA
	 *                               here, which crashed every launch at x18=0.
	 *
	 * So this reads NOTHING. ntdll writes ios_fex_band_base/end directly, from
	 * arm64ec_process_init_dispatchers(), which provably runs before this does
	 * (its own else-branch reports "band selection has not run yet"). The caller
	 * already skips the selector entirely when the band is set, which is exactly
	 * the ml793 requirement: a published arena must be consumed, not raced. */

	i = ios_va_cat(buf, 0, "[va-profile] ml787 advertised-maxapp(NOT the task ceiling)=");
	i = ios_va_hex(buf, i, (uintptr_t)si.lpMaximumApplicationAddress);
	i = ios_va_cat(buf, i, " -- the usable ceiling is TASK_VM_INFO.max_address, which is far lower\n");
	ios_va_emit(buf, i);

	for (c = 0; c < (int)(sizeof(cand) / sizeof(cand[0])); ++c) {
		MEM_ADDRESS_REQUIREMENTS req;
		MEM_EXTENDED_PARAMETER param;
		void* probe;

		memset(&req, 0, sizeof(req));
		memset(&param, 0, sizeof(param));
		req.Alignment = 0x10000;
		req.LowestStartingAddress = (PVOID)cand[c][0];
		req.HighestEndingAddress = (PVOID)cand[c][1];
		param.Type = MemExtendedParameterAddressRequirements;
		param.Pointer = &req;
		/* A real placement attempt. Mappability is never inferred from a VM gap
		 * walk: on 26.x the walk reports [0x70,0x80) as 65536 MB FREE with all
		 * four slots CLEAR while the kernel refuses every mapping in it. */
		probe = valloc2(GetCurrentProcess(), 0, 0x10000, MEM_RESERVE, PAGE_NOACCESS, &param, 1);

		i = ios_va_cat(buf, 0, "[va-profile] ml706 cand");
		buf[i++] = (char)('0' + c);
		i = ios_va_cat(buf, i, " base=");
		i = ios_va_hex(buf, i, cand[c][0]);
		if (probe) {
			i = ios_va_cat(buf, i, " PROBE-OK got=");
			i = ios_va_hex(buf, i, (uintptr_t)probe);
		} else {
			i = ios_va_cat(buf, i, " PROBE-FAIL");
		}
		i = ios_va_cat(buf, i, "\n");
		ios_va_emit(buf, i);

		if (probe) {
			void* big;
			VirtualFree(probe, 0, MEM_RELEASE);

			/* ml750: 16KB landing somewhere in a 4-8GB window says almost nothing
			 * about whether real span allocations will fit -- rpmalloc reserves
			 * 64-128MB at a time. Ask for something meaningful and REPORT it.
			 * Deliberately NOT a selection criterion: cand0/cand1 are proven on
			 * hardware and on iOS 26 with the 16KB test, and silently changing
			 * what they require could regress a working device to chase a VM. If
			 * this line reports FAIL on the band that then gets selected, that is
			 * the next thing to fix, and now it is visible. */
			memset(&req, 0, sizeof(req));
			req.Alignment = 0x10000;
			req.LowestStartingAddress = (PVOID)cand[c][0];
			req.HighestEndingAddress = (PVOID)cand[c][1];
			param.Type = MemExtendedParameterAddressRequirements;
			param.Pointer = &req;
			big = valloc2(GetCurrentProcess(), 0, 0x10000000 /* 256MB */, MEM_RESERVE, PAGE_NOACCESS, &param, 1);
			i = ios_va_cat(buf, 0, "[va-profile] ml750 cand");
			buf[i++] = (char)('0' + c);
			i = ios_va_cat(buf, i, " 256MB-reserve ");
			if (big) {
				i = ios_va_cat(buf, i, "OK got=");
				i = ios_va_hex(buf, i, (uintptr_t)big);
				VirtualFree(big, 0, MEM_RELEASE);
			} else {
				i = ios_va_cat(buf, i, "FAIL -- 16KB fits but a real span may not");
			}
			i = ios_va_cat(buf, i, "\n");
			ios_va_emit(buf, i);

			ios_fex_band_base = cand[c][0];
			ios_fex_band_end = cand[c][1];
			break;
		}
	}

	/* ml753: SWEEP -- do not hardcode a low band, DISCOVER one.
	 *
	 * ml750 added a fixed 40-44GB candidate because a fixed 16KB probe found
	 * 40 and 44GB usable on the research VM. It was usable *that launch*. Two
	 * launches later, on the same VM and the same build, 40 and 44GB were
	 * REFUSED and 34 and 36GB were mappable -- the opposite result. This
	 * kernel randomises its vm_map_range_configure() partitions per process,
	 * so every hardcoded low band is right sometimes and wrong the rest of the
	 * time, and when it is wrong FEX gets no arena and rpmalloc wedges with
	 * every thread parked on an event forever (the ml413/ml415 wedge shape).
	 *
	 * So walk the low region and take the first window that actually accepts a
	 * reservation. A 16KB probe only proves the address is legal; rpmalloc
	 * reserves 64-128MB spans, so confirm with a real 256MB reservation before
	 * committing. Both are released immediately.
	 *
	 * The two fixed candidates above are tried FIRST and are untouched, so a
	 * real device and the iOS 26 regime keep the exact placement they already
	 * had -- this only runs when both have failed, which on hardware never
	 * happens. */
	if (!ios_fex_band_base) {
		uintptr_t base;
		for (base = 0x0800000000ULL; base < 0x1000000000ULL; base += 0x0100000000ULL) {
			MEM_ADDRESS_REQUIREMENTS req;
			MEM_EXTENDED_PARAMETER param;
			void* small;
			void* big;
			uintptr_t end = base + 0x0100000000ULL - 1;

			memset(&req, 0, sizeof(req));
			memset(&param, 0, sizeof(param));
			req.Alignment = 0x10000;
			req.LowestStartingAddress = (PVOID)base;
			req.HighestEndingAddress = (PVOID)end;
			param.Type = MemExtendedParameterAddressRequirements;
			param.Pointer = &req;

			small = valloc2(GetCurrentProcess(), 0, 0x10000, MEM_RESERVE, PAGE_NOACCESS, &param, 1);
			if (!small)
				continue;
			VirtualFree(small, 0, MEM_RELEASE);

			memset(&req, 0, sizeof(req));
			memset(&param, 0, sizeof(param));
			req.Alignment = 0x10000;
			req.LowestStartingAddress = (PVOID)base;
			req.HighestEndingAddress = (PVOID)end;
			param.Type = MemExtendedParameterAddressRequirements;
			param.Pointer = &req;
			big = valloc2(GetCurrentProcess(), 0, 0x10000000, MEM_RESERVE, PAGE_NOACCESS, &param, 1);

			i = ios_va_cat(buf, 0, "[va-profile] ml753 sweep base=");
			i = ios_va_hex(buf, i, base);
			i = ios_va_cat(buf, i, big ? " 16KB+256MB OK -- TAKING\n" : " 16KB ok but 256MB FAIL -- skipping\n");
			ios_va_emit(buf, i);

			if (big) {
				VirtualFree(big, 0, MEM_RELEASE);
				ios_fex_band_base = base;
				ios_fex_band_end = end;
				break;
			}
		}
	}

	if (ios_fex_band_base) {
		i = ios_va_cat(buf, 0, "[va-profile] ml706 SELECTED base=");
		i = ios_va_hex(buf, i, ios_fex_band_base);
		i = ios_va_cat(buf, i, " end=");
		i = ios_va_hex(buf, i, ios_fex_band_end);
		i = ios_va_cat(buf, i, "\n");
	} else {
		i = ios_va_cat(buf, 0,
		               "[va-profile] ml706 NO BAND -- FEX host allocations fail instead of entering guest space\n");
		/* ml755: SAY SO LOUDLY. With no band every FEX host allocation returns
		 * NULL, and the first use is `str xzr, [x20, #0x7f0]` through that null
		 * result -- which the fault path then redelivers 2,000 times before a
		 * guard kills the process. The real cause (no arena) is nowhere near
		 * that wreckage. On the research VM this happens whenever the kernel's
		 * randomised VA partitions leave no usable window: one launch had EVERY
		 * 4GB window from 32-63GB refuse even a 16KB reservation. */
		/* ml787: message made GUEST-WIDTH AGNOSTIC. This selector is linked into
		 * both CPU modules -- the ARM64EC one (64-bit guests) and the WoW64 one
		 * (32-bit guests) -- and the 32-bit bring-up hit it first, where "x64
		 * cannot start" reads as "this cannot be my failure". The arena is host
		 * memory; no guest of any width can run without it. */
		i = ios_va_cat(buf, i,
		               "[va-profile] ml755 FATAL: no FEX host arena -- the emulator cannot start "
		               "(any guest width). Expect a null-pointer store through the first NULL host "
		               "allocation next; that is a SYMPTOM, not the cause.\n");
	}
	ios_va_emit(buf, i);
}
#endif

static void*
os_mmap(size_t size, size_t alignment, size_t* offset, size_t* mapped_size) {
	size_t map_size = size + alignment;
#if PLATFORM_WINDOWS
	// Ok to MEM_COMMIT - according to MSDN, "actual physical pages are not allocated unless/until the virtual addresses
	// are actually accessed". But if we enable decommit it's better to not immediately commit and instead commit per
	// page to avoid saturating the OS commit limit
#if ENABLE_DECOMMIT
	DWORD do_commit = 0;
#else
	DWORD do_commit = MEM_COMMIT;
#endif
	void* ptr = 0;
#ifdef FEX_IOS_HOST
	/* iOS-Mythic ml415 (#60/#62): size+alignment doubles every span to 128MB of
	 * reserved VA, and per-thread heaps map one span per page type — with a
	 * 100+ thread webhelper this alone exhausts the 16GB FEX band, at which
	 * point span maps return NULL and allocation livelocks inside
	 * heap_get_page_generic/page_put_thread_free_block DURING CompileCode,
	 * with CodeInvalidationMutex held shared — the ml413/ml414/ml415 wedge.
	 * Wine's NtAllocateVirtualMemoryEx honors MemExtendedParameterAddress-
	 * Requirements (the iOS va-scan is alignment-aware), so ask for an exact
	 * aligned reservation first: a 64MB span then costs 64MB. Fall through to
	 * the legacy over-reserve on any failure. */
	/* iOS-Mythic ml465 (#76): this was gated on `if (alignment)`, which is TRUE
	 * for spans (SPAN_SIZE-aligned) and FALSE for heap_allocate_new — so heap_t
	 * METADATA fell through to the plain VirtualAlloc below and landed in the
	 * GUEST band (0x7047860000, 0x70544d0000, 0x7089180000 across ml460/462/464),
	 * i.e. guest-writable memory, while the spans it manages sat safely in the
	 * FEX band. That is the #76 corrupter: three separate runs died reading a
	 * poisoned heap->local_free[1], twice holding x86 INSTRUCTION BYTES
	 * (0x8b4c2877d1394507, 0x0fc72e0f66000002) — a guest write, not a data race
	 * (the ml463 CAS proved that: zero lost-claim markers this run, corruption
	 * unchanged). The ml420 comment above even predicted "ml419 shows heaps in
	 * the GUEST band" but the fix only ever covered the aligned span path.
	 * Pin EVERY rpmalloc mapping to the FEX band; unaligned callers just get the
	 * 64KB Windows allocation granularity. */
	{
		size_t band_alignment = alignment ? alignment : 0x10000;
		typedef PVOID(WINAPI* VirtualAlloc2_t)(HANDLE, PVOID, SIZE_T, ULONG, ULONG, MEM_EXTENDED_PARAMETER*, ULONG);
		static VirtualAlloc2_t pVirtualAlloc2 = (VirtualAlloc2_t)(uintptr_t)-1;
		if (pVirtualAlloc2 == (VirtualAlloc2_t)(uintptr_t)-1) {
			HMODULE kb = GetModuleHandleW(L"kernelbase.dll");
			pVirtualAlloc2 = kb ? (VirtualAlloc2_t)(void*)GetProcAddress(kb, "VirtualAlloc2") : 0;
		}
		if (pVirtualAlloc2) {
			MEM_ADDRESS_REQUIREMENTS req;
			MEM_EXTENDED_PARAMETER param;
			memset(&req, 0, sizeof(req));
			memset(&param, 0, sizeof(param));
			req.Alignment = band_alignment;
			/* iOS-Mythic ml420 (#69/#62): without an address range the spans
			 * land wherever wine finds aligned VA — ml419 shows heaps in the
			 * GUEST band (0x703d860000, 0x70873f0000), violating the VA map
			 * (guest <= 0x73ffff0000 | PA [0x74,0x7c) | FEX host [0x7c,0x80)).
			 * rpmalloc spans are FEX host structures — pin them to the FEX
			 * band. If the band is full, retry unconstrained (pollution over
			 * livelock), then the legacy over-reserve. */
			/* ml706: the band is chosen at runtime, on the first mapping. */
			if (!ios_fex_band_base)
				ios_fex_band_select(pVirtualAlloc2);
			if (ios_fex_band_base) {
				req.LowestStartingAddress = (PVOID)ios_fex_band_base;
				req.HighestEndingAddress = (PVOID)ios_fex_band_end;
				param.Type = MemExtendedParameterAddressRequirements;
				param.Pointer = &req;
				ptr = pVirtualAlloc2(GetCurrentProcess(), 0, size,
				                     (os_huge_pages ? MEM_LARGE_PAGES : 0) | MEM_RESERVE | do_commit,
				                     PAGE_READWRITE, &param, 1);
			}
			/* ml706: NO unconstrained retry. Clearing the bounds and re-issuing
			 * is exactly how rpmalloc's spans and heap metadata ended up in
			 * guest-writable memory on a constrained device, which corrupted
			 * the heap before FEX had a ThreadState. A failure here stays a
			 * failure; see the emit below. */
			if (ptr)
				map_size = size;
		}
	}
#endif
#ifdef FEX_IOS_HOST
	/* ml706: the legacy over-reserve is unconstrained too, so it is the same
	 * hazard by another name. Report and leave ptr NULL rather than hand
	 * rpmalloc guest-writable memory. */
	if (!ptr) {
		static _Atomic(int) band_fail_logs;
		if (atomic_fetch_add_explicit(&band_fail_logs, 1, memory_order_relaxed) < 8) {
			char b[160];
			int n = ios_va_cat(b, 0, "[va-profile] ml706 HOST MAP FAILED size=");
			n = ios_va_hex(b, n, (uintptr_t)size);
			n = ios_va_cat(b, n, " band=");
			n = ios_va_hex(b, n, ios_fex_band_base);
			n = ios_va_cat(b, n, " (no unconstrained fallback by design)\n");
			ios_va_emit(b, n);
		}
	}
#else
	if (!ptr)
		ptr = VirtualAlloc(0, map_size, (os_huge_pages ? MEM_LARGE_PAGES : 0) | MEM_RESERVE | do_commit, PAGE_READWRITE);
#endif
#ifdef FEX_IOS_HOST
	/* ml465 (#76): verdict line. Anything rpmalloc owns that lands BELOW the
	 * FEX band is guest-writable and can be scribbled (that is exactly how the
	 * heap metadata got poisoned three runs running). A clean run prints
	 * nothing here; any [rpm-band] line names a mapping still at risk.
	 * ml466 UPDATE: the ml465 run printed nothing here (pin verified) and a
	 * FEX-band heap was poisoned anyway — the guest-band framing above is
	 * REFUTED as the root cause. Keep the pin as VA-map hygiene; the corrupter
	 * is pointer-mediated (see ios_block_ptr_ok / [rpm-poison]). */
	if (ptr && ios_fex_band_base && (uintptr_t)ptr < ios_fex_band_base) {
		static _Atomic(int) band_logs;
		if (atomic_fetch_add_explicit(&band_logs, 1, memory_order_relaxed) < 24) {
			/* No printf in this TU (see [rpfree-skip] below) — hand-format. */
			char buf[96];
			const char *hexd = "0123456789abcdef";
			const char *pre = "[rpm-band] GUEST-BAND ptr=0x";
			const char *szs = " size=0x";
			unsigned long long _p = (unsigned long long)(uintptr_t)ptr, _s = (unsigned long long)size;
			int i = 0, j;
			unsigned long w;
			while (pre[i]) { buf[i] = pre[i]; i++; }
			for (j = 60; j >= 0; j -= 4) buf[i++] = hexd[(_p >> j) & 0xf];
			for (j = 0; szs[j]; ++j) buf[i++] = szs[j];
			for (j = 60; j >= 0; j -= 4) buf[i++] = hexd[(_s >> j) & 0xf];
			buf[i++] = ' '; buf[i++] = 'm'; buf[i++] = 'l'; buf[i++] = '4';
			buf[i++] = '6'; buf[i++] = '5'; buf[i++] = '\n';
			WriteFile(GetStdHandle((unsigned long)-12), buf, (unsigned long)i, &w, 0);
		}
	}
#endif
#else
	int flags = MAP_PRIVATE | MAP_ANONYMOUS | MAP_UNINITIALIZED;
#if defined(__APPLE__) && !TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
	int fd = (int)VM_MAKE_TAG(240U);
	if (os_huge_pages)
		fd |= VM_FLAGS_SUPERPAGE_SIZE_2MB;
	void* ptr = mmap(0, map_size, PROT_READ | PROT_WRITE, flags, fd, 0);
#elif defined(MAP_HUGETLB)
	void* ptr = mmap(0, map_size, PROT_READ | PROT_WRITE | PROT_MAX(PROT_READ | PROT_WRITE),
	                 (os_huge_pages ? MAP_HUGETLB : 0) | flags, -1, 0);
#if defined(MADV_HUGEPAGE)
	// In some configurations, huge pages allocations might fail thus
	// we fallback to normal allocations and promote the region as transparent huge page
	if ((ptr == MAP_FAILED || !ptr) && os_huge_pages) {
		ptr = mmap(0, map_size, PROT_READ | PROT_WRITE, flags, -1, 0);
		if (ptr && ptr != MAP_FAILED) {
			int prm = madvise(ptr, size, MADV_HUGEPAGE);
			(void)prm;
			rpmalloc_assert((prm == 0), "Failed to promote the page to transparent huge page");
		}
	}
#endif
	os_set_page_name(ptr, map_size);
#elif defined(MAP_ALIGNED)
	const size_t align = (sizeof(size_t) * 8) - (size_t)(__builtin_clzl(size - 1));
	void* ptr = mmap(0, map_size, PROT_READ | PROT_WRITE, (os_huge_pages ? MAP_ALIGNED(align) : 0) | flags, -1, 0);
#elif defined(MAP_ALIGN)
	caddr_t base = (os_huge_pages ? (caddr_t)(4 << 20) : 0);
	void* ptr = mmap(base, map_size, PROT_READ | PROT_WRITE, (os_huge_pages ? MAP_ALIGN : 0) | flags, -1, 0);
#else
	void* ptr = mmap(0, map_size, PROT_READ | PROT_WRITE, flags, -1, 0);
#endif
	if (ptr == MAP_FAILED)
		ptr = 0;
#endif
	if (!ptr) {
		if (global_memory_interface->map_fail_callback) {
			if (global_memory_interface->map_fail_callback(map_size))
				return os_mmap(size, alignment, offset, mapped_size);
		} else {
			rpmalloc_assert(ptr != 0, "Failed to map more virtual memory");
		}
		return 0;
	}
	if (alignment) {
		size_t padding = ((uintptr_t)ptr & (uintptr_t)(alignment - 1));
		if (padding)
			padding = alignment - padding;
		rpmalloc_assert(padding <= alignment, "Internal failure in padding");
		rpmalloc_assert(!(padding % 8), "Internal failure in padding");
		ptr = pointer_offset(ptr, padding);
		*offset = padding;
	}
	*mapped_size = map_size;
#if ENABLE_STATISTICS
	size_t page_count = map_size / global_config.page_size;
	size_t page_mapped_current =
	    atomic_fetch_add_explicit(&global_statistics.page_mapped, page_count, memory_order_relaxed) + page_count;
	size_t page_mapped_peak = atomic_load_explicit(&global_statistics.page_mapped_peak, memory_order_relaxed);
	while (page_mapped_current > page_mapped_peak) {
		if (atomic_compare_exchange_weak_explicit(&global_statistics.page_mapped_peak, &page_mapped_peak,
		                                          page_mapped_current, memory_order_relaxed, memory_order_relaxed))
			break;
	}
#if ENABLE_DECOMMIT
	size_t page_active_current =
	    atomic_fetch_add_explicit(&global_statistics.page_active, page_count, memory_order_relaxed) + page_count;
	size_t page_active_peak = atomic_load_explicit(&global_statistics.page_active_peak, memory_order_relaxed);
	while (page_active_current > page_active_peak) {
		if (atomic_compare_exchange_weak_explicit(&global_statistics.page_active_peak, &page_active_peak,
		                                          page_active_current, memory_order_relaxed, memory_order_relaxed))
			break;
	}
#endif
#endif
	return ptr;
}

static void
os_mcommit(void* address, size_t size) {
#if ENABLE_DECOMMIT
	if (global_config.disable_decommit)
		return;
#if PLATFORM_WINDOWS
	if (!VirtualAlloc(address, size, MEM_COMMIT, PAGE_READWRITE)) {
		rpmalloc_assert(0, "Failed to commit virtual memory block");
	}
#else
		/*
		if (mprotect(address, size, PROT_READ | PROT_WRITE)) {
		    rpmalloc_assert(0, "Failed to commit virtual memory block");
		}
		*/
#endif
#if ENABLE_STATISTICS
	size_t page_count = size / global_config.page_size;
	atomic_fetch_add_explicit(&global_statistics.page_commit, page_count, memory_order_relaxed);
	size_t page_active_current =
	    atomic_fetch_add_explicit(&global_statistics.page_active, page_count, memory_order_relaxed) + page_count;
	size_t page_active_peak = atomic_load_explicit(&global_statistics.page_active_peak, memory_order_relaxed);
	while (page_active_current > page_active_peak) {
		if (atomic_compare_exchange_weak_explicit(&global_statistics.page_active_peak, &page_active_peak,
		                                          page_active_current, memory_order_relaxed, memory_order_relaxed))
			break;
	}
#endif
#endif
	(void)sizeof(address);
	(void)sizeof(size);
}

static void
os_mdecommit(void* address, size_t size) {
#if ENABLE_DECOMMIT
	if (global_config.disable_decommit)
		return;
#if PLATFORM_WINDOWS
	if (!VirtualFree(address, size, MEM_DECOMMIT)) {
		rpmalloc_assert(0, "Failed to decommit virtual memory block");
	}
#else
		/*
		if (mprotect(address, size, PROT_NONE)) {
		    rpmalloc_assert(0, "Failed to decommit virtual memory block");
		}
		*/
#if defined(MADV_DONTNEED)
	if (madvise(address, size, MADV_DONTNEED)) {
#elif defined(MADV_FREE_REUSABLE)
	int ret;
	while ((ret = madvise(address, size, MADV_FREE_REUSABLE)) == -1 && (errno == EAGAIN))
		errno = 0;
	if ((ret == -1) && (errno != 0)) {
#elif defined(MADV_PAGEOUT)
	if (madvise(address, size, MADV_PAGEOUT)) {
#elif defined(MADV_FREE)
	if (madvise(address, size, MADV_FREE)) {
#else
	if (posix_madvise(address, size, POSIX_MADV_DONTNEED)) {
#endif
		rpmalloc_assert(0, "Failed to decommit virtual memory block");
	}
#endif
#if ENABLE_STATISTICS
	size_t page_count = size / global_config.page_size;
	atomic_fetch_add_explicit(&global_statistics.page_decommit, page_count, memory_order_relaxed);
	size_t page_active_current =
	    atomic_fetch_sub_explicit(&global_statistics.page_active, page_count, memory_order_relaxed);
	rpmalloc_assert(page_active_current >= page_count, "Decommit counter out of sync");
	(void)sizeof(page_active_current);
#endif
#else
	(void)sizeof(address);
	(void)sizeof(size);
#endif
}

static void
os_munmap(void* address, size_t offset, size_t mapped_size) {
	(void)sizeof(mapped_size);
	address = pointer_offset(address, -(int32_t)offset);
#if ENABLE_UNMAP
#if PLATFORM_WINDOWS
	if (!VirtualFree(address, 0, MEM_RELEASE)) {
		rpmalloc_assert(0, "Failed to unmap virtual memory block");
	}
#else
	if (munmap(address, mapped_size))
		rpmalloc_assert(0, "Failed to unmap virtual memory block");
#endif
#if ENABLE_STATISTICS
	size_t page_count = mapped_size / global_config.page_size;
	atomic_fetch_sub_explicit(&global_statistics.page_mapped, page_count, memory_order_relaxed);
	atomic_fetch_sub_explicit(&global_statistics.page_active, page_count, memory_order_relaxed);
#endif
#endif
}

////////////
///
/// Page interface
///
//////

static inline span_t*
page_get_span(page_t* page) {
	return (span_t*)((uintptr_t)page & SPAN_MASK);
}

static inline size_t
page_get_size(page_t* page) {
	if (page->page_type == PAGE_SMALL)
		return SMALL_PAGE_SIZE;
	else if (page->page_type == PAGE_MEDIUM)
		return MEDIUM_PAGE_SIZE;
	else if (page->page_type == PAGE_LARGE)
		return LARGE_PAGE_SIZE;
	else
		return page_get_span(page)->page_size;
}

static inline int
page_is_thread_heap(page_t* page) {
#if RPMALLOC_FIRST_CLASS_HEAPS
	return (!page->heap->owner_thread || (page->heap->owner_thread == get_thread_id()));
#else
	return (page->heap->owner_thread == get_thread_id());
#endif
}

static inline block_t*
page_block_start(page_t* page) {
	return pointer_offset(page, PAGE_HEADER_SIZE);
}

static inline block_t*
page_block(page_t* page, uint32_t block_index) {
	return pointer_offset(page, PAGE_HEADER_SIZE + (page->block_size * block_index));
}

static inline uint32_t
page_block_index(page_t* page, block_t* block) {
	block_t* block_first = page_block_start(page);
	return (uint32_t)pointer_diff(block, block_first) / page->block_size;
}

static inline uint32_t
page_block_from_thread_free_list(page_t* page, uint64_t token, block_t** block) {
	uint32_t block_index = (uint32_t)(token & 0xFFFFFFFFULL);
	uint32_t list_count = (uint32_t)((token >> 32ULL) & 0xFFFFFFFFULL);
	*block = list_count ? page_block(page, block_index) : 0;
	return list_count;
}

static inline uint64_t
page_block_to_thread_free_list(page_t* page, uint32_t block_index, uint32_t list_count) {
	(void)sizeof(page);
	return ((uint64_t)list_count << 32ULL) | (uint64_t)block_index;
}

#ifdef FEX_IOS_HOST
/* iOS-Mythic ml466 (#76): the ml465 run REFUTED the guest-band framing — the
 * band-pin held ([rpm-band] silent, every heap at 0x7c...) and local_free[1]
 * of FEX-band heap 0x7c08720000 was STILL poisoned (0x26750000000090be),
 * identical shape to the three guest-band runs. Four heaps, two bands, same
 * struct slot ⇒ the writer holds a genuine pointer to the block, it is not a
 * spatial wild write. The poison values are live-object leading bytes
 * (ml462: {u32 0x1df, u32 0x1e6} — a refcount pair; ml464/465: x86 code
 * bytes) landing where a free block's `next` field lives — a use-after-free
 * or double-free of a size-class-1 block whose content then propagates into
 * the list head on pop. Every legitimate block lives in the FEX span band
 * [0x7c00000000, 0x8000000000), so validate at every list deref: amputate a
 * poisoned chain (leak a few blocks) instead of dereferencing garbage, and
 * dump the holder block's leading qwords — the content names the corrupter's
 * object type. A clean run prints no [rpm-poison] lines. */
static inline int
ios_block_ptr_ok(void* p) {
	/* ml706: follows the selected band. Before selection nothing can be
	 * classified, so do not amputate chains on a guess. */
	if (!ios_fex_band_base)
		return 1;
	return ((uintptr_t)p - ios_fex_band_base) <= (ios_fex_band_end - ios_fex_band_base);
}

/* iOS-Mythic ml490 (corrupter hunt): route poison notes to a FILE.
 *
 * These have always gone to GetStdHandle(STD_ERROR), which for steamwebhelper
 * is its CONSOLE WINDOW — invisible in mythic-log. That is why every #76/#88
 * diagnostic since ml466 has been silently discarded: 0 hits across six runs,
 * including two that crashed ONE INSTRUCTION after this call. Writing to
 * C:\rpm-poison.log (pullable via devicectl) turns them on for the first time.
 *
 * Why this matters now: the bytes that overwrite rpmalloc's free-list pointer
 * decode as ASCII — 0xa316531373030 is "0071e1\n", the tail of a hex address
 * plus a newline, i.e. FORMATTED LOG TEXT. Something writes log output into a
 * block it does not own. The note already dumps the holder block's leading
 * qwords; rendering them as ASCII should show enough of the string to identify
 * the writer by its format. */
static void*
ios_rpm_emit_handle(void) {
	static void* h;
	if (!h)
		h = CreateFileA("C:\\rpm-poison.log", 4 /*FILE_APPEND_DATA*/, 1 | 2 /*share rw*/, 0,
		                4 /*OPEN_ALWAYS*/, 0x80 /*NORMAL*/, 0);
	return (h == (void*)(uintptr_t)-1) ? 0 : h;
}

static void
ios_rpm_emit(const char* buf, int len) {
	unsigned long w;
	void* h = ios_rpm_emit_handle();
	if (h)
		WriteFile(h, buf, (unsigned long)len, &w, 0);
	WriteFile(GetStdHandle((unsigned long)-12), buf, (unsigned long)len, &w, 0);
}

static void
ios_rpm_poison_note(const char* tag, void* owner, void* bad, void* holder) {
	static _Atomic(int) poison_logs;
	if (atomic_fetch_add_explicit(&poison_logs, 1, memory_order_relaxed) >= 32)
		return;
	/* No printf in this TU (see [rpfree-skip]) — hand-format. */
	char buf[640];
	const char* hexd = "0123456789abcdef";
	int i = 0, j;
	unsigned long w;
	const char* pre = "[rpm-poison] ";
	while (pre[i]) { buf[i] = pre[i]; i++; }
	for (j = 0; tag[j] && j < 12; ++j) buf[i++] = tag[j];
	{
		const char* s = " owner=0x";
		unsigned long long v = (unsigned long long)(uintptr_t)owner;
		for (j = 0; s[j]; ++j) buf[i++] = s[j];
		for (j = 60; j >= 0; j -= 4) buf[i++] = hexd[(v >> j) & 0xf];
	}
	{
		const char* s = " bad=0x";
		unsigned long long v = (unsigned long long)(uintptr_t)bad;
		for (j = 0; s[j]; ++j) buf[i++] = s[j];
		for (j = 60; j >= 0; j -= 4) buf[i++] = hexd[(v >> j) & 0xf];
	}
	{
		const char* s = " holder=0x";
		unsigned long long v = (unsigned long long)(uintptr_t)holder;
		for (j = 0; s[j]; ++j) buf[i++] = s[j];
		for (j = 60; j >= 0; j -= 4) buf[i++] = hexd[(v >> j) & 0xf];
	}
	if (holder && ios_block_ptr_ok(holder)) {
		unsigned long long* q = (unsigned long long*)holder;
		int k;
		for (k = 0; k < 4; ++k) {
			unsigned long long v = q[k];
			buf[i++] = ' '; buf[i++] = 'q'; buf[i++] = hexd[k]; buf[i++] = '=';
			for (j = 60; j >= 0; j -= 4) buf[i++] = hexd[(v >> j) & 0xf];
		}
		/* ml490: render the same bytes as ASCII — the payload is log text, and
		 * the format string it came from names the writer. */
		{
			const unsigned char* c = (const unsigned char*)holder;
			const char* s = " ascii=\"";
			for (j = 0; s[j]; ++j) buf[i++] = s[j];
			for (k = 0; k < 48; ++k)
				buf[i++] = (c[k] >= 32 && c[k] < 127) ? (char)c[k] : '.';
			buf[i++] = '"';
		}
	}
	/* ml490: also dump the raw BAD value as ASCII — for heap-head/page-head the
	 * poisoned slot IS the payload and there is no holder block to dump. */
	{
		const unsigned char* c = (const unsigned char*)&bad;
		const char* s = " badascii=\"";
		for (j = 0; s[j]; ++j) buf[i++] = s[j];
		for (j = 0; j < 8; ++j)
			buf[i++] = (c[j] >= 32 && c[j] < 127) ? (char)c[j] : '.';
		buf[i++] = '"';
	}
	buf[i++] = ' '; buf[i++] = 'm'; buf[i++] = 'l'; buf[i++] = '4'; buf[i++] = '9'; buf[i++] = '0'; buf[i++] = '\n';
	ios_rpm_emit(buf, i);
}
#endif

static inline block_t*
page_block_realign(page_t* page, block_t* block) {
	void* blocks_start = page_block_start(page);
	uint32_t block_offset = (uint32_t)pointer_diff(block, blocks_start);
	return pointer_offset(block, -(int32_t)(block_offset % page->block_size));
}

static block_t*
page_get_local_free_block(page_t* page) {
#ifdef FEX_IOS_HOST
	/* ml484 (#88): same omission as heap_pop_local_free — the block was checked
	 * but `page` itself never was, and every branch below both reads and writes
	 * through it. Validate the owner first. */
	if (UNEXPECTED(!ios_block_ptr_ok(page))) {
		ios_rpm_poison_note("page-base", page, page, 0);
		return 0;
	}
#endif
	block_t* block = page->local_free;
#ifdef FEX_IOS_HOST
	/* ml466 (#76): poisoned head — drop the whole chain, report empty. */
	if (UNEXPECTED(!ios_block_ptr_ok(block))) {
		ios_rpm_poison_note("page-head", page, block, 0);
		if (UNEXPECTED(!ios_block_ptr_ok(page))) return 0;   /* ml485 — see heap_pop_local_free */
		page->local_free = 0;
		page->local_free_count = 0;
		return 0;
	}
	{
		block_t* next = block->next;
		/* ml466 (#76): scribbled `next` — truncate before it becomes the head. */
		if (UNEXPECTED(next && !ios_block_ptr_ok(next))) {
			ios_rpm_poison_note("page-next", page, next, block);
			next = 0;
			if (UNEXPECTED(!ios_block_ptr_ok(page))) return 0;   /* ml485 */
			page->local_free_count = 1;
		}
		if (UNEXPECTED(!ios_block_ptr_ok(page))) return 0;       /* ml485 */
		page->local_free = next;
	}
#else
	page->local_free = block->next;
#endif
	--page->local_free_count;
	++page->block_used;
	return block;
}

static inline void
page_decommit_memory_pages(page_t* page) {
	if (page->is_decommitted)
		return;
	void* extra_page = pointer_offset(page, global_config.page_size);
	size_t extra_page_size = page_get_size(page) - global_config.page_size;
	global_memory_interface->memory_decommit(extra_page, extra_page_size);
	page->is_decommitted = 1;
}

static inline void
page_commit_memory_pages(page_t* page) {
	if (!page->is_decommitted)
		return;
	void* extra_page = pointer_offset(page, global_config.page_size);
	size_t extra_page_size = page_get_size(page) - global_config.page_size;
	global_memory_interface->memory_commit(extra_page, extra_page_size);
	page->is_decommitted = 0;
#if ENABLE_DECOMMIT
#if !defined(__APPLE__)
	// When page is recommitted, the blocks in the second memory page and forward
	// will be zeroed out by OS - take advantage in zalloc/calloc calls and make sure
	// blocks in first page is zeroed out
	void* first_page = pointer_offset(page, PAGE_HEADER_SIZE);
	memset(first_page, 0, global_config.page_size - PAGE_HEADER_SIZE);
	page->is_zero = 1;
#endif
#endif
}

/* iOS-Mythic ml607: page_available[] INVARIANT TRAP.
 *
 * ml606 crashed in rpmalloc with an entry that was not a page at all:
 *     x20 (page)      = 0x7c00000298   <- 0x298 INTO the default heap_t at 0x7c00000000,
 *                                         i.e. a pointer into its own local_free[] array
 *     x8  (size_class)= 0x07c06080     <- valid range is 0..SIZE_CLASS_COUNT-1 (0..116)
 *     ldr x10,[x9,x8,lsl #3] -> 0x8 + 0x7c06080*8 = 0x3e030408 = the exact fault address
 *
 * So page_available[] held a pointer into rpmalloc's own metadata. A narrow
 * "non-head page with prev == NULL" check would MISS this case entirely, which
 * is why the checks below are broader. This traps at the first observation of a
 * corrupt entry — at the mutation sites as well as the consumer — so we catch
 * the state closer to whoever wrote it.
 *
 * NOTE: catching a bad entry here does NOT prove rpmalloc wrote it. A wild
 * foreign writer or an overlapping mapping produces identical symptoms; that is
 * what the caller/owner fields in the dump are for.
 *
 * Report only — no repair. Repairing would erase the evidence and the protected
 * structures may be half-mutated anyway.
 */
/* ml615: RETURNS the bad-mask so callers can REFUSE TO MUTATE a corrupt list.
 * 0 = clean. Previously void ("report only"), which meant ml614 detected nothing
 * and then walked straight into the faulting store. */
static unsigned
rpm_avail_check(heap_t* heap, size_t size_class, page_t* page, int is_head, const char* op) {
	if (!heap)
		return 0;

	unsigned bad = 0;
	if (size_class >= SIZE_CLASS_COUNT)
		bad |= 1u;

	if (page) {
		/* ml607b: establish the pointer is PLAUSIBLE before touching any field.
		 * The previous version dereferenced page->size_class immediately, which
		 * on the ml606 signature would fault inside the probe itself — the trap
		 * would die before it could report. Pointer-plausibility first, fields
		 * only after. */
		const uintptr_t p = (uintptr_t)page;
		const int inside_heap = (p >= (uintptr_t)heap && p < ((uintptr_t)heap + sizeof(heap_t)));
		if (inside_heap)
			bad |= 2u; /* the exact ml606 signature: 0x298 into the heap_t */
		if (p & 0xfULL)
			bad |= 128u; /* page headers are at least 16-byte aligned */

		if (!bad) {
			if (page->size_class >= SIZE_CLASS_COUNT)
				bad |= 4u;
			if (!(bad & 1u) && page->size_class != (uint32_t)size_class)
				bad |= 8u;
			if (page->heap != heap)
				bad |= 16u;
			/* ml615: DERIVE the head instead of trusting the caller's promise.
			 *
			 * ml607b removed the prev check for page_available_to_free() because
			 * `is_head=0` callers legitimately have a non-NULL prev — but that
			 * threw away the invariant that actually matters, and ml614 crashed on
			 * exactly the case it would have caught:
			 *
			 *   head != page  &&  page->prev == NULL
			 *     -> page_available_to_free() takes the else-branch and executes
			 *        `page->prev->next = page->next`, i.e. STR x9,[x10,#0x30]
			 *        with x10 == 0  ->  fatal write to 0x30.
			 *
			 * `is_head` means "the caller promises this IS the head", never "a NULL
			 * prev is legitimate here". The real condition is positional, so
			 * compute the position.
			 *
			 * ml623: "head must have no prev" was NOT an invariant of this
			 * allocator until ml623 made it one. bad=0x20 with intact
			 * reciprocity (p.prev->next == page) was the allocator's own doing:
			 * the head-removal branches published `page_available[sc] = page->next`
			 * WITHOUT clearing the new head's prev, and page_full_to_available()
			 * re-published a page as head keeping the prev from its previous stint.
			 * Upstream never reads head->prev, so it was benign there — but here it
			 * drove page_available_to_free() into the "corrupt" branch on a healthy
			 * list, which then zeroed the whole head slot and orphaned the rest of
			 * the list (the ml614 shape). Both producers now clear prev, so the two
			 * positional bits below are real invariants and a hit is real
			 * corruption, not bookkeeping slack. */
			page_t* head = (size_class < SIZE_CLASS_COUNT) ? heap->page_available[size_class] : 0;
			if (head == page) {
				if (page->prev)
					bad |= 32u; /* head must have no prev */
			} else if (!page->prev) {
				bad |= 256u; /* NOT head but no prev => the ml614 fatal shape */
			}
			if (is_head && head != page)
				bad |= 512u; /* caller promised head; list disagrees */

			/* Link reciprocity + alignment, both directions. Validate the pointer
			 * before dereferencing it — a corrupt link must not fault the probe. */
			if (page->next) {
				if ((uintptr_t)page->next & 0xfULL)
					bad |= 1024u;
				else if (page->next->prev != page)
					bad |= 64u;
			}
			if (page->prev) {
				if ((uintptr_t)page->prev & 0xfULL)
					bad |= 2048u;
				else if (page->prev->next != page)
					bad |= 4096u;
			}
			if (page->next == page || page->prev == page)
				bad |= 8192u; /* self-link: ml614 had next pointing inside itself */
		}
	}
	if (!bad)
		return 0;

	static _Atomic(int) avail_logs;
	/* ml615: still return the mask when the log cap is hit — the CALLER must
	 * refuse to mutate regardless of whether we had budget to print. */
	if (atomic_fetch_add_explicit(&avail_logs, 1, memory_order_relaxed) >= 16)
		return bad;

	{
		char buf[256];
		const char* hexd = "0123456789abcdef";
		int i = 0, j;
		unsigned long w;
#define RPM_STR(s)                                     \
	do {                                               \
		const char* _s = (s);                          \
		while (*_s)                                    \
			buf[i++] = *_s++;                          \
	} while (0)
#define RPM_HEX(v)                                     \
	do {                                               \
		unsigned long long _v = (unsigned long long)(v); \
		for (j = 60; j >= 0; j -= 4)                   \
			buf[i++] = hexd[(_v >> j) & 0xf];          \
	} while (0)
		RPM_STR("[rpm-avail] ml607 CORRUPT op=");
		RPM_STR(op);
		RPM_STR(" bad=0x");
		RPM_HEX(bad);
		RPM_STR(" class=0x");
		RPM_HEX(size_class);
		RPM_STR(" page=0x");
		RPM_HEX((uintptr_t)page);
		RPM_STR(" heap=0x");
		RPM_HEX((uintptr_t)heap);
		if (page) {
			RPM_STR(" p.class=0x");
			RPM_HEX(page->size_class);
			RPM_STR(" p.heap=0x");
			RPM_HEX((uintptr_t)page->heap);
			RPM_STR(" p.prev=0x");
			RPM_HEX((uintptr_t)page->prev);
			RPM_STR(" p.next=0x");
			RPM_HEX((uintptr_t)page->next);
		}
		RPM_STR(" ra=0x");
		RPM_HEX((uintptr_t)__builtin_return_address(0));
		buf[i++] = '\n';
#undef RPM_STR
#undef RPM_HEX
		WriteFile(GetStdHandle((unsigned long)-12), buf, (unsigned long)i, &w, 0);
	}
	return bad;
}

/* The one thing a caller may do with a page the trap has rejected: take it off
 * the list WITHOUT reading or writing through either of its links. Once the trap
 * has fired, page->next and page->prev are unverified pointers, and a store
 * through one of them is exactly the wild write the trap exists to prevent.
 *
 * If the page genuinely is the head, the size class's available list is dropped
 * (published as 0), as upstream's ml615 guard does: the rest of that list is
 * quarantined -- no longer reachable from the heap, never walked again from the
 * head, its pages leaked rather than trusted. Otherwise the list is left exactly
 * as it is. The page's own links are cleared by the caller.
 *
 * (An earlier revision advanced the head to page->next and cleared next->prev to
 * keep the remainder reachable. That wrote through the link the trap had just
 * rejected, so it is gone: a leaked list is recoverable, a wild store is not.) */
static void
rpm_avail_quarantine(heap_t* heap, page_t* page) {
	if (page->size_class < SIZE_CLASS_COUNT && heap->page_available[page->size_class] == page)
		heap->page_available[page->size_class] = 0;
}

static void
page_available_to_free(page_t* page) {
	/* ml615: TRAP BEFORE MUTATION. ml614 checked, ignored the answer, and then
	 * executed `page->prev->next = ...` with prev == NULL — a fatal store to 0x30
	 * that killed the whole app. Continuing into a known-corrupt allocator list
	 * cannot do anything useful, so on any detected corruption we UNLINK NOTHING:
	 * the page is dropped from the available list without touching neighbours.
	 * That leaks one page. A leaked page is unambiguously better than a wild
	 * write through a corrupt link, and the [rpm-avail] dump above has already
	 * recorded the state for diagnosis. */
	/* ml623: a FULL page is not on the available list at all — page_available_to_full()
	 * unlinked it and cleared both links — so page_available[]'s invariants do not
	 * apply to it and there is nothing to unlink. This is reachable: a full page can
	 * have block_used dropped below block_count by page_adopt_thread_free_block_list()
	 * and then reach 0 on the next local free. The old code ran the trap (which would
	 * now report the harmless prev==0/not-head shape) and, before ml615, executed
	 * `page->prev->next = …` through the page's STALE prev — a wild write into a page
	 * that may already have been reused. Handle it explicitly instead. */
	unsigned bad = 0;
	if (UNEXPECTED(page->is_full != 0)) {
		page->is_full = 0;
		page->prev = 0;
		page->is_free = 1;
		page->is_zero = 0;
		heap_t* full_heap = page->heap;
		page->next = full_heap->page_free[page->page_type];
		full_heap->page_free[page->page_type] = page;
		if (++full_heap->page_free_commit_count[page->page_type] >= global_page_free_overflow[page->page_type])
			heap_page_free_decommit(full_heap, page->page_type, global_page_free_retain[page->page_type]);
		return;
	}
	bad = rpm_avail_check(page->heap, page->size_class, page, /*is_head=*/0, "to_free");
	rpmalloc_assert(page->is_decommitted == 0, "Page decommitted flag internal failure");
	heap_t* heap = page->heap;
	if (bad) {
		rpm_avail_quarantine(heap, page);
	} else if (heap->page_available[page->size_class] == page) {
		heap->page_available[page->size_class] = page->next;
		/* ml623: the new head must have no prev — see page_full_to_available(). */
		if (page->next)
			page->next->prev = 0;
	} else {
		page->prev->next = page->next;
		if (page->next)
			page->next->prev = page->prev;
	}
	page->prev = 0; /* ml623: a page off the available list carries no stale prev */
	page->is_free = 1;
	page->is_zero = 0;
	page->next = heap->page_free[page->page_type];
	heap->page_free[page->page_type] = page;
	if (++heap->page_free_commit_count[page->page_type] >= global_page_free_overflow[page->page_type])
		heap_page_free_decommit(heap, page->page_type, global_page_free_retain[page->page_type]);
}

static void
page_full_to_available(page_t* page) {
	rpmalloc_assert(page->is_full == 1, "Page full flag internal failure");
	rpmalloc_assert(page->is_decommitted == 0, "Page decommitted flag internal failure");
	heap_t* heap = page->heap;
	page->next = heap->page_available[page->size_class];
	/* ml623: the page is being published as the HEAD, so its prev must be NULL.
	 * This used to keep whatever prev the page carried from its previous stint in
	 * the list (available_to_full does not clear it), which made
	 * "head with a non-NULL prev" a normal state — the bad=0x20 false positive
	 * the ml607 trap kept reporting, and which drove page_available_to_free()
	 * into its "corrupt" branch on a perfectly healthy list. */
	page->prev = 0;
	if (page->next)
		page->next->prev = page;
	heap->page_available[page->size_class] = page;
	page->is_full = 0;
	if (page->has_aligned_block == 0)
		page->generic_free = 0;
}

static void
page_full_to_free_on_new_heap(page_t* page, heap_t* heap) {
	rpmalloc_assert(heap->id, "Page full to free on default heap");
	rpmalloc_assert(page->is_full == 1, "Page full flag internal failure");
	rpmalloc_assert(page->is_decommitted == 0, "Page decommitted flag internal failure");
	page->is_full = 0;
	page->is_free = 1;
	page->heap = heap;
	atomic_store_explicit(&page->thread_free, 0, memory_order_release);
	page->next = heap->page_free[page->page_type];
	heap->page_free[page->page_type] = page;
	if (++heap->page_free_commit_count[page->page_type] >= global_page_free_overflow[page->page_type])
		heap_page_free_decommit(heap, page->page_type, global_page_free_retain[page->page_type]);
}

static void
page_available_to_full(page_t* page) {
	heap_t* heap = page->heap;
	unsigned bad = rpm_avail_check(page->heap, page->size_class, page, /*is_head=*/0, "to_full");
	if (UNEXPECTED(bad != 0)) {
		/* ml623: same policy as page_available_to_free(). */
		rpm_avail_quarantine(heap, page);
	} else if (heap->page_available[page->size_class] == page) {
		heap->page_available[page->size_class] = page->next;
		/* ml623: the new head must have no prev. */
		if (page->next)
			page->next->prev = 0;
	} else {
		page->prev->next = page->next;
		if (page->next)
			page->next->prev = page->prev;
	}
	page->prev = 0; /* ml623: off the available list => no stale prev */
	page->next = 0;
	page->is_full = 1;
	page->is_zero = 0;
	page->generic_free = 1;
}

static inline void
page_put_local_free_block(page_t* page, block_t* block) {
	block->next = page->local_free;
	page->local_free = block;
	++page->local_free_count;
	if (UNEXPECTED(--page->block_used == 0)) {
		page_available_to_free(page);
	} else if (UNEXPECTED(page->is_full != 0)) {
		page_full_to_available(page);
	}
}

static NOINLINE void
page_adopt_thread_free_block_list(page_t* page) {
	if (page->local_free)
		return;
	unsigned long long thread_free = atomic_load_explicit(&page->thread_free, memory_order_acquire);
	if (thread_free != 0) {
		// Other threads can only replace with another valid list head, this will never change to 0 in other threads
		while (!atomic_compare_exchange_weak_explicit(&page->thread_free, &thread_free, 0, memory_order_acquire,
		                                              memory_order_relaxed))
			wait_spin();
		page->local_free_count = page_block_from_thread_free_list(page, thread_free, &page->local_free);
		rpmalloc_assert(page->local_free_count <= page->block_used, "Page thread free list count internal failure");
		page->block_used -= page->local_free_count;
	}
}

/* iOS-Mythic ml622: REMOTE-FREE CAS WATCHDOG.
 *
 * ml621 froze with two threads burning CPU forever in this function's CAS loops:
 *   CrBrowserMain cpu=908  PC=libarm64ecfex+0x1b999c  atomic=0x7c35630040
 *   Compositor    cpu=991  PC=libarm64ecfex+0x1b9940  atomic=0x7c35610040
 * on NEIGHBOURING rpmalloc pages. CrBrowserMain entered this loop holding the
 * shared CodeInvalidationMutex, so a writer queued behind it, write-priority
 * blocked every later reader, and ALL JIT compilation stopped process-wide. Same
 * visible wedge as ml611/ml617 but a completely different cause — nothing died,
 * nothing leaked a hold; a live thread simply never left the allocator.
 *
 * ⛔⛔ NOTHING HERE MAY FORMAT OR EMIT. LogMan/fmt/dprintf/stdio can allocate or
 * lock, which would re-enter rpmalloc at exactly the point it is already
 * compromised. ml620 died because a probe formatted inside a corruption path.
 * So: copy scalars into ONE fixed POD, publish with an atomic ready flag, and let
 * an out-of-band sampler print it later. No ring, no allocator-backed storage.
 *
 * The counters split the three causes, which need different fixes:
 *   changed   — the atomic really changed under us: real contention, page reuse,
 *               OR a foreign writer. NOT automatically "legitimate contention".
 *   unchanged — expected value identical across the failure: spurious LDAXR/STLXR
 *               exclusive-monitor loss (weak-CAS livelock).
 *   invalid   — decoded index/count or block address does not fit the page:
 *               stale/duplicate page lifetime.
 * ⛔ Do NOT jump to a strong CAS on this evidence: the two spinning threads were
 * on DIFFERENT atomics, so they were not contending with each other. */
struct rpm_cas_snapshot {
	unsigned long long page_addr, block_addr, heap_addr, owner_teb;
	unsigned long long prev_token, cur_token, ret_addr, atomic_addr;
	unsigned int size_class, page_type, block_index, list_size;
	unsigned int fail_changed, fail_unchanged, fail_invalid, quarantined;
	unsigned int block_count, block_used, is_full, which_loop;
};
static struct rpm_cas_snapshot rpm_cas_snap;
static _Atomic(int) rpm_cas_snap_ready;
static _Atomic(int) rpm_cas_snap_taken;

/* Drained by the periodic sampler OUTSIDE rpmalloc. Returns 1 if a snapshot was
 * copied out. Caller formats; this function must stay allocation-free. */
int
rpm_cas_snapshot_take(struct rpm_cas_snapshot* out) {
	if (!atomic_load_explicit(&rpm_cas_snap_ready, memory_order_acquire))
		return 0;
	*out = rpm_cas_snap;
	atomic_store_explicit(&rpm_cas_snap_ready, 0, memory_order_release);
	return 1;
}

/* One publish per run by default: the first extreme spin is the informative one,
 * and a second would overwrite it while the sampler is copying. */
static void
rpm_cas_publish(page_t* page, block_t* block, unsigned long long prev, unsigned long long cur,
                unsigned int idx, unsigned int lsize, unsigned int changed, unsigned int unchanged,
                unsigned int invalid, unsigned int quarantined, unsigned int which, const void* atomic_addr) {
	int expected = 0;
	if (!atomic_compare_exchange_strong_explicit(&rpm_cas_snap_taken, &expected, 1, memory_order_acq_rel,
	                                             memory_order_relaxed))
		return;
	rpm_cas_snap.page_addr   = (unsigned long long)(uintptr_t)page;
	rpm_cas_snap.block_addr  = (unsigned long long)(uintptr_t)block;
	rpm_cas_snap.heap_addr   = (unsigned long long)(uintptr_t)(page ? page->heap : 0);
	rpm_cas_snap.owner_teb   = 0;
#if defined(__aarch64__) || defined(_M_ARM64)
	{ unsigned long long t = 0; __asm__ volatile("mov %0, x18" : "=r"(t)); rpm_cas_snap.owner_teb = t; }
#endif
	rpm_cas_snap.prev_token  = prev;
	rpm_cas_snap.cur_token   = cur;
	rpm_cas_snap.ret_addr    = (unsigned long long)(uintptr_t)__builtin_return_address(0);
	rpm_cas_snap.atomic_addr = (unsigned long long)(uintptr_t)atomic_addr;
	rpm_cas_snap.size_class  = page ? (unsigned int)page->size_class : 0u;
	rpm_cas_snap.page_type   = page ? (unsigned int)page->page_type : 0u;
	rpm_cas_snap.block_index = idx;
	rpm_cas_snap.list_size   = lsize;
	rpm_cas_snap.fail_changed   = changed;
	rpm_cas_snap.fail_unchanged = unchanged;
	rpm_cas_snap.fail_invalid   = invalid;
	rpm_cas_snap.quarantined    = quarantined;
	rpm_cas_snap.block_count = page ? (unsigned int)page->block_count : 0u;
	rpm_cas_snap.block_used  = page ? (unsigned int)page->block_used : 0u;
	rpm_cas_snap.is_full     = page ? (unsigned int)page->is_full : 0u;
	rpm_cas_snap.which_loop  = which;
	atomic_store_explicit(&rpm_cas_snap_ready, 1, memory_order_release);
}

#define RPM_CAS_REPORT_AT   (1u << 22)  /* ~4M failures: far past any real contention */
#define RPM_CAS_QUARANTINE  (1u << 24)  /* ~16M: give up, leak this one block */

static NOINLINE void
page_put_thread_free_block(page_t* page, block_t* block) {
	atomic_thread_fence(memory_order_acquire);
	if (page->is_full) {
		// Page is full, put the block in the heap thread free list instead, otherwise
		// the heap will not pick up the free blocks until a thread local free happens
		heap_t* heap = page->heap;
		uintptr_t prev_head = atomic_load_explicit(&heap->thread_free[page->page_type], memory_order_relaxed);
		unsigned int f_changed = 0, f_unchanged = 0, f_total = 0;
		block->next = (void*)prev_head;
		while (!atomic_compare_exchange_weak_explicit(&heap->thread_free[page->page_type], &prev_head, (uintptr_t)block,
		                                              memory_order_release, memory_order_relaxed)) {
			/* ml622: classify BEFORE re-reading — prev_head has already been updated
			 * by the failed CAS, so compare it against what we last tried. */
			uintptr_t was = (uintptr_t)block->next;
			if (prev_head != was)
				++f_changed;
			else
				++f_unchanged;
			if (++f_total == RPM_CAS_REPORT_AT)
				rpm_cas_publish(page, block, (unsigned long long)was, (unsigned long long)prev_head, 0u, 0u,
				                f_changed, f_unchanged, 0u, 0u, 1u, &heap->thread_free[page->page_type]);
			if (f_total >= RPM_CAS_QUARANTINE) {
				/* Containment: never published, so the block is simply LEAKED — it is
				 * not exposed for reuse. Vastly preferable to spinning forever while
				 * holding CodeInvalidationMutex and stopping all JIT (ml621). */
				rpm_cas_publish(page, block, (unsigned long long)was, (unsigned long long)prev_head, 0u, 0u,
				                f_changed, f_unchanged, 0u, 1u, 1u, &heap->thread_free[page->page_type]);
				return;
			}
			block->next = (void*)prev_head;
			wait_spin();
		}
	} else {
		unsigned long long prev_thread_free = atomic_load_explicit(&page->thread_free, memory_order_relaxed);
		uint32_t block_index = page_block_index(page, block);
		rpmalloc_assert(page_block(page, block_index) == block, "Block pointer is not aligned to start of block");
		uint32_t list_size = page_block_from_thread_free_list(page, prev_thread_free, &block->next) + 1;
		uint64_t thread_free = page_block_to_thread_free_list(page, block_index, list_size);
		unsigned int f_changed = 0, f_unchanged = 0, f_invalid = 0, f_total = 0;
		while (!atomic_compare_exchange_weak_explicit(&page->thread_free, &prev_thread_free, thread_free,
		                                              memory_order_release, memory_order_relaxed)) {
			/* ml622: prev_thread_free now holds what was ACTUALLY there. */
			unsigned long long seen = (unsigned long long)prev_thread_free;
			if (seen != (unsigned long long)thread_free)
				++f_changed;
			else
				++f_unchanged;
			/* Validate the decoded token against the page before trusting it: a
			 * list_size past block_count, or an index outside the page, means stale
			 * or duplicate page lifetime rather than contention. */
			if ((block_index >= page->block_count) || (list_size > page->block_count))
				++f_invalid;
			if (++f_total == RPM_CAS_REPORT_AT)
				rpm_cas_publish(page, block, seen, (unsigned long long)thread_free, block_index, list_size,
				                f_changed, f_unchanged, f_invalid, 0u, 2u, &page->thread_free);
			if (f_total >= RPM_CAS_QUARANTINE) {
				rpm_cas_publish(page, block, seen, (unsigned long long)thread_free, block_index, list_size,
				                f_changed, f_unchanged, f_invalid, 1u, 2u, &page->thread_free);
				return; /* leak this one block; see loop-1 comment */
			}
			list_size = page_block_from_thread_free_list(page, prev_thread_free, &block->next) + 1;
			thread_free = page_block_to_thread_free_list(page, block_index, list_size);
			wait_spin();
		}
	}
}

static void
page_push_local_free_to_heap(page_t* page) {
	// Push the page free list as the fast track list of free blocks for heap
	page->heap->local_free[page->size_class] = page->local_free;
	page->block_used += page->local_free_count;
	page->local_free = 0;
	page->local_free_count = 0;
}

static NOINLINE void*
page_initialize_blocks(page_t* page) {
	rpmalloc_assert(page->block_initialized < page->block_count, "Block initialization internal failure");
	block_t* block = page_block(page, page->block_initialized);
	++page->block_initialized;
	++page->block_used;

	if ((page->page_type == PAGE_SMALL) && (page->block_size < (global_config.page_size >> 1))) {
		// Link up until next memory page in free list
		void* memory_page_start = (void*)((uintptr_t)block & ~(uintptr_t)(global_config.page_size - 1));
		void* memory_page_next = pointer_offset(memory_page_start, global_config.page_size);
		block_t* free_block = pointer_offset(block, page->block_size);
		block_t* first_block = free_block;
		block_t* last_block = free_block;
		uint32_t list_count = 0;
		uint32_t max_list_count = page->block_count - page->block_initialized;
		while (((void*)free_block < memory_page_next) && (list_count < max_list_count)) {
			last_block = free_block;
			free_block->next = pointer_offset(free_block, page->block_size);
			free_block = free_block->next;
			++list_count;
		}
		if (list_count) {
			last_block->next = 0;
			page->local_free = first_block;
			page->block_initialized += list_count;
			page->local_free_count = list_count;
		}
	}

	return block;
}

static inline RPMALLOC_ALLOCATOR void*
page_allocate_block(page_t* page, unsigned int zero) {
	unsigned int is_zero = 0;
	block_t* block = (page->local_free != 0) ? page_get_local_free_block(page) : 0;
	if (UNEXPECTED(block == 0)) {
		if (atomic_load_explicit(&page->thread_free, memory_order_acquire) != 0) {
			page_adopt_thread_free_block_list(page);
			block = (page->local_free != 0) ? page_get_local_free_block(page) : 0;
		}
		if (block == 0) {
			block = page_initialize_blocks(page);
			is_zero = page->is_zero;
		}
	}

	rpmalloc_assert(page->block_used <= page->block_count, "Page block use counter out of sync");
	if (page->local_free && !page->heap->local_free[page->size_class])
		page_push_local_free_to_heap(page);

	// The page might be full when free list has been pushed to heap local free list,
	// check if there is a thread free list to adopt
	if (page->block_used == page->block_count)
		page_adopt_thread_free_block_list(page);

	if (page->block_used == page->block_count) {
		// Page is now fully utilized
		rpmalloc_assert(!page->is_full, "Page block use counter out of sync with full flag");
		page_available_to_full(page);
	}

	if (zero) {
		if (!is_zero)
			memset(block, 0, page->block_size);
		else
			*(uintptr_t*)block = 0;
	}

	return block;
}

////////////
///
/// Span interface
///
//////

static inline int
span_is_thread_heap(span_t* span) {
#if RPMALLOC_FIRST_CLASS_HEAPS
	return (!span->heap->owner_thread || (span->heap->owner_thread == get_thread_id()));
#else
	return (span->heap->owner_thread == get_thread_id());
#endif
}

static inline page_t*
span_get_page_from_block(span_t* span, void* block) {
	return (page_t*)((uintptr_t)block & span->page_address_mask);
}

//! Find or allocate a page from the given span
static inline page_t*
span_allocate_page(span_t* span) {
	// Allocate path, initialize a new chunk of memory for a page in the given span
	rpmalloc_assert(span->page_initialized < span->page_count, "Page initialization internal failure");
	heap_t* heap = span->heap;
	page_t* page = pointer_offset(span, span->page_size * span->page_initialized);

#if ENABLE_DECOMMIT
	// The first page is always committed on initial span map of memory
	if (span->page_initialized)
		global_memory_interface->memory_commit(page, span->page_size);
#endif
	++span->page_initialized;

	page->page_type = span->page_type;
	page->is_zero = 1;
	page->heap = heap;
	rpmalloc_assert(page_is_thread_heap(page), "Page owner thread mismatch");

	if (span->page_initialized == span->page_count) {
		// Span fully utilized
		rpmalloc_assert(span == heap->span_partial[span->page_type], "Span partial tracking out of sync");
		heap->span_partial[span->page_type] = 0;

		span->next = heap->span_used[span->page_type];
		heap->span_used[span->page_type] = span;
	}

	return page;
}

static NOINLINE void
span_deallocate_block(span_t* span, page_t* page, void* block) {
	if (UNEXPECTED(page->page_type == PAGE_HUGE)) {
		global_memory_interface->memory_unmap(span, span->offset, span->mapped_size);
		return;
	}

	if (page->has_aligned_block) {
		// Realign pointer to block start
		block = page_block_realign(page, block);
	}

	int is_thread_local = page_is_thread_heap(page);
	if (EXPECTED(is_thread_local != 0)) {
		page_put_local_free_block(page, block);
	} else {
		// Multithreaded deallocation, push to deferred deallocation list.
		page_put_thread_free_block(page, block);
	}
}

////////////
///
/// Block interface
///
//////

static inline span_t*
block_get_span(block_t* block) {
	return (span_t*)((uintptr_t)block & SPAN_MASK);
}

static inline void
block_deallocate(block_t* block) {
	span_t* span = (span_t*)((uintptr_t)block & SPAN_MASK);
	page_t* page = span_get_page_from_block(span, block);
	const int is_thread_local = page_is_thread_heap(page);

	// Optimized path for thread local free with non-huge block in page
	// that has no aligned blocks
	if (EXPECTED(is_thread_local != 0)) {
		if (EXPECTED(page->generic_free == 0)) {
			// Page is not huge, not full and has no aligned block - fast path
			block->next = page->local_free;
			page->local_free = block;
			++page->local_free_count;
			if (UNEXPECTED(--page->block_used == 0))
				page_available_to_free(page);
		} else {
			span_deallocate_block(span, page, block);
		}
	} else {
		span_deallocate_block(span, page, block);
	}
}

static inline size_t
block_usable_size(block_t* block) {
	span_t* span = (span_t*)((uintptr_t)block & SPAN_MASK);
	if (EXPECTED(span->page_type <= PAGE_LARGE)) {
		page_t* page = span_get_page_from_block(span, block);
		void* blocks_start = pointer_offset(page, PAGE_HEADER_SIZE);
		return page->block_size - ((size_t)pointer_diff(block, blocks_start) % page->block_size);
	} else {
		return ((size_t)span->page_size * (size_t)span->page_count) - (size_t)pointer_diff(block, span);
	}
}

////////////
///
/// Heap interface
///
//////

static inline void
heap_lock_acquire(void) {
	uintptr_t lock = 0;
	uintptr_t this_lock = get_thread_id();
	while (!atomic_compare_exchange_strong(&global_heap_lock, &lock, this_lock)) {
		lock = 0;
		wait_spin();
	}
}

static inline void
heap_lock_release(void) {
	rpmalloc_assert((uintptr_t)atomic_load_explicit(&global_heap_lock, memory_order_relaxed) == get_thread_id(),
	                "Bad heap lock");
	atomic_store_explicit(&global_heap_lock, 0, memory_order_release);
}

static inline heap_t*
heap_initialize(void* block) {
	heap_t* heap = block;
	memset_const(heap, 0, sizeof(heap_t));
	heap->id = 1 + atomic_fetch_add_explicit(&global_heap_id, 1, memory_order_relaxed);
	return heap;
}

static heap_t*
heap_allocate_new(void) {
	if (!global_config.page_size)
		rpmalloc_initialize(0);
	size_t heap_size = get_page_aligned_size(sizeof(heap_t));
	size_t offset = 0;
	size_t mapped_size = 0;
	block_t* block = global_memory_interface->memory_map(heap_size, 0, &offset, &mapped_size);
#if ENABLE_DECOMMIT
	global_memory_interface->memory_commit(block, heap_size);
#endif
	heap_t* heap = heap_initialize((void*)block);
	heap->offset = (uint32_t)offset;
	heap->mapped_size = mapped_size;
#if ENABLE_STATISTICS
	atomic_fetch_add_explicit(&global_statistics.heap_count, 1, memory_order_relaxed);
#endif
	return heap;
}

static void
heap_unmap(heap_t* heap) {
	global_memory_interface->memory_unmap(heap, heap->offset, heap->mapped_size);
}

static heap_t*
heap_allocate(int first_class) {
	heap_t* heap = 0;
	if (!first_class) {
		heap_lock_acquire();
		heap = global_heap_queue;
		global_heap_queue = heap ? heap->next : 0;
		heap_lock_release();
	}
	if (!heap)
		heap = heap_allocate_new();
	if (heap) {
		uintptr_t current_thread_id = get_thread_id();
		heap_lock_acquire();
		heap->next = global_heap_used;
		heap->prev = 0;
		if (global_heap_used)
			global_heap_used->prev = heap;
		global_heap_used = heap;
		heap_lock_release();
		heap->owner_thread = current_thread_id;
	}
	return heap;
}

static inline void
heap_release(heap_t* heap) {
	heap_lock_acquire();
	if (heap->prev)
		heap->prev->next = heap->next;
	if (heap->next)
		heap->next->prev = heap->prev;
	if (global_heap_used == heap)
		global_heap_used = heap->next;
	heap->next = global_heap_queue;
	global_heap_queue = heap;
	heap_lock_release();
}

static void
heap_page_free_decommit(heap_t* heap, uint32_t page_type, uint32_t page_retain_count) {
	page_t* page = heap->page_free[page_type];
	while (page && page_retain_count) {
		page = page->next;
		--page_retain_count;
	}
	while (page && (page->is_decommitted == 0)) {
		page_decommit_memory_pages(page);
		--heap->page_free_commit_count[page_type];
		page = page->next;
	}
}

static inline void
heap_make_free_page_available(heap_t* heap, uint32_t size_class, page_t* page) {
	page->size_class = size_class;
	page->block_size = global_size_class[size_class].block_size;
	page->block_count = global_size_class[size_class].block_count;
	page->block_used = 0;
	page->block_initialized = 0;
	page->local_free = 0;
	page->local_free_count = 0;
	page->is_full = 0;
	page->is_free = 0;
	page->has_aligned_block = 0;
	page->generic_free = 0;
	page->heap = heap;
	rpm_avail_check(heap, size_class, heap->page_available[size_class], /*is_head=*/1, "head-read");
	page_t* head = heap->page_available[size_class];
	page->next = head;
	page->prev = 0;
	atomic_store_explicit(&page->thread_free, 0, memory_order_release);
	if (head)
		head->prev = page;
	heap->page_available[size_class] = page;
	if (page->is_decommitted)
		page_commit_memory_pages(page);
}

//! Find or allocate a span for the given page type with the given size class
static inline span_t*
heap_get_span(heap_t* heap, page_type_t page_type) {
	// Fast path, available span for given page type
	if (EXPECTED(heap->span_partial[page_type] != 0))
		return heap->span_partial[page_type];

	// Fallback path, map more memory
	size_t offset = 0;
	size_t mapped_size = 0;
	span_t* span = global_memory_interface->memory_map(SPAN_SIZE, SPAN_SIZE, &offset, &mapped_size);
	if (EXPECTED(span != 0)) {
		uint32_t page_count = 0;
		uint32_t page_size = 0;
		uintptr_t page_address_mask = 0;
		if (page_type == PAGE_SMALL) {
			page_count = SPAN_SIZE / SMALL_PAGE_SIZE;
			page_size = SMALL_PAGE_SIZE;
			page_address_mask = SMALL_PAGE_MASK;
		} else if (page_type == PAGE_MEDIUM) {
			page_count = SPAN_SIZE / MEDIUM_PAGE_SIZE;
			page_size = MEDIUM_PAGE_SIZE;
			page_address_mask = MEDIUM_PAGE_MASK;
		} else {
			page_count = SPAN_SIZE / LARGE_PAGE_SIZE;
			page_size = LARGE_PAGE_SIZE;
			page_address_mask = LARGE_PAGE_MASK;
		}
#if ENABLE_DECOMMIT
		global_memory_interface->memory_commit(span, page_size);
#endif
		span->heap = heap;
		span->page_type = page_type;
		span->page_count = page_count;
		span->page_size = page_size;
		span->page_address_mask = page_address_mask;
		span->offset = (uint32_t)offset;
		span->mapped_size = mapped_size;

		heap->span_partial[page_type] = span;
	}

	return span;
}

static page_t*
heap_get_page(heap_t* heap, uint32_t size_class);

static void
block_deallocate(block_t* block);

static page_t*
heap_get_page_generic(heap_t* heap, uint32_t size_class) {
	page_type_t page_type = get_page_type(size_class);

	// Check if there is a free page from multithreaded deallocations
	uintptr_t block_mt = atomic_load_explicit(&heap->thread_free[page_type], memory_order_acquire);
	if (UNEXPECTED(block_mt != 0)) {
#ifdef FEX_IOS_HOST
		/* iOS-Mythic ml416 (#60): if heap->owner_thread != this thread's TEB,
		 * every block_deallocate below classifies the block as remote
		 * (page_is_thread_heap fails) and page_put_thread_free_block pushes it
		 * straight back onto the list being drained — the drain never
		 * converges. Repairing the stamp makes the frees local and the walk
		 * converge.
		 *
		 * ml463 (#76): the ml416 repair was a PLAIN STORE, and "ownership is
		 * by-construction this thread's" is FALSE for the TLS-less/orphan
		 * heaps it actually fires on (both ml460 and ml462 breadcrumbs show
		 * old_owner=0): several threads can reach this drain on the SAME heap
		 * and all claim it, after which each treats remote frees as local and
		 * they mutate local_free[]/page counters concurrently — the ml460 run
		 * died with x86 payload bytes over local_free[1], the ml462 run with
		 * a torn u32 counter pair in the same slot, both on repaired heaps
		 * ([census-hold] RPMALLOC-REPAIR breadcrumbs on the exact heap).
		 * Claim by CAS instead, BEFORE consuming the thread_free list (the
		 * old order took the list first — a losing claimant would have leaked
		 * every block on it). The loser leaves the list for the winner and
		 * falls through to the non-drain paths. This closes the ownership
		 * ping-pong; [rpm-clash] visibility tells us how often contention
		 * actually happens (frequent hits = the fallback-heap sharing itself
		 * needs a lock, a bigger fix). */
		{
			uintptr_t self_teb = get_thread_id();
			uintptr_t cur_owner = heap->owner_thread;
			if (cur_owner != self_teb) {
				if (!__atomic_compare_exchange_n(&heap->owner_thread, &cur_owner, self_teb, 0,
				                                 __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
					static _Atomic(int) clash_count;
					int cc = atomic_fetch_add_explicit(&clash_count, 1, memory_order_relaxed);
					if (cc < 16) {
						if (self_teb > 0x10000 && !(self_teb & 0xfff)) {
							((void**)self_teb)[0x16d8 / 8] = (void*)cur_owner;
							((void**)self_teb)[0x16e0 / 8] = (void*)((uintptr_t)heap | 1); /* low bit = lost claim */
						}
					}
					goto ios_skip_thread_free_drain;
				}
				if (self_teb > 0x10000 && !(self_teb & 0xfff)) {
					((void**)self_teb)[0x16d8 / 8] = (void*)cur_owner;
					((void**)self_teb)[0x16e0 / 8] = (void*)heap;
				}
			}
		}
#endif
		while (!atomic_compare_exchange_weak_explicit(&heap->thread_free[page_type], &block_mt, 0, memory_order_release,
		                                              memory_order_relaxed)) {
			wait_spin();
		}
		block_t* block = (void*)block_mt;
		while (block) {
#ifdef FEX_IOS_HOST
			/* ml466 (#76): poisoned node in the deferred-free chain — stop the
			 * walk before dereferencing it; the truncated tail leaks. */
			if (UNEXPECTED(!ios_block_ptr_ok(block))) {
				ios_rpm_poison_note("hdrain", heap, block, 0);
				break;
			}
#endif
			block_t* next_block = block->next;
			block_deallocate(block);
			block = next_block;
		}
		// Retry after processing deferred thread frees
		return heap_get_page(heap, size_class);
	}
#ifdef FEX_IOS_HOST
ios_skip_thread_free_drain:;
#endif

	// Check if there is a free page
	page_t* page = heap->page_free[page_type];
	if (EXPECTED(page != 0)) {
		heap->page_free[page_type] = page->next;
		if (page->is_decommitted == 0) {
			rpmalloc_assert(heap->page_free_commit_count[page_type] > 0, "Free committed page count out of sync");
			--heap->page_free_commit_count[page_type];
		}
		heap_make_free_page_available(heap, size_class, page);
		return page;
	}
	rpmalloc_assert(heap->page_free_commit_count[page_type] == 0, "Free committed page count out of sync");

	if (heap->id == 0) {
		// Thread has not yet initialized, assign heap and try again
		rpmalloc_initialize(0);
		return heap_get_page(get_thread_heap(), size_class);
	}

	// Fallback path, find or allocate span for given size class
	// If thread was not initialized, the heap for the new span
	// will be different from the local heap variable in this scope
	// (which is the default heap) - so use span page heap instead
	span_t* span = heap_get_span(heap, page_type);
	if (EXPECTED(span != 0)) {
		page = span_allocate_page(span);
		heap_make_free_page_available(page->heap, size_class, page);
	}

	return page;
}

//! Find or allocate a page for the given size class
static page_t*
heap_get_page(heap_t* heap, uint32_t size_class) {
	// Fast path, available page for given size class
	page_t* page = heap->page_available[size_class];
	rpm_avail_check(heap, size_class, page, /*is_head=*/1, "consume");
	if (EXPECTED(page != 0))
		return page;
	return heap_get_page_generic(heap, size_class);
}

//! Pop a block from the heap local free list
static inline RPMALLOC_ALLOCATOR void*
heap_pop_local_free(heap_t* heap, uint32_t size_class) {
	block_t** free_list = heap->local_free + size_class;
#ifdef FEX_IOS_HOST
	/* ml484 (#88): ml466's guard validated the BLOCK but then read and wrote
	 * through `heap->local_free[size_class]` — an address derived from an
	 * UNVALIDATED heap. ml483 died exactly there: `str xzr, [x21, x20, lsl #3]`
	 * (heap_allocate_block_aligned+…, right after ios_rpm_poison_note) faulted
	 * writing to 0x5183a58a7a8188 — a wild address far outside the 39-bit VA,
	 * i.e. the HEAP pointer itself was garbage, not just the block. 65 repeats,
	 * then the webhelper died c0000005 with the login window already up.
	 * Validate the owner before touching it; a bad heap means this thread's
	 * cache is unusable, so report empty and let the caller map fresh. */
	if (UNEXPECTED(!ios_block_ptr_ok(free_list))) {
		ios_rpm_poison_note("heap-base", heap, free_list, 0);
		return 0;
	}
#endif
	block_t* block = *free_list;
#ifdef FEX_IOS_HOST
	/* ml466 (#76): all four crashes were THIS pop dereferencing a poisoned
	 * local_free slot. Amputate instead of faulting. */
	if (EXPECTED(block != 0)) {
		if (UNEXPECTED(!ios_block_ptr_ok(block))) {
			ios_rpm_poison_note("heap-head", heap, block, 0);
			/* ml485 (#88): re-derive and re-validate the destination AFTER the
			 * call, with nothing between the check and the store. ml484 added
			 * an entry check and ml484's run STILL died one instruction after
			 * ios_rpm_poison_note — `str xzr, [x20]` in the heap-next branch,
			 * writing to 0xa316531373030 (ASCII "\n1e1700"). local_free is an
			 * ARRAY, so free_list is pure arithmetic on `heap`; a wild
			 * destination therefore means the compiler rematerialised it from a
			 * spilled/reloaded `heap` that the corrupter had scribbled while we
			 * were inside the note. An entry-only check cannot cover that. */
			block_t** dst = heap->local_free + size_class;
			if (UNEXPECTED(!ios_block_ptr_ok(dst))) return 0;
			*dst = 0;
			return 0;
		}
		block_t* next = block->next;
		if (UNEXPECTED(next && !ios_block_ptr_ok(next))) {
			ios_rpm_poison_note("heap-next", heap, next, block);
			next = 0;
		}
		{
			block_t** dst = heap->local_free + size_class;   /* ml485 — see above */
			if (UNEXPECTED(!ios_block_ptr_ok(dst))) return 0;
			*dst = next;
		}
	}
#else
	if (EXPECTED(block != 0))
		*free_list = block->next;
#endif
	return block;
}

//! Generic allocation path from heap pages, spans or new mapping
static NOINLINE RPMALLOC_ALLOCATOR void*
heap_allocate_block_small_to_large(heap_t* heap, uint32_t size_class, unsigned int zero) {
	page_t* page = heap_get_page(heap, size_class);
	if (EXPECTED(page != 0))
		return page_allocate_block(page, zero);
	return 0;
}

//! Generic allocation path from heap pages, spans or new mapping
static NOINLINE RPMALLOC_ALLOCATOR void*
heap_allocate_block_huge(heap_t* heap, size_t size, unsigned int zero) {
	if (heap->id == 0) {
		rpmalloc_initialize(0);
		heap = get_thread_heap();
	}
	size_t alloc_size = get_page_aligned_size(size + SPAN_HEADER_SIZE);
	size_t offset = 0;
	size_t mapped_size = 0;
	void* block = global_memory_interface->memory_map(alloc_size, SPAN_SIZE, &offset, &mapped_size);
	if (block) {
		span_t* span = block;
#if ENABLE_DECOMMIT
		global_memory_interface->memory_commit(span, alloc_size);
#endif
		span->heap = heap;
		span->page_type = PAGE_HUGE;
		span->page_size = (uint32_t)global_config.page_size;
		span->page_count = (uint32_t)(alloc_size / global_config.page_size);
		span->page_address_mask = LARGE_PAGE_MASK;
		span->offset = (uint32_t)offset;
		span->mapped_size = mapped_size;
		span->page.heap = heap;
		span->page.is_full = 1;
		span->page.generic_free = 1;
		span->page.page_type = PAGE_HUGE;
		// Keep track of span if first class heap
		if (!heap->owner_thread) {
			span->next = heap->span_used[PAGE_HUGE];
			heap->span_used[PAGE_HUGE] = span;
		}
		void* ptr = pointer_offset(block, SPAN_HEADER_SIZE);
		if (zero)
			memset(ptr, 0, size);
		return ptr;
	}
	return 0;
}

static RPMALLOC_ALLOCATOR NOINLINE void*
heap_allocate_block_generic(heap_t* heap, size_t size, unsigned int zero) {
	uint32_t size_class = get_size_class(size);
	if (EXPECTED(size_class < SIZE_CLASS_COUNT)) {
		block_t* block = heap_pop_local_free(heap, size_class);
		if (EXPECTED(block != 0)) {
			// Fast track with small block available in heap level local free list
			if (zero)
				memset(block, 0, global_size_class[size_class].block_size);
			return block;
		}

		return heap_allocate_block_small_to_large(heap, size_class, zero);
	}

	return heap_allocate_block_huge(heap, size, zero);
}

//! Find or allocate a block of the given size
static inline RPMALLOC_ALLOCATOR void*
heap_allocate_block(heap_t* heap, size_t size, unsigned int zero) {
	if (size <= (SMALL_GRANULARITY * 64)) {
		uint32_t size_class = get_size_class_tiny(size);
		block_t* block = heap_pop_local_free(heap, size_class);
		if (EXPECTED(block != 0)) {
			// Fast track with small block available in heap level local free list
			if (zero)
				memset(block, 0, global_size_class[size_class].block_size);
			return block;
		}
	}
	return heap_allocate_block_generic(heap, size, zero);
}

static RPMALLOC_ALLOCATOR void*
heap_allocate_block_aligned(heap_t* heap, size_t alignment, size_t size, unsigned int zero) {
	if (alignment <= SMALL_GRANULARITY)
		return heap_allocate_block(heap, size, zero);

#if ENABLE_VALIDATE_ARGS
	if ((size + alignment) < size) {
		errno = EINVAL;
		return 0;
	}
	if (alignment & (alignment - 1)) {
		errno = EINVAL;
		return 0;
	}
#endif
	if (alignment >= RPMALLOC_MAX_ALIGNMENT) {
		errno = EINVAL;
		return 0;
	}

	size_t align_mask = alignment - 1;
	block_t* block = heap_allocate_block(heap, size + alignment, zero);
	if ((uintptr_t)block & align_mask) {
		block = (void*)(((uintptr_t)block & ~(uintptr_t)align_mask) + alignment);
		// Mark as having aligned blocks
		span_t* span = block_get_span(block);
		page_t* page = span_get_page_from_block(span, block);
		page->has_aligned_block = 1;
		page->generic_free = 1;
	}
	return block;
}

static void*
heap_reallocate_block(heap_t* heap, void* block, size_t size, size_t old_size, unsigned int flags) {
	if (block) {
		// Grab the span using guaranteed span alignment
		span_t* span = block_get_span(block);
		if (EXPECTED(span->page_type <= PAGE_LARGE)) {
			// Normal sized block
			page_t* page = span_get_page_from_block(span, block);
			void* blocks_start = pointer_offset(page, PAGE_HEADER_SIZE);
			uint32_t block_offset = (uint32_t)pointer_diff(block, blocks_start);
			uint32_t block_idx = block_offset / page->block_size;
			void* block_origin = pointer_offset(blocks_start, (size_t)block_idx * page->block_size);
			if (!old_size)
				old_size = (size_t)((ptrdiff_t)page->block_size - pointer_diff(block, block_origin));
			if ((size_t)page->block_size >= size) {
				// Still fits in block, never mind trying to save memory, but preserve data if alignment changed
				if ((block != block_origin) && !(flags & RPMALLOC_NO_PRESERVE))
					memmove(block_origin, block, old_size);
				return block_origin;
			}
		} else {
			// Huge block
			void* block_start = pointer_offset(span, SPAN_HEADER_SIZE);
			if (!old_size)
				old_size = ((size_t)span->page_size * (size_t)span->page_count) - SPAN_HEADER_SIZE;
			if ((size < old_size) && (size > LARGE_BLOCK_SIZE_LIMIT)) {
				// Still fits in block and still huge, never mind trying to save memory,
				// but preserve data if alignment changed
				if ((block_start != block) && !(flags & RPMALLOC_NO_PRESERVE))
					memmove(block_start, block, old_size);
				return block_start;
			}
		}
	} else {
		old_size = 0;
	}

	if (!!(flags & RPMALLOC_GROW_OR_FAIL))
		return 0;

	// Size is greater than block size or saves enough memory to resize, need to allocate a new block
	// and deallocate the old. Avoid hysteresis by overallocating if increase is small (below 37%)
	size_t lower_bound = old_size + (old_size >> 2) + (old_size >> 3);
	size_t new_size = (size > lower_bound) ? size : ((size > old_size) ? lower_bound : size);
	void* old_block = block;
	block = heap_allocate_block(heap, new_size, 0);
	if (block && old_block) {
		if (!(flags & RPMALLOC_NO_PRESERVE))
			memcpy(block, old_block, old_size < new_size ? old_size : new_size);
		block_deallocate(old_block);
	}

	return block;
}

static void*
heap_reallocate_block_aligned(heap_t* heap, void* block, size_t alignment, size_t size, size_t old_size,
                              unsigned int flags) {
	if (alignment <= SMALL_GRANULARITY)
		return heap_reallocate_block(heap, block, size, old_size, flags);

	int no_alloc = !!(flags & RPMALLOC_GROW_OR_FAIL);
	size_t usable_size = (block ? block_usable_size(block) : 0);
	if ((usable_size >= size) && !((uintptr_t)block & (alignment - 1))) {
		if (no_alloc || (size >= (usable_size / 2)))
			return block;
	}
	// Aligned alloc marks span as having aligned blocks
	void* old_block = block;
	block = (!no_alloc ? heap_allocate_block_aligned(heap, alignment, size, 0) : 0);
	if (EXPECTED(block != 0)) {
		if (!(flags & RPMALLOC_NO_PRESERVE) && old_block) {
			if (!old_size)
				old_size = usable_size;
			memcpy(block, old_block, old_size < size ? old_size : size);
		}
		if (EXPECTED(old_block != 0))
			block_deallocate(old_block);
	}
	return block;
}

static void
heap_free_all(heap_t* heap) {
	for (int itype = 0; itype < 3; ++itype) {
		span_t* span = heap->span_partial[itype];
		while (span) {
			span_t* span_next = span->next;
			global_memory_interface->memory_unmap(span, span->offset, span->mapped_size);
			span = span_next;
		}
		heap->span_partial[itype] = 0;
		heap->page_free[itype] = 0;
		heap->page_free_commit_count[itype] = 0;
		atomic_store_explicit(&heap->thread_free[itype], 0, memory_order_release);
	}
	for (int itype = 0; itype < 4; ++itype) {
		span_t* span = heap->span_used[itype];
		while (span) {
			span_t* span_next = span->next;
			global_memory_interface->memory_unmap(span, span->offset, span->mapped_size);
			span = span_next;
		}
		heap->span_used[itype] = 0;
	}
	memset(heap->local_free, 0, sizeof(heap->local_free));
	memset(heap->page_available, 0, sizeof(heap->page_available));

#if ENABLE_STATISTICS
	// TODO: Fix
#endif
}

////////////
///
/// Extern interface
///
//////

int
rpmalloc_is_thread_initialized(void) {
	return (get_thread_heap() != global_heap_default) ? 1 : 0;
}

#ifdef FEX_IOS_HOST
/* ml1044: ONE RECURSIVE LOCK AROUND THE WHOLE ALLOCATOR -- an experiment with a
 * clear verdict either way.
 *
 * Two consecutive runs died inside FEX's own heap: rpfree+0x38 dereferencing a
 * page header whose `heap` field held 0x400F70000, then a fextl::deque in the
 * DFE pass whose block pointer had become NULL between two reads. Both are the
 * container/metadata corruption family that has been open since ml606/ml610,
 * and the ml463 comment above already names the suspect: heaps that more than
 * one thread believes it owns ("the fallback-heap sharing itself needs a lock,
 * a bigger fix"). rpmalloc's fast paths are lock-free BECAUSE a heap has one
 * owner; with two, local_free[] and the page counters are mutated concurrently.
 *
 * Serialising every entry point makes that class of race impossible. If the
 * corruption stops, shared ownership is proven and the real fix is a proper
 * ownership model; if it continues, the writer is outside the allocator and
 * this lock is exonerated as a cause. Owner-aware and recursive on purpose: a
 * fault taken mid-allocation re-enters the allocator from the exception path,
 * and a plain spinlock there is the IosMigrateLock self-deadlock all over again
 * (ml1035). */
static _Atomic(uintptr_t) fex_ios_rpm_owner;
static unsigned fex_ios_rpm_depth;
static int fex_ios_rpm_enabled = -1;
void fex_ios_rpm_lock(void) {
	uintptr_t self, expected = 0;
	/* ml1045: NO getenv() HERE. ml1044 read an off-switch from the environment on
	 * first use, and the first use is during early thread setup -- before the CRT
	 * is usable on that thread (x18 was still 0). Calling into ucrtbase from there
	 * recursed until the launcher generation's main thread ran off its stack
	 * (BUS at ucrtbase+0x3a138, write to the guard page at sp=0x702f323fc0); the
	 * thread was killed and every process waiting on it hung at boot. An allocator
	 * entry point must not call anything that can allocate or touch per-thread
	 * CRT state. The lock is unconditional; build without it to turn it off. */
	fex_ios_rpm_enabled = 1;
	self = get_thread_id() | 1;
	if (atomic_load_explicit(&fex_ios_rpm_owner, memory_order_acquire) == self) { ++fex_ios_rpm_depth; return; }
	while (!atomic_compare_exchange_weak_explicit(&fex_ios_rpm_owner, &expected, self, memory_order_acquire,
	                                              memory_order_relaxed)) {
		expected = 0;
		wait_spin();
	}
	fex_ios_rpm_depth = 1;
}
void fex_ios_rpm_unlock(void) {
	if (fex_ios_rpm_enabled <= 0) return;
	if (atomic_load_explicit(&fex_ios_rpm_owner, memory_order_acquire) != (get_thread_id() | 1)) return;
	if (--fex_ios_rpm_depth == 0) atomic_store_explicit(&fex_ios_rpm_owner, 0, memory_order_release);
}
#endif

extern inline RPMALLOC_ALLOCATOR void*
rpmalloc(size_t size) {
#if ENABLE_VALIDATE_ARGS
	if (size >= MAX_ALLOC_SIZE) {
		errno = EINVAL;
		return 0;
	}
#endif
	heap_t* heap = get_thread_heap();
	void* _fex_p = heap_allocate_block(heap, size, 0);
	FEX_WATCH_NOTE(_fex_p, FEX_WATCH_ALLOC);
	return _fex_p;
}

extern inline RPMALLOC_ALLOCATOR void*
rpzalloc(size_t size) {
#if ENABLE_VALIDATE_ARGS
	if (size >= MAX_ALLOC_SIZE) {
		errno = EINVAL;
		return 0;
	}
#endif
	heap_t* heap = get_thread_heap();
	void* _fex_p = heap_allocate_block(heap, size, 1);
	FEX_WATCH_NOTE(_fex_p, FEX_WATCH_ALLOC);
	return _fex_p;
}

/* iOS-Mythic diagnostic: log+exit if called with an obviously bad pointer.
 * On iOS we hit rpfree with x0=small (< 0x10000000) which faults inside
 * block_deallocate. Encode the bad pointer's low 16 bits + caller's LR
 * low 16 bits into exit status so we can identify the bug. */
extern inline void
rpfree(void* ptr) {
	if (UNEXPECTED(ptr == 0))
		return;
	/* ml611: recorded BEFORE the block goes back, so the log shows the free of a
	 * buffer the CFG still holds — the decisive use-after-free evidence. */
	FEX_WATCH_NOTE(ptr, FEX_WATCH_FREE);
	if (UNEXPECTED((unsigned long long)ptr < 0x10000000ULL)) {
		/* iOS-Mythic: skip free for obviously-bad pointer (likely from
		 * destructor of zero-initialized vector with non-null garbage data
		 * pointer due to ARM64EC ABI mismatch on struct return). Log it but
		 * continue execution so x86_64 PE can still print Hello World. */
		unsigned long long _lr = (unsigned long long)__builtin_return_address(0);
		unsigned long long _p = (unsigned long long)ptr;
		char buf[80];
		const char *hexd = "0123456789abcdef";
		int i = 0;
		const char *prefix = "[rpfree-skip] ptr=0x";
		while (prefix[i]) { buf[i] = prefix[i]; i++; }
		for (int j = 60; j >= 0; j -= 4) buf[i++] = hexd[(_p >> j) & 0xf];
		const char *lrstr = " lr=0x";
		for (int k = 0; lrstr[k]; ++k) buf[i++] = lrstr[k];
		for (int j = 60; j >= 0; j -= 4) buf[i++] = hexd[(_lr >> j) & 0xf];
		buf[i++] = '\n';
		void *h = GetStdHandle((unsigned long)-12);
		unsigned long w;
		WriteFile(h, buf, (unsigned long)i, &w, 0);
		return;
	}
	block_deallocate(ptr);
}

extern inline RPMALLOC_ALLOCATOR void*
rpcalloc(size_t num, size_t size) {
	size_t total;
#if ENABLE_VALIDATE_ARGS
#if PLATFORM_WINDOWS
	int err = SizeTMult(num, size, &total);
	if ((err != S_OK) || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#else
	int err = __builtin_umull_overflow(num, size, &total);
	if (err || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#endif
#else
	total = num * size;
#endif
	heap_t* heap = get_thread_heap();
	return heap_allocate_block(heap, total, 1);
}

extern inline RPMALLOC_ALLOCATOR void*
rprealloc(void* ptr, size_t size) {
#if ENABLE_VALIDATE_ARGS
	if (size >= MAX_ALLOC_SIZE) {
		errno = EINVAL;
		return ptr;
	}
#endif
	heap_t* heap = get_thread_heap();
	/* ml611: a vector growing past capacity comes through here — the OLD buffer is
	 * released and a NEW one handed out, which is exactly the transition that can
	 * strand a stale data() pointer. Record both sides. */
	FEX_WATCH_NOTE(ptr, FEX_WATCH_FREE);
	void* _fex_p = heap_reallocate_block(heap, ptr, size, 0, 0);
	FEX_WATCH_NOTE(_fex_p, FEX_WATCH_ALLOC);
	return _fex_p;
}

extern RPMALLOC_ALLOCATOR void*
rpaligned_realloc(void* ptr, size_t alignment, size_t size, size_t oldsize, unsigned int flags) {
#if ENABLE_VALIDATE_ARGS
	if ((size + alignment < size) || (alignment > _memory_page_size)) {
		errno = EINVAL;
		return 0;
	}
#endif
	heap_t* heap = get_thread_heap();
	return heap_reallocate_block_aligned(heap, ptr, alignment, size, oldsize, flags);
}

extern RPMALLOC_ALLOCATOR void*
rpaligned_alloc(size_t alignment, size_t size) {
	heap_t* heap = get_thread_heap();
	return heap_allocate_block_aligned(heap, alignment, size, 0);
}

extern RPMALLOC_ALLOCATOR void*
rpaligned_zalloc(size_t alignment, size_t size) {
	heap_t* heap = get_thread_heap();
	return heap_allocate_block_aligned(heap, alignment, size, 1);
}

extern inline RPMALLOC_ALLOCATOR void*
rpaligned_calloc(size_t alignment, size_t num, size_t size) {
	size_t total;
#if ENABLE_VALIDATE_ARGS
#if PLATFORM_WINDOWS
	int err = SizeTMult(num, size, &total);
	if ((err != S_OK) || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#else
	int err = __builtin_umull_overflow(num, size, &total);
	if (err || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#endif
#else
	total = num * size;
#endif
	heap_t* heap = get_thread_heap();
	return heap_allocate_block_aligned(heap, alignment, total, 1);
}

extern inline RPMALLOC_ALLOCATOR void*
rpmemalign(size_t alignment, size_t size) {
	heap_t* heap = get_thread_heap();
	return heap_allocate_block_aligned(heap, alignment, size, 0);
}

extern inline int
rpposix_memalign(void** memptr, size_t alignment, size_t size) {
	heap_t* heap = get_thread_heap();
	if (memptr)
		*memptr = heap_allocate_block_aligned(heap, alignment, size, 0);
	else
		return EINVAL;
	return *memptr ? 0 : ENOMEM;
}

extern inline size_t
rpmalloc_usable_size(void* ptr) {
	return (ptr ? block_usable_size(ptr) : 0);
}

////////////
///
/// Initialization and finalization
///
//////

static void
rpmalloc_thread_destructor(void* value) {
	// If this is called on main thread assume it means rpmalloc_finalize
	// has not been called and shutdown is forced (through _exit) or unclean
	if (get_thread_id() == global_main_thread_id)
		return;
	if (value)
		rpmalloc_thread_finalize();
}

extern int
rpmalloc_initialize_config(rpmalloc_interface_t* memory_interface, rpmalloc_config_t* config) {
	if (global_rpmalloc_initialized) {
		rpmalloc_thread_initialize();
		if (config)
			*config = global_config;
		return 0;
	}

	if (config)
		global_config = *config;

	int result = rpmalloc_initialize(memory_interface);

	if (config)
		*config = global_config;

	return result;
}

extern int
rpmalloc_initialize(rpmalloc_interface_t* memory_interface) {
	if (global_rpmalloc_initialized) {
		rpmalloc_thread_initialize();
		return 0;
	}

	global_rpmalloc_initialized = 1;

#ifdef FEX_IOS_HOST
	/* ml492: prove the sink. C:\rpm-poison.log is created lazily on the first
	 * poison note, so an ABSENT file was ambiguous — guard never fired, or the
	 * write is broken? One banner at init disambiguates: file MISSING => sink
	 * broken; banner ONLY => genuinely clean run; banner + [rpm-poison] =>
	 * payload captured.
	 * ml491 put this in rpmalloc_initialize_config(), which iOS never calls —
	 * Source/Windows/Common/CRT/CRT_iOS.cpp calls rpmalloc_initialize(nullptr)
	 * directly, so the banner never ran and the file stayed missing, which read
	 * as "sink broken" when it was really "banner in the wrong function".
	 * This is the common path: _config() delegates here too. */
	{
		static const char banner[] = "[rpm-sink] alive rev=ml492\n";
		ios_rpm_emit(banner, (int)(sizeof(banner) - 1));
	}
#endif

	global_memory_interface = memory_interface ? memory_interface : &global_memory_interface_default;
	if (!global_memory_interface->memory_map || !global_memory_interface->memory_unmap) {
		global_memory_interface->memory_map = trampoline_mmap;
		global_memory_interface->memory_commit = os_mcommit;
		global_memory_interface->memory_decommit = os_mdecommit;
		global_memory_interface->memory_unmap = trampoline_munmap;
	}

#if PLATFORM_WINDOWS
	SYSTEM_INFO system_info;
	memset(&system_info, 0, sizeof(system_info));
	GetSystemInfo(&system_info);
	os_map_granularity = system_info.dwAllocationGranularity;
#else
	os_map_granularity = (size_t)sysconf(_SC_PAGESIZE);
#endif

#if PLATFORM_WINDOWS
	os_page_size = system_info.dwPageSize;
#else
	os_page_size = os_map_granularity;
#endif
#ifdef ENABLE_HUGE_PAGES
	if (global_config.enable_huge_pages) {
#if PLATFORM_WINDOWS
		HANDLE token = 0;
#if WINAPI_FAMILY_PARTITION(WINAPI_PARTITION_APP | WINAPI_PARTITION_SYSTEM)
		size_t large_page_minimum = GetLargePageMinimum();
#else
		size_t large_page_minimum = 2 * 1024 * 1024;
#endif
		if (large_page_minimum)
			OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &token);
		if (token) {
			LUID luid;
			if (LookupPrivilegeValue(0, SE_LOCK_MEMORY_NAME, &luid)) {
				TOKEN_PRIVILEGES token_privileges;
				memset(&token_privileges, 0, sizeof(token_privileges));
				token_privileges.PrivilegeCount = 1;
				token_privileges.Privileges[0].Luid = luid;
				token_privileges.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
				if (AdjustTokenPrivileges(token, FALSE, &token_privileges, 0, 0, 0)) {
					if (GetLastError() == ERROR_SUCCESS)
						os_huge_pages = 1;
				}
			}
			CloseHandle(token);
		}
		if (os_huge_pages) {
			if (large_page_minimum > os_page_size)
				os_page_size = large_page_minimum;
			if (large_page_minimum > os_map_granularity)
				os_map_granularity = large_page_minimum;
		}
#elif defined(__linux__)
		size_t huge_page_size = 0;
		FILE* meminfo = fopen("/proc/meminfo", "r");
		if (meminfo) {
			char line[128];
			while (!huge_page_size && fgets(line, sizeof(line) - 1, meminfo)) {
				line[sizeof(line) - 1] = 0;
				if (strstr(line, "Hugepagesize:"))
					huge_page_size = (size_t)strtol(line + 13, 0, 10) * 1024;
			}
			fclose(meminfo);
		}
		if (huge_page_size) {
			os_huge_pages = 1;
			os_page_size = huge_page_size;
			os_map_granularity = huge_page_size;
		}
#elif defined(__FreeBSD__)
		int rc;
		size_t sz = sizeof(rc);

		if (sysctlbyname("vm.pmap.pg_ps_enabled", &rc, &sz, NULL, 0) == 0 && rc == 1) {
			os_huge_pages = 1;
			os_page_size = 2 * 1024 * 1024;
			os_map_granularity = os_page_size;
		}
#elif defined(__APPLE__) || defined(__NetBSD__)
		os_huge_pages = 1;
		os_page_size = 2 * 1024 * 1024;
		os_map_granularity = os_page_size;
#endif
	} else
#endif
  {

		os_huge_pages = 0;
	}

	global_config.enable_huge_pages = os_huge_pages;

	if (!memory_interface || (global_config.page_size < os_page_size))
		global_config.page_size = os_page_size;

	if (global_config.enable_huge_pages || global_config.page_size > (256 * 1024))
		global_config.disable_decommit = 1;

#if defined(__linux__) || defined(__ANDROID__)
	if (global_config.disable_thp)
		(void)prctl(PR_SET_THP_DISABLE, 1, 0, 0, 0);
#endif

#ifdef _WIN32
#if defined(DYNAMIC_TLS_NO_FLS)
  tls_key = TlsAlloc();
#else
	fls_key = FlsAlloc(&rpmalloc_thread_destructor);
#endif
#else
	pthread_key_create(&pthread_key, rpmalloc_thread_destructor);
#endif

	global_main_thread_id = get_thread_id();

	rpmalloc_thread_initialize();

	return 0;
}

extern const rpmalloc_config_t*
rpmalloc_config(void) {
	return &global_config;
}

extern void
rpmalloc_finalize(void) {
	rpmalloc_thread_finalize();

	if (global_config.unmap_on_finalize) {
		heap_t* heap = global_heap_queue;
		global_heap_queue = 0;
		while (heap) {
			heap_t* heap_next = heap->next;
			heap_free_all(heap);
			heap_unmap(heap);
			heap = heap_next;
		}
		heap = global_heap_used;
		global_heap_used = 0;
		while (heap) {
			heap_t* heap_next = heap->next;
			heap_free_all(heap);
			heap_unmap(heap);
			heap = heap_next;
		}
#if ENABLE_STATISTICS
		memset(&global_statistics, 0, sizeof(global_statistics));
#endif
	}

#ifdef _WIN32
#if defined(DYNAMIC_TLS_NO_FLS)
  TlsFree(tls_key);
  tls_key = 0;
#else
	FlsFree(fls_key);
	fls_key = 0;
#endif
#else
	pthread_key_delete(pthread_key);
	pthread_key = 0;
#endif

	global_main_thread_id = 0;
	global_rpmalloc_initialized = 0;
}

extern void
rpmalloc_thread_initialize(void) {
	if (get_thread_heap() == global_heap_default)
		get_thread_heap_allocate();
}

extern void
rpmalloc_thread_finalize(void) {
	heap_t* heap = get_thread_heap();
	if (heap != global_heap_default) {
		heap_release(heap);
		set_thread_heap(global_heap_default);
	}
}

extern void
rpmalloc_thread_collect(void) {
}

void
rpmalloc_dump_statistics(void* file) {
#if ENABLE_STATISTICS
	fprintf(file, "Mapped pages:        %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.page_mapped, memory_order_relaxed));
	fprintf(file, "Mapped pages (peak): %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.page_mapped_peak, memory_order_relaxed));
	fprintf(file, "Active pages:        %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.page_active, memory_order_relaxed));
	fprintf(file, "Active pages (peak): %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.page_active_peak, memory_order_relaxed));
	fprintf(file, "Pages committed:     %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.page_commit, memory_order_relaxed));
	fprintf(file, "Pages decommitted:   %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.page_decommit, memory_order_relaxed));
	fprintf(file, "Heaps created:       %llu\n",
	        (unsigned long long)atomic_load_explicit(&global_statistics.heap_count, memory_order_relaxed));
#else
	(void)sizeof(file);
#endif
}

#if RPMALLOC_FIRST_CLASS_HEAPS

rpmalloc_heap_t*
rpmalloc_heap_acquire(void) {
	// Must be a pristine heap from newly mapped memory pages, or else memory blocks
	// could already be allocated from the heap which would (wrongly) be released when
	// heap is cleared with rpmalloc_heap_free_all(). Also heaps guaranteed to be
	// pristine from the dedicated orphan list can be used.
	heap_t* heap = heap_allocate(1);
	rpmalloc_assume(heap != 0);
	heap->owner_thread = 0;
	return heap;
}

void
rpmalloc_heap_release(rpmalloc_heap_t* heap) {
	if (heap)
		heap_release(heap);
}

RPMALLOC_ALLOCATOR void*
rpmalloc_heap_alloc(rpmalloc_heap_t* heap, size_t size) {
#if ENABLE_VALIDATE_ARGS
	if (size >= MAX_ALLOC_SIZE) {
		errno = EINVAL;
		return 0;
	}
#endif
	return heap_allocate_block(heap, size, 0);
}

RPMALLOC_ALLOCATOR void*
rpmalloc_heap_aligned_alloc(rpmalloc_heap_t* heap, size_t alignment, size_t size) {
#if ENABLE_VALIDATE_ARGS
	if (size >= MAX_ALLOC_SIZE) {
		errno = EINVAL;
		return 0;
	}
#endif
	return heap_allocate_block_aligned(heap, alignment, size, 0);
}

RPMALLOC_ALLOCATOR void*
rpmalloc_heap_calloc(rpmalloc_heap_t* heap, size_t num, size_t size) {
	size_t total;
#if ENABLE_VALIDATE_ARGS
#if PLATFORM_WINDOWS
	int err = SizeTMult(num, size, &total);
	if ((err != S_OK) || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#else
	int err = __builtin_umull_overflow(num, size, &total);
	if (err || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#endif
#else
	total = num * size;
#endif
	return heap_allocate_block(heap, total, 1);
}

extern inline RPMALLOC_ALLOCATOR void*
rpmalloc_heap_aligned_calloc(rpmalloc_heap_t* heap, size_t alignment, size_t num, size_t size) {
	size_t total;
#if ENABLE_VALIDATE_ARGS
#if PLATFORM_WINDOWS
	int err = SizeTMult(num, size, &total);
	if ((err != S_OK) || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#else
	int err = __builtin_umull_overflow(num, size, &total);
	if (err || (total >= MAX_ALLOC_SIZE)) {
		errno = EINVAL;
		return 0;
	}
#endif
#else
	total = num * size;
#endif
	return heap_allocate_block_aligned(heap, alignment, total, 1);
}

RPMALLOC_ALLOCATOR void*
rpmalloc_heap_realloc(rpmalloc_heap_t* heap, void* ptr, size_t size, unsigned int flags) {
#if ENABLE_VALIDATE_ARGS
	if (size >= MAX_ALLOC_SIZE) {
		errno = EINVAL;
		return ptr;
	}
#endif
	return heap_reallocate_block(heap, ptr, size, 0, flags);
}

RPMALLOC_ALLOCATOR void*
rpmalloc_heap_aligned_realloc(rpmalloc_heap_t* heap, void* ptr, size_t alignment, size_t size, unsigned int flags) {
#if ENABLE_VALIDATE_ARGS
	if ((size + alignment < size) || (alignment > _memory_page_size)) {
		errno = EINVAL;
		return 0;
	}
#endif
	return heap_reallocate_block_aligned(heap, ptr, alignment, size, 0, flags);
}

void
rpmalloc_heap_free(rpmalloc_heap_t* heap, void* ptr) {
	(void)sizeof(heap);
	block_deallocate(ptr);
}

//! Free all memory allocated by the heap
void
rpmalloc_heap_free_all(rpmalloc_heap_t* heap) {
	heap_free_all(heap);
}

extern inline void
rpmalloc_heap_thread_set_current(rpmalloc_heap_t* heap) {
	heap_t* prev_heap = get_thread_heap();
	if (prev_heap != heap) {
		set_thread_heap(heap);
		if (prev_heap)
			heap_release(prev_heap);
	}
}

rpmalloc_heap_t*
rpmalloc_get_heap_for_ptr(void* ptr) {
	// Grab the span, and then the heap from the span
	span_t* span = (span_t*)((uintptr_t)ptr & SPAN_MASK);
	if (span)
		return span_get_page_from_block(span, ptr)->heap;
	return 0;
}

#endif

#include "malloc.c"
