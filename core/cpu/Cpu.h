// One guest thread's CPU. The real backend is dynarmic's A32 JIT; the
// interface keeps the loader and thunks independent of it.
#pragma once

#include "core/mem/GuestMemory.h"

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <mutex>
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

    // The host thread running this Cpu, by its Mach port (what the guest's
    // mach_thread_self returns), for Mach's thread calls.
    void bindToCurrentThread();
    void unbindThread();
    static Cpu *forThread(uint32_t port);
    static std::vector<uint32_t> threadPorts();

    // Suspension from another thread (Mach thread_suspend, which garbage
    // collectors use to stop the world): suspend() returns once the thread
    // isn't running guest code, and it doesn't run any more until resumed.
    // A thread inside a thunk carries on with it; its registers stay as they
    // were at the SVC.
    void suspend();
    void resume();
    int suspendCount();

    // Guest signal handlers (sigaction), process-wide. A guest access to
    // unmapped memory goes to the SIGSEGV (or SIGBUS) handler when there is
    // one: Mono turns those faults into NullReferenceExceptions.
    struct SignalAction {
        GuestAddr handler = 0;  // 0 is SIG_DFL, 1 SIG_IGN
        uint32_t mask = 0, flags = 0;
    };
    static SignalAction signalAction(int sig);
    static SignalAction setSignalAction(int sig, SignalAction action);  // returns the old one
    static bool guestHandlesFaults();

protected:
    // Executes until an SVC; returns its immediate. The PC is left after it.
    virtual uint32_t runUntilSvc() = 0;

    // Runs the guest's handler for a fault at `addr` by the instruction at
    // the PC, as the kernel would: with siginfo and a ucontext of the
    // faulting state on the stack, resuming from whatever state the handler
    // leaves there. Fatal when there's no handler.
    void deliverFault(uint32_t addr, bool write);

    // Bracket each stretch of guest execution in runUntilSvc: enterGuest
    // waits out a suspension, leaveGuest lets suspend() return.
    void enterGuest();
    void leaveGuest();
    // Makes the running guest code return to runUntilSvc soon; called from
    // another thread.
    virtual void requestHalt() = 0;

private:
    GuestMemory &mem_;
    SvcHandler handler_;
    bool stopRequested_ = false;

    std::mutex suspendLock_;
    std::condition_variable suspendChanged_;
    int suspendCount_ = 0;
    bool inGuest_ = false;
    uint32_t thread_ = 0;
};

}  // namespace b32
