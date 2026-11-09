// Loads a guest executable without running it and reports what the loader
// saw: entry point, sections, linked dylibs, and imports that have no host
// implementation yet.

#include "core/Runtime.h"
#include "core/arch/Arch.h"

#include <cstdio>

int main(int argc, char **argv) {
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s <%s Mach-O executable>\n", argv[0], b32::arch::name());
        return 2;
    }
    b32::Runtime rt([](b32::GuestMemory &, b32::Cpu::SvcHandler) { return std::unique_ptr<b32::Cpu>(); });
    rt.load(argv[1]);
    const b32::Image &image = rt.image();

#if defined(B32_GUEST_ARM)
    std::printf("cpu subtype: %s\n", image.cpuSubtype == 9 ? "armv7" : image.cpuSubtype == 6 ? "armv6" : "other");
#else
    std::printf("cpu type: i386 (subtype %u)\n", image.cpuSubtype);
#endif
    std::printf("entry: 0x%08x (%s)\n", image.entry, image.hasMain ? "LC_MAIN" : "LC_UNIXTHREAD");
    std::printf("binds: %u\n", image.bindCount);
    std::printf("initializers: %zu\n", image.initializers.size());
    std::printf("dylibs:\n");
    for (const auto &d : image.dylibs) std::printf("  %s\n", d.c_str());
    std::printf("sections:\n");
    for (const auto &s : image.sections)
        std::printf("  %-8s %-18s 0x%08x %8u\n", s.segment.c_str(), s.name.c_str(), s.addr, s.size);

    auto missing = rt.thunks().missing();
    std::printf("unimplemented imports: %zu\n", missing.size());
    for (const auto &m : missing) std::printf("  %s\n", m.c_str());
    return 0;
}
