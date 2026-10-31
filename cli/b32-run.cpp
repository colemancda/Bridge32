// Runs a guest executable headless: no UIKit, just the loader, the JIT and
// whatever thunks it needs. Used by the guest tests.

#include "core/Runtime.h"
#include "core/cpu/DynarmicCpu.h"

#include <dynarmic/interface/exclusive_monitor.h>

#include <atomic>
#include <cstdio>

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: %s <guest executable> [args...]\n", argv[0]);
        return 2;
    }
    static auto monitor = b32::DynarmicCpu::makeMonitor();
    static std::atomic<size_t> nextProcessor{0};
    // ARMv7 runs armv6 user code too, so one arch covers both binary eras.
    b32::Runtime rt([](b32::GuestMemory &mem, b32::Cpu::SvcHandler handler) -> std::unique_ptr<b32::Cpu> {
        return std::make_unique<b32::DynarmicCpu>(mem, std::move(handler), b32::DynarmicCpu::Arch::V7,
                                                  monitor.get(), nextProcessor++);
    });
    // Guest builds of libraries like libstdc++ (see Runtime::addGuestLibraryDir).
    if (const char *dir = getenv("B32_GUEST_LIBS")) rt.addGuestLibraryDir(dir);
    rt.load(argv[1]);

    std::vector<std::string> guestArgv(argv + 1, argv + argc);
    std::vector<std::string> envp = {"HOME=/var/mobile", "TMPDIR=/tmp"};
    int status = rt.run(guestArgv, envp);
    std::fflush(stdout);
    return status;
}
