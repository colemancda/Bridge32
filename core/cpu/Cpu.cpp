#include "Cpu.h"

#include "core/Log.h"
#include "core/mem/Layout.h"

#include <array>

namespace b32 {

void Cpu::jump(GuestAddr addr) {
    if (addr & 1)
        setCpsr(cpsr() | kThumbBit);
    else
        setCpsr(cpsr() & ~kThumbBit);
    setReg(PC, addr & ~1u);
}

void Cpu::run() {
    while (!stopRequested_) {
        uint32_t imm = runUntilSvc();
        if (imm == kSentinelSvc) return;
        handler_(*this, imm);
    }
}

uint64_t Cpu::call(GuestAddr fn, std::initializer_list<uint32_t> args) {
    std::array<uint32_t, 16> saved;
    for (int i = 0; i < 16; i++) saved[i] = reg(i);
    uint32_t savedCpsr = cpsr();

    uint32_t stackArgs = args.size() > 4 ? uint32_t(args.size()) - 4 : 0;
    uint32_t sp = (reg(SP) - stackArgs * 4) & ~7u;

    int i = 0;
    for (uint32_t a : args) {
        if (i < 4)
            setReg(i, a);
        else
            mem_.write<uint32_t>(sp + (i - 4) * 4, a);
        i++;
    }
    setReg(SP, sp);
    setReg(LR, layout::kSentinel);
    jump(fn);
    run();

    uint64_t result = reg(0) | (uint64_t(reg(1)) << 32);
    for (int r = 0; r < 16; r++) setReg(r, saved[r]);
    setCpsr(savedCpsr);
    return result;
}

}  // namespace b32
