#!/usr/bin/env python3
"""Exercise the production cancellation walk with inline and queued completion."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'server/async.c').read_text()
start = source.index('static int cancel_process_async(')
walk = source[start:source.index('\n}\n', start) + 3]
assert 'async->completed     = 0;' in source
result = source[source.index('void async_set_result('):]
assert result.index('async->completed = 1;') < result.index('async_complete_cancel( async );')
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include "wine/list.h"
typedef uintptr_t client_ptr_t;
typedef unsigned obj_handle_t;
#define SYNCHRONIZE 1
struct object { int refs, kind; };
struct thread { int unused; };
struct process { struct list asyncs; };
struct async_cancel { struct object obj; unsigned count; };
struct async {
    struct object obj;
    struct list process_entry;
    struct thread *thread;
    void *fd;
    struct { client_ptr_t iosb; } data;
    int terminated, is_system, canceled, completed, inline_completion;
    struct async_cancel *async_cancel;
};
static struct async_cancel group;
static int freed, handles;
static void *grab_object(void *p) { struct object *o=p; assert(o->refs > 0); o->refs++; return p; }
static void release_object(void *p) {
    struct object *o=p; assert(o->refs > 0);
    if (!--o->refs && !o->kind) {
        struct async *a=p; assert(!a->async_cancel); list_remove(&a->process_entry); freed++;
    }
}
static void *get_fd_user(void *fd) { return fd; }
static struct async_cancel *create_async_cancel(struct process *p) {
    (void)p; group=(struct async_cancel){.obj={1,1}}; return &group;
}
static obj_handle_t alloc_handle(struct process *p, void *o, unsigned access, int attributes) {
    (void)p; (void)access; (void)attributes; grab_object(o); handles++; return 7;
}
static void cancel_async(struct async *a) {
    a->canceled=1;
    if (a->inline_completion) { a->completed=a->terminated=1; release_object(a); }
}
WALK
static void scenario(int count, int inline_mask, int grouped) {
    struct process p; struct thread thread={0}; struct async a[2]={0};
    obj_handle_t wait=0; int pending=0;
    list_init(&p.asyncs); freed=handles=0;
    for (int i=0;i<count;i++) {
        a[i].obj.refs=1; a[i].thread=&thread; a[i].inline_completion=inline_mask & (1<<i);
        list_add_tail(&p.asyncs,&a[i].process_entry);
    }
    assert(cancel_process_async(&p,NULL,grouped ? &thread : NULL,0,&wait)==count);
    for (int i=0;i<count;i++) {
        if (a[i].inline_completion) assert(a[i].obj.refs==0 && !a[i].async_cancel);
        else { assert(a[i].obj.refs==1); pending++; }
    }
    assert(freed==count-pending);
    assert(handles==(grouped && pending ? 1 : 0));
    assert(wait==(grouped && pending ? 7u : 0u));
    if (grouped) assert(group.count==(unsigned)pending);
}
int main(void) {
    scenario(1,1,0); scenario(1,1,1); scenario(2,3,0);
    scenario(1,0,0); scenario(1,0,1); scenario(2,2,1);
    puts("PASS: inline, queued, mixed cancellation and group lifetime");
}
'''.replace('WALK', walk)
with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    c, binary = directory / 'cancel.c', directory / 'cancel'
    c.write_text(code)
    subprocess.run(['cc', '-std=c11', '-g', '-fsanitize=address,undefined', '-I', str(root / 'include'), str(c), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
