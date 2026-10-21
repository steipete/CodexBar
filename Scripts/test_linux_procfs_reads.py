#!/usr/bin/env python3
"""Check Linux procfs teardown allocations in an isolated glibc process.

Compile the actual terminator enum without the app or a parallel test runner.
Pass an older TTYCommandRunner.swift to reproduce the regression on that source.
"""
import pathlib
import subprocess
import sys
import tempfile
source_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
    pathlib.Path(__file__).resolve().parents[1]
    / "Sources/CodexBarCore/Host/PTY/TTYCommandRunner.swift")
source = source_path.read_text()
start = source.index('enum TTYProcessTreeTerminator {')
end = source.index('\nprivate enum TTYCommandRunnerTestingOverrides', start)
with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    (root / 'heap.c').write_text('#include <malloc.h>\n#include <stdint.h>\nuint64_t allocated_bytes(void) { return mallinfo2().uordblks; }\n')
    (root / 'main.swift').write_text('import Foundation\nimport Glibc\n' + source[start:end] + '''
@_silgen_name("allocated_bytes") func allocatedBytes() -> UInt64
for _ in 0..<100 { _ = TTYProcessTreeTerminator.currentChildPIDs(of: getpid()) }
// Warm up Foundation before measuring live allocations, not RSS or elapsed time.
let before = allocatedBytes()
for _ in 0..<10000 { _ = TTYProcessTreeTerminator.currentChildPIDs(of: getpid()) }
let after = allocatedBytes()
let growth = after > before ? after - before : 0
print("procfs reads=10000 retained_bytes=\\(growth) limit_bytes=1048576")
exit(growth <= 1048576 ? 0 : 1)
''')
    subprocess.run(['clang', '-c', str(root / 'heap.c'), '-o', str(root / 'heap.o')], check=True)
    subprocess.run(['swiftc', '-gnone', str(root / 'main.swift'), str(root / 'heap.o'), '-o', str(root / 'check')], check=True)
    sys.exit(subprocess.run([str(root / 'check')]).returncode)
