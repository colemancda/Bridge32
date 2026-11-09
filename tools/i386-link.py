#!/usr/bin/env python3
"""A small static linker for Bridge32's i386 guest tests.

Apple's ld stopped linking i386 in Xcode 15 and lld never did, but clang
still compiles i386 objects. This turns one relocatable object (compiled
with -mdynamic-no-pic) into an i386 MH_EXECUTE that Bridge32's loader
accepts: every undefined function gets a stub through a lazy symbol pointer,
data imports keep their non-lazy pointers, and LC_MAIN points at _main. It is
not a general linker: one object, no dyld-side binding, no unwind tables.

    i386-link.py -o hello hello.o

Two more modes produce what the loader meets in binaries from the Mac OS X
10.4 era, which no current tool writes:

    i386-link.py --classic --entry start -o tool tool.o
        LC_UNIXTHREAD instead of LC_MAIN, and imports through a self-modifying
        __IMPORT,__jump_table instead of stubs and lazy pointers.

    i386-link.py --dylib -o libfoo.dylib foo.o
        A dylib linked at address 0, with a jump table and local relocations
        for the loader to slide: every other one scattered, and any section
        named __absolute covered by R_ABS relocations the loader must ignore.
"""
import argparse
import struct
import sys

MH_MAGIC, MH_OBJECT, MH_EXECUTE, MH_DYLIB = 0xFEEDFACE, 1, 2, 6
CPU_TYPE_I386, CPU_SUBTYPE_I386_ALL = 7, 3
MH_NOUNDEFS, MH_DYLDLINK, MH_TWOLEVEL = 0x1, 0x4, 0x80
LC_SEGMENT, LC_SYMTAB, LC_DYSYMTAB, LC_LOAD_DYLINKER, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_UNIXTHREAD = 0x1, 0x2, 0xB, 0xE, 0xC, 0xD, 0x5
LC_MAIN, LC_BUILD_VERSION = 0x80000028, 0x32
VM_PROT_READ, VM_PROT_WRITE, VM_PROT_EXECUTE = 1, 2, 4
S_REGULAR, S_ZEROFILL, S_CSTRING_LITERALS, S_NON_LAZY_SYMBOL_POINTERS, S_LAZY_SYMBOL_POINTERS, S_SYMBOL_STUBS = 0, 1, 2, 6, 7, 8
S_MOD_INIT_FUNC_POINTERS = 9
SECTION_TYPE, S_ATTR_PURE_INSTRUCTIONS, S_ATTR_SOME_INSTRUCTIONS, S_ATTR_SELF_MODIFYING_CODE = 0xFF, 0x80000000, 0x400, 0x04000000
N_STAB, N_PEXT, N_TYPE, N_EXT = 0xE0, 0x10, 0x0E, 0x01
N_UNDF, N_ABS, N_SECT = 0x0, 0x2, 0xE
R_SCATTERED = 0x80000000
GENERIC_RELOC_VANILLA, GENERIC_RELOC_PAIR, GENERIC_RELOC_SECTDIFF, GENERIC_RELOC_LOCAL_SECTDIFF = 0, 1, 2, 4
INDIRECT_SYMBOL_LOCAL, INDIRECT_SYMBOL_ABS = 0x80000000, 0x40000000
R_ABS = 0
PAGE = 0x1000
JUMP_ENTRY = 5


class Section:
    def __init__(self, sectname, segname, addr, size, offset, align, reloff, nreloc, flags, reserved1, reserved2):
        self.sectname, self.segname = sectname, segname
        self.addr, self.size, self.offset, self.align = addr, size, offset, align
        self.reloff, self.nreloc, self.flags = reloff, nreloc, flags
        self.reserved1, self.reserved2 = reserved1, reserved2
        self.data = b""
        self.relocs = []
        self.out_addr = None  # assigned by layout
        self.out_segment = None

    @property
    def type(self):
        return self.flags & SECTION_TYPE

    @property
    def zerofill(self):
        return self.type == S_ZEROFILL


class Symbol:
    def __init__(self, name, n_type, n_sect, n_desc, n_value):
        self.name, self.n_type, self.n_sect, self.n_desc, self.n_value = name, n_type, n_sect, n_desc, n_value
        self.out_value = None
        self.out_index = None

    @property
    def external(self):
        return bool(self.n_type & N_EXT)

    @property
    def undefined(self):
        return (self.n_type & N_TYPE) == N_UNDF

    @property
    def common(self):
        return self.undefined and self.n_value != 0

    @property
    def defined_in_section(self):
        return (self.n_type & N_TYPE) == N_SECT


def cstr(b):
    return b.split(b"\0", 1)[0].decode()


def read_object(path):
    data = open(path, "rb").read()
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack_from("<7I", data, 0)
    if magic != MH_MAGIC or cputype != CPU_TYPE_I386 or filetype != MH_OBJECT:
        sys.exit(f"{path}: not an i386 Mach-O object")
    sections, symbols, indirect = [], [], []
    off = 28
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<2I", data, off)
        if cmd == LC_SEGMENT:
            nsects = struct.unpack_from("<I", data, off + 48)[0]
            for s in range(nsects):
                so = off + 56 + s * 68
                sectname, segname = cstr(data[so:so + 16]), cstr(data[so + 16:so + 32])
                fields = struct.unpack_from("<9I", data, so + 32)
                sec = Section(sectname, segname, *fields)
                if not sec.zerofill:
                    sec.data = data[sec.offset:sec.offset + sec.size]
                for r in range(sec.nreloc):
                    r_address, r_info = struct.unpack_from("<Ii", data, sec.reloff + r * 8)
                    r_address &= 0xFFFFFFFF
                    sec.relocs.append((r_address, r_info & 0xFFFFFFFF))
                sections.append(sec)
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<4I", data, off + 8)
            for i in range(nsyms):
                n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBhI", data, symoff + i * 12)
                symbols.append(Symbol(cstr(data[stroff + n_strx:stroff + n_strx + 4096]), n_type, n_sect, n_desc, n_value))
        elif cmd == LC_DYSYMTAB:
            indirectsymoff, nindirectsyms = struct.unpack_from("<2I", data, off + 56)
            indirect = list(struct.unpack_from(f"<{nindirectsyms}I", data, indirectsymoff))
        off += cmdsize
    return sections, symbols, indirect


def align_up(v, a):
    return (v + a - 1) & ~(a - 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", dest="output", required=True)
    ap.add_argument("--classic", action="store_true")
    ap.add_argument("--entry", default="_main")
    ap.add_argument("--dylib", action="store_true")
    ap.add_argument("object")
    args = ap.parse_args()
    classic = args.classic or args.dylib
    TEXT_BASE = 0 if args.dylib else 0x1000
    install_name = ("/usr/lib/" + args.output.rsplit("/", 1)[-1]).encode() + b"\0"
    sections, symbols, indirect = read_object(args.object)

    # Sections that are dropped: unwind tables and debug info are never read by Bridge32.
    def kept(sec):
        if sec.segname in ("__LD", "__DWARF"):
            return False
        if sec.sectname in ("__eh_frame", "__compact_unwind"):
            return False
        return True

    text_secs = [s for s in sections if kept(s) and s.segname == "__TEXT"]
    data_secs = [s for s in sections if kept(s) and s.segname in ("__DATA", "__IMPORT") and not s.zerofill]
    bss_secs = [s for s in sections if kept(s) and s.segname in ("__DATA", "__IMPORT") and s.zerofill]
    for s in sections:
        if kept(s) and s not in text_secs + data_secs + bss_secs:
            sys.exit(f"unsupported section {s.segname},{s.sectname}")
    for s in data_secs + bss_secs:
        s.out_segment = "__DATA"
    for s in text_secs:
        s.out_segment = "__TEXT"

    # Imports: undefined, non-common externals. Functions and data alike get a
    # stub (jmp *lazy_pointer); direct data references go through the object's
    # own non-lazy pointer sections.
    imports = [s for s in symbols if s.external and s.undefined and not s.common]
    commons = [s for s in symbols if s.common]
    import_index = {s.name: i for i, s in enumerate(imports)}

    import_secs = []
    if classic:
        # Non-lazy pointers live with the jump table in __IMPORT, as ld wrote them.
        import_secs = [s for s in data_secs if s.type == S_NON_LAZY_SYMBOL_POINTERS]
        data_secs = [s for s in data_secs if s not in import_secs]
        stubs = Section("__jump_table", "__IMPORT", 0, JUMP_ENTRY * len(imports), 0, 0, 0, 0,
                        S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS | S_ATTR_SELF_MODIFYING_CODE,
                        0, JUMP_ENTRY)
        stubs.data = b"\xF4" * stubs.size  # hlt, until dyld patches each entry
        import_secs.append(stubs)
        for sec in import_secs:
            sec.out_segment = "__IMPORT"
        la_ptr = None
        stub_size = JUMP_ENTRY
    else:
        stubs = Section("__stubs", "__TEXT", 0, 6 * len(imports), 0, 1, 0, 0,
                        S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0, 6)
        stubs.out_segment = "__TEXT"
        la_ptr = Section("__la_symbol_ptr", "__DATA", 0, 4 * len(imports), 0, 2, 0, 0, S_LAZY_SYMBOL_POINTERS, 0, 0)
        la_ptr.out_segment = "__DATA"
        la_ptr.data = b"\0" * la_ptr.size
        text_secs.append(stubs)
        data_secs.append(la_ptr)
        stub_size = 6

    # Layout. __TEXT holds the header and load commands first.
    out_sections = text_secs + data_secs + bss_secs + import_secs
    header_size = 28
    def dylib_cmd_size(name):
        return 24 + align_up(len(name), 4)
    libsystem = b"/usr/lib/libSystem.B.dylib\0"
    dylinker = b"/usr/lib/dyld\0"
    segment_count = 3 + (0 if args.dylib else 1) + (1 if classic else 0)
    cmds_size = 56 * segment_count + 68 * len(out_sections) + 24 + 80 + dylib_cmd_size(libsystem)
    if args.dylib:
        cmds_size += dylib_cmd_size(install_name)
    else:
        cmds_size += 12 + align_up(len(dylinker), 4)
        cmds_size += 16 + 64 if classic else 24 + 24  # LC_UNIXTHREAD, or LC_BUILD_VERSION and LC_MAIN
    addr = TEXT_BASE + header_size + cmds_size
    for s in text_secs:
        addr = align_up(addr, 1 << s.align)
        s.out_addr = addr
        addr += s.size
    text_end = align_up(addr, PAGE)
    addr = text_end
    data_start = addr
    for s in data_secs:
        addr = align_up(addr, 1 << s.align)
        s.out_addr = addr
        addr += s.size
    data_file_end = addr
    for s in bss_secs:
        addr = align_up(addr, 1 << s.align)
        s.out_addr = addr
        addr += s.size
    # Common symbols get space after the bss sections.
    common_base = align_up(addr, 16)
    for sym in commons:
        align = max(4, 1 << ((sym.n_desc >> 8) & 0xF))  # GET_COMM_ALIGN
        common_base = align_up(common_base, align)
        sym.out_value = common_base
        common_base += sym.n_value
    data_end = align_up(common_base, PAGE)
    addr = import_start = data_end
    for s in import_secs:
        addr = align_up(addr, 1 << s.align)
        s.out_addr = addr
        addr += s.size
    import_file_end = addr
    import_end = align_up(addr, PAGE) if import_secs else data_end

    in_sections = sections  # 1-based n_sect indexes into this
    def section_of_addr(a):
        for s in in_sections:
            if s.addr <= a < s.addr + max(s.size, 1):
                return s
        sys.exit(f"no input section contains 0x{a:x}")

    def delta(sec):
        if sec.out_addr is None:
            sys.exit(f"relocation into dropped section {sec.segname},{sec.sectname}")
        return sec.out_addr - sec.addr

    stub_addr = lambda i: stubs.out_addr + stub_size * i

    # Addresses of the 4-byte words holding an address inside this image, and
    # the words of __absolute sections: the dylib's local relocations.
    slid_words, absolute_words = [], []

    # Symbol values.
    for sym in symbols:
        if sym.defined_in_section:
            sec = in_sections[sym.n_sect - 1]
            if sec.out_addr is None:
                continue
            sym.out_value = sym.n_value + delta(sec)
        elif (sym.n_type & N_TYPE) == N_ABS:
            sym.out_value = sym.n_value
    for sym in imports:
        sym.out_value = 0

    def symbol_address(sym):
        if sym.name in import_index and sym.undefined and not sym.common:
            return stub_addr(import_index[sym.name])
        if sym.out_value is None:
            sys.exit(f"symbol {sym.name} has no address")
        return sym.out_value

    # Relocations.
    for sec in sections:
        if sec.out_addr is None or sec.zerofill:
            continue
        buf = bytearray(sec.data)
        relocs = sec.relocs
        i = 0
        while i < len(relocs):
            r_address, r_info = relocs[i]
            if r_address & R_SCATTERED:
                r_type = (r_address >> 24) & 0xF
                r_length = (r_address >> 28) & 3
                r_pcrel = (r_address >> 30) & 1
                offset = r_address & 0xFFFFFF
                r_value = r_info
                if r_type in (GENERIC_RELOC_SECTDIFF, GENERIC_RELOC_LOCAL_SECTDIFF):
                    pair_address, pair_value = relocs[i + 1]
                    i += 1
                    if r_length != 2:
                        sys.exit("sectdiff of unsupported length")
                    content = struct.unpack_from("<i", buf, offset)[0]
                    a_out = r_value + delta(section_of_addr(r_value))
                    b_out = pair_value + delta(section_of_addr(pair_value))
                    struct.pack_into("<i", buf, offset, content - (r_value - pair_value) + (a_out - b_out))
                elif r_type == GENERIC_RELOC_VANILLA and not r_pcrel and r_length == 2:
                    content = struct.unpack_from("<I", buf, offset)[0]
                    struct.pack_into("<I", buf, offset, (content + delta(section_of_addr(r_value))) & 0xFFFFFFFF)
                    slid_words.append(sec.out_addr + offset)
                else:
                    sys.exit(f"unsupported scattered relocation type {r_type} in {sec.sectname}")
                i += 1
                continue
            r_symbolnum = r_info & 0xFFFFFF
            r_pcrel = (r_info >> 24) & 1
            r_length = (r_info >> 25) & 3
            r_extern = (r_info >> 27) & 1
            r_type = (r_info >> 28) & 0xF
            if r_type != GENERIC_RELOC_VANILLA or r_length != 2:
                sys.exit(f"unsupported relocation type {r_type} length {r_length} in {sec.sectname}")
            offset = r_address
            content = struct.unpack_from("<i", buf, offset)[0]
            place_in = sec.addr + offset
            place_out = sec.out_addr + offset
            if r_extern:
                target = symbol_address(symbols[r_symbolnum])
                if r_pcrel:
                    # The assembler stored A - (P_in + 4) with S = 0.
                    addend = content + place_in + 4
                    value = target + addend - (place_out + 4)
                else:
                    value = target + content
                    slid_words.append(place_out)
            else:
                tsec = in_sections[r_symbolnum - 1]
                if r_pcrel:
                    value = content + delta(tsec) - (place_out - place_in)
                else:
                    value = content + delta(tsec)
                    slid_words.append(place_out)
            struct.pack_into("<I", buf, offset, value & 0xFFFFFFFF)
            i += 1
        sec.data = bytes(buf)

    for sec in out_sections:
        if sec.sectname == "__absolute":
            absolute_words += [sec.out_addr + k for k in range(0, sec.size, 4)]

    # Stubs: jmp *la_ptr[i].
    if not classic:
        stub_code = bytearray()
        for i in range(len(imports)):
            stub_code += b"\xFF\x25" + struct.pack("<I", la_ptr.out_addr + 4 * i)
        stubs.data = bytes(stub_code)

    # Output symbol table: defined externals first (sorted), then undefined.
    defined = sorted([s for s in symbols if s.external and not s.undefined and s.out_value is not None], key=lambda s: s.name)
    for s in commons:
        s.n_type = N_SECT | N_EXT
        s.n_sect = 0  # set below
    out_syms = defined + imports
    strtab = bytearray(b"\0")
    nlist = bytearray()
    for idx, s in enumerate(out_syms):
        s.out_index = idx
    # Output section ordinals (1-based) for N_SECT symbols.
    ordinal = {id(s): i + 1 for i, s in enumerate(out_sections)}
    for s in out_syms:
        n_strx = len(strtab)
        strtab += s.name.encode() + b"\0"
        if s.undefined and not s.common:
            nlist += struct.pack("<IBBhI", n_strx, N_UNDF | N_EXT, 0, 0, 0)
        elif s.common:
            nlist += struct.pack("<IBBhI", n_strx, N_SECT | N_EXT, ordinal[id(bss_secs[-1])] if bss_secs else ordinal[id(data_secs[-1])], 0, s.out_value)
        else:
            sect = ordinal[id(in_sections[s.n_sect - 1])] if s.defined_in_section else 0
            nlist += struct.pack("<IBBhI", n_strx, s.n_type & ~N_PEXT, sect, s.n_desc, s.out_value)

    # Indirect symbol table: non-lazy pointer sections from the object, then our lazy pointers.
    out_indirect = []
    for sec in data_secs + import_secs:
        if sec.type == S_NON_LAZY_SYMBOL_POINTERS and sec is not la_ptr:
            start = len(out_indirect)
            for k in range(sec.size // 4):
                entry = indirect[sec.reserved1 + k]
                if entry & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS):
                    out_indirect.append(entry)
                else:
                    sym = symbols[entry]
                    if sym.out_index is None:
                        # A non-lazy pointer to a local: the pointer already holds its address, relocated above.
                        out_indirect.append(INDIRECT_SYMBOL_LOCAL)
                    else:
                        out_indirect.append(sym.out_index)
            sec.reserved1 = start
    stubs.reserved1 = len(out_indirect)
    if la_ptr:
        la_ptr.reserved1 = len(out_indirect)
    for s in imports:
        out_indirect.append(s.out_index)

    # Entry point.
    main_sym = None
    if not args.dylib:
        main_sym = next((s for s in symbols if s.name == args.entry and s.defined_in_section), None)
        if not main_sym:
            sys.exit(f"no {args.entry}")

    # File layout: __TEXT at file 0, __DATA, then __LINKEDIT.
    text_file_size = text_end - TEXT_BASE
    data_file_size = align_up(data_file_end - data_start, PAGE) if data_secs else 0
    import_file_off = text_file_size + data_file_size
    import_file_size = align_up(import_file_end - import_start, PAGE) if import_secs else 0
    linkedit_off = import_file_off + import_file_size
    out = bytearray(linkedit_off)
    for s in text_secs:
        s.offset = s.out_addr - TEXT_BASE
        out[s.offset:s.offset + len(s.data)] = s.data
    for s in data_secs:
        s.offset = text_file_size + (s.out_addr - data_start)
        out[s.offset:s.offset + len(s.data)] = s.data
    for s in import_secs:
        s.offset = import_file_off + (s.out_addr - import_start)
        out[s.offset:s.offset + len(s.data)] = s.data
    # Local relocations, in the dylib only: r_address is relative to the first
    # segment, which is at 0. A scattered one carries the target in r_value; a
    # plain one the ordinal of the section.
    locrel = bytearray()
    if args.dylib:
        for i, where in enumerate(sorted(set(slid_words) - set(absolute_words))):
            target = struct.unpack_from("<I", out, where)[0]
            if i % 2:
                locrel += struct.pack("<II", R_SCATTERED | (2 << 28) | where, target)
            else:
                locrel += struct.pack("<II", where, 1 | (2 << 25))
        for where in absolute_words:
            locrel += struct.pack("<II", where, R_ABS | (2 << 25))
    locreloff = linkedit_off
    symoff = locreloff + len(locrel)
    indirectsymoff = symoff + len(nlist)
    stroff = indirectsymoff + 4 * len(out_indirect)
    strtab += b"\0" * (align_up(len(strtab), 4) - len(strtab))
    linkedit = bytes(locrel) + bytes(nlist) + struct.pack(f"<{len(out_indirect)}I", *out_indirect) + bytes(strtab)
    out += linkedit

    def segment(name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, secs):
        cmd = struct.pack("<2I16s8I", LC_SEGMENT, 56 + 68 * len(secs), name.encode(), vmaddr, vmsize, fileoff, filesize,
                          maxprot, initprot, len(secs), 0)
        for s in secs:
            cmd += struct.pack("<16s16s9I", s.sectname.encode(), s.out_segment.encode(), s.out_addr, s.size,
                               0 if s.zerofill else s.offset, s.align, 0, 0, s.flags, s.reserved1, s.reserved2)
        return cmd

    def dylib_cmd(kind, name):
        size = dylib_cmd_size(name)
        return struct.pack("<6I", kind, size, 24, 2, 0x4F0000, 0x10000) + name.ljust(size - 24, b"\0")

    cmds = b""
    ncmds = 0
    def add(cmd):
        nonlocal cmds, ncmds
        cmds += cmd
        ncmds += 1

    rx, rw = VM_PROT_READ | VM_PROT_EXECUTE, VM_PROT_READ | VM_PROT_WRITE
    if not args.dylib:
        add(segment("__PAGEZERO", 0, TEXT_BASE, 0, 0, 0, 0, []))
    add(segment("__TEXT", TEXT_BASE, text_file_size, 0, text_file_size, rx, rx, text_secs))
    add(segment("__DATA", data_start, data_end - data_start, text_file_size, data_file_size, rw, rw, data_secs + bss_secs))
    if import_secs:
        rwx = rw | VM_PROT_EXECUTE
        add(segment("__IMPORT", import_start, import_end - import_start, import_file_off, import_file_size, rwx, rwx, import_secs))
    add(segment("__LINKEDIT", import_end, align_up(len(linkedit), PAGE), linkedit_off, len(linkedit), VM_PROT_READ,
                VM_PROT_READ, []))
    add(struct.pack("<6I", LC_SYMTAB, 24, symoff, len(out_syms), stroff, len(strtab)))
    nundef = len(imports)
    add(struct.pack("<20I", LC_DYSYMTAB, 80, 0, 0, 0, len(defined), len(defined), nundef, 0, 0, 0, 0, 0, 0,
                    indirectsymoff, len(out_indirect), 0, 0, locreloff, len(locrel) // 8))
    if args.dylib:
        add(dylib_cmd(LC_ID_DYLIB, install_name))
    else:
        add(struct.pack("<3I", LC_LOAD_DYLINKER, 12 + align_up(len(dylinker), 4), 12) + dylinker.ljust(align_up(len(dylinker), 4), b"\0"))
    add(dylib_cmd(LC_LOAD_DYLIB, libsystem))
    if classic and not args.dylib:
        # x86_thread_state32: eax ebx ecx edx edi esi ebp esp ss eflags eip cs ds es fs gs.
        state = [0] * 16
        state[10] = main_sym.out_value
        add(struct.pack("<4I16I", LC_UNIXTHREAD, 80, 1, 16, *state))
    elif not args.dylib:
        add(struct.pack("<2I4I", LC_BUILD_VERSION, 24, 1, 0x000A0D00, 0x000A0D00, 0))  # macOS 10.13, no tools
        add(struct.pack("<2IQQ", LC_MAIN, 24, main_sym.out_value - TEXT_BASE, 0))
    filetype = MH_DYLIB if args.dylib else MH_EXECUTE
    header = struct.pack("<7I", MH_MAGIC, CPU_TYPE_I386, CPU_SUBTYPE_I386_ALL, filetype, ncmds, len(cmds),
                         MH_DYLDLINK | MH_TWOLEVEL)
    out[0:28] = header
    if 28 + len(cmds) > text_secs[0].offset:
        sys.exit("load commands overlap the first section; raise the estimate")
    out[28:28 + len(cmds)] = cmds
    with open(args.output, "wb") as f:
        f.write(out)
    entry = f"entry 0x{main_sym.out_value:x}" if main_sym else f"{len(locrel) // 8} local relocations"
    print(f"{args.output}: {len(imports)} imports, {len(defined)} exports, {entry}")


if __name__ == "__main__":
    main()
