#include "Cpu.h"

#include "core/Log.h"

#include <mach/mach.h>
#include <signal.h>

#include <atomic>
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

void Cpu::run() {
    while (!stopRequested_) {
        uint32_t index = runUntilSvc();
        if (index == kSentinelSvc) return;
        handler_(*this, index);
    }
}

}  // namespace b32
