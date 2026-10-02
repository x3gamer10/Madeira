#!/usr/bin/env python3
"""PE helpers for rebuilt Wine modules (tools/build-all-macos.sh, stage_wine_arm64ec).

  pe-sections.py pad-ntdll FILE
      Pad FILE with zeros to SizeOfImage + 0x50000, as build/wine-pe/build-ntdll.sh
      does for the tracked ARM64EC ntdll.dll (the loader maps the file image; the
      padding is the slack the iOS mapping path relies on).

  pe-sections.py compare REBUILT TRACKED
      Say whether REBUILT reproduces TRACKED section by section. The header's
      TimeDateStamp and CheckSum are ignored; everything else must match for
      "identical". Informational: always exits 0.

  pe-sections.py has-utf16 FILE TEXT
      Exit 0 if FILE contains TEXT as a UTF-16LE string (a wide literal), else 1.
"""
import hashlib
import struct
import sys


def headers(d):
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    if d[pe:pe + 4] != b'PE\0\0':
        raise SystemExit('not a PE file')
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    opt_size = struct.unpack_from('<H', d, pe + 20)[0]
    opt = pe + 24
    sec = opt + opt_size
    sections = []
    for i in range(nsec):
        o = sec + 40 * i
        name = d[o:o + 8].rstrip(b'\0').decode('ascii', 'replace')
        vsize, vaddr, rsize, rptr = struct.unpack_from('<IIII', d, o + 8)
        sections.append((name, vaddr, vsize, d[rptr:rptr + rsize]))
    return pe, opt, sec + 40 * nsec, sections


def pad_ntdll(path):
    d = open(path, 'rb').read()
    _, opt, _, _ = headers(d)
    soi = struct.unpack_from('<I', d, opt + 56)[0]
    target = soi + 0x50000
    if len(d) > target:
        raise SystemExit('%s is %d bytes, already larger than SizeOfImage + 0x50000 = %d'
                         % (path, len(d), target))
    with open(path, 'ab') as f:
        f.write(b'\0' * (target - len(d)))
    print('%s: %d + pad %d = %d bytes (SizeOfImage %#x + 0x50000)'
          % (path, len(d), target - len(d), target, soi))


def compare(rebuilt, tracked):
    a, b = open(rebuilt, 'rb').read(), open(tracked, 'rb').read()
    pa, oa, ea, sa = headers(a)
    pb, ob, eb, sb = headers(b)

    def masked(d, pe, opt, end):
        h = bytearray(d[:end])
        h[pe + 8:pe + 12] = b'\0' * 4      # FileHeader.TimeDateStamp
        h[opt + 64:opt + 68] = b'\0' * 4   # OptionalHeader.CheckSum
        return bytes(h)

    same = True
    if len(a) != len(b):
        print('size: rebuilt %d, tracked %d' % (len(a), len(b)))
        same = False
    if masked(a, pa, oa, ea) != masked(b, pb, ob, eb):
        print('headers differ (beyond TimeDateStamp and CheckSum)')
        same = False
    names_a = [s[0] for s in sa]
    names_b = [s[0] for s in sb]
    if names_a != names_b:
        print('section lists differ: rebuilt %s, tracked %s' % (names_a, names_b))
        same = False
    for (n, va, vs, da), (_, vb, vsb, db) in zip(sa, sb):
        ok = (va, vs, da) == (vb, vsb, db)
        same &= ok
        print('  %-8s %s  vsize %#x/%#x  sha256 %s/%s' % (
            n, 'same     ' if ok else 'DIFFERENT', vs, vsb,
            hashlib.sha256(da).hexdigest()[:12], hashlib.sha256(db).hexdigest()[:12]))
    print('RESULT: rebuilt %s the tracked binary' % ('reproduces' if same else 'does NOT reproduce'))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == 'pad-ntdll':
        pad_ntdll(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == 'compare':
        compare(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 4 and sys.argv[1] == 'has-utf16':
        sys.exit(0 if sys.argv[3].encode('utf-16-le') in open(sys.argv[2], 'rb').read() else 1)
    else:
        raise SystemExit(__doc__)


if __name__ == '__main__':
    main()
