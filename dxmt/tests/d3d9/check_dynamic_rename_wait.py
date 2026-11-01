#!/usr/bin/env python3
"""Run both production mirror-refresh methods with failed rename and GPU-drain fixtures."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[2] / 'src/d3d9/d3d9_buffer.cpp').read_text()
methods = []
for name in ['MTLD3D9VertexBuffer', 'MTLD3D9IndexBuffer']:
    start = source.index('void\n' + name + '::refreshWholeMirror()')
    methods.append(source[start:source.index('\n}', start) + 2])

fixture = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <initializer_list>
static int failures, calls, writes, waits, in_place;
static bool wait_ok, gpu_idle;
#define FAILED(hr) ((hr) < 0)
struct Logger { static void warn(const char *) {} };
struct Name { void updateContents(int, void *, unsigned, int) {
    assert(calls <= failures ? gpu_idle : true); ++writes;
} };
struct Dynamic {
    Name name;
    Dynamic *ptr() { return this; }
    Dynamic *operator->() { return this; }
    Name *immediateName() { return &name; }
    int immediateSuballocation() { return 0; }
};
struct Device {
    uint64_t m_currentCmdSeq = 2;
    std::atomic<uint64_t> m_cachedSignaled{1};
    bool drainForDynamicRename() { ++waits; gpu_idle = wait_ok; return wait_ok; }
    void noteRenameInPlace() { assert(gpu_idle); ++in_place; }
};
int renameDynamicBuffer(Device *, Dynamic *, uint64_t, uint64_t) { return ++calls <= failures ? -1 : 0; }
struct Mirror {
    bool m_dirty = true, m_direct = false, m_writeLocked = false;
    Device device;
    Device *m_device = &device;
    Dynamic m_dynamic;
    void *m_hostPtr = nullptr;
    unsigned m_size = 16;
};
struct MTLD3D9VertexBuffer : Mirror { void refreshWholeMirror(); };
struct MTLD3D9IndexBuffer : Mirror { void refreshWholeMirror(); };
'''
fixture += '\n'.join(methods)
fixture += r'''
template<class Buffer> void check() {
    for (int fail : {0, 1, 2}) for (bool wait : {false, true}) {
        failures = fail; calls = writes = waits = in_place = 0; gpu_idle = false; wait_ok = wait;
        Buffer buffer;
        buffer.refreshWholeMirror();
        assert(calls == (fail && wait ? 2 : 1));
        assert(waits == (fail ? 1 : 0));
        assert(writes == (!fail || wait ? 1 : 0));
        assert(in_place == (fail == 2 && wait ? 1 : 0));
        assert(buffer.m_dirty == (fail && !wait));
    }
    calls = 0; Buffer direct; direct.m_direct = true;
    direct.refreshWholeMirror(); assert(calls == 0);
    Buffer clean; clean.m_dirty = false;
    clean.refreshWholeMirror(); assert(calls == 0);
    failures = 0; Buffer locked; locked.m_writeLocked = true;
    locked.refreshWholeMirror(); assert(locked.m_dirty);
}
int main() { check<MTLD3D9VertexBuffer>(); check<MTLD3D9IndexBuffer>(); }
'''
with tempfile.TemporaryDirectory(prefix='dxmt-rename-') as folder:
    path = Path(folder)
    (path / 'check.cpp').write_text(fixture)
    subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-fsanitize=address,undefined',
                    str(path / 'check.cpp'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
print('PASS: both mirror callers retry after the GPU drain, preserve failed waits and skip direct buffers')
