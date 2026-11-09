// i386 calling convention, stubs and shims (see X86Cpu.h and Arch.h).

#include "X86Cpu.h"

#include "core/Log.h"
#include "core/arch/Arch.h"
#include "core/mem/GuestHeap.h"
#include "core/mem/Layout.h"
#include "core/thunks/Thunks.h"

#include <signal.h>
#include <unistd.h>

#include <cmath>
#include <cstring>
#include <string>

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
    try {
        run();
    } catch (...) {  // a throw on its way through host frames (legacy_thunks.mm)
        restoreState(saved);
        throw;
    }
    uint64_t result = this->result();
    lastX87Result_ = x87HasResult() ? popX87() : 0;
    restoreState(saved);
    return result;
}

void X86Cpu::popStructPointer() {
    uint32_t sp = reg(ESP);
    mem().write<uint32_t>(sp + 4, mem().read<uint32_t>(sp));
    setReg(ESP, sp + 4);
}

// The i386 Mac layouts: ucontext { uc_onstack, uc_sigmask, uc_stack { ss_sp,
// ss_size, ss_flags }, uc_link, uc_mcsize, uc_mcontext } (32 bytes) pointing at
// mcontext { __es { trapno, cpu, err, faultvaddr }, __ss (x86_thread_state32),
// __fs (x86_float_state32, 524 bytes) } (600 bytes), and a 64-byte siginfo
// { si_signo, si_errno, si_code, si_pid, si_uid, si_status, si_addr, si_value,
// si_band, pad }. Only the control words of __fs are filled in; the floating
// point state the handler runs with is the faulting code's, and is put back
// when it returns, so a handler can't change it through the context.
void X86Cpu::deliverFault(uint32_t addr, bool write) {
    int sig = signalAction(SIGSEGV).handler > 1 ? SIGSEGV : SIGBUS;
    SignalAction action = signalAction(sig);
    if (action.handler <= 1) {
        std::string frames;
        for (uint32_t ret : frameChain(16)) {
            char text[16];
            std::snprintf(text, sizeof text, " %08x", ret);
            frames += text;
        }
        fatal("guest %s of unmapped 0x%08x (eip=0x%08x esp=0x%08x; frames%s)", write ? "write" : "read", addr, reg(EIP),
              reg(ESP), frames.c_str());
    }

    constexpr uint32_t kUcontext = 32, kMcontext = 600, kSiginfo = 64;
    constexpr uint32_t kSs = 12, kFs = kSs + 64;
    constexpr uint32_t kPageFault = 14, kUserAccess = 4, kWriteAccess = 2;
    // x86_thread_state32's order; ss, cs, ds, es, fs and gs are fixed here.
    static constexpr Reg kStateOrder[] = {EAX, EBX, ECX, EDX, EDI, ESI, EBP, ESP};
    constexpr uint32_t kEflagsSlot = 9, kEipSlot = 10;

    GuestAddr frame = (reg(ESP) - (kUcontext + kMcontext + kSiginfo)) & ~15u;
    GuestAddr uc = frame, mc = frame + kUcontext, si = mc + kMcontext;
    if (!mem().isMapped(frame)) {
        std::string frames;
        for (uint32_t ret : frameChain(24)) {
            char text[16];
            std::snprintf(text, sizeof text, " %08x", ret);
            frames += text;
        }
        fatal("guest stack overflow: fault at 0x%08x with esp=0x%08x, eip=0x%08x (frames%s)", addr, reg(ESP), reg(EIP), frames.c_str());
    }
    std::memset(mem().ptr<void>(frame), 0, kUcontext + kMcontext + kSiginfo);
    mem().write<uint32_t>(uc + 24, kMcontext);
    mem().write<uint32_t>(uc + 28, mc);
    mem().write<uint16_t>(mc, kPageFault);
    mem().write<uint32_t>(mc + 4, kUserAccess | (write ? kWriteAccess : 0));
    mem().write<uint32_t>(mc + 8, addr);
    for (uint32_t i = 0; i < 8; i++) mem().write<uint32_t>(mc + kSs + i * 4, reg(kStateOrder[i]));
    const uint32_t segments[] = {0x10, 0x08, 0x10, 0x10, 0x10, 0x18};  // ss, then cs ds es fs gs (see UnicornCpu)
    mem().write<uint32_t>(mc + kSs + 8 * 4, segments[0]);
    mem().write<uint32_t>(mc + kSs + kEflagsSlot * 4, reg(EFLAGS));
    mem().write<uint32_t>(mc + kSs + kEipSlot * 4, reg(EIP));
    for (uint32_t i = 1; i < 6; i++) mem().write<uint32_t>(mc + kSs + (10 + i) * 4, segments[i]);
    mem().write<uint16_t>(mc + kFs + 8, 0x037F);    // fcw, the default
    mem().write<uint32_t>(mc + kFs + 32, 0x1F80);   // mxcsr, the default
    mem().write<uint32_t>(si, uint32_t(sig));
    mem().write<uint32_t>(si + 8, SEGV_MAPERR);
    mem().write<uint32_t>(si + 12, uint32_t(getpid()));
    mem().write<uint32_t>(si + 24, addr);

    setReg(ESP, frame);
    call(action.handler, {uint32_t(sig), si, uc});

    // sigreturn: the state the handler left in the context.
    for (uint32_t i = 0; i < 8; i++) setReg(kStateOrder[i], mem().read<uint32_t>(mc + kSs + i * 4));
    setReg(EFLAGS, mem().read<uint32_t>(mc + kSs + kEflagsSlot * 4));
    setReg(EIP, mem().read<uint32_t>(mc + kSs + kEipSlot * 4));
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

// pthread_getspecific as Apple's i386 libSystem has it, so a thread key is a
// plain %gs-relative load: Mono reads these instructions to learn how to
// inline it (the third word is the displacement it adds to key * 4), and
// it's by far the most called import of anything built on TLS.
//     mov 4(%esp), %eax
//     mov %gs:0(,%eax,4), %eax
//     ret
GuestAddr nativeFunction(GuestMemory &mem, GuestHeap &heap, const std::string &symbol) {
    if (symbol != "_pthread_getspecific") return 0;
    static const uint8_t code[] = {0x8B, 0x44, 0x24, 0x04, 0x65, 0x8B, 0x04, 0x85, 0, 0, 0, 0, 0xC3};
    GuestAddr addr = heap.alloc(sizeof code);
    mem.copyIn(addr, code, sizeof code);
    return addr;
}

double longDouble(const uint32_t *words) {
    uint8_t bytes[10];
    std::memcpy(bytes, words, sizeof bytes);
    return fromFloat80(bytes);
}

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
}  // namespace

void X86Cpu::longjmpTo(GuestAddr buf, uint32_t value) {
    setReg(EBX, mem().read<uint32_t>(buf));
    setReg(ESI, mem().read<uint32_t>(buf + 4));
    setReg(EDI, mem().read<uint32_t>(buf + 8));
    setReg(EBP, mem().read<uint32_t>(buf + 12));
    setReg(ESP, mem().read<uint32_t>(buf + 16));
    setReg(EAX, value ? value : 1);
    jump(mem().read<uint32_t>(buf + 20));
}

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
    x86(c).longjmpTo(buf, c.args.u32());
}
B32_THUNK(__longjmp) {
    GuestAddr buf = c.args.ptr();
    x86(c).longjmpTo(buf, c.args.u32());
}
B32_THUNK(_siglongjmp) {
    GuestAddr buf = c.args.ptr();
    x86(c).longjmpTo(buf, c.args.u32());
}

}  // namespace b32
