#!/usr/bin/env python3
"""Assembles and links a PowerPC test program into a Mach-O executable.

Apple's ld no longer links PowerPC, and Xcode's clang has no PowerPC target
(see ppc-asm.py), but any LLVM that has one assembles PowerPC as ELF. This
reads that object and writes what Mac OS X 10.4's ld wrote for a program with
no dependencies but libSystem, which is what Bridge32's loader meets in real
binaries: big-endian headers, LC_UNIXTHREAD at `start`, and every undefined
function reached through a __symbol_stub1 stub and a lazy pointer that the
loader binds. It is not a general linker: one object, a .text and a .data
section, and these relocations: R_PPC_REL24 (a call), R_PPC_ADDR16_HA/LO/HI
(an address built with lis and addi) and R_PPC_ADDR32 (a pointer in data).

    ppc-link.py -o hello hello.s

The assembly follows the Darwin ABI, not the SysV one clang's PowerPC backend
assumes, so tests are written in assembly: see tests/guest/ppc/hello.s.
"""
import argparse
import os
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MH_MAGIC, CPU_TYPE_POWERPC, CPU_SUBTYPE_POWERPC_7400, MH_EXECUTE = 0xFEEDFACE, 18, 10, 2
LC_SEGMENT, LC_SYMTAB, LC_DYSYMTAB, LC_LOAD_DYLIB, LC_UNIXTHREAD = 1, 2, 11, 12, 5
S_REGULAR, S_SYMBOL_STUBS, S_LAZY_SYMBOL_POINTERS = 0, 8, 7
S_ATTR_PURE_INSTRUCTIONS, S_ATTR_SOME_INSTRUCTIONS = 0x80000000, 0x400
R_PPC_ADDR32, R_PPC_ADDR16_LO, R_PPC_ADDR16_HI, R_PPC_ADDR16_HA, R_PPC_REL24 = 1, 4, 5, 6, 10
PAGE, STUB_SIZE = 0x1000, 16


def align(value, to):
    return (value + to - 1) // to * to


def assemble(source, obj):
    from importlib.machinery import SourceFileLoader
    helper = SourceFileLoader("ppc_asm", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ppc-asm.py")).load_module()
    clang = helper.find_clang()
    subprocess.run(clang + ["-target", "powerpc-unknown-linux-gnu", "-mcpu=7400", "-maltivec", "-c", "-o", obj, source], check=True)


def read_elf(path):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 1 or data[5] != 2:
        sys.exit("not a 32-bit big-endian ELF object")
    shoff, = struct.unpack(">I", data[0x20:0x24])
    shentsize, shnum, shstrndx = struct.unpack(">3H", data[0x2E:0x34])
    headers = [struct.unpack(">10I", data[shoff + i * shentsize: shoff + i * shentsize + 40]) for i in range(shnum)]
    names = headers[shstrndx]
    strtab = data[names[4]: names[4] + names[5]]
    sections = {}
    for index, (name, kind, flags, addr, offset, size, link, info, alignment, entsize) in enumerate(headers):
        label = strtab[name:strtab.index(b"\0", name)].decode()
        sections[label] = dict(index=index, kind=kind, offset=offset, size=size, link=link, info=info,
                               data=data[offset: offset + size] if kind != 8 else bytes(size))
    sym_section = sections[".symtab"]
    strings = sections[".strtab"]["data"]
    symbols = []
    for i in range(sym_section["size"] // 16):
        name, value, size, info, other, shndx = struct.unpack(">3IBBH", sym_section["data"][i * 16: i * 16 + 16])
        symbols.append(dict(name=strings[name:strings.index(b"\0", name)].decode(), value=value, kind=info & 0xF,
                            bind=info >> 4, shndx=shndx))
    relocations = {}
    for label, section in sections.items():
        if section["kind"] == 4:  # SHT_RELA
            target = [n for n, s in sections.items() if s["index"] == section["info"]][0]
            entries = []
            for i in range(section["size"] // 12):
                offset, info, addend = struct.unpack(">IIi", section["data"][i * 12: i * 12 + 12])
                entries.append((offset, info & 0xFF, info >> 8, addend))
            relocations[target] = entries
    return sections, symbols, relocations


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("-o", dest="output", required=True)
    parser.add_argument("source")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as work:
        obj = args.source
        if not obj.endswith(".o"):
            obj = os.path.join(work, "code.o")
            assemble(args.source, obj)
        sections, symbols, relocations = read_elf(obj)
        text = bytearray(sections[".text"]["data"])
        data = bytearray(sections[".data"]["data"]) if ".data" in sections else bytearray()
        text_index = sections[".text"]["index"]
        data_index = sections[".data"]["index"] if ".data" in sections else None

        # Every undefined symbol that's called gets a stub and a lazy pointer.
        imports = []
        for entries in relocations.values():
            for offset, kind, sym, addend in entries:
                if symbols[sym]["shndx"] == 0 and symbols[sym]["name"] not in imports:
                    imports.append(symbols[sym]["name"])

        # Layout. TEXT: the header and load commands, then __text, then the stubs.
        header_size = 0x400
        text_addr = PAGE + header_size
        stubs_addr = align(text_addr + len(text), 16)
        text_end = stubs_addr + STUB_SIZE * len(imports)
        text_seg_size = align(text_end - PAGE, PAGE)
        data_seg_addr = PAGE + text_seg_size
        lazy_addr = data_seg_addr
        data_addr = align(lazy_addr + 4 * len(imports), 16)
        data_end = data_addr + len(data)
        data_seg_size = align(max(data_end - data_seg_addr, 1), PAGE)
        linkedit_addr = data_seg_addr + data_seg_size

        def address(shndx, value):
            if shndx == text_index:
                return text_addr + value
            if shndx == data_index:
                return data_addr + value
            sys.exit("symbol in an unsupported section")

        def symbol_address(sym):
            s = symbols[sym]
            if s["shndx"] == 0:
                return stubs_addr + STUB_SIZE * imports.index(s["name"])
            return address(s["shndx"], s["value"])

        for section_name, buffer, base in ((".text", text, text_addr), (".data", data, data_addr)):
            for offset, kind, sym, addend in relocations.get(section_name, []):
                place = base + offset
                target = symbol_address(sym) + addend
                if kind == R_PPC_REL24:
                    word, = struct.unpack(">I", buffer[offset: offset + 4])
                    delta = target - place
                    if delta % 4 or not -(1 << 25) <= delta < (1 << 25):
                        sys.exit("call out of range")
                    buffer[offset: offset + 4] = struct.pack(">I", (word & 0xFC000003) | (delta & 0x03FFFFFC))
                elif kind in (R_PPC_ADDR16_LO, R_PPC_ADDR16_HI, R_PPC_ADDR16_HA):
                    value = {R_PPC_ADDR16_LO: target, R_PPC_ADDR16_HI: target >> 16,
                             R_PPC_ADDR16_HA: (target + 0x8000) >> 16}[kind] & 0xFFFF
                    buffer[offset: offset + 2] = struct.pack(">H", value)
                elif kind == R_PPC_ADDR32:
                    buffer[offset: offset + 4] = struct.pack(">I", target)
                else:
                    sys.exit(f"unsupported relocation type {kind}")

        entry = [s for s in symbols if s["name"] == "start" and s["shndx"] == text_index]
        if not entry:
            sys.exit("no `start` label in .text")
        entry_addr = text_addr + entry[0]["value"]

        # The stubs, as ld wrote them: lis r11, ha16(ptr); lwzu r12, lo16(ptr)(r11); mtctr r12; bctr
        stubs = bytearray()
        for i in range(len(imports)):
            pointer = lazy_addr + 4 * i
            ha, lo = ((pointer + 0x8000) >> 16) & 0xFFFF, pointer & 0xFFFF
            stubs += struct.pack(">4I", 0x3D600000 | ha, 0x858B0000 | lo, 0x7D8903A6, 0x4E800420)

        # LINKEDIT: nlist entries for the imports, their names, the indirect symbol table.
        strtab = b"\0" + b"".join(name.encode() + b"\0" for name in imports)
        symtab = b""
        offset = 1
        for name in imports:
            # N_UNDF | N_EXT, flat in libSystem (library 1), a lazy reference.
            symtab += struct.pack(">IBBHI", offset, 0x01, 0, (1 << 8) | 1, 0)
            offset += len(name) + 1
        indirect = b"".join(struct.pack(">I", i) for i in range(len(imports))) * 2
        file_text = header_size + 0  # the TEXT segment's file bytes start at 0
        text_file_size = text_seg_size
        data_file_offset = text_file_size
        data_file_size = data_seg_size
        linkedit_offset = data_file_offset + data_file_size
        symoff = linkedit_offset
        stroff = symoff + len(symtab)
        indirectoff = align(stroff + len(strtab), 4)
        linkedit_size = indirectoff + len(indirect) - linkedit_offset

        def segment(name, vmaddr, vmsize, fileoff, filesize, prot, sects):
            body = struct.pack(">I I 16s 8I", LC_SEGMENT, 56 + 68 * len(sects), name.encode(), vmaddr, vmsize, fileoff,
                               filesize, prot, prot, len(sects), 0)
            for sect in sects:
                sname, sseg, saddr, ssize, soffset, flags, r1, r2 = sect
                body += struct.pack(">16s 16s 9I", sname.encode(), sseg.encode(), saddr, ssize, soffset, 0, 0, 0, flags, r1, r2)
            return body

        commands = [
            segment("__PAGEZERO", 0, PAGE, 0, 0, 0, []),
            segment("__TEXT", PAGE, text_seg_size, 0, text_file_size, 5,
                    [("__text", "__TEXT", text_addr, len(text), text_addr - PAGE, S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0, 0)] +
                    ([("__symbol_stub1", "__TEXT", stubs_addr, len(stubs), stubs_addr - PAGE,
                       S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0, STUB_SIZE)] if imports else [])),
            segment("__DATA", data_seg_addr, data_seg_size, data_file_offset, data_file_size, 3,
                    ([("__la_symbol_ptr", "__DATA", lazy_addr, 4 * len(imports), data_file_offset, S_LAZY_SYMBOL_POINTERS, len(imports), 0)] if imports else []) +
                    [("__data", "__DATA", data_addr, len(data), data_file_offset + data_addr - data_seg_addr, S_REGULAR, 0, 0)]),
            segment("__LINKEDIT", linkedit_addr, align(linkedit_size, PAGE), linkedit_offset, linkedit_size, 1, []),
            struct.pack(">6I", LC_SYMTAB, 24, symoff, len(imports), stroff, len(strtab)),
            struct.pack(">20I", LC_DYSYMTAB, 80, 0, 0, 0, 0, 0, len(imports), 0, 0, 0, 0, 0, 0, indirectoff,
                        len(imports) * 2, 0, 0, 0, 0),
            # PPC_THREAD_STATE: srr0 is the entry point; the kernel sets up r1.
            struct.pack(">4I", LC_UNIXTHREAD, 16 + 160, 1, 40) + struct.pack(">40I", entry_addr, *([0] * 39)),
            struct.pack(">6I", LC_LOAD_DYLIB, 24 + 28, 24, 0, 0x580306, 0x10000) + b"/usr/lib/libSystem.B.dylib\0\0",
        ]
        header = struct.pack(">7I", MH_MAGIC, CPU_TYPE_POWERPC, CPU_SUBTYPE_POWERPC_7400, MH_EXECUTE, len(commands),
                             sum(len(c) for c in commands), 0x85)
        head = header + b"".join(commands)
        if len(head) > header_size:
            sys.exit("load commands don't fit")

        image = bytearray(text_file_size + data_file_size + linkedit_size + 8)
        image[0:len(head)] = head
        image[text_addr - PAGE: text_addr - PAGE + len(text)] = text
        image[stubs_addr - PAGE: stubs_addr - PAGE + len(stubs)] = stubs
        image[data_file_offset + data_addr - data_seg_addr: data_file_offset + data_addr - data_seg_addr + len(data)] = data
        image[symoff: symoff + len(symtab)] = symtab
        image[stroff: stroff + len(strtab)] = strtab
        image[indirectoff: indirectoff + len(indirect)] = indirect
        with open(args.output, "wb") as out:
            out.write(image[: linkedit_offset + linkedit_size])
        os.chmod(args.output, 0o755)


main()
