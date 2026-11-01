#!/usr/bin/env python3
"""Exercise the production async-owner predicate and iOS completion routing."""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
async_source = (root / "server/async.c").read_text()
thread_source = (root / "server/thread.c").read_text()


def function(source, name):
    start = source.index(name)
    return source[start:source.index("\n}\n", start) + 3]


owner = function(async_source, "int async_can_defer_to_issuer(")
enabled = function(thread_source, "static int ios_apc_requeue_enabled(")
route = function(thread_source, "static struct thread *ios_apc_requeue_target(")
assert "async_can_defer_to_issuer( struct object *obj, struct thread *thread );" in (root / "server/file.h").read_text()
# Unknown-status device requests return a wait handle before pending is set.
handoff = function(async_source, "obj_handle_t async_handoff(")
unknown = handoff[handoff.index("if (async->unknown_status)"):handoff.index("if (get_error()")]
assert "return async->wait_handle;" in unknown

harness = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "wine/list.h"
enum { APC_NONE, APC_ASYNC_IO, TERMINATED = 9, SELECT_INTERRUPTIBLE = 1 };
struct object { const void *ops; };
struct process { struct list thread_list; };
struct thread_wait { unsigned flags; };
struct thread { struct process *process; struct list proc_entry; struct thread_wait *wait;
                int state, suspended; unsigned id; };
struct async { struct object obj; struct thread *thread; unsigned blocking, pending, wait_handle,
               direct_result, initial_status; };
struct thread_apc { struct { int type; struct { unsigned status; } async_io; } call;
                    struct object *owner; };
static const char async_ops, other_ops;
static int is_thread_suspended(struct thread *thread) { return thread->suspended; }
OWNER
ENABLED
ROUTE
int main(void)
{
    struct process process;
    struct thread issuer = {.process = &process, .id = 1}, other = {.process = &process, .id = 2};
    struct thread_wait wait = {SELECT_INTERRUPTIBLE};
    struct async request = {.obj = {&async_ops}, .thread = &issuer, .blocking = 1, .wait_handle = 7};
    struct object unrelated = {&other_ops};
    struct thread_apc apc = {.call = {.type = APC_ASYNC_IO}, .owner = &request.obj};
    const char *setting = getenv("MADEIRA_APC_REQUEUE");
    int on = !(setting && setting[0] == '0');
    list_init(&process.thread_list);
    list_add_tail(&process.thread_list, &issuer.proc_entry);
    list_add_tail(&process.thread_list, &other.proc_entry);

    /* A device ioctl can complete while unknown_status and pending == 0. */
    assert(ios_apc_requeue_target(&issuer, &apc) == (on ? &issuer : NULL));
    request.pending = 1;
    assert(ios_apc_requeue_target(&issuer, &apc) == (on ? &issuer : NULL));
    request.thread = &other;
    assert(!ios_apc_requeue_target(&issuer, &apc));
    request.thread = &issuer;
    request.blocking = 0;
    assert(!ios_apc_requeue_target(&issuer, &apc));
    request.blocking = 1; request.wait_handle = 0;
    assert(!ios_apc_requeue_target(&issuer, &apc));
    request.wait_handle = 7; apc.owner = NULL;
    assert(!ios_apc_requeue_target(&issuer, &apc));
    apc.owner = &unrelated;
    assert(!ios_apc_requeue_target(&issuer, &apc));
    apc.owner = &request.obj; apc.call.type = APC_NONE;
    assert(!ios_apc_requeue_target(&issuer, &apc));
    apc.call.type = APC_ASYNC_IO; other.wait = &wait;
    assert(ios_apc_requeue_target(&issuer, &apc) == (on ? &other : NULL));
    other.state = TERMINATED;
    assert(ios_apc_requeue_target(&issuer, &apc) == (on ? &issuer : NULL));
    other.state = 0; other.suspended = 1;
    assert(ios_apc_requeue_target(&issuer, &apc) == (on ? &issuer : NULL));
    return 0;
}
'''.replace("OWNER", owner).replace("ENABLED", enabled).replace("ROUTE", route)

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    c, binary = directory / "route.c", directory / "route"
    c.write_text(harness)
    subprocess.run([os.environ.get("CC", "clang"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsanitize=address,undefined", "-I", str(root / "include"), str(c),
                    "-o", str(binary)], check=True)
    for setting in (None, "0", "1"):
        env = dict(os.environ)
        env.pop("MADEIRA_APC_REQUEUE", None)
        if setting is not None:
            env["MADEIRA_APC_REQUEUE"] = setting
        subprocess.run([str(binary)], env=env, check=True, capture_output=True)
print("PASS: early ioctl completion, issuer checks, waiting-thread routing, and rollback")
