// One guest thread's CPU. The real backend is dynarmic's A32 JIT; the
// interface keeps the loader and thunks independent of it.
#pragma once

#include "core/mem/GuestMemory.h"

#include <functional>
#include <initializer_list>
#include <vector>

namespace b32 {

class Cpu {
public:
    // Called for every SVC; `imm` is the SVC immediate (the thunk index).
    // Runs outside the JIT, so it may call back into the guest with call().
    using SvcHandler = std::function<void(Cpu &, uint32_t imm)>;

    enum Reg { SP = 13, LR = 14, PC = 15 };
    static constexpr uint32_t kThumbBit = 1u << 5;
    // SVC immediate at layout::kSentinel; returning to it ends a call().
    static constexpr uint32_t kSentinelSvc = 0xFFFFFF;

    Cpu(GuestMemory &mem, SvcHandler handler) : mem_(mem), handler_(std::move(handler)) {}
    virtual ~Cpu() = default;

    GuestMemory &mem() const { return mem_; }

    virtual uint32_t reg(int n) const = 0;  // r0-r15
    virtual void setReg(int n, uint32_t value) = 0;
    virtual uint32_t cpsr() const = 0;
    virtual void setCpsr(uint32_t value) = 0;
    // Bit patterns of s0-s31 (d0-d15 are pairs of these).
    virtual uint32_t extReg(int n) const = 0;
    virtual void setExtReg(int n, uint32_t value) = 0;

    // Jumps to addr; bit 0 selects Thumb state.
    void jump(GuestAddr addr);

    // Runs guest code until the sentinel is reached at the current call depth.
    void run();

    // Calls a guest function with AAPCS arguments and returns r0 (and r1 in
    // the high half). Reentrant: SVC handlers may call back into the guest.
    uint64_t call(GuestAddr fn, std::initializer_list<uint32_t> args) { return call(fn, std::vector<uint32_t>(args)); }
    uint64_t call(GuestAddr fn, const std::vector<uint32_t> &args);

    // Ends the current run() as if the sentinel were reached (exit()).
    void stop() { stopRequested_ = true; }

protected:
    // Executes until an SVC; returns its immediate. The PC is left after it.
    virtual uint32_t runUntilSvc() = 0;

private:
    GuestMemory &mem_;
    SvcHandler handler_;
    bool stopRequested_ = false;
};

}  // namespace b32
