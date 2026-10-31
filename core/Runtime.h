// A guest process: memory, heap, thunks, the loaded executable and its main
// thread's CPU.
#pragma once

#include "core/cpu/Cpu.h"
#include "core/loader/MachO.h"
#include "core/mem/GuestHeap.h"
#include "core/thunks/Thunks.h"

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace b32 {

namespace objc {
class Bridge;
}

class Runtime {
public:
    using CpuFactory = std::function<std::unique_ptr<Cpu>(GuestMemory &, Cpu::SvcHandler)>;

    explicit Runtime(CpuFactory makeCpu);
    ~Runtime();

    GuestMemory &mem() { return *mem_; }
    GuestHeap &heap() { return *heap_; }
    ThunkTable &thunks() { return *thunks_; }
    const Image &image() const { return image_; }
    Cpu &mainCpu() { return *cpu_; }
    objc::Bridge &bridge() { return *bridge_; }

    // The CPU of the guest thread running on this host thread, if any.
    static Cpu *currentCpu();
    // The current thread's CPU, attaching one (with its own guest stack) to
    // a host thread that hasn't run guest code before: callbacks from
    // AudioToolbox's or GCD's threads into guest functions.
    static Cpu &threadCpu();

    // Runs fn(arg) as a new guest thread on the calling host thread, with
    // its own CPU and a guest stack in `slot` (1..kMaxThreads-1); returns
    // fn's result. exit() from the thread ends the process.
    uint32_t runThread(uint32_t slot, GuestAddr fn, GuestAddr arg);

    // Thrown by pthread_exit; runThread catches it and returns `value`.
    struct ThreadExit {
        uint32_t value;
    };

    // Loads the executable and binds every import. Doesn't run anything.
    void load(const std::string &path);

    // Runs initializers and the entry point; returns the exit status.
    int run(const std::vector<std::string> &argv, const std::vector<std::string> &envp);

    // Called by exit() and friends: unwinds back out of run().
    [[noreturn]] void exit(int status);

    // Guest address of an imported data symbol (___stderrp etc.), or 0.
    GuestAddr dataSymbol(const std::string &symbol);
    // Copies a host string into guest memory that lives as long as the process.
    GuestAddr internString(const std::string &s);

private:
    GuestAddr resolve(const std::string &symbol);
    GuestAddr buildProcessStack(GuestAddr stackTop, const std::vector<std::string> &argv,
                                const std::vector<std::string> &envp, GuestAddr *argvOut, GuestAddr *envpOut,
                                GuestAddr *appleOut);

    std::unique_ptr<GuestMemory> mem_;
    std::unique_ptr<GuestHeap> heap_;
    std::unique_ptr<ThunkTable> thunks_;
    CpuFactory makeCpu_;
    std::mutex attachLock_;
    std::vector<std::unique_ptr<Cpu>> attachedCpus_;  // never freed; foreign threads are few
    std::unique_ptr<Cpu> cpu_;
    std::unique_ptr<objc::Bridge> bridge_;
    Image image_;
    std::unordered_map<std::string, GuestAddr> data_;
    std::unordered_map<std::string, GuestAddr> strings_;
};

// Imported data symbols (variables rather than functions). `init` fills the
// variable's guest memory once, when the import is first bound.
struct DataSymbolRegistry {
    using Init = void (*)(Runtime &, GuestAddr);
    struct Entry {
        uint32_t size;
        Init init;
    };
    static std::unordered_map<std::string, Entry> &all();
    DataSymbolRegistry(const char *symbol, uint32_t size, Init init) { all().emplace(symbol, Entry{size, init}); }
};

#define B32_DATA(symbol, size)                                                          \
    static void datainit_##symbol(::b32::Runtime &rt, ::b32::GuestAddr addr);           \
    static ::b32::DataSymbolRegistry dataregistry_##symbol(#symbol, size, datainit_##symbol); \
    static void datainit_##symbol([[maybe_unused]] ::b32::Runtime &rt, [[maybe_unused]] ::b32::GuestAddr addr)

}  // namespace b32
