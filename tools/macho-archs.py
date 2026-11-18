#!/usr/bin/env python3
"""Prints the architectures in a Mach-O file, one per line: i386, ppc, x86_64,
arm, arm64, ppc64. Thin or fat, either byte order. lipo -archs does this for
the formats it knows, but it can't read a thin PowerPC binary any more.

usage: macho-archs.py FILE   (prints nothing for a file that isn't Mach-O)
"""
import struct
import sys

NAMES = {7: "i386", 18: "ppc", 0x01000007: "x86_64", 12: "arm", 0x0100000C: "arm64", 0x01000012: "ppc64"}


def archs(path):
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            return []
        magic, = struct.unpack(">I", head[:4])
        if magic in (0xCAFEBABE, 0xCAFEBABF):  # fat (BE); a 32- or 64-bit table
            count, = struct.unpack(">I", head[4:8])
            if count > 32:  # Java class files share the 0xCAFEBABE magic
                return []
            entry = 32 if magic == 0xCAFEBABF else 20
            found = []
            for i in range(count):
                row = f.read(entry)
                if len(row) < 4:
                    break
                found.append(NAMES.get(struct.unpack(">I", row[:4])[0]))
            return [n for n in found if n]
        if magic in (0xFEEDFACE, 0xFEEDFACF):  # thin, big-endian
            cpu, = struct.unpack(">I", head[4:8])
        elif struct.unpack("<I", head[:4])[0] in (0xFEEDFACE, 0xFEEDFACF):  # thin, little-endian
            cpu, = struct.unpack("<I", head[4:8])
        else:
            return []
        return [NAMES[cpu]] if cpu in NAMES else []


if __name__ == "__main__":
    print("\n".join(archs(sys.argv[1])))
