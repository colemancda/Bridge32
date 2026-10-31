// Loads a 32-bit ARM Mach-O executable into guest memory at its preferred
// address and binds its imports. Handles both eras of binaries:
//  - iPhone OS 2-3: LC_UNIXTHREAD, a __dyld section, external relocations
//  - iOS 4+: LC_MAIN and LC_DYLD_INFO bind opcodes
// Lazy and non-lazy symbol pointers are bound eagerly through the indirect
// symbol table, which every armv6/armv7 binary has.
#pragma once

#include "core/mem/GuestMemory.h"

#include <functional>
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

    const Section *section(const char *segment, const char *name) const;
};

class MachOLoader {
public:
    // Maps an imported symbol name (with its leading underscore) to the guest
    // address it should bind to.
    using Resolver = std::function<GuestAddr(const std::string &symbol)>;

    MachOLoader(GuestMemory &mem, Resolver resolver) : mem_(mem), resolve_(std::move(resolver)) {}

    Image load(const std::string &path);

    // Called with the image's linked libraries after its load commands are
    // read and before anything is bound.
    std::function<void(const std::vector<std::string> &dylibs)> onDylibs;

private:
    GuestMemory &mem_;
    Resolver resolve_;
};

}  // namespace b32
