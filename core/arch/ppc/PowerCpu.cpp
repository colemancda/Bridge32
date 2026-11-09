// The PowerPC calling convention, stubs and fault delivery (see PowerCpu.h
// and Arch.h).

#include "PowerCpu.h"

#include "core/Log.h"
#include "core/arch/Arch.h"
#include "core/mem/Layout.h"

#include <signal.h>
#include <unistd.h>

#include <cstring>
#include <string>

namespace b32 {

namespace {
// Below r1 a leaf function may keep data without making a frame (the red
// zone), so anything we push on its behalf has to stay clear of it.
constexpr uint32_t kRedZone = 224;
// A frame starts with a back chain, a saved CR and a saved LR, then the
// linkage words, and the parameter area follows at 24.
constexpr uint32_t kParamArea = 24;
constexpr uint32_t kRegisterArgs = 8;
}  // namespace

uint32_t PowerCpu::arg(int i) const {
    return i < int(kRegisterArgs) ? reg(R3 + i) : mem().read<uint32_t>(reg(SP) + kParamArea + uint32_t(i) * 4);
}

void PowerCpu::setArg(int i, uint32_t value) {
    if (i < int(kRegisterArgs))
        setReg(R3 + i, value);
    else
        mem().write<uint32_t>(reg(SP) + kParamArea + uint32_t(i) * 4, value);
}

void PowerCpu::setResult64(uint64_t value) {
    setReg(R3, uint32_t(value >> 32));
    setReg(R4, uint32_t(value));
}

// Each frame's first word points at its caller's frame, and a function saves
// its own return address at 8 bytes into its caller's. At a thunk trap LR is
// the return address of the function that called the thunk.
std::vector<uint32_t> PowerCpu::frameChain(int max) const {
    std::vector<uint32_t> frames;
    if (max > 0) frames.push_back(reg(LR));
    uint32_t frame = reg(SP);
    for (int i = 1; i < max && frame && (frame & 3) == 0 && mem().isMapped(frame); i++) {
        uint32_t caller = mem().read<uint32_t>(frame);
        if (caller <= frame || (caller & 3) || !mem().isMapped(caller) || !mem().isMapped(caller + 11)) break;
        frames.push_back(mem().read<uint32_t>(caller + 8));
        frame = caller;
    }
    return frames;
}

// PPC_THREAD_STATE (1): { srr0, srr1, r0-r31, cr, xer, lr, ctr, mq, vrsave }.
bool PowerCpu::threadState(int flavor, GuestAddr state, GuestAddr countOut) {
    constexpr int kPpcThreadState = 1;
    constexpr uint32_t kCount = 40;
    if (flavor != kPpcThreadState || mem().read<uint32_t>(countOut) < kCount) return false;
    mem().write<uint32_t>(state, reg(PC));
    mem().write<uint32_t>(state + 4, reg(MSR));
    for (int i = 0; i < 32; i++) mem().write<uint32_t>(state + 8 + uint32_t(i) * 4, reg(R0 + i));
    mem().write<uint32_t>(state + 136, reg(CR));
    mem().write<uint32_t>(state + 140, reg(XER));
    mem().write<uint32_t>(state + 144, reg(LR));
    mem().write<uint32_t>(state + 148, reg(CTR));
    mem().write<uint32_t>(state + 152, 0);  // mq: the 601's
    mem().write<uint32_t>(state + 156, 0);  // vrsave
    mem().write<uint32_t>(countOut, kCount);
    return true;
}

// A new frame goes below r1 and the red zone, 16-byte aligned, with a back
// chain to the old one so a frame chain walks through it. The first eight
// words go in r3-r10 and the rest on the stack; r12 holds the function's
// address, which position-independent code uses to find its own data.
uint64_t PowerCpu::call(GuestAddr fn, const std::vector<uint32_t> &args) {
    std::vector<uint8_t> saved = saveState();
    uint32_t oldSp = reg(SP);
    uint32_t words = args.size() > kRegisterArgs ? uint32_t(args.size()) : kRegisterArgs;
    uint32_t frame = (oldSp - kRedZone - kParamArea - words * 4) & ~15u;
    mem().write<uint32_t>(frame, oldSp);
    for (size_t i = 0; i < args.size(); i++) {
        if (i < kRegisterArgs)
            setReg(R3 + int(i), args[i]);
        else
            mem().write<uint32_t>(frame + kParamArea + uint32_t(i) * 4, args[i]);
    }
    setReg(SP, frame);
    setReg(LR, layout::kSentinel);
    setReg(R12, fn);
    setReg(PC, fn);
    try {
        run();
    } catch (...) {  // a throw on its way through host frames
        restoreState(saved);
        throw;
    }
    uint64_t result = this->result();
    lastFloatResult_ = fpr(1);
    restoreState(saved);
    return result;
}

// Mac OS X's 32-bit PowerPC layouts: ucontext { uc_onstack, uc_sigmask,
// uc_stack { ss_sp, ss_size, ss_flags }, uc_link, uc_mcsize, uc_mcontext }
// (32 bytes), pointing at mcontext { es { dar, dsisr, exception, pad[5] },
// ss (the 40 words of PPC_THREAD_STATE), fs (the 32 FPRs, a pad word, fpscr),
// vs (32 vector registers and vscr, 576 bytes) }, and a 64-byte siginfo
// { si_signo, si_errno, si_code, si_pid, si_uid, si_status, si_addr, ... }.
// Only the exception and thread states are filled in; the floating-point and
// vector registers the handler runs with are the faulting code's and are put
// back when it returns, so a handler can't change them through the context.
void PowerCpu::deliverFault(uint32_t addr, bool write) {
    int sig = signalAction(SIGSEGV).handler > 1 ? SIGSEGV : SIGBUS;
    SignalAction action = signalAction(sig);
    auto framesText = [this](int max) {
        std::string frames;
        for (uint32_t ret : frameChain(max)) {
            char text[16];
            std::snprintf(text, sizeof text, " %08x", ret);
            frames += text;
        }
        return frames;
    };
    if (action.handler <= 1)
        fatal("guest %s of unmapped 0x%08x (pc=0x%08x r1=0x%08x; frames%s)", write ? "write" : "read", addr,
              reg(PC), reg(SP), framesText(16).c_str());

    constexpr uint32_t kUcontext = 32, kEs = 0, kSs = 32, kFs = kSs + 160, kVs = kFs + 264, kMcontext = kVs + 576;
    constexpr uint32_t kSiginfo = 64;
    constexpr uint32_t kDsiStore = 1u << 25;  // DSISR's "store" bit
    constexpr uint32_t kDataAccess = 3;       // the data storage exception

    GuestAddr frame = (reg(SP) - kRedZone - (kUcontext + kMcontext + kSiginfo + kParamArea)) & ~15u;
    GuestAddr uc = frame + kParamArea, mc = uc + kUcontext, si = mc + kMcontext;
    if (!mem().isMapped(frame))
        fatal("guest stack overflow: fault at 0x%08x with r1=0x%08x, pc=0x%08x (frames%s)", addr, reg(SP), reg(PC),
              framesText(24).c_str());
    std::memset(mem().ptr<void>(frame), 0, kParamArea + kUcontext + kMcontext + kSiginfo);
    mem().write<uint32_t>(frame, reg(SP));
    mem().write<uint32_t>(uc + 24, kMcontext);
    mem().write<uint32_t>(uc + 28, mc);
    mem().write<uint32_t>(mc + kEs, addr);
    mem().write<uint32_t>(mc + kEs + 4, write ? kDsiStore : 0);
    mem().write<uint32_t>(mc + kEs + 8, kDataAccess);
    mem().write<uint32_t>(mc + kSs, reg(PC));
    mem().write<uint32_t>(mc + kSs + 4, reg(MSR));
    for (int i = 0; i < 32; i++) mem().write<uint32_t>(mc + kSs + 8 + uint32_t(i) * 4, reg(R0 + i));
    mem().write<uint32_t>(mc + kSs + 136, reg(CR));
    mem().write<uint32_t>(mc + kSs + 140, reg(XER));
    mem().write<uint32_t>(mc + kSs + 144, reg(LR));
    mem().write<uint32_t>(mc + kSs + 148, reg(CTR));
    mem().write<uint32_t>(si, uint32_t(sig));
    mem().write<uint32_t>(si + 8, SEGV_MAPERR);
    mem().write<uint32_t>(si + 12, uint32_t(getpid()));
    mem().write<uint32_t>(si + 24, addr);

    setReg(SP, frame);
    call(action.handler, {uint32_t(sig), si, uc});

    // sigreturn: the state the handler left in the context.
    for (int i = 0; i < 32; i++) setReg(R0 + i, mem().read<uint32_t>(mc + kSs + 8 + uint32_t(i) * 4));
    setReg(CR, mem().read<uint32_t>(mc + kSs + 136));
    setReg(XER, mem().read<uint32_t>(mc + kSs + 140));
    setReg(LR, mem().read<uint32_t>(mc + kSs + 144));
    setReg(CTR, mem().read<uint32_t>(mc + kSs + 148));
    setReg(PC, mem().read<uint32_t>(mc + kSs));
}

// --- stubs and shims ----------------------------------------------------------

namespace arch {

const char *name() { return "ppc"; }

constexpr uint32_t kSc = 0x44000002, kBlr = 0x4E800020;

// `sc; blr`: the sc traps to the host with the stub's index (from its address);
// the blr runs when the guest resumes. A thunk that tail-calls guest code moves
// the PC instead, skipping the blr.
void writeThunkStub(GuestMemory &mem, GuestAddr stub, uint32_t index) {
    mem.write<uint32_t>(stub, kSc);
    mem.write<uint32_t>(stub + 4, kBlr);
}

void writeSentinel(GuestMemory &mem, GuestAddr addr) { mem.write<uint32_t>(addr, kSc); }

// Constructors and destructors don't return `this` in GCC's PowerPC C++ ABI.
GuestAddr thisReturningShim(GuestMemory &mem, GuestHeap &heap, GuestAddr target) { return target; }

//     lis r12, context@h;  ori r12, r12, context@l
//     lis r11, target@h;   ori r11, r11, target@l
//     mtctr r11;           bctr
void writeMethodStub(GuestMemory &mem, GuestAddr stub, uint32_t context, GuestAddr target) {
    auto lis = [](int reg, uint32_t value) { return 0x3C000000u | uint32_t(reg) << 21 | (value >> 16); };
    auto ori = [](int reg, uint32_t value) { return 0x60000000u | uint32_t(reg) << 21 | uint32_t(reg) << 16 | (value & 0xFFFF); };
    const uint32_t code[kMethodStubSize / 4] = {lis(12, context), ori(12, context), lis(11, target), ori(11, target),
                                                0x7D6903A6 /* mtctr r11 */, 0x4E800420 /* bctr */};
    for (uint32_t i = 0; i < kMethodStubSize / 4; i++) mem.write<uint32_t>(stub + i * 4, code[i]);
}

GuestAddr nativeFunction(GuestMemory &mem, GuestHeap &heap, const std::string &symbol) { return 0; }

// A 128-bit long double is two doubles that add up to the value.
double longDouble(const uint32_t *words) {
    auto asDouble = [&](int i) {
        uint64_t bits = uint64_t(words[i]) << 32 | words[i + 1];
        double value;
        std::memcpy(&value, &bits, 8);
        return value;
    };
    return asDouble(0) + asDouble(2);
}

}  // namespace arch

}  // namespace b32
