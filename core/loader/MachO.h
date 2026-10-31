// Loads a 32-bit ARM Mach-O executable into guest memory at its preferred
// address, or a dylib at a given base (sliding it), and binds its imports. Handles both eras of binaries:
//  - iPhone OS 2-3: LC_UNIXTHREAD, a __dyld section, external relocations
//  - iOS 4+: LC_MAIN and LC_DYLD_INFO bind opcodes
// Lazy and non-lazy symbol pointers are bound eagerly through the indirect
// symbol table, which every armv6/armv7 binary has.
#pragma once

#include "core/mem/GuestMemory.h"

#include <functional>
#include <unordered_map>
#include <string>
#include <vector>

namespace b32 {

struct Section {
    std::string segment, name;
    GuestAddr addr;
    uint32_t size;
};

struct Image {
    std::string path;
    std::string installName;  // LC_ID_DYLIB, for dylibs
    uint32_t slide = 0;
    GuestAddr base = 0;       // where the Mach-O header is (__TEXT's start)
    GuestAddr end = 0;        // first address past the image
    uint32_t cpuSubtype = 0;
    std::vector<Section> sections;
    std::vector<std::string> dylibs;
    // LC_MAIN binaries are entered at main(argc, argv, envp, apple); older
    // ones at crt1's start with the argc/argv block on the stack.
    bool hasMain = false;
    GuestAddr entry = 0;
    GuestAddr dyldSection = 0;  // __DATA,__dyld if present
    std::vector<GuestAddr> initializers;  // __mod_init_func contents
    uint32_t bindCount = 0;
    // External definitions (slid), which other images bind to.
    std::unordered_map<std::string, GuestAddr> exports;

    const Section *section(const char *segment, const char *name) const;
};

class MachOLoader {
public:
    // Maps an imported symbol name (with its leading underscore) to the guest
    // address it should bind to.
    using Resolver = std::function<GuestAddr(const std::string &symbol)>;

    MachOLoader(GuestMemory &mem, Resolver resolver) : mem_(mem), resolve_(std::move(resolver)) {}

    // Executables load at their own addresses; dylibs (linked at 0 on iOS)
    // are slid to `dylibBase`.
    Image load(const std::string &path, GuestAddr dylibBase = 0);

    // Called with the image's linked libraries after its load commands are
    // read and before anything is bound.
    std::function<void(const std::vector<std::string> &dylibs)> onDylibs;

private:
    GuestMemory &mem_;
    Resolver resolve_;
};

}  // namespace b32
