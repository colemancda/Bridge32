#include "DynarmicCpu.h"

#include "core/Log.h"
#include "core/mem/Layout.h"

#include <dynarmic/interface/A32/a32.h>
#include <dynarmic/interface/A32/config.h>
#include <dynarmic/interface/exclusive_monitor.h>

#include <cstdlib>
#include <optional>

namespace b32 {

using Dynarmic::A32::Exception;
using Dynarmic::A32::VAddr;

// Fastmem handles ordinary loads and stores; these callbacks only run for
// accesses fastmem gave up on, which in practice means unmapped addresses.
struct DynarmicCpu::Callbacks final : Dynarmic::A32::UserCallbacks {
    GuestMemory &mem;
    Dynarmic::A32::Jit *jit = nullptr;
    std::optional<uint32_t> pendingSvc;

    explicit Callbacks(GuestMemory &m) : mem(m) {}

    uint8_t *at(VAddr addr, size_t size, const char *what) {
        if (!mem.isMapped(addr) || !mem.isMapped(addr + uint32_t(size) - 1))
            fatal("guest %s of unmapped 0x%08x (pc=0x%08x lr=0x%08x)", what, addr, jit->Regs()[15], jit->Regs()[14]);
        return mem.ptr<uint8_t>(addr);
    }
    template <typename T> T load(VAddr addr) {
        T v;
        std::memcpy(&v, at(addr, sizeof v, "read"), sizeof v);
        return v;
    }
    template <typename T> void store(VAddr addr, T v) { std::memcpy(at(addr, sizeof v, "write"), &v, sizeof v); }
    template <typename T> bool storeExclusive(VAddr addr, T value, T expected) {
        auto *p = reinterpret_cast<T *>(at(addr, sizeof value, "exclusive write"));
        return __atomic_compare_exchange_n(p, &expected, value, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }

    std::optional<uint32_t> MemoryReadCode(VAddr addr) override { return load<uint32_t>(addr); }
    uint8_t MemoryRead8(VAddr addr) override { return load<uint8_t>(addr); }
    uint16_t MemoryRead16(VAddr addr) override { return load<uint16_t>(addr); }
    uint32_t MemoryRead32(VAddr addr) override { return load<uint32_t>(addr); }
    uint64_t MemoryRead64(VAddr addr) override { return load<uint64_t>(addr); }
    void MemoryWrite8(VAddr addr, uint8_t v) override { store(addr, v); }
    void MemoryWrite16(VAddr addr, uint16_t v) override { store(addr, v); }
    void MemoryWrite32(VAddr addr, uint32_t v) override { store(addr, v); }
    void MemoryWrite64(VAddr addr, uint64_t v) override { store(addr, v); }
    bool MemoryWriteExclusive8(VAddr a, uint8_t v, uint8_t e) override { return storeExclusive(a, v, e); }
    bool MemoryWriteExclusive16(VAddr a, uint16_t v, uint16_t e) override { return storeExclusive(a, v, e); }
    bool MemoryWriteExclusive32(VAddr a, uint32_t v, uint32_t e) override { return storeExclusive(a, v, e); }
    bool MemoryWriteExclusive64(VAddr a, uint64_t v, uint64_t e) override { return storeExclusive(a, v, e); }

    void InterpreterFallback(VAddr pc, size_t count) override {
        fatal("dynarmic has no translation for %zu instruction(s) at 0x%08x", count, pc);
    }

    // The SVC handler must not run inside Jit::Run (it may re-enter the
    // guest), so stop the JIT and let runUntilSvc() return the immediate.
    void CallSVC(uint32_t swi) override {
        pendingSvc = swi;
        jit->HaltExecution();
    }

    void ExceptionRaised(VAddr pc, Exception exception) override {
        switch (exception) {
        case Exception::Yield:
        case Exception::WaitForEvent:
        case Exception::WaitForInterrupt:
        case Exception::SendEvent:
        case Exception::SendEventLocal:
        case Exception::PreloadData:
        case Exception::PreloadDataWithIntentToWrite:
        case Exception::PreloadInstruction:
            // Hints: skip the instruction and carry on.
            jit->Regs()[15] = pc + ((jit->Cpsr() & Cpu::kThumbBit) ? 2 : 4);
            return;
        case Exception::Breakpoint:
            fatal("guest breakpoint at 0x%08x", pc);
        default:
            fatal("guest exception %d at 0x%08x (lr=0x%08x)", int(exception), pc, jit->Regs()[14]);
        }
    }

    void AddTicks(uint64_t) override {}
    uint64_t GetTicksRemaining() override { return UINT64_MAX; }
};

struct DynarmicCpu::JitHolder {
    Dynarmic::A32::Jit jit;
    explicit JitHolder(Dynarmic::A32::UserConfig config) : jit(config) {}
};

std::unique_ptr<Dynarmic::ExclusiveMonitor> DynarmicCpu::makeMonitor() {
    return std::make_unique<Dynarmic::ExclusiveMonitor>(layout::kMaxThreads);
}

DynarmicCpu::DynarmicCpu(GuestMemory &mem, SvcHandler handler, Arch arch, Dynarmic::ExclusiveMonitor *monitor,
                         size_t processorId)
    : Cpu(mem, std::move(handler)), callbacks_(std::make_unique<Callbacks>(mem)) {
    Dynarmic::A32::UserConfig config;
    config.callbacks = callbacks_.get();
    config.arch_version = arch == Arch::V6K ? Dynarmic::A32::ArchVersion::v6K : Dynarmic::A32::ArchVersion::v7;
    // B32_NO_FASTMEM=1 routes every guest access through the callbacks. It's
    // slow, but without fastmem dynarmic installs no exception handler, so a
    // debugger sees host crashes directly.
    if (!getenv("B32_NO_FASTMEM")) config.fastmem_pointer = reinterpret_cast<uintptr_t>(mem.base());
    config.global_monitor = monitor;
    config.processor_id = processorId;
    config.fastmem_exclusive_access = monitor != nullptr;
    config.enable_cycle_counting = false;
    // ARMv6 apps sometimes rely on unaligned word accesses, which the A5 and
    // later cores allow, so don't trap misalignment.
    config.detect_misaligned_access_via_page_table = 0;
    jit_ = std::make_unique<JitHolder>(config);
    callbacks_->jit = &jit_->jit;
    jit_->jit.SetCpsr(0x10);  // user mode, ARM state
}

DynarmicCpu::~DynarmicCpu() = default;

uint32_t DynarmicCpu::reg(int n) const { return jit_->jit.Regs()[n]; }
void DynarmicCpu::setReg(int n, uint32_t value) { jit_->jit.Regs()[n] = value; }
uint32_t DynarmicCpu::cpsr() const { return jit_->jit.Cpsr(); }
void DynarmicCpu::setCpsr(uint32_t value) { jit_->jit.SetCpsr(value); }
uint32_t DynarmicCpu::extReg(int n) const { return jit_->jit.ExtRegs()[n]; }
void DynarmicCpu::setExtReg(int n, uint32_t value) { jit_->jit.ExtRegs()[n] = value; }

uint32_t DynarmicCpu::runUntilSvc() {
    callbacks_->pendingSvc.reset();
    while (!callbacks_->pendingSvc) {
        jit_->jit.Run();
        jit_->jit.ClearHalt();
    }
    return *callbacks_->pendingSvc;
}

}  // namespace b32
