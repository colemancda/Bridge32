// i386 calling convention, stubs and shims (see X86Cpu.h and Arch.h).

#include "X86Cpu.h"

#include "core/Log.h"
#include "core/arch/Arch.h"
#include "core/mem/GuestHeap.h"
#include "core/mem/Layout.h"
#include "core/thunks/Thunks.h"

#include <cmath>
#include <cstring>

namespace b32 {

void X86Cpu::setResult64(uint64_t value) {
    setReg(EAX, uint32_t(value));
    setReg(EDX, uint32_t(value >> 32));
}

// Frames are { saved ebp, return address } at ebp.
std::vector<uint32_t> X86Cpu::frameChain(int max) const {
    std::vector<uint32_t> frames;
    uint32_t fp = reg(EBP);
    for (int i = 0; i < max && fp && (fp & 3) == 0 && mem().isMapped(fp) && mem().isMapped(fp + 7); i++) {
        frames.push_back(mem().read<uint32_t>(fp + 4));
        uint32_t next = mem().read<uint32_t>(fp);
        if (next <= fp) break;
        fp = next;
    }
    return frames;
}

// x86_THREAD_STATE32 (1): { eax, ebx, ecx, edx, edi, esi, ebp, esp, ss,
// eflags, eip, cs, ds, es, fs, gs }.
bool X86Cpu::threadState(int flavor, GuestAddr state, GuestAddr countOut) {
    constexpr int kX86ThreadState32 = 1;
    constexpr uint32_t kCount = 16;
    if (flavor != kX86ThreadState32 || mem().read<uint32_t>(countOut) < kCount) return false;
    const uint32_t words[kCount] = {reg(EAX), reg(EBX), reg(ECX), reg(EDX), reg(EDI), reg(ESI), reg(EBP), reg(ESP),
                                    0x10,     reg(EFLAGS), reg(EIP), 0x08, 0x10, 0x10, 0x10, 0x18};
    for (uint32_t i = 0; i < kCount; i++) mem().write<uint32_t>(state + i * 4, words[i]);
    mem().write<uint32_t>(countOut, kCount);
    return true;
}

// Arguments are pushed right to left; the stack is 16-byte aligned at the
// call, so the callee sees esp = 12 mod 16 after the return address.
uint64_t X86Cpu::call(GuestAddr fn, const std::vector<uint32_t> &args) {
    std::vector<uint8_t> saved = saveState();
    uint32_t sp = (reg(ESP) - uint32_t(args.size()) * 4) & ~15u;
    for (size_t i = 0; i < args.size(); i++) mem().write<uint32_t>(sp + uint32_t(i) * 4, args[i]);
    sp -= 4;
    mem().write<uint32_t>(sp, layout::kSentinel);
    setReg(ESP, sp);
    setReg(EIP, fn);
    run();
    uint64_t result = this->result();
    lastX87Result_ = x87HasResult() ? popX87() : 0;
    restoreState(saved);
    return result;
}

void X86Cpu::retStruct(const void *value, uint32_t size) {
    mem().copyIn(arg(0), value, size);
    uint32_t sp = reg(ESP);
    mem().write<uint32_t>(sp + 4, mem().read<uint32_t>(sp));
    setReg(ESP, sp + 4);
}

void X86Cpu::deliverFault(uint32_t addr, bool write) {
    // Guest signal handlers on i386 (x86 ucontext layout) aren't delivered yet.
    std::string frames;
    for (uint32_t ret : frameChain(16)) {
        char text[16];
        std::snprintf(text, sizeof text, " %08x", ret);
        frames += text;
    }
    fatal("guest %s of unmapped 0x%08x (eip=0x%08x esp=0x%08x; frames%s)", write ? "write" : "read", addr, reg(EIP),
          reg(ESP), frames.c_str());
}

// --- x87 extended precision -------------------------------------------------------

void toFloat80(double value, uint8_t out[10]) {
    uint64_t bits;
    std::memcpy(&bits, &value, 8);
    uint16_t sign = uint16_t(bits >> 63) << 15;
    uint64_t mantissa = 0;
    uint16_t exponent = 0;
    if (std::isnan(value) || std::isinf(value)) {
        exponent = 0x7FFF;
        mantissa = std::isnan(value) ? 0xC000000000000000ull : 0x8000000000000000ull;
    } else if (value != 0) {
        int e;
        double m = std::frexp(std::fabs(value), &e);  // value = m * 2^e, 0.5 <= m < 1
        mantissa = uint64_t(std::ldexp(m, 64));
        exponent = uint16_t(e - 1 + 16383);
    }
    std::memcpy(out, &mantissa, 8);
    uint16_t top = exponent | sign;
    std::memcpy(out + 8, &top, 2);
}

double fromFloat80(const uint8_t in[10]) {
    uint64_t mantissa;
    uint16_t top;
    std::memcpy(&mantissa, in, 8);
    std::memcpy(&top, in + 8, 2);
    bool negative = top & 0x8000;
    int exponent = top & 0x7FFF;
    double value;
    if (exponent == 0x7FFF)
        value = (mantissa << 1) ? NAN : INFINITY;
    else if (exponent == 0 && mantissa == 0)
        value = 0;
    else
        value = std::ldexp(double(mantissa), exponent - 16383 - 63);
    return negative ? -value : value;
}

// --- stubs and shims ----------------------------------------------------------

namespace arch {

const char *name() { return "i386"; }

// `hlt; ret`, padded: the hlt traps to the host with the stub's index (from
// its address); the ret runs when the guest resumes. A thunk that tail-calls
// guest code moves eip instead, skipping the ret.
void writeThunkStub(GuestMemory &mem, GuestAddr stub, uint32_t index) {
    const uint8_t code[kThunkStubSize] = {0xF4, 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90};
    mem.copyIn(stub, code, sizeof code);
}

void writeSentinel(GuestMemory &mem, GuestAddr addr) { mem.write<uint8_t>(addr, 0xF4); }

// Nothing returns `this` in the i386 C++ ABI.
GuestAddr thisReturningShim(GuestMemory &mem, GuestHeap &heap, GuestAddr target) { return target; }

//     mov $context, %ecx
//     jmp target
void writeMethodStub(GuestMemory &mem, GuestAddr stub, uint32_t context, GuestAddr target) {
    uint8_t code[kMethodStubSize] = {0xB9, 0, 0, 0, 0, 0xE9, 0, 0, 0, 0, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC};
    std::memcpy(code + 1, &context, 4);
    int32_t rel = int32_t(target - (stub + 10));
    std::memcpy(code + 6, &rel, 4);
    mem.copyIn(stub, code, sizeof code);
}

}  // namespace arch

// --- setjmp / longjmp -----------------------------------------------------------
// The guest jmp_buf (18 words, sigjmp_buf 19) holds what we choose: ebx,
// esi, edi, ebp, the caller's esp after setjmp returns, and its return
// address. longjmp resumes there with eax = value.

namespace {
X86Cpu &x86(Call &c) { return static_cast<X86Cpu &>(c.cpu); }

void saveContext(Call &c, GuestAddr buf) {
    X86Cpu &cpu = x86(c);
    c.mem.write<uint32_t>(buf, cpu.reg(X86Cpu::EBX));
    c.mem.write<uint32_t>(buf + 4, cpu.reg(X86Cpu::ESI));
    c.mem.write<uint32_t>(buf + 8, cpu.reg(X86Cpu::EDI));
    c.mem.write<uint32_t>(buf + 12, cpu.reg(X86Cpu::EBP));
    c.mem.write<uint32_t>(buf + 16, cpu.reg(X86Cpu::ESP) + 4);
    c.mem.write<uint32_t>(buf + 20, cpu.returnAddress());
}
void restoreContext(Call &c, GuestAddr buf, uint32_t value) {
    X86Cpu &cpu = x86(c);
    cpu.setReg(X86Cpu::EBX, c.mem.read<uint32_t>(buf));
    cpu.setReg(X86Cpu::ESI, c.mem.read<uint32_t>(buf + 4));
    cpu.setReg(X86Cpu::EDI, c.mem.read<uint32_t>(buf + 8));
    cpu.setReg(X86Cpu::EBP, c.mem.read<uint32_t>(buf + 12));
    cpu.setReg(X86Cpu::ESP, c.mem.read<uint32_t>(buf + 16));
    cpu.setReg(X86Cpu::EAX, value ? value : 1);
    cpu.jump(c.mem.read<uint32_t>(buf + 20));
}
}  // namespace

B32_THUNK(_setjmp) {
    saveContext(c, c.args.ptr());
    c.ret(0);
}
B32_THUNK(__setjmp) {
    saveContext(c, c.args.ptr());
    c.ret(0);
}
B32_THUNK(_sigsetjmp) {
    saveContext(c, c.args.ptr());
    c.ret(0);
}
B32_THUNK(_longjmp) {
    GuestAddr buf = c.args.ptr();
    restoreContext(c, buf, c.args.u32());
}
B32_THUNK(__longjmp) {
    GuestAddr buf = c.args.ptr();
    restoreContext(c, buf, c.args.u32());
}
B32_THUNK(_siglongjmp) {
    GuestAddr buf = c.args.ptr();
    restoreContext(c, buf, c.args.u32());
}

}  // namespace b32
