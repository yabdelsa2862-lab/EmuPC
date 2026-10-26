/* avail_quarantine.c  -  host test for the page_available[] corruption guard
 *
 * Copyright 2026 125hz. Distributed under the same terms as rpmalloc.c in this
 * fork (see LICENSE and LICENSE-MADEIRA.md).
 *
 * page_available_to_free() and page_available_to_full() run rpm_avail_check()
 * before they unlink a page. When the check reports corruption, they must take
 * the page off the list WITHOUT reading or writing through its links: the
 * links are exactly what the check has just rejected. This test builds
 * synthetic heaps and pages, corrupts one link at a time, and checks that
 *   - the memory a rejected link points at is byte-for-byte unchanged;
 *   - a corrupt head drops the size class's list (published as 0);
 *   - a corrupt non-head page leaves the list exactly as it was;
 *   - a healthy list is still unlinked correctly, with the new head's prev
 *     cleared (the invariant the check relies on).
 *
 * It compiles rpmalloc.c itself (the shipped code, not a copy) for x86-64
 * Windows, where rpm_avail_check's WriteFile diagnostics work. The expected
 * "[rpm-avail] ml607 CORRUPT" lines on stderr are part of a passing run.
 *
 * Build (llvm-mingw) and run on Windows:
 *   x86_64-w64-mingw32-clang -O1 -Wall -Irpmalloc test/avail_quarantine.c -o avail_quarantine.exe
 *   avail_quarantine.exe
 */
#include "../rpmalloc/rpmalloc.c"

#include <stdio.h>
#include <string.h>

/* Normally provided by FEX; the allocation watch stays disarmed here. */
volatile int FEX_AllocWatch_Armed;
void
FEX_AllocWatch_Event(const void* ptr, unsigned int event) {
	(void)ptr;
	(void)event;
}

static int g_fail, g_pass;

#define CHECK(cond, what)                                                     \
	do {                                                                      \
		if (cond) {                                                           \
			++g_pass;                                                         \
		} else {                                                              \
			++g_fail;                                                         \
			fprintf(stdout, "FAIL %s:%d: %s\n", __func__, __LINE__, what);    \
		}                                                                     \
	} while (0)

#define SC 5 /* any small size class */

/* Separate, aligned objects: nothing here may lie inside the heap_t, which
 * the check treats as a corruption signature of its own. */
static _Alignas(64) heap_t g_heap;
/* One page per 64-byte slot: real page headers are page-aligned, and the
 * check rejects any link that is not at least 16-byte aligned. */
static struct {
	_Alignas(64) page_t page;
} g_slots[6];
#define g_pages_count ((int)(sizeof g_slots / sizeof g_slots[0]))
/* Memory a corrupt link points at. It is shaped like a page (aligned, large
 * enough) so that a write through the link would land inside it and change
 * its bytes, rather than fault. */
static _Alignas(64) page_t g_canary;
static _Alignas(64) unsigned char g_canary_ref[sizeof(page_t)];

static void
setup(void) {
	memset(&g_heap, 0, sizeof g_heap);
	memset(g_slots, 0, sizeof g_slots);
	g_heap.id = 1;
	for (int i = 0; i < g_pages_count; ++i) {
		g_slots[i].page.heap = &g_heap;
		g_slots[i].page.size_class = SC;
		g_slots[i].page.page_type = PAGE_SMALL;
		g_slots[i].page.block_count = 4;
	}
	/* Keep heap_page_free_decommit() out of it: that is not what is tested. */
	for (int t = 0; t < 4; ++t)
		global_page_free_overflow[t] = 1000;
	/* A foreign "page": plausible-looking pointer fields, wrong relationships. */
	memset(&g_canary, 0xA5, sizeof g_canary);
	g_canary.heap = &g_heap;
	g_canary.size_class = SC;
	g_canary.prev = &g_slots[5].page; /* not the page that points at it */
	g_canary.next = &g_slots[5].page;
	memcpy(g_canary_ref, &g_canary, sizeof g_canary);
}

static int
canary_intact(void) {
	return memcmp(&g_canary, g_canary_ref, sizeof g_canary) == 0;
}

/* A -> B -> C, reciprocal, A is head with no prev. */
static void
build_healthy(page_t* a, page_t* b, page_t* c) {
	g_heap.page_available[SC] = a;
	a->prev = 0;
	a->next = b;
	b->prev = a;
	b->next = c;
	c->prev = b;
	c->next = 0;
}

typedef void (*unlink_fn)(page_t*);

static void
run_unlink(unlink_fn fn, page_t* p) {
	fn(p);
}

/* 1. Head whose next link is not reciprocal (next->prev != head): bad=0x40.
 *    The old repair advanced the head to that link and cleared its prev. */
static void
test_head_next_not_reciprocal(unlink_fn fn, const char* name) {
	setup();
	page_t* a = &g_slots[0].page;
	g_heap.page_available[SC] = a;
	a->prev = 0;
	a->next = &g_canary;
	run_unlink(fn, a);
	(void)name;
	CHECK(canary_intact(), "rejected next link was written through");
	CHECK(g_heap.page_available[SC] == 0, "corrupt head: list not dropped");
	CHECK(a->prev == 0, "page kept a stale prev");
}

/* 2. Head with a non-NULL prev (bad=0x20) whose prev points at foreign memory.
 *    Neither link may be followed. */
static void
test_head_with_prev(unlink_fn fn) {
	setup();
	page_t *a = &g_slots[0].page, *b = &g_slots[1].page, *c = &g_slots[2].page;
	build_healthy(a, b, c);
	a->prev = &g_canary;
	unsigned char bref[sizeof(page_t)];
	memcpy(bref, b, sizeof *b);
	run_unlink(fn, a);
	CHECK(canary_intact(), "rejected prev link was written through");
	CHECK(memcmp(b, bref, sizeof *b) == 0, "next page modified after the check rejected the head");
	CHECK(g_heap.page_available[SC] == 0, "corrupt head: list not dropped");
}

/* 3. Head whose next is misaligned (bad=0x400). */
static void
test_head_next_misaligned(unlink_fn fn) {
	setup();
	page_t* a = &g_slots[0].page;
	g_heap.page_available[SC] = a;
	a->prev = 0;
	a->next = (page_t*)((char*)&g_canary + 8);
	run_unlink(fn, a);
	CHECK(canary_intact(), "misaligned next link was written through");
	CHECK(g_heap.page_available[SC] == 0, "corrupt head: list not dropped");
}

/* 4. Head that links to itself (bad=0x2000). */
static void
test_head_self_link(unlink_fn fn) {
	setup();
	page_t* a = &g_slots[0].page;
	g_heap.page_available[SC] = a;
	a->prev = 0;
	a->next = a;
	run_unlink(fn, a);
	CHECK(g_heap.page_available[SC] == 0, "self-linked head: list not dropped");
}

/* 5. Non-head page whose prev does not point back (bad=0x1000), with a
 *    foreign next: the list must be left exactly as it was. */
static void
test_middle_prev_not_reciprocal(unlink_fn fn) {
	setup();
	page_t *a = &g_slots[0].page, *b = &g_slots[1].page, *c = &g_slots[2].page;
	build_healthy(a, b, c);
	b->prev = &g_canary;
	b->next = &g_canary;
	unsigned char aref[sizeof(page_t)], cref[sizeof(page_t)];
	memcpy(aref, a, sizeof *a);
	memcpy(cref, c, sizeof *c);
	run_unlink(fn, b);
	CHECK(canary_intact(), "rejected link of a non-head page was written through");
	CHECK(memcmp(a, aref, sizeof *a) == 0, "head modified for a corrupt non-head page");
	CHECK(memcmp(c, cref, sizeof *c) == 0, "tail modified for a corrupt non-head page");
	CHECK(g_heap.page_available[SC] == a, "list head changed for a corrupt non-head page");
}

/* 6. Non-head page with prev == NULL (bad=0x100, the fatal-store shape). */
static void
test_middle_null_prev(unlink_fn fn) {
	setup();
	page_t *a = &g_slots[0].page, *b = &g_slots[1].page, *c = &g_slots[2].page;
	build_healthy(a, b, c);
	b->prev = 0;
	unsigned char aref[sizeof(page_t)], cref[sizeof(page_t)];
	memcpy(aref, a, sizeof *a);
	memcpy(cref, c, sizeof *c);
	run_unlink(fn, b);
	CHECK(memcmp(a, aref, sizeof *a) == 0, "head modified for a prev==NULL non-head page");
	CHECK(memcmp(c, cref, sizeof *c) == 0, "tail modified for a prev==NULL non-head page");
	CHECK(g_heap.page_available[SC] == a, "list head changed for a prev==NULL non-head page");
}

/* 7. Healthy list: head removal publishes next with a NULL prev. */
static void
test_healthy_head(unlink_fn fn) {
	setup();
	page_t *a = &g_slots[0].page, *b = &g_slots[1].page, *c = &g_slots[2].page;
	build_healthy(a, b, c);
	run_unlink(fn, a);
	CHECK(g_heap.page_available[SC] == b, "healthy head removal: wrong new head");
	CHECK(b->prev == 0, "healthy head removal: new head kept a prev");
	CHECK(b->next == c && c->prev == b, "healthy head removal: rest of list changed");
	CHECK(a->prev == 0, "removed page kept a stale prev");
}

/* 8. Healthy list: middle removal relinks the neighbours. */
static void
test_healthy_middle(unlink_fn fn) {
	setup();
	page_t *a = &g_slots[0].page, *b = &g_slots[1].page, *c = &g_slots[2].page;
	build_healthy(a, b, c);
	run_unlink(fn, b);
	CHECK(g_heap.page_available[SC] == a, "healthy middle removal: head changed");
	CHECK(a->next == c && c->prev == a, "healthy middle removal: neighbours not relinked");
	CHECK(a->prev == 0, "healthy middle removal: head gained a prev");
}

static void
to_free(page_t* p) {
	page_available_to_free(p);
}

static void
to_full(page_t* p) {
	page_available_to_full(p);
}

int
main(void) {
	static const struct {
		unlink_fn fn;
		const char* name;
	} fns[] = {{to_free, "page_available_to_free"}, {to_full, "page_available_to_full"}};
	for (size_t i = 0; i < sizeof fns / sizeof fns[0]; ++i) {
		int before = g_fail;
		test_head_next_not_reciprocal(fns[i].fn, fns[i].name);
		test_head_with_prev(fns[i].fn);
		test_head_next_misaligned(fns[i].fn);
		test_head_self_link(fns[i].fn);
		test_middle_prev_not_reciprocal(fns[i].fn);
		test_middle_null_prev(fns[i].fn);
		test_healthy_head(fns[i].fn);
		test_healthy_middle(fns[i].fn);
		fprintf(stdout, "%s: %s\n", fns[i].name, g_fail == before ? "ok" : "FAILED");
	}
	fprintf(stdout, "avail_quarantine: %d passed, %d failed\n", g_pass, g_fail);
	return g_fail ? 1 : 0;
}
