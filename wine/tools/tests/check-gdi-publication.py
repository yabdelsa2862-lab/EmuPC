#!/usr/bin/env python3
"""Compile the process check shared by the GDI call sites."""
from pathlib import Path
import subprocess
import tempfile
root=Path(__file__).resolve().parents[2]
s=(root/'dlls/win32u/win32u_private.h').read_text()
a=s.index('static inline void win32u_gdi_check_publish(void)\n{')
fn=s[a:s.index('\n}',a)+2]
code=r'''
#include <assert.h>
#include <stdio.h>
static struct { void *Peb; int WowTebOffset; } teb;
static void *win32u_gdi_published_peb;
static int win32u_wow_session, published, reported;
#define NtCurrentTeb() (&teb)
static void win32u_gdi_publish_shared(void) { published++; win32u_gdi_published_peb=teb.Peb; }
static void win32u_gdi_report_private(void) { reported++; win32u_gdi_published_peb=teb.Peb; }
FUNCTION
int main(void) {
    teb.Peb=(void *)1; win32u_gdi_check_publish(); assert(published==1 && !reported);
    win32u_gdi_check_publish(); assert(published==1);
    teb.Peb=(void *)2; win32u_gdi_check_publish(); assert(published==2);
    teb.Peb=(void *)3; teb.WowTebOffset=1;
    win32u_gdi_check_publish(); assert(published==2 && reported==1);
    win32u_gdi_check_publish(); assert(reported==1);
    teb.Peb=(void *)4; win32u_wow_session=1;
    win32u_gdi_check_publish(); assert(published==3 && reported==1);
    puts("PASS: each 64-bit child publishes once; private and shared WoW64 routes are retained");
}
'''.replace('FUNCTION',fn)
with tempfile.TemporaryDirectory() as d:
    c,exe=Path(d)/'gdi.c',Path(d)/'gdi';c.write_text(code)
    subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',str(c),'-o',str(exe)],check=True)
    subprocess.run([str(exe)],check=True)
