// The armv6/armv7 guest: AAPCS with iOS's soft-float variant (r0-r3 then
// stack words, results in r0/r1, floats as their bit patterns), Thumb
// interworking, TPIDRURO as the thread register.
#pragma once

#include "core/cpu/Cpu.h"

namespace b32 {

class ArmCpu : public Cpu {
public:
    enum Reg { SP = 13, LR = 14, PC = 15 };
    static constexpr uint32_t kThumbBit = 1u << 5;

    using Cpu::Cpu;

    virtual uint32_t cpsr() const = 0;
    virtual void setCpsr(uint32_t value) = 0;
    // Bit patterns of s0-s31 (d0-d15 are pairs of these).
    virtual uint32_t extReg(int n) const = 0;
    virtual void setExtReg(int n, uint32_t value) = 0;

    uint32_t arg(int i) const override;
    void setArg(int i, uint32_t value) override;
    uint32_t sp() const override { return reg(SP); }
    void setSp(uint32_t value) override { setReg(SP, value); }
    uint32_t pc() const override { return reg(PC); }
    uint32_t returnAddress() const override { return reg(LR); }
    void setResult(uint32_t value) override { setReg(0, value); }
    void setResult64(uint64_t value) override;
    void setFloatResult(float value) override;
    void setDoubleResult(double value) override;
    uint64_t result() const override { return reg(0) | (uint64_t(reg(1)) << 32); }
    double floatingResult(bool isFloat) override;
    uint32_t stubContext() const override { return reg(12); }
    std::vector<uint32_t> frameChain(int max) const override;
    bool threadState(int flavor, GuestAddr state, GuestAddr countOut) override;

    // Jumps to addr; bit 0 selects Thumb state.
    void jump(GuestAddr addr) override;
    void enterAt(GuestAddr entry) override;
    using Cpu::call;
    uint64_t call(GuestAddr fn, const std::vector<uint32_t> &args) override;

protected:
    void deliverFault(uint32_t addr, bool write) override;
};

}  // namespace b32
