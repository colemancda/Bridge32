#include "MachO.h"

#include "core/Log.h"

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

// Picks the armv7 slice of a fat binary, falling back to armv6.
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
        if (cpu_type_t(OSSwapBigToHostInt32(arch.cputype)) != CPU_TYPE_ARM) continue;
        uint32_t subtype = OSSwapBigToHostInt32(arch.cpusubtype);
        int rank = subtype == CPU_SUBTYPE_ARM_V7 ? 2 : subtype == CPU_SUBTYPE_ARM_V6 ? 1 : 0;
        if (rank > bestRank) {
            bestRank = rank;
            best = {OSSwapBigToHostInt32(arch.offset), OSSwapBigToHostInt32(arch.size)};
        }
    }
    if (bestRank < 0) fatal("fat binary has no 32-bit ARM slice");
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

Image MachOLoader::load(const std::string &path, GuestAddr dylibBase) {
    std::vector<uint8_t> file = readFile(path);
    auto [sliceOffset, sliceSize] = pickSlice(file);
    const uint8_t *slice = file.data() + sliceOffset;

    mach_header header;
    std::memcpy(&header, slice, sizeof header);
    if (header.magic != MH_MAGIC || header.cputype != CPU_TYPE_ARM) fatal("%s is not a 32-bit ARM Mach-O", path.c_str());
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
            std::memcpy(&lc, c, sizeof lc);
            if (lc.cmd == LC_SEGMENT) {
                segment_command seg;
                std::memcpy(&seg, c, sizeof seg);
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
        std::memcpy(&lc, cmd, sizeof lc);
        switch (lc.cmd) {
        case LC_SEGMENT: {
            segment_command seg;
            std::memcpy(&seg, cmd, sizeof seg);
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
                std::memcpy(&sect, cmd + sizeof seg + s * sizeof sect, sizeof sect);
                image.sections.push_back(
                    {fixedName(sect.segname, 16), fixedName(sect.sectname, 16), sect.addr + slide, sect.size});
            }
            break;
        }
        case LC_SYMTAB: std::memcpy(&symtab, cmd, sizeof symtab); break;
        case LC_DYSYMTAB: std::memcpy(&dysymtab, cmd, sizeof dysymtab); break;
        case LC_DYLD_INFO:
        case LC_DYLD_INFO_ONLY:
            std::memcpy(&dyldInfo, cmd, sizeof dyldInfo);
            haveDyldInfo = true;
            break;
        case LC_MAIN: {
            entry_point_command ep;
            std::memcpy(&ep, cmd, sizeof ep);
            image.hasMain = true;
            image.entry = uint32_t(ep.entryoff);  // made absolute below
            break;
        }
        case LC_UNIXTHREAD: {
            // thread_command, flavor, count, then arm_thread_state (r0-r12, sp, lr, pc, cpsr).
            uint32_t pc, cpsr;
            std::memcpy(&pc, cmd + sizeof(thread_command) + 8 + 15 * 4, 4);
            std::memcpy(&cpsr, cmd + sizeof(thread_command) + 8 + 16 * 4, 4);
            image.entry = pc | ((cpsr & (1u << 5)) ? 1 : 0);
            break;
        }
        case LC_ID_DYLIB: {
            dylib_command dc;
            std::memcpy(&dc, cmd, sizeof dc);
            image.installName = reinterpret_cast<const char *>(cmd) + dc.dylib.name.offset;
            break;
        }
        case LC_LOAD_DYLIB:
        case LC_LOAD_WEAK_DYLIB:
        case LC_REEXPORT_DYLIB: {
            dylib_command dc;
            std::memcpy(&dc, cmd, sizeof dc);
            image.dylibs.push_back(reinterpret_cast<const char *>(cmd) + dc.dylib.name.offset);
            break;
        }
        case LC_ENCRYPTION_INFO: {
            encryption_info_command enc;
            std::memcpy(&enc, cmd, sizeof enc);
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
        std::memcpy(&sym, slice + symtab.symoff + index * sizeof sym, sizeof sym);
        return reinterpret_cast<const char *>(slice + symtab.stroff + sym.n_un.n_strx);
    };
    // The image's own external definitions. Weak and coalesced symbols (C++
    // template instantiations, inline functions) are bound like imports but
    // resolve to the image itself.
    std::unordered_map<std::string, GuestAddr> &defined = image.exports;
    for (uint32_t i = 0; i < symtab.nsyms; i++) {
        struct nlist sym;
        std::memcpy(&sym, slice + symtab.symoff + i * sizeof sym, sizeof sym);
        if ((sym.n_type & N_STAB) || (sym.n_type & N_TYPE) != N_SECT || !(sym.n_type & N_EXT)) continue;
        GuestAddr addr = (sym.n_value + slide) | ((sym.n_desc & N_ARM_THUMB_DEF) ? 1 : 0);
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
                case REBASE_OPCODE_SET_TYPE_IMM: break;  // always pointers on arm
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
                std::memcpy(&rel, slice + dysymtab.locreloff + i * sizeof rel, sizeof rel);
                if (uint32_t(rel.r_address) & R_SCATTERED) {
                    scattered_relocation_info srel;
                    std::memcpy(&srel, &rel, sizeof srel);
                    rebase(base + srel.r_address);
                } else if (rel.r_length == 2) {
                    rebase(base + uint32_t(rel.r_address));
                }
            }
        }
    }

    auto bind = [&](GuestAddr where, const std::string &symbol, int64_t addend) {
        auto own = defined.find(symbol);
        GuestAddr target = own != defined.end() ? own->second : resolve_(symbol);
        mem_.write<uint32_t>(where, uint32_t(target + addend));
        image.bindCount++;
    };

    // Pass 2: symbol pointer sections through the indirect symbol table.
    const uint8_t *sectCmd = slice + sizeof header;
    for (uint32_t i = 0; i < header.ncmds; i++) {
        load_command lc;
        std::memcpy(&lc, sectCmd, sizeof lc);
        if (lc.cmd == LC_SEGMENT) {
            segment_command seg;
            std::memcpy(&seg, sectCmd, sizeof seg);
            for (uint32_t s = 0; s < seg.nsects; s++) {
                section sect;
                std::memcpy(&sect, sectCmd + sizeof seg + s * sizeof sect, sizeof sect);
                uint32_t type = sect.flags & SECTION_TYPE;
                if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
                for (uint32_t k = 0; k < sect.size / 4; k++) {
                    uint32_t indirect;
                    std::memcpy(&indirect, slice + dysymtab.indirectsymoff + (sect.reserved1 + k) * 4, 4);
                    if (indirect & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
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
        std::memcpy(&rel, slice + dysymtab.extreloff + i * sizeof rel, sizeof rel);
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
            case BIND_OPCODE_SET_TYPE_IMM: break;  // always BIND_TYPE_POINTER on arm
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
