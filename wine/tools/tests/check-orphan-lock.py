#!/usr/bin/env python3
"""Compile the production monitor walk and check safe release decisions."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
s = (root / 'dlls/ntdll/unix/sync.c').read_text()
a = s.index('void ios_orphan_check(')
walk = s[a:s.index('\n}', a) + 2]
code = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
typedef uintptr_t ULONG_PTR;
#define IOS_ALERT_WAITER_MAX 16
static struct { const void *addr; } ios_alert_waiters[IOS_ALERT_WAITER_MAX];
static int releases;
static void ios_srw_reap_exclusive(unsigned long long lock, unsigned long long owner)
{ (void)lock; (void)owner; releases++; }
WALK
int main(void) {
    unsigned *word = mmap((void *)0x20000000, 0x4000, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANON, -1, 0);
    assert(word != MAP_FAILED && (uintptr_t)word < 0x8000000000ULL);
    unsigned long long lock = (uintptr_t)word, stamp[70];
    for (int i=0;i<4;i++) ios_alert_waiters[i].addr=(char *)word+2;
    *word=0x10009;
    for(int i=0;i<4;i++) ios_orphan_check(NULL,0);
    assert(!releases); /* guest locks are never stamped */
    ios_orphan_check(&lock,1); assert(!releases);
    ios_orphan_check(NULL,0); assert(!releases);
    *word=0x10007; /* handoff resets the strike count */
    ios_orphan_check(NULL,0); assert(!releases);
    ios_orphan_check(NULL,0); assert(!releases);
    ios_orphan_check(NULL,0); assert(releases==1);
    /* More than 32 distinct locks must not disable new stamped locks. */
    for(int i=0;i<70;i++) stamp[i]=0x30000000ULL+i*4;
    ios_orphan_check(stamp,70);
    *word=0x10009;
    ios_orphan_check(&lock,1);
    ios_orphan_check(NULL,0); ios_orphan_check(NULL,0); assert(releases==1);
    ios_orphan_check(NULL,0); assert(releases==2);
    setenv("MADEIRA_LOCK_ORPHAN","0",1);
    for(int i=0;i<4;i++) ios_orphan_check(NULL,0);
    assert(releases==2);
    munmap(word,0x4000);
    puts("PASS: guest locks, one strike per cycle, handoff reset, bounded history, rollback");
}
'''.replace('WALK', walk)
with tempfile.TemporaryDirectory() as d:
    c, exe = Path(d)/'lock.c', Path(d)/'lock'
    c.write_text(code)
    subprocess.run(['cc','-std=c11','-D_DARWIN_C_SOURCE','-g','-fsanitize=address,undefined',str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
