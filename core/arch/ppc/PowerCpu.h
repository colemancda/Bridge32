// The PowerPC guest: Darwin's 32-bit ABI (the first eight argument words in
// r3-r10 with their stack slots reserved, the rest at 24(r1) and up; results
// in r3/r4 and f1; the return address in LR; no callee-popped hidden pointer),
// as seen at a thunk trap, and the 32-bit PowerPC Mac's signal frames.
// UnicornPowerCpu derives from this.
#pragma once

#include "core/cpu/Cpu.h"

#include <cstdint>
#include <vector>

namespace b32 {

class PowerCpu : public Cpu {
public:
    // reg() numbering: r0-r31 as their numbers, then the specials.
    enum Reg { R0 = 0, SP = 1, R3 = 3, R4 = 4, R11 = 11, R12 = 12, R31 = 31, PC = 32, LR, CTR, CR, XER, MSR };

    using Cpu::Cpu;

    // The floating-point registers hold doubles (a float is widened), and an
    // AltiVec register is 16 bytes in the order stvx stores them.
    virtual double fpr(int n) const = 0;
    virtual void setFpr(int n, double value) = 0;
    virtual void vr(int n, uint8_t out[16]) const = 0;
    virtual void setVr(int n, const uint8_t in[16]) = 0;
    // Everything a call() must put back afterwards.
    virtual std::vector<uint8_t> saveState() = 0;
    virtual void restoreState(const std::vector<uint8_t> &state) = 0;

    uint32_t arg(int i) const override;
    void setArg(int i, uint32_t value) override;
    // The floating-point arguments of a call with a fixed prototype are in f1-f13.
    bool floatArgsInRegisters() const override { return true; }
    double floatArg(int n) const override { return fpr(1 + n); }
    uint32_t sp() const override { return reg(SP); }
    void setSp(uint32_t value) override { setReg(SP, value); }
    uint32_t pc() const override { return reg(PC); }
    uint32_t returnAddress() const override { return reg(LR); }
    void setResult(uint32_t value) override { setReg(R3, value); }
    // A 64-bit value comes back as r3 (high) : r4 (low).
    void setResult64(uint64_t value) override;
    void setFloatResult(float value) override { setFpr(1, value); }
    void setDoubleResult(double value) override { setFpr(1, value); }
    // The first result register in the low word and the second in the high
    // word, as on the other guests; for a 64-bit result that is the halves
    // the other way round from the value.
    uint64_t result() const override { return reg(R3) | (uint64_t(reg(R4)) << 32); }
    double floatingResult(bool isFloat) override { return lastFloatResult_; }
    // Method stubs (arch::writeMethodStub) leave their context in r12.
    uint32_t stubContext() const override { return reg(R12); }
    std::vector<uint32_t> frameChain(int max) const override;
    bool threadState(int flavor, GuestAddr state, GuestAddr countOut) override;

    void jump(GuestAddr addr) override { setReg(PC, addr); }
    void enterAt(GuestAddr entry) override { setReg(PC, entry); }
    using Cpu::call;
    uint64_t call(GuestAddr fn, const std::vector<uint32_t> &args) override;

protected:
    void deliverFault(uint32_t addr, bool write) override;

private:
    double lastFloatResult_ = 0;
};

}  // namespace b32
