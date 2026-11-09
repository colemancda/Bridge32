// ARM calling convention, stubs and shims (see ArmCpu.h and Arch.h).

#include "ArmCpu.h"

#include "core/Log.h"
#include "core/arch/Arch.h"
#include "core/mem/GuestHeap.h"
#include "core/mem/Layout.h"
#include "core/thunks/Thunks.h"

#include <signal.h>
#include <unistd.h>

#include <array>
#include <cstring>

namespace b32 {

uint32_t ArmCpu::arg(int i) const { return i < 4 ? reg(i) : mem().read<uint32_t>(reg(SP) + (i - 4) * 4); }

void ArmCpu::setArg(int i, uint32_t value) {
    if (i < 4)
        setReg(i, value);
    else
        mem().write<uint32_t>(reg(SP) + (i - 4) * 4, value);
}

void ArmCpu::setResult64(uint64_t value) {
    setReg(0, uint32_t(value));
    setReg(1, uint32_t(value >> 32));
}

void ArmCpu::setFloatResult(float value) {
    uint32_t bits;
    std::memcpy(&bits, &value, 4);
    setReg(0, bits);
}

void ArmCpu::setDoubleResult(double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, 8);
    setResult64(bits);
}

double ArmCpu::floatingResult(bool isFloat) {
    if (isFloat) {
        uint32_t bits = reg(0);
        float f;
        std::memcpy(&f, &bits, 4);
        return f;
    }
    uint64_t bits = result();
    double d;
    std::memcpy(&d, &bits, 8);
    return d;
}

// iOS code keeps a frame chain in r7: { saved r7, saved lr }.
std::vector<uint32_t> ArmCpu::frameChain(int max) const {
    std::vector<uint32_t> frames;
    uint32_t fp = reg(7);
    for (int i = 0; i < max && fp && (fp & 3) == 0 && mem().isMapped(fp) && mem().isMapped(fp + 7); i++) {
        frames.push_back(mem().read<uint32_t>(fp + 4));
        uint32_t next = mem().read<uint32_t>(fp);
        if (next <= fp) break;
        fp = next;
    }
    return frames;
}

// ARM_THREAD_STATE (1): arm_thread_state_t { r[13], sp, lr, pc, cpsr }.
bool ArmCpu::threadState(int flavor, GuestAddr state, GuestAddr countOut) {
    constexpr int kArmThreadState = 1;
    constexpr uint32_t kCount = 17;
    if (flavor != kArmThreadState || mem().read<uint32_t>(countOut) < kCount) return false;
    for (int r = 0; r < 16; r++) mem().write<uint32_t>(state + r * 4, reg(r));
    mem().write<uint32_t>(state + 64, cpsr());
    mem().write<uint32_t>(countOut, kCount);
    return true;
}

void ArmCpu::jump(GuestAddr addr) {
    if (addr & 1)
        setCpsr(cpsr() | kThumbBit);
    else
        setCpsr(cpsr() & ~kThumbBit);
    setReg(PC, addr & ~1u);
}

void ArmCpu::enterAt(GuestAddr entry) {
    setReg(LR, layout::kSentinel);
    jump(entry);
}

uint64_t ArmCpu::call(GuestAddr fn, const std::vector<uint32_t> &args) {
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
            mem().write<uint32_t>(sp + (i - 4) * 4, a);
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

// The 32-bit iOS layouts: ucontext { uc_onstack, uc_sigmask, uc_stack { ss_sp,
// ss_size, ss_flags }, uc_link, uc_mcsize, uc_mcontext } (32 bytes) pointing at
// mcontext { __es { exception, fsr, far }, __ss { r[13], sp, lr, pc, cpsr },
// __fs { r[64], fpscr } } (340 bytes), and a 64-byte siginfo { si_signo,
// si_errno, si_code, si_pid, si_uid, si_status, si_addr, si_value, si_band, pad }.
void ArmCpu::deliverFault(uint32_t addr, bool write) {
    int sig = signalAction(SIGSEGV).handler > 1 ? SIGSEGV : SIGBUS;
    SignalAction action = signalAction(sig);
    if (action.handler <= 1)
        fatal("guest %s of unmapped 0x%08x (pc=0x%08x lr=0x%08x)", write ? "write" : "read", addr, reg(PC), reg(LR));

    constexpr uint32_t kUcontext = 32, kMcontext = 340, kSiginfo = 64;
    constexpr uint32_t kSs = 12, kFs = kSs + 68;
    GuestAddr frame = (reg(SP) - (kUcontext + kMcontext + kSiginfo)) & ~15u;
    GuestAddr uc = frame, mc = frame + kUcontext, si = mc + kMcontext;
    std::memset(mem().ptr<void>(frame), 0, kUcontext + kMcontext + kSiginfo);
    mem().write<uint32_t>(uc + 24, kMcontext);
    mem().write<uint32_t>(uc + 28, mc);
    mem().write<uint32_t>(mc + 4, write ? 1u << 11 : 0);  // fsr's WnR bit
    mem().write<uint32_t>(mc + 8, addr);
    for (int r = 0; r < 16; r++) mem().write<uint32_t>(mc + kSs + r * 4, reg(r));
    mem().write<uint32_t>(mc + kSs + 64, cpsr());
    for (int r = 0; r < 64; r++) mem().write<uint32_t>(mc + kFs + r * 4, extReg(r));
    mem().write<uint32_t>(si, uint32_t(sig));
    mem().write<uint32_t>(si + 8, SEGV_MAPERR);
    mem().write<uint32_t>(si + 12, uint32_t(getpid()));
    mem().write<uint32_t>(si + 24, addr);

    setReg(SP, frame);
    call(action.handler, {uint32_t(sig), si, uc});

    // sigreturn: the state the handler left in the context.
    for (int r = 0; r < 64; r++) setExtReg(r, mem().read<uint32_t>(mc + kFs + r * 4));
    for (int r = 0; r < 15; r++) setReg(r, mem().read<uint32_t>(mc + kSs + r * 4));
    uint32_t pc = mem().read<uint32_t>(mc + kSs + 60);
    uint32_t psr = mem().read<uint32_t>(mc + kSs + 64);
    if (pc & 1) psr |= kThumbBit;
    setCpsr(psr);
    setReg(PC, pc & ~1u);
}

// --- stubs and shims ----------------------------------------------------------

namespace arch {

namespace {
constexpr uint32_t kArmSvc = 0xEF000000;
constexpr uint32_t kArmBxLr = 0xE12FFF1E;
}  // namespace

const char *name() { return "armv7"; }

// `svc #index; bx lr`
void writeThunkStub(GuestMemory &mem, GuestAddr stub, uint32_t index) {
    mem.write<uint32_t>(stub, kArmSvc | index);
    mem.write<uint32_t>(stub + 4, kArmBxLr);
}

void writeSentinel(GuestMemory &mem, GuestAddr addr) { mem.write<uint32_t>(addr, kArmSvc | Cpu::kSentinelSvc); }

//     push {r0, lr}
//     ldr  r12, [pc, #4]
//     blx  r12
//     pop  {r0, pc}
//     .word target
GuestAddr thisReturningShim(GuestMemory &mem, GuestHeap &heap, GuestAddr target) {
    GuestAddr shim = heap.alloc(20);
    const uint32_t code[5] = {0xe92d4001, 0xe59fc004, 0xe12fff3c, 0xe8bd8001, target};
    mem.copyIn(shim, code, sizeof code);
    return shim;
}

//     ldr r12, [pc]     ; context
//     ldr pc, [pc]      ; target (out of branch range)
//     .word context
//     .word target
void writeMethodStub(GuestMemory &mem, GuestAddr stub, uint32_t context, GuestAddr target) {
    mem.write<uint32_t>(stub, 0xe59fc000);
    mem.write<uint32_t>(stub + 4, 0xe59ff000);
    mem.write<uint32_t>(stub + 8, context);
    mem.write<uint32_t>(stub + 12, target);
}

}  // namespace arch

// --- setjmp / longjmp -----------------------------------------------------------
// The guest jmp_buf holds what we choose: r4-r11, sp, lr and d8-d15 (26
// words; the buffer has room for 27). setjmp returns through the caller's lr
// as usual; longjmp resumes at the saved lr with r0 = value.

namespace {
ArmCpu &arm(Call &c) { return static_cast<ArmCpu &>(c.cpu); }

void saveContext(Call &c, GuestAddr buf) {
    ArmCpu &cpu = arm(c);
    for (int r = 4; r <= 11; r++) c.mem.write<uint32_t>(buf + (r - 4) * 4, cpu.reg(r));
    c.mem.write<uint32_t>(buf + 32, cpu.reg(ArmCpu::SP));
    c.mem.write<uint32_t>(buf + 36, cpu.reg(ArmCpu::LR));
    for (int s = 16; s < 32; s++) c.mem.write<uint32_t>(buf + 40 + (s - 16) * 4, cpu.extReg(s));
}
void restoreContext(Call &c, GuestAddr buf, uint32_t value) {
    ArmCpu &cpu = arm(c);
    for (int r = 4; r <= 11; r++) cpu.setReg(r, c.mem.read<uint32_t>(buf + (r - 4) * 4));
    cpu.setReg(ArmCpu::SP, c.mem.read<uint32_t>(buf + 32));
    for (int s = 16; s < 32; s++) cpu.setExtReg(s, c.mem.read<uint32_t>(buf + 40 + (s - 16) * 4));
    cpu.setReg(0, value ? value : 1);
    cpu.jump(c.mem.read<uint32_t>(buf + 36));
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
