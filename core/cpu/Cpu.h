// One guest thread's CPU. The backend is a JIT (dynarmic for ARM, Unicorn
// for i386); this interface keeps the loader, the thunks and the ObjC bridge
// independent of both the engine and the guest architecture. What depends on
// the architecture's calling convention is virtual here and implemented by
// ArmCpu and X86Cpu (core/arch); the engines derive from those.
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
    // Called for every thunk trap; `index` is the thunk's index (Thunks.h).
    // Runs outside the JIT, so it may call back into the guest with call().
    using SvcHandler = std::function<void(Cpu &, uint32_t index)>;

    // Trap index of layout::kSentinel; returning to it ends a call().
    static constexpr uint32_t kSentinelSvc = 0xFFFFFF;

    Cpu(GuestMemory &mem, SvcHandler handler) : mem_(mem), handler_(std::move(handler)) {}
    virtual ~Cpu() = default;

    GuestMemory &mem() const { return mem_; }

    // Raw registers, numbered as the architecture's class says (ArmCpu::Reg,
    // X86Cpu::Reg). Architecture-neutral code uses the accessors below.
    virtual uint32_t reg(int n) const = 0;
    virtual void setReg(int n, uint32_t value) = 0;

    // The calling convention, as seen at a thunk trap: argument words (every
    // argument is 4-byte words on both guests; 64-bit values take two with no
    // alignment), the stack pointer, the caller's return address.
    virtual uint32_t arg(int i) const = 0;
    virtual void setArg(int i, uint32_t value) = 0;
    virtual uint32_t sp() const = 0;
    virtual void setSp(uint32_t value) = 0;
    virtual uint32_t pc() const = 0;
    virtual uint32_t returnAddress() const = 0;

    // Results of the thunk in progress. Floating-point results go where the
    // ABI puts them (integer registers on arm's soft-float ABI, x87's ST(0)
    // on i386).
    virtual void setResult(uint32_t value) = 0;
    virtual void setResult64(uint64_t value) = 0;
    virtual void setFloatResult(float value) = 0;
    virtual void setDoubleResult(double value) = 0;

    // The integer-class result of the guest function a call() just returned
    // from (the low word, and the high word of a 64-bit result), and its
    // floating-point result: `isFloat` says whether the function returns a
    // float rather than a double, which matters where the two are returned
    // differently.
    virtual uint64_t result() const = 0;
    virtual double floatingResult(bool isFloat) = 0;

    // Ends a host function that returned a struct through a hidden pointer
    // (arch::structReturnedInMemory), for ABIs where the callee pops it.
    virtual void popStructPointer() {}

    // The word a method stub (arch::writeMethodStub) left for its thunk.
    virtual uint32_t stubContext() const = 0;
    // Return addresses up the guest's frame chain, innermost first, for logs.
    virtual std::vector<uint32_t> frameChain(int max = 16) const = 0;
    // thread_get_state: fills `state` in the guest's layout of its native
    // flavor and writes the count; false for other flavors.
    virtual bool threadState(int flavor, GuestAddr state, GuestAddr countOut) = 0;

    // The thread's pthread_getspecific slots, kTsdSlots words of guest memory
    // indexed by key. Darwin hands their address to user code in a thread
    // register (TPIDRURO on arm, the %gs base on i386), and engines (Mono,
    // Unity) read it there instead of calling pthread_getspecific.
    static constexpr uint32_t kTsdSlots = 768;
    GuestAddr tsd() const { return tsd_; }
    void setTsd(GuestAddr addr) {
        tsd_ = addr;
        tsdChanged();
    }

    // Continues at addr: a tail call out of a thunk, with the caller's
    // arguments and return address in place.
    virtual void jump(GuestAddr addr) = 0;
    // Starts a routine that never returns (crt1's start, a thread's body).
    virtual void enterAt(GuestAddr entry) = 0;

    // Runs guest code until the sentinel is reached at the current call depth.
    void run();
    // How many run()s are in progress on this thread: guest and host frames
    // alternate, one stretch of guest code per run.
    int runDepth() const { return runDepth_; }

    // Calls a guest function with argument words and returns its result()
    // (the high half holds the second word). Reentrant: thunks may call back
    // into the guest. Everything but the result is as it was afterwards.
    uint64_t call(GuestAddr fn, std::initializer_list<uint32_t> args) { return call(fn, std::vector<uint32_t>(args)); }
    virtual uint64_t call(GuestAddr fn, const std::vector<uint32_t> &args) = 0;

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
    // were at the trap.
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
    // Executes until a thunk trap; returns its index. The PC is left where
    // the trap's stub continues (its return instruction).
    virtual uint32_t runUntilSvc() = 0;

    // Runs the guest's handler for a fault at `addr` by the instruction at
    // the PC, as the kernel would: with siginfo and a ucontext of the
    // faulting state on the stack, resuming from whatever state the handler
    // leaves there. Fatal when there's no handler.
    virtual void deliverFault(uint32_t addr, bool write) = 0;

    // The thread register must follow tsd_ (X86Cpu reloads %gs).
    virtual void tsdChanged() {}

    // Bracket each stretch of guest execution in runUntilSvc: enterGuest
    // waits out a suspension, leaveGuest lets suspend() return.
    void enterGuest();
    void leaveGuest();
    // Makes the running guest code return to runUntilSvc soon; called from
    // another thread.
    virtual void requestHalt() = 0;

    uint32_t tsd_ = 0;  // the JIT may read it in place

private:
    GuestMemory &mem_;
    SvcHandler handler_;
    bool stopRequested_ = false;
    int runDepth_ = 0;

    std::mutex suspendLock_;
    std::condition_variable suspendChanged_;
    int suspendCount_ = 0;
    bool inGuest_ = false;
    uint32_t thread_ = 0;
};

}  // namespace b32
