#!/usr/bin/env python3
"""Fix the CPUID brand-string crash in the prebuilt 32-bit FEX module
(app/Madeira/aarch64-windows/xtajit.dll, internally libwow64fex.dll).

The bug: FEXCore's CPUIDEmu::Function_8000_000{2,3,4}h(Leaf) index
PerCPUData[GetCPUID()] without the `% PerCPUData.size()` that
RunFunctionName() applies. On iOS, CPUFeatures::FetchHostFeatures (FEX_IOS_HOST)
records a single MIDR, so PerCPUData has one entry, while GetCPUID() is
GetCurrentProcessorNumber() and returns the real core (0-5 on an iPhone). A
32-bit program that reads the CPU brand string (CPUID 0x80000002-4) on any core
but the first reads past the vector, gets a garbage ProductName pointer and
strlen() faults inside ntdll (seen with CoD4 / iw3sp_mod.exe: SEGV in
ntdll.dll+0x68bf4 called from libwow64fex.dll+0x1ca28).

The fix: in each of the three functions, replace the index computation
`ubfiz x9, x0, #4, #32` (CPU * sizeof(CPUData)) with `mov x9, xzr`, i.e. always
entry 0, which is exactly `CPU % PerCPUData.size()` when the size is 1.

The instruction sequence is matched exactly, so a rebuilt or updated DLL that
no longer has it is left alone (with a warning). Idempotent.
"""
import struct
import sys
from pathlib import Path

DLL = Path(__file__).resolve().parent.parent / "app/Madeira/aarch64-windows/xtajit.dll"

# ldr x8,[x0,#0x40]; mov x19,x0; blr x8; ldr x8,[x19,#0x28];
# ubfiz x9,x0,#4,#32; stp xzr,xzr,[sp]; ldr x19,[x8,x9]
ORIGINAL = (0xF9402008, 0xAA0003F3, 0xD63F0100, 0xF9401668, 0xD37C7C09, 0xA9007FFF, 0xF8696913)
INDEX_WORD = 4
MOV_X9_XZR = 0xAA1F03E9
PATCHED = ORIGINAL[:INDEX_WORD] + (MOV_X9_XZR,) + ORIGINAL[INDEX_WORD + 1:]
EXPECTED = 3  # Function_8000_0002h, _0003h, _0004h


def text_section(raw):
    pe = struct.unpack_from("<I", raw, 0x3C)[0]
    if raw[pe:pe + 4] != b"PE\0\0":
        raise SystemExit(f"{DLL}: not a PE file")
    nsec = struct.unpack_from("<H", raw, pe + 6)[0]
    opt_size = struct.unpack_from("<H", raw, pe + 20)[0]
    sec = pe + 24 + opt_size
    for i in range(nsec):
        s = sec + 40 * i
        if raw[s:s + 8].rstrip(b"\0") == b".text":
            size, ptr = struct.unpack_from("<II", raw, s + 16)
            return ptr, size
    raise SystemExit(f"{DLL}: no .text section")


def find(raw, start, size, pattern):
    words = struct.unpack_from(f"<{size // 4}I", raw, start)
    n = len(pattern)
    return [start + 4 * i for i in range(len(words) - n + 1) if words[i:i + n] == pattern]


def main():
    global DLL
    if len(sys.argv) > 1:
        DLL = Path(sys.argv[1])
    raw = bytearray(DLL.read_bytes())
    start, size = text_section(raw)
    todo = find(raw, start, size, ORIGINAL)
    done = find(raw, start, size, PATCHED)
    if not todo and len(done) == EXPECTED:
        print(f"xtajit CPUID fix: already applied ({len(done)} sites)")
        return
    if len(todo) + len(done) != EXPECTED:
        print(f"WARNING: xtajit CPUID fix: found {len(todo)} unpatched and {len(done)} patched sites, "
              f"expected {EXPECTED}; leaving {DLL.name} unchanged")
        return
    for off in todo:
        struct.pack_into("<I", raw, off + 4 * INDEX_WORD, MOV_X9_XZR)
    DLL.write_bytes(raw)
    print(f"xtajit CPUID fix: patched {len(todo)} sites at file offsets "
          + ", ".join(hex(o + 4 * INDEX_WORD) for o in todo))


if __name__ == "__main__":
    sys.exit(main())
