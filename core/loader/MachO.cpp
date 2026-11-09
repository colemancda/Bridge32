#include "MachO.h"

#include "core/Log.h"
#include "core/arch/Arch.h"

#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/reloc.h>
#include <libkern/OSByteOrder.h>

#include <algorithm>
#include <cstring>
#include <fstream>
#include <iterator>
#include <unordered_map>

namespace b32 {

const Section *Image::section(const char *segment, const char *name) const {
    for (const auto &s : sections)
        if (s.segment == segment && s.name == name) return &s;
    return nullptr;
}

namespace {

std::vector<uint8_t> readFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) fatal("cannot open %s", path.c_str());
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
}

std::string fixedName(const char *name, size_t len) { return std::string(name, strnlen(name, len)); }

#if defined(B32_GUEST_ARM)
constexpr cpu_type_t kGuestCpuType = CPU_TYPE_ARM;
// armv7 over armv6.
int sliceRank(uint32_t subtype) { return subtype == CPU_SUBTYPE_ARM_V7 ? 2 : subtype == CPU_SUBTYPE_ARM_V6 ? 1 : 0; }
#elif defined(B32_GUEST_PPC)
constexpr cpu_type_t kGuestCpuType = CPU_TYPE_POWERPC;
// A G4 (7400, 7450) over a G3 (750) over code for any PowerPC; a G5's 970 slice
// needs 64-bit hardware.
int sliceRank(uint32_t subtype) {
    switch (subtype) {
    case CPU_SUBTYPE_POWERPC_7400:
    case CPU_SUBTYPE_POWERPC_7450: return 3;
    case CPU_SUBTYPE_POWERPC_750: return 2;
    case CPU_SUBTYPE_POWERPC_970: return -1;
    default: return 1;
    }
}
#else
constexpr cpu_type_t kGuestCpuType = CPU_TYPE_I386;
int sliceRank(uint32_t) { return 1; }
#endif

// Fat headers are always big-endian; so are a PowerPC image's own headers, load
// commands, symbols and relocations, where every other guest's are the host's.
// fetch<T> reads one such structure from the file in the host's byte order.
#if defined(B32_GUEST_BIG_ENDIAN)
inline uint32_t be32(uint32_t value) { return OSSwapBigToHostInt32(value); }
void swapWords(void *structure, size_t first, size_t count) {
    uint32_t *words = static_cast<uint32_t *>(structure) + first;
    for (size_t i = 0; i < count; i++) words[i] = be32(words[i]);
}
inline void fix(uint32_t &value) { value = be32(value); }
inline void fix(mach_header &h) { swapWords(&h, 0, 7); }
inline void fix(load_command &c) { swapWords(&c, 0, 2); }
// cmd and cmdsize, then (past the 16-byte name) vmaddr to flags.
inline void fix(segment_command &s) { swapWords(&s, 0, 2); swapWords(&s, 6, 8); }
// Past the two 16-byte names: addr to reserved2.
inline void fix(section &s) { swapWords(&s, 8, 9); }
inline void fix(symtab_command &c) { swapWords(&c, 0, 6); }
inline void fix(dysymtab_command &c) { swapWords(&c, 0, 20); }
inline void fix(dyld_info_command &c) { swapWords(&c, 0, 12); }
inline void fix(dylib_command &c) { swapWords(&c, 0, 6); }
inline void fix(encryption_info_command &c) { swapWords(&c, 0, 5); }
inline void fix(entry_point_command &c) {
    swapWords(&c, 0, 2);
    c.entryoff = OSSwapBigToHostInt64(c.entryoff);
    c.stacksize = OSSwapBigToHostInt64(c.stacksize);
}
inline void fix(struct nlist &n) {
    n.n_un.n_strx = be32(n.n_un.n_strx);
    n.n_desc = int16_t(OSSwapBigToHostInt16(uint16_t(n.n_desc)));
    n.n_value = be32(n.n_value);
}
// A relocation's bitfields are laid out from the other end on a big-endian
// machine, so they're decoded by hand: { address, symbolnum:24 pcrel:1
// length:2 extern:1 type:4 }, or, when the top bit of the first word is set,
// { scattered:1 pcrel:1 length:2 type:4 address:24, value }.
inline void fix(relocation_info &r) {
    uint32_t words[2];
    std::memcpy(words, &r, 8);
    uint32_t w0 = be32(words[0]), w1 = be32(words[1]);
    if (w0 & R_SCATTERED) {
        scattered_relocation_info s{};
        s.r_scattered = 1;
        s.r_pcrel = (w0 >> 30) & 1;
        s.r_length = (w0 >> 28) & 3;
        s.r_type = (w0 >> 24) & 0xF;
        s.r_address = w0 & 0xFFFFFF;
        s.r_value = int32_t(w1);
        std::memcpy(&r, &s, 8);
    } else {
        r.r_address = int32_t(w0);
        r.r_symbolnum = w1 >> 8;
        r.r_pcrel = (w1 >> 7) & 1;
        r.r_length = (w1 >> 5) & 3;
        r.r_extern = (w1 >> 4) & 1;
        r.r_type = w1 & 0xF;
    }
}
#else
template <typename T> inline void fix(T &) {}
#endif

template <typename T> T fetch(const uint8_t *p) {
    T value;
    std::memcpy(&value, p, sizeof value);
    fix(value);
    return value;
}

// Picks the guest architecture's slice of a fat binary.
std::pair<size_t, size_t> pickSlice(const std::vector<uint8_t> &file) {
    uint32_t magic;
    std::memcpy(&magic, file.data(), 4);
    if (magic != OSSwapHostToBigInt32(FAT_MAGIC)) return {0, file.size()};
    fat_header header;
    std::memcpy(&header, file.data(), sizeof header);
    uint32_t count = OSSwapBigToHostInt32(header.nfat_arch);
    std::pair<size_t, size_t> best{0, 0};
    int bestRank = -1;
    for (uint32_t i = 0; i < count; i++) {
        fat_arch arch;
        std::memcpy(&arch, file.data() + sizeof header + i * sizeof arch, sizeof arch);
        if (cpu_type_t(OSSwapBigToHostInt32(arch.cputype)) != kGuestCpuType) continue;
        int rank = sliceRank(OSSwapBigToHostInt32(arch.cpusubtype));
        if (rank > bestRank) {
            bestRank = rank;
            best = {OSSwapBigToHostInt32(arch.offset), OSSwapBigToHostInt32(arch.size)};
        }
    }
    if (bestRank < 0) fatal("fat binary has no %s slice", arch::name());
    return best;
}

uint64_t readUleb(const uint8_t *&p, const uint8_t *end) {
    uint64_t result = 0;
    int shift = 0;
    while (p < end) {
        uint8_t byte = *p++;
        result |= uint64_t(byte & 0x7f) << shift;
        shift += 7;
        if (!(byte & 0x80)) break;
    }
    return result;
}

int64_t readSleb(const uint8_t *&p, const uint8_t *end) {
    int64_t result = 0;
    int shift = 0;
    uint8_t byte = 0;
    while (p < end) {
        byte = *p++;
        result |= int64_t(byte & 0x7f) << shift;
        shift += 7;
        if (!(byte & 0x80)) break;
    }
    if (shift < 64 && (byte & 0x40)) result |= -(int64_t(1) << shift);
    return result;
}

}  // namespace

uint32_t MachOLoader::span(const std::string &path) {
    std::vector<uint8_t> file = readFile(path);
    auto [sliceOffset, sliceSize] = pickSlice(file);
    const uint8_t *slice = file.data() + sliceOffset;
    mach_header header;
    header = fetch<decltype(header)>(slice);
    uint32_t start = UINT32_MAX, end = 0;
    const uint8_t *cmd = slice + sizeof header;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        load_command lc;
        lc = fetch<decltype(lc)>(cmd);
        if (lc.cmd == LC_SEGMENT) {
            segment_command seg;
            seg = fetch<decltype(seg)>(cmd);
            if (seg.vmsize) {
                start = std::min(start, seg.vmaddr);
                end = std::max(end, seg.vmaddr + seg.vmsize);
            }
        }
        cmd += lc.cmdsize;
    }
    return end > start ? end - start : 0;
}

Image MachOLoader::load(const std::string &path, GuestAddr dylibBase) {
    std::vector<uint8_t> file = readFile(path);
    auto [sliceOffset, sliceSize] = pickSlice(file);
    const uint8_t *slice = file.data() + sliceOffset;

    mach_header header;
    header = fetch<decltype(header)>(slice);
    if (header.magic != MH_MAGIC || header.cputype != kGuestCpuType) fatal("%s is not a %s Mach-O", path.c_str(), arch::name());
    if (header.filetype != MH_EXECUTE && header.filetype != MH_DYLIB)
        fatal("%s is not an executable or a dylib", path.c_str());

    Image image;
    image.path = path;
    image.cpuSubtype = header.cpusubtype;
    const bool isDylib = header.filetype == MH_DYLIB;
    if (isDylib) {
        // Slide so the first segment starts at dylibBase.
        const uint8_t *c = slice + sizeof header;
        for (uint32_t i = 0; i < header.ncmds; i++) {
            load_command lc;
            lc = fetch<decltype(lc)>(c);
            if (lc.cmd == LC_SEGMENT) {
                segment_command seg;
                seg = fetch<decltype(seg)>(c);
                image.slide = dylibBase - seg.vmaddr;
                break;
            }
            c += lc.cmdsize;
        }
    }
    const uint32_t slide = image.slide;

    std::vector<segment_command> segments;
    symtab_command symtab{};
    dysymtab_command dysymtab{};
    dyld_info_command dyldInfo{};
    bool haveDyldInfo = false;

    // Pass 1: map segments and collect the other load commands.
    const uint8_t *cmd = slice + sizeof header;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        load_command lc;
        lc = fetch<decltype(lc)>(cmd);
        switch (lc.cmd) {
        case LC_SEGMENT: {
            segment_command seg;
            seg = fetch<decltype(seg)>(cmd);
            seg.vmaddr += slide;
            segments.push_back(seg);
            image.end = std::max(image.end, seg.vmaddr + seg.vmsize);
            if (fixedName(seg.segname, 16) == "__TEXT") image.base = seg.vmaddr;
            if (seg.vmsize && seg.initprot) {
                mem_.map(seg.vmaddr, seg.vmsize);
                if (seg.filesize) mem_.copyIn(seg.vmaddr, slice + seg.fileoff, seg.filesize);
            }
            for (uint32_t s = 0; s < seg.nsects; s++) {
                section sect;
                sect = fetch<decltype(sect)>(cmd + sizeof seg + s * sizeof sect);
                image.sections.push_back(
                    {fixedName(sect.segname, 16), fixedName(sect.sectname, 16), sect.addr + slide, sect.size});
            }
            break;
        }
        case LC_SYMTAB: symtab = fetch<decltype(symtab)>(cmd); break;
        case LC_DYSYMTAB: dysymtab = fetch<decltype(dysymtab)>(cmd); break;
        case LC_DYLD_INFO:
        case LC_DYLD_INFO_ONLY:
            dyldInfo = fetch<decltype(dyldInfo)>(cmd);
            haveDyldInfo = true;
            break;
        case LC_MAIN: {
            entry_point_command ep;
            ep = fetch<decltype(ep)>(cmd);
            image.hasMain = true;
            image.entry = uint32_t(ep.entryoff);  // made absolute below
            break;
        }
        case LC_UNIXTHREAD: {
            // thread_command, flavor, count, then the thread state.
            const uint8_t *state = cmd + sizeof(thread_command) + 8;
#if defined(B32_GUEST_ARM)
            // arm_thread_state: r0-r12, sp, lr, pc, cpsr.
            uint32_t pc, cpsr;
            std::memcpy(&pc, state + 15 * 4, 4);
            std::memcpy(&cpsr, state + 16 * 4, 4);
            image.entry = pc | ((cpsr & (1u << 5)) ? 1 : 0);
#elif defined(B32_GUEST_PPC)
            // ppc_thread_state: srr0 (the entry point), srr1, r0-r31, cr, xer, lr, ctr, mq, vrsave.
            image.entry = fetch<uint32_t>(state);
#else
            // x86_thread_state32: eax ebx ecx edx edi esi ebp esp ss eflags eip ...
            std::memcpy(&image.entry, state + 10 * 4, 4);
#endif
            break;
        }
        case LC_ID_DYLIB: {
            dylib_command dc;
            dc = fetch<decltype(dc)>(cmd);
            image.installName = reinterpret_cast<const char *>(cmd) + dc.dylib.name.offset;
            break;
        }
        case LC_LOAD_DYLIB:
        case LC_LOAD_WEAK_DYLIB:
        case LC_REEXPORT_DYLIB: {
            dylib_command dc;
            dc = fetch<decltype(dc)>(cmd);
            image.dylibs.push_back(reinterpret_cast<const char *>(cmd) + dc.dylib.name.offset);
            break;
        }
        case LC_ENCRYPTION_INFO: {
            encryption_info_command enc;
            enc = fetch<decltype(enc)>(cmd);
            if (enc.cryptid) fatal("%s is FairPlay-encrypted; decrypt it first", path.c_str());
            break;
        }
        default: break;
        }
        cmd += lc.cmdsize;
    }

    if (onDylibs) onDylibs(image.dylibs);

    if (image.hasMain) {
        // entryoff is a file offset; turn it into the address in __TEXT.
        for (const auto &seg : segments)
            if (fixedName(seg.segname, 16) == "__TEXT") image.entry += seg.vmaddr - seg.fileoff;
    }

    auto symbolName = [&](uint32_t index) -> std::string {
        struct nlist sym;
        sym = fetch<decltype(sym)>(slice + symtab.symoff + index * sizeof sym);
        return reinterpret_cast<const char *>(slice + symtab.stroff + sym.n_un.n_strx);
    };
    // The image's own external definitions. Weak and coalesced symbols (C++
    // template instantiations, inline functions) are bound like imports but
    // resolve to the image itself.
    std::unordered_map<std::string, GuestAddr> &defined = image.exports;
    for (uint32_t i = 0; i < symtab.nsyms; i++) {
        struct nlist sym;
        sym = fetch<decltype(sym)>(slice + symtab.symoff + i * sizeof sym);
        if ((sym.n_type & N_STAB) || (sym.n_type & N_TYPE) != N_SECT || !(sym.n_type & N_EXT)) continue;
        GuestAddr addr = sym.n_value + slide;
#if defined(B32_GUEST_ARM)
        if (sym.n_desc & N_ARM_THUMB_DEF) addr |= 1;
#endif
        defined.emplace(reinterpret_cast<const char *>(slice + symtab.stroff + sym.n_un.n_strx), addr);
    }

    // A slid image's own pointers move with it: rebase opcodes (iOS 4+) or
    // local relocations (older images).
    if (slide) {
        auto rebase = [&](GuestAddr where) { mem_.write<uint32_t>(where, mem_.read<uint32_t>(where) + slide); };
        if (haveDyldInfo) {
            const uint8_t *p = slice + dyldInfo.rebase_off, *end = p + dyldInfo.rebase_size;
            uint64_t segOffset = 0;
            int segIndex = 0;
            auto address = [&] { return GuestAddr(segments.at(segIndex).vmaddr + segOffset); };
            while (p < end) {
                uint8_t byte = *p++;
                uint8_t imm = byte & REBASE_IMMEDIATE_MASK;
                switch (byte & REBASE_OPCODE_MASK) {
                case REBASE_OPCODE_DONE: p = end; break;
                case REBASE_OPCODE_SET_TYPE_IMM: break;  // always pointers in 32-bit images
                case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                    segIndex = imm;
                    segOffset = readUleb(p, end);
                    break;
                case REBASE_OPCODE_ADD_ADDR_ULEB: segOffset += readUleb(p, end); break;
                case REBASE_OPCODE_ADD_ADDR_IMM_SCALED: segOffset += imm * 4; break;
                case REBASE_OPCODE_DO_REBASE_IMM_TIMES:
                    for (int k = 0; k < imm; k++, segOffset += 4) rebase(address());
                    break;
                case REBASE_OPCODE_DO_REBASE_ULEB_TIMES:
                    for (uint64_t k = 0, n = readUleb(p, end); k < n; k++, segOffset += 4) rebase(address());
                    break;
                case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB:
                    rebase(address());
                    segOffset += 4 + readUleb(p, end);
                    break;
                case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: {
                    uint64_t count = readUleb(p, end), skip = readUleb(p, end);
                    for (uint64_t k = 0; k < count; k++, segOffset += 4 + skip) rebase(address());
                    break;
                }
                default: fatal("unknown rebase opcode 0x%02x in %s", byte, path.c_str());
                }
            }
        } else {
            GuestAddr base = segments.empty() ? 0 : segments.front().vmaddr;
            for (uint32_t i = 0; i < dysymtab.nlocrel; i++) {
                relocation_info rel;
                rel = fetch<decltype(rel)>(slice + dysymtab.locreloff + i * sizeof rel);
                // As dyld does: only 4-byte vanilla relocations move a pointer;
                // absolute ones don't, and a prebound lazy pointer is bound below.
                if (uint32_t(rel.r_address) & R_SCATTERED) {
                    scattered_relocation_info srel;
                    srel = fetch<decltype(srel)>(&rel);
                    if (srel.r_length == 2 && srel.r_type == GENERIC_RELOC_VANILLA) rebase(base + srel.r_address);
                } else if (rel.r_length == 2 && rel.r_type == GENERIC_RELOC_VANILLA && rel.r_symbolnum != R_ABS) {
                    rebase(base + uint32_t(rel.r_address));
                }
            }
        }
    }

    auto targetOf = [&](const std::string &symbol) {
        auto own = defined.find(symbol);
        return own != defined.end() ? own->second : resolve_(symbol);
    };
    auto bind = [&](GuestAddr where, const std::string &symbol, int64_t addend) {
        mem_.write<uint32_t>(where, uint32_t(targetOf(symbol) + addend));
        image.bindCount++;
    };

    // Pass 2: symbol pointer sections through the indirect symbol table.
    const uint8_t *sectCmd = slice + sizeof header;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        load_command lc;
        lc = fetch<decltype(lc)>(sectCmd);
        if (lc.cmd == LC_SEGMENT) {
            segment_command seg;
            seg = fetch<decltype(seg)>(sectCmd);
            for (uint32_t s = 0; s < seg.nsects; s++) {
                section sect;
                sect = fetch<decltype(sect)>(sectCmd + sizeof seg + s * sizeof sect);
                uint32_t type = sect.flags & SECTION_TYPE;
#if defined(B32_GUEST_I386)
                // Mac OS X 10.4-era __IMPORT,__jump_table: five-byte entries of
                // hlt that dyld overwrites with `jmp target`.
                constexpr uint32_t kJumpTableEntry = 5;
                if (type == S_SYMBOL_STUBS && (sect.flags & S_ATTR_SELF_MODIFYING_CODE) &&
                    sect.reserved2 == kJumpTableEntry) {
                    for (uint32_t k = 0; k < sect.size / kJumpTableEntry; k++) {
                        uint32_t indirect;
                        std::memcpy(&indirect, slice + dysymtab.indirectsymoff + (sect.reserved1 + k) * 4, 4);
                        if (indirect & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                        GuestAddr entry = sect.addr + slide + k * kJumpTableEntry;
                        mem_.write<uint8_t>(entry, 0xE9);
                        mem_.write<uint32_t>(entry + 1, targetOf(symbolName(indirect)) - (entry + kJumpTableEntry));
                        image.bindCount++;
                    }
                    continue;
                }
#endif
                if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
                for (uint32_t k = 0; k < sect.size / 4; k++) {
                    uint32_t indirect = fetch<uint32_t>(slice + dysymtab.indirectsymoff + (sect.reserved1 + k) * 4);
                    if (indirect & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                    // A symbol the linker made private to this image (a template
                    // instantiation): the pointer already holds its address.
                    struct nlist sym;
                    sym = fetch<decltype(sym)>(slice + symtab.symoff + indirect * sizeof sym);
                    if ((sym.n_type & N_TYPE) == N_SECT && !(sym.n_type & N_EXT)) continue;
                    bind(sect.addr + slide + k * 4, symbolName(indirect), 0);
                }
            }
        }
        sectCmd += lc.cmdsize;
    }

    // External relocations (pre-iOS 4 data imports). For 32-bit images the
    // addresses are relative to the first segment, and the addend is already
    // stored at the target.
    GuestAddr relocBase = segments.empty() ? 0 : segments.front().vmaddr;
    for (uint32_t i = 0; i < dysymtab.nextrel; i++) {
        relocation_info rel;
        rel = fetch<decltype(rel)>(slice + dysymtab.extreloff + i * sizeof rel);
        if (uint32_t(rel.r_address) & R_SCATTERED) continue;
        if (!rel.r_extern || rel.r_length != 2 || rel.r_type != GENERIC_RELOC_VANILLA) {
            log("skipping unsupported external relocation type %u at 0x%08x", rel.r_type, rel.r_address);
            continue;
        }
        GuestAddr where = relocBase + rel.r_address;
        bind(where, symbolName(rel.r_symbolnum), int32_t(mem_.read<uint32_t>(where)));
    }

    // LC_DYLD_INFO bind and lazy-bind opcodes (iOS 4+).
    auto runBindOpcodes = [&](uint32_t offset, uint32_t size) {
        const uint8_t *p = slice + offset, *end = p + size;
        std::string symbol;
        int64_t addend = 0;
        uint64_t segOffset = 0;
        int segIndex = 0;
        auto address = [&] { return GuestAddr(segments.at(segIndex).vmaddr + segOffset); };
        while (p < end) {
            uint8_t byte = *p++;
            uint8_t imm = byte & BIND_IMMEDIATE_MASK;
            switch (byte & BIND_OPCODE_MASK) {
            case BIND_OPCODE_DONE: break;  // ends one lazy entry; keep going
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: break;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: readUleb(p, end); break;
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: break;
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
                symbol = reinterpret_cast<const char *>(p);
                p += symbol.size() + 1;
                break;
            case BIND_OPCODE_SET_TYPE_IMM: break;  // always BIND_TYPE_POINTER in 32-bit images
            case BIND_OPCODE_SET_ADDEND_SLEB: addend = readSleb(p, end); break;
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB:
                segIndex = imm;
                segOffset = readUleb(p, end);
                break;
            case BIND_OPCODE_ADD_ADDR_ULEB: segOffset += readUleb(p, end); break;
            case BIND_OPCODE_DO_BIND:
                bind(address(), symbol, addend);
                segOffset += 4;
                break;
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB:
                bind(address(), symbol, addend);
                segOffset += 4 + readUleb(p, end);
                break;
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED:
                bind(address(), symbol, addend);
                segOffset += 4 + imm * 4;
                break;
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t count = readUleb(p, end), skip = readUleb(p, end);
                for (uint64_t k = 0; k < count; k++) {
                    bind(address(), symbol, addend);
                    segOffset += 4 + skip;
                }
                break;
            }
            default: fatal("unknown bind opcode 0x%02x in %s", byte, path.c_str());
            }
        }
    };
    if (haveDyldInfo) {
        runBindOpcodes(dyldInfo.bind_off, dyldInfo.bind_size);
        runBindOpcodes(dyldInfo.lazy_bind_off, dyldInfo.lazy_bind_size);
    }

    for (const auto &s : image.sections) {
        if (s.name == "__mod_init_func")
            for (uint32_t k = 0; k < s.size / 4; k++) image.initializers.push_back(mem_.read<uint32_t>(s.addr + k * 4));
        if (s.segment == "__DATA" && s.name == "__dyld") image.dyldSection = s.addr;
    }
    return image;
}

}  // namespace b32
