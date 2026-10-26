#!/usr/bin/env python3
"""Run production image-protection and publication blocks with injected failures."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "build/ntdll-unix/virtual_ios.c").read_text()
start = source.index("    /* set the image protections */\n\n    set_vprot( view, ptr, ROUND_SIZE")
end = source.index("\ndone:\n    free( sections );", start)
protect = source[start:end]
start = source.index("    status = map_image_into_view( view, nt_name, unix_fd")
start = source.index("    if (NT_SUCCESS(status))", start)
end = source.index("\ndone:\n    server_leave_uninterrupted_section", start)
publish = source[start:end]
start = source.index("        /* set the image protections */\n")
end = source.index("\n\n    /* map all the sections */", start)
flat = source[start:end].rstrip().removesuffix("}")
start = source.index("static int mprotect_range( void *base")
end = source.index("\n\n/***********************************************************************", start)
protect_range = source[start:end]

code = r'''
#include <assert.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#define WINE_IOS 1
#define STATUS_SUCCESS 0
#define STATUS_NO_MEMORY 0xc0000017u
#define STATUS_ACCESS_DENIED 0xc0000022u
#define NT_SUCCESS(s) ((int32_t)(s) >= 0)
#define IMAGE_DOS_SIGNATURE 0x5a4d
#define IMAGE_NT_SIGNATURE 0x4550
#define IMAGE_SCN_MEM_EXECUTE 0x20000000
#define IMAGE_SCN_MEM_READ 0x40000000
#define IMAGE_SCN_MEM_WRITE 0x80000000
#define VPROT_COMMITTED 1
#define VPROT_READ 2
#define VPROT_WRITECOPY 4
#define VPROT_EXEC 8
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4
#define ERR(...) ((void)0)
#define IOS_IMG_FAIL(...) ((void)0)
#define VIRTUAL_DEBUG_DUMP_VIEW(v) ((void)0)
#define max(a,b) ((a) > (b) ? (a) : (b))
#define ROUND_SIZE(a,s,m) (((s) + ((uintptr_t)(a) & (m)) + (m)) & ~(m))
typedef size_t SIZE_T;
typedef unsigned char BYTE;
typedef struct { unsigned e_magic, e_lfanew; } IMAGE_DOS_HEADER;
typedef struct { unsigned Signature; struct { uint16_t NumberOfSections; } FileHeader; } IMAGE_NT_HEADERS;
typedef struct {
    char Name[8];
    struct { unsigned VirtualSize; } Misc;
    unsigned VirtualAddress, SizeOfRawData, Characteristics;
} IMAGE_SECTION_HEADER;
static IMAGE_SECTION_HEADER sections[3];
#define IMAGE_FIRST_SECTION(nt) (sections)
static _Alignas(0x4000) struct { IMAGE_DOS_HEADER dos; IMAGE_NT_HEADERS nt; char data[0x10000]; } image;
static const size_t host_page_mask = 0x3fff, host_page_size = 0x4000;
#define ROUND_ADDR(a,m) ((char *)((uintptr_t)(a) & ~(uintptr_t)(m)))
static BYTE get_host_page_vprot(void *addr)
{
    size_t page = (char *)addr - (char *)&image;
    BYTE prot = VPROT_COMMITTED | VPROT_READ;
    for (unsigned i = 0; i < image.nt.FileHeader.NumberOfSections; i++)
        if (sections[i].VirtualAddress < page + host_page_size &&
            sections[i].VirtualAddress + sections[i].Misc.VirtualSize > page)
        {
            if (sections[i].Characteristics & IMAGE_SCN_MEM_WRITE) prot |= VPROT_WRITECOPY;
            if (sections[i].Characteristics & IMAGE_SCN_MEM_EXECUTE) prot |= VPROT_EXEC;
        }
    return prot;
}
static int get_unix_prot(BYTE prot)
{
    return ((prot & VPROT_READ) ? PROT_READ : 0) |
           ((prot & VPROT_WRITECOPY) ? PROT_WRITE : 0) |
           ((prot & VPROT_EXEC) ? PROT_EXEC : 0);
}
struct file_view { char *base; };
static int failure_stage, failure_index, failure_errno, protect_calls, eager_calls, deleted, registered;
static int set_vprot(struct file_view *v, void *addr, size_t size, BYTE prot)
{
    (void)v; (void)addr; (void)size;
    if (prot & VPROT_EXEC)
        if (++protect_calls == failure_index && failure_stage == 1)
        { errno = failure_errno; return 0; }
    return 1;
}
static int mprotect_exec(void *addr, size_t size, int prot)
{
    /* Simulate mprotect's host alignment constraint, including i386 data
       mappings, and require write access for the shared text/data host page. */
    if (((uintptr_t)addr & host_page_mask) || (size & host_page_mask))
    { errno = EINVAL; return -1; }
    assert(size == host_page_size);
    assert(prot == (PROT_READ | PROT_EXEC | (addr == (void *)&image ? PROT_WRITE : 0)));
    if (++eager_calls == failure_index && failure_stage == 2)
    { errno = failure_errno; return -1; }
    return 0;
}
'''
code += protect_range
code += r'''
static void add_builtin_module(void *base, void *handle) { (void)base; (void)handle; registered++; }
static void delete_view(struct file_view *view) { (void)view; deleted++; }
static unsigned map_protections(struct file_view *view)
{
    char *ptr = view->base;
    IMAGE_NT_HEADERS *nt = &image.nt;
    IMAGE_SECTION_HEADER *sec = sections;
    SIZE_T header_size = 0x1000, align_mask = 0xfff;
    unsigned status = STATUS_ACCESS_DENIED, i;
'''
code += protect
code += r'''
done:
    return status;
}
static unsigned publish_image(struct file_view *view, unsigned status, int is_builtin, size_t offset,
                              void **addr_ptr, size_t *size_ptr)
{
    struct { size_t alignment; } info = {0x1000}, *image_info = &info;
    size_t page_mask = 0xfff, size = 0x10000;
'''
code += publish
code += r'''
    return status;
}
static unsigned map_flat(struct file_view *view)
{
    char *ptr = view->base;
    size_t total_size = sizeof(image);
    unsigned status = STATUS_ACCESS_DENIED;
'''
code += flat
code += r'''
done:
    return status;
}
static void reset(int stage, int index, int error)
{
    failure_stage = stage; failure_index = index; failure_errno = error;
    protect_calls = eager_calls = deleted = registered = 0;
}
int main(void)
{
    struct file_view view = {(char *)&image};
    image.dos.e_magic = IMAGE_DOS_SIGNATURE;
    image.dos.e_lfanew = offsetof(__typeof__(image), nt);
    image.nt.Signature = IMAGE_NT_SIGNATURE;
    image.nt.FileHeader.NumberOfSections = 3;
    for (unsigned i = 0; i < 3; i++)
    {
        sections[i].VirtualAddress = i == 2 ? 0x5000 : (i + 1) * 0x1000;
        sections[i].Misc.VirtualSize = 0x1000;
        sections[i].Characteristics = IMAGE_SCN_MEM_READ | (i == 1 ? IMAGE_SCN_MEM_WRITE : IMAGE_SCN_MEM_EXECUTE);
    }
    for (int stage = 1; stage <= 3; stage++)
        for (int index = 1; index <= 2; index++)
            for (int error = 0; error < 2; error++)
            {
                int err = error ? EACCES : ENOMEM;
                reset(stage == 3 ? 0 : stage, index, err);
                void *addr = (void *)(uintptr_t)0x1234;
                size_t size = 123;
                unsigned status = map_protections(&view);
                if (stage == 3)
                {
                    assert(status == STATUS_SUCCESS);
                    reset(2, index, err);
                }
                status = publish_image(&view, status, 1, 0, &addr, &size);
                assert(status == (error ? STATUS_ACCESS_DENIED : STATUS_NO_MEMORY));
                assert(addr == (void *)(uintptr_t)0x1234 && size == 123);
                assert(deleted == 1 && !registered);
                if (stage == 1) assert(!eager_calls);
                else assert(eager_calls == index);
            }
    for (int error = 0; error < 2; error++)
    {
        reset(1, 1, error ? EACCES : ENOMEM);
        assert(map_flat(&view) == (error ? STATUS_ACCESS_DENIED : STATUS_NO_MEMORY));
    }
    reset(0, 0, 0);
    assert(map_flat(&view) == STATUS_SUCCESS);
    for (int builtin = 0; builtin <= 1; builtin++)
        for (int offset = 0; offset <= 1; offset++)
        {
            reset(0, 0, 0);
            void *addr = NULL;
            size_t size = 0;
            unsigned status = map_protections(&view);
            assert(status == STATUS_SUCCESS && protect_calls == 2 && eager_calls == 2);
            status = publish_image(&view, status, builtin, offset, &addr, &size);
            assert(status == STATUS_SUCCESS && addr == view.base && size == 0x10000);
            assert(!deleted && registered == (builtin && !offset));
        }
    puts("PASS: image protection failures stop publication, clean up, and preserve successful loads");
}
'''
with tempfile.TemporaryDirectory(prefix="madeira-image-failure-") as tmp:
    cfile = Path(tmp) / "check.c"
    executable = Path(tmp) / "check"
    cfile.write_text(code)
    subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(cfile),
                    "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
