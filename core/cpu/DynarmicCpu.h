#pragma once

#include "Cpu.h"

#include <memory>

namespace Dynarmic {
class ExclusiveMonitor;
}

namespace b32 {

// Cpu backed by dynarmic's A32 JIT, with fastmem over the guest reservation.
// All guest threads share one ExclusiveMonitor so LDREX/STREX work across them.
class DynarmicCpu final : public Cpu {
public:
    enum class Arch { V6K, V7 };

    DynarmicCpu(GuestMemory &mem, SvcHandler handler, Arch arch, Dynarmic::ExclusiveMonitor *monitor,
                size_t processorId);
    ~DynarmicCpu() override;

    uint32_t reg(int n) const override;
    void setReg(int n, uint32_t value) override;
    uint32_t cpsr() const override;
    void setCpsr(uint32_t value) override;
    uint32_t extReg(int n) const override;
    void setExtReg(int n, uint32_t value) override;

    // A monitor sized for every guest thread the runtime can create.
    static std::unique_ptr<Dynarmic::ExclusiveMonitor> makeMonitor();

protected:
    uint32_t runUntilSvc() override;

private:
    struct Callbacks;
    std::unique_ptr<Callbacks> callbacks_;
    struct JitHolder;
    std::unique_ptr<JitHolder> jit_;
};

}  // namespace b32
