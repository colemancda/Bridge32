// The i386 guest: Darwin's cdecl (every argument a stack word, results in
// EAX/EDX, floating-point results in x87's ST(0), the callee pops a hidden
// struct-result pointer), %gs as the thread register.
#pragma once

#include "core/cpu/Cpu.h"

#include <cstdint>
#include <vector>

namespace b32 {

class X86Cpu : public Cpu {
public:
    // reg() numbering: Intel's encoding order, then the two specials.
    enum Reg { EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI, EIP, EFLAGS };

    using Cpu::Cpu;

    // The x87 stack: push a value as a returning function would, pop what a
    // returning function left.
    virtual void pushX87(double value) = 0;
    virtual double popX87() = 0;
    // Everything a call() must put back afterwards.
    virtual std::vector<uint8_t> saveState() = 0;
    virtual void restoreState(const std::vector<uint8_t> &state) = 0;

    uint32_t arg(int i) const override { return mem().read<uint32_t>(reg(ESP) + 4 + i * 4); }
    void setArg(int i, uint32_t value) override { mem().write<uint32_t>(reg(ESP) + 4 + i * 4, value); }
    uint32_t sp() const override { return reg(ESP); }
    void setSp(uint32_t value) override { setReg(ESP, value); }
    uint32_t pc() const override { return reg(EIP); }
    uint32_t returnAddress() const override { return mem().read<uint32_t>(reg(ESP)); }
    void setResult(uint32_t value) override { setReg(EAX, value); }
    void setResult64(uint64_t value) override;
    void setFloatResult(float value) override { pushX87(value); }
    void setDoubleResult(double value) override { pushX87(value); }
    uint64_t result() const override { return reg(EAX) | (uint64_t(reg(EDX)) << 32); }
    double floatingResult(bool isFloat) override { return lastX87Result_; }
    uint32_t stubContext() const override { return reg(ECX); }
    std::vector<uint32_t> frameChain(int max) const override;
    bool threadState(int flavor, GuestAddr state, GuestAddr countOut) override;

    void jump(GuestAddr addr) override { setReg(EIP, addr); }
    void enterAt(GuestAddr entry) override { setReg(EIP, entry); }
    using Cpu::call;
    uint64_t call(GuestAddr fn, const std::vector<uint32_t> &args) override;

    // A thunk standing in for a function that returns a struct too big for
    // EAX:EDX: copies the result to the caller's buffer (argument word 0)
    // and pops that hidden argument, as the callee's `ret $4` would, by
    // moving the return address up.
    void retStruct(const void *value, uint32_t size);

protected:
    void deliverFault(uint32_t addr, bool write) override;

    // Whether the x87 stack has a value on top (a function just returned one).
    virtual bool x87HasResult() = 0;

private:
    double lastX87Result_ = 0;
};

// x87 extended precision as the 10 bytes Unicorn reads and writes.
void toFloat80(double value, uint8_t out[10]);
double fromFloat80(const uint8_t in[10]);

}  // namespace b32
