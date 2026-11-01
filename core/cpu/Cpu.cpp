#include "Cpu.h"

#include "core/Log.h"
#include "core/mem/Layout.h"

#include <mach/mach.h>
#include <signal.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cstring>
#include <unordered_map>

namespace b32 {

namespace {
std::mutex threadsLock;
std::unordered_map<uint32_t, Cpu *> threads;  // by Mach port
}  // namespace

namespace {
std::mutex signalsLock;
Cpu::SignalAction signalActions[32];
std::atomic<bool> faultHandlers{false};

bool isHandler(GuestAddr handler) { return handler > 1; }
}  // namespace

Cpu::SignalAction Cpu::signalAction(int sig) {
    std::lock_guard guard(signalsLock);
    return sig > 0 && sig < 32 ? signalActions[sig] : SignalAction{};
}

Cpu::SignalAction Cpu::setSignalAction(int sig, SignalAction action) {
    std::lock_guard guard(signalsLock);
    if (sig <= 0 || sig >= 32) return {};
    SignalAction old = signalActions[sig];
    signalActions[sig] = action;
    faultHandlers = isHandler(signalActions[SIGSEGV].handler) || isHandler(signalActions[SIGBUS].handler);
    return old;
}

bool Cpu::guestHandlesFaults() { return faultHandlers; }

// The 32-bit iOS layouts: ucontext { uc_onstack, uc_sigmask, uc_stack { ss_sp,
// ss_size, ss_flags }, uc_link, uc_mcsize, uc_mcontext } (32 bytes) pointing at
// mcontext { __es { exception, fsr, far }, __ss { r[13], sp, lr, pc, cpsr },
// __fs { r[64], fpscr } } (340 bytes), and a 64-byte siginfo { si_signo,
// si_errno, si_code, si_pid, si_uid, si_status, si_addr, si_value, si_band, pad }.
void Cpu::deliverFault(uint32_t addr, bool write) {
    int sig = isHandler(signalAction(SIGSEGV).handler) ? SIGSEGV : SIGBUS;
    SignalAction action = signalAction(sig);
    if (!isHandler(action.handler))
        fatal("guest %s of unmapped 0x%08x (pc=0x%08x lr=0x%08x)", write ? "write" : "read", addr, reg(PC), reg(LR));

    constexpr uint32_t kUcontext = 32, kMcontext = 340, kSiginfo = 64;
    constexpr uint32_t kSs = 12, kFs = kSs + 68;
    GuestAddr frame = (reg(SP) - (kUcontext + kMcontext + kSiginfo)) & ~15u;
    GuestAddr uc = frame, mc = frame + kUcontext, si = mc + kMcontext;
    std::memset(mem_.ptr<void>(frame), 0, kUcontext + kMcontext + kSiginfo);
    mem_.write<uint32_t>(uc + 24, kMcontext);
    mem_.write<uint32_t>(uc + 28, mc);
    mem_.write<uint32_t>(mc + 4, write ? 1u << 11 : 0);  // fsr's WnR bit
    mem_.write<uint32_t>(mc + 8, addr);
    for (int r = 0; r < 16; r++) mem_.write<uint32_t>(mc + kSs + r * 4, reg(r));
    mem_.write<uint32_t>(mc + kSs + 64, cpsr());
    for (int r = 0; r < 64; r++) mem_.write<uint32_t>(mc + kFs + r * 4, extReg(r));
    mem_.write<uint32_t>(si, uint32_t(sig));
    mem_.write<uint32_t>(si + 8, SEGV_MAPERR);
    mem_.write<uint32_t>(si + 12, uint32_t(getpid()));
    mem_.write<uint32_t>(si + 24, addr);

    setReg(SP, frame);
    call(action.handler, {uint32_t(sig), si, uc});

    // sigreturn: the state the handler left in the context.
    for (int r = 0; r < 64; r++) setExtReg(r, mem_.read<uint32_t>(mc + kFs + r * 4));
    for (int r = 0; r < 15; r++) setReg(r, mem_.read<uint32_t>(mc + kSs + r * 4));
    uint32_t pc = mem_.read<uint32_t>(mc + kSs + 60);
    uint32_t psr = mem_.read<uint32_t>(mc + kSs + 64);
    if (pc & 1) psr |= kThumbBit;
    setCpsr(psr);
    setReg(PC, pc & ~1u);
}

void Cpu::bindToCurrentThread() {
    // mach_thread_self adds a send right each call; this one is kept while bound.
    thread_ = mach_thread_self();
    std::lock_guard guard(threadsLock);
    threads[thread_] = this;
}

void Cpu::unbindThread() {
    std::lock_guard guard(threadsLock);
    if (auto it = threads.find(thread_); it != threads.end() && it->second == this) threads.erase(it);
    mach_port_deallocate(mach_task_self(), thread_);
    thread_ = 0;
}

Cpu *Cpu::forThread(uint32_t port) {
    std::lock_guard guard(threadsLock);
    auto it = threads.find(port);
    return it == threads.end() ? nullptr : it->second;
}

std::vector<uint32_t> Cpu::threadPorts() {
    std::lock_guard guard(threadsLock);
    std::vector<uint32_t> ports;
    for (auto &[port, cpu] : threads) ports.push_back(port);
    return ports;
}

void Cpu::suspend() {
    std::unique_lock guard(suspendLock_);
    suspendCount_++;
    if (!inGuest_) return;
    guard.unlock();
    requestHalt();
    guard.lock();
    suspendChanged_.wait(guard, [this] { return !inGuest_; });
}

void Cpu::resume() {
    std::lock_guard guard(suspendLock_);
    if (suspendCount_ > 0 && --suspendCount_ == 0) suspendChanged_.notify_all();
}

int Cpu::suspendCount() {
    std::lock_guard guard(suspendLock_);
    return suspendCount_;
}

void Cpu::enterGuest() {
    std::unique_lock guard(suspendLock_);
    suspendChanged_.wait(guard, [this] { return suspendCount_ == 0; });
    inGuest_ = true;
}

void Cpu::leaveGuest() {
    std::lock_guard guard(suspendLock_);
    inGuest_ = false;
    suspendChanged_.notify_all();
}

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

uint64_t Cpu::call(GuestAddr fn, const std::vector<uint32_t> &args) {
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
