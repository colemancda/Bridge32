// POSIX threads. Each guest thread is a host thread running its own CPU (see
// Runtime::runThread); synchronization objects in guest memory are backed by
// host ones, looked up by guest address. That covers objects set up with
// static initializers (PTHREAD_MUTEX_INITIALIZER) as well as *_init.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"
#include "core/mem/Layout.h"

#include <pthread.h>

#include <cerrno>
#include <cstdlib>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <unordered_map>

using namespace b32;

namespace {

struct Thread {
    uint32_t slot;
    std::thread host;
    uint32_t result = 0;
    bool detached = false;
};

std::mutex threadsLock;
std::unordered_map<GuestAddr, Thread *> threads;  // guest pthread_t -> thread
bool slotsUsed[layout::kMaxThreads] = {true};     // slot 0 is the main thread
thread_local GuestAddr selfHandle = 0;
GuestAddr mainHandle = 0;

uint32_t takeSlot() {
    std::lock_guard guard(threadsLock);
    // The top half of the slots belongs to host threads attached by Runtime::threadCpu.
    for (uint32_t i = 1; i < layout::kMaxThreads / 2; i++)
        if (!slotsUsed[i]) {
            slotsUsed[i] = true;
            return i;
        }
    fatal("more than %u guest threads", layout::kMaxThreads - 1);
}

// A guest mutex as old iOS mutexes behaved: any thread may unlock it (some
// engines hand a locked mutex from one thread to another), and only
// recursive ones may be relocked by their owner.
class GuestMutex {
public:
    explicit GuestMutex(bool recursive) : recursive_(recursive) {}

    void lock() {
        std::unique_lock guard(m_);
        auto me = std::this_thread::get_id();
        if (recursive_ && count_ && owner_ == me) {
            count_++;
            return;
        }
        released_.wait(guard, [&] { return count_ == 0; });
        owner_ = me;
        count_ = 1;
    }

    bool try_lock() {
        std::lock_guard guard(m_);
        auto me = std::this_thread::get_id();
        if (recursive_ && count_ && owner_ == me) {
            count_++;
            return true;
        }
        if (count_) return false;
        owner_ = me;
        count_ = 1;
        return true;
    }

    void unlock() {
        std::lock_guard guard(m_);
        if (count_ == 0) return;
        if (--count_ == 0) {
            owner_ = {};
            released_.notify_one();
        }
    }

private:
    std::mutex m_;
    std::condition_variable released_;
    std::thread::id owner_;
    uint32_t count_ = 0;
    bool recursive_;
};

constexpr uint32_t kRecursiveMutexSignature = 0x32AAABA2;  // PTHREAD_RECURSIVE_MUTEX_INITIALIZER
constexpr uint32_t kRecursiveMutexType = 2;  // PTHREAD_MUTEX_RECURSIVE

std::mutex objectsLock;
std::unordered_map<GuestAddr, GuestMutex *> mutexes;
std::unordered_map<GuestAddr, std::condition_variable_any *> conds;
std::unordered_map<GuestAddr, uint32_t> mutexAttrTypes;  // pthread_mutexattr_t -> type

GuestMutex &mutexAt(Call &c, GuestAddr m, bool recursive = false) {
    std::lock_guard guard(objectsLock);
    auto &slot = mutexes[m];
    // Mutexes set up by a static initializer first appear here.
    if (!slot) slot = new GuestMutex(recursive || c.mem.read<uint32_t>(m) == kRecursiveMutexSignature);
    return *slot;
}

std::condition_variable_any &condAt(GuestAddr cv) {
    std::lock_guard guard(objectsLock);
    auto &slot = conds[cv];
    if (!slot) slot = new std::condition_variable_any;
    return *slot;
}

}  // namespace

// int pthread_create(pthread_t *thread, const pthread_attr_t *attr, void *(*start)(void *), void *arg)
B32_THUNK(_pthread_create) {
    GuestAddr out = c.args.ptr();
    c.args.ptr();  // attributes: stack size and detach state are ignored
    GuestAddr start = c.args.ptr();
    GuestAddr arg = c.args.ptr();

    // The guest's pthread_t is an opaque pointer; give it a small block.
    GuestAddr handle = c.heap.calloc(1, 16);
    auto *thread = new Thread{takeSlot(), {}, 0, false};
    {
        std::lock_guard guard(threadsLock);
        threads[handle] = thread;
    }
    Runtime &rt = c.rt;
    thread->host = std::thread([&rt, thread, handle, start, arg] {
        selfHandle = handle;
        thread->result = rt.runThread(thread->slot, start, arg);
        std::lock_guard guard(threadsLock);
        slotsUsed[thread->slot] = false;
    });
    c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}

// int pthread_join(pthread_t thread, void **value)
B32_THUNK(_pthread_join) {
    GuestAddr handle = c.args.ptr();
    GuestAddr value = c.args.ptr();
    Thread *thread;
    {
        std::lock_guard guard(threadsLock);
        auto it = threads.find(handle);
        if (it == threads.end()) {
            c.ret(ESRCH);
            return;
        }
        thread = it->second;
        threads.erase(it);
    }
    thread->host.join();
    if (value) c.mem.write<uint32_t>(value, thread->result);
    delete thread;
    c.ret(0);
}

B32_THUNK(_pthread_detach) {
    GuestAddr handle = c.args.ptr();
    std::lock_guard guard(threadsLock);
    if (auto it = threads.find(handle); it != threads.end()) {
        it->second->host.detach();
        threads.erase(it);
    }
    c.ret(0);
}

// Cancellation would need cancellation points in every blocking thunk; the
// request is logged and the thread keeps running.
B32_THUNK(_pthread_cancel) {
    log("pthread_cancel(0x%08x) ignored", c.args.ptr());
    c.ret(0);
}

B32_THUNK(_pthread_self) {
    if (!selfHandle) {
        if (!mainHandle) mainHandle = c.heap.calloc(1, 16);
        selfHandle = mainHandle;
    }
    c.ret(selfHandle);
}

B32_THUNK(_pthread_equal) {
    GuestAddr a = c.args.ptr();
    c.ret(a == c.args.ptr());
}

// --- mutexes ---------------------------------------------------------------------

// int pthread_mutex_init(pthread_mutex_t *, const pthread_mutexattr_t *)
B32_THUNK(_pthread_mutex_init) {
    GuestAddr m = c.args.ptr();
    GuestAddr attr = c.args.ptr();
    bool recursive;
    {
        std::lock_guard guard(objectsLock);
        recursive = attr && mutexAttrTypes[attr] == kRecursiveMutexType;
        if (auto it = mutexes.find(m); it != mutexes.end()) {
            delete it->second;
            mutexes.erase(it);
        }
    }
    mutexAt(c, m, recursive);
    c.ret(0);
}
B32_THUNK(_pthread_mutex_destroy) {
    GuestAddr m = c.args.ptr();
    std::lock_guard guard(objectsLock);
    if (auto it = mutexes.find(m); it != mutexes.end()) {
        delete it->second;
        mutexes.erase(it);
    }
    c.ret(0);
}
// B32_TRACE_LOCKS=1 logs guest mutex traffic with the calling guest code.
const bool traceLocks = getenv("B32_TRACE_LOCKS") != nullptr;

B32_THUNK(_pthread_mutex_lock) {
    GuestAddr m = c.args.ptr();
    if (traceLocks) log("lock 0x%08x from 0x%08x (thread %p)", m, c.cpu.reg(Cpu::LR), (void *)pthread_self());
    mutexAt(c, m).lock();
    if (traceLocks) log("locked 0x%08x (thread %p)", m, (void *)pthread_self());
    c.ret(0);
}
B32_THUNK(_pthread_mutex_trylock) { c.ret(mutexAt(c, c.args.ptr()).try_lock() ? 0 : EBUSY); }
B32_THUNK(_pthread_mutex_unlock) {
    GuestAddr m = c.args.ptr();
    if (traceLocks) log("unlock 0x%08x from 0x%08x (thread %p)", m, c.cpu.reg(Cpu::LR), (void *)pthread_self());
    mutexAt(c, m).unlock();
    c.ret(0);
}

B32_THUNK(_pthread_mutexattr_init) {
    GuestAddr attr = c.args.ptr();
    std::lock_guard guard(objectsLock);
    mutexAttrTypes[attr] = 0;
    c.ret(0);
}
B32_THUNK(_pthread_mutexattr_settype) {
    GuestAddr attr = c.args.ptr();
    uint32_t type = c.args.u32();
    std::lock_guard guard(objectsLock);
    mutexAttrTypes[attr] = type;
    c.ret(0);
}
B32_THUNK(_pthread_mutexattr_destroy) { c.ret(0); }

// --- condition variables -------------------------------------------------------------

B32_THUNK(_pthread_cond_init) {
    condAt(c.args.ptr());
    c.ret(0);
}
B32_THUNK(_pthread_cond_destroy) { c.ret(0); }
B32_THUNK(_pthread_cond_signal) {
    condAt(c.args.ptr()).notify_one();
    c.ret(0);
}
B32_THUNK(_pthread_cond_broadcast) {
    condAt(c.args.ptr()).notify_all();
    c.ret(0);
}
B32_THUNK(_pthread_cond_wait) {
    GuestAddr cv = c.args.ptr();
    GuestMutex &m = mutexAt(c, c.args.ptr());
    condAt(cv).wait(m);
    c.ret(0);
}

// int pthread_cond_timedwait(pthread_cond_t *, pthread_mutex_t *, const struct timespec *abstime)
// with a 32-bit timespec { time_t tv_sec; long tv_nsec }.
B32_THUNK(_pthread_cond_timedwait) {
    GuestAddr cv = c.args.ptr();
    GuestMutex &m = mutexAt(c, c.args.ptr());
    GuestAddr ts = c.args.ptr();
    auto since = std::chrono::seconds(c.mem.read<int32_t>(ts)) + std::chrono::nanoseconds(c.mem.read<int32_t>(ts + 4));
    auto deadline = std::chrono::system_clock::time_point(
        std::chrono::duration_cast<std::chrono::system_clock::duration>(since));
    c.ret(condAt(cv).wait_until(m, deadline) == std::cv_status::timeout ? ETIMEDOUT : 0);
}

// --- thread-specific data ------------------------------------------------------------------

namespace {
std::mutex keysLock;
uint32_t nextKey = 1;
thread_local std::unordered_map<uint32_t, GuestAddr> specific;
}  // namespace

// Destructors aren't run; guest threads rarely depend on them.
B32_THUNK(_pthread_key_create) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(keysLock);
    c.mem.write<uint32_t>(out, nextKey++);
    c.ret(0);
}
B32_THUNK(_pthread_key_delete) { c.ret(0); }
B32_THUNK(_pthread_getspecific) { c.ret(specific[c.args.u32()]); }
B32_THUNK(_pthread_setspecific) {
    uint32_t key = c.args.u32();
    specific[key] = c.args.ptr();
    c.ret(0);
}

// --- sleeping ------------------------------------------------------------------------------

B32_THUNK(_usleep) {
    std::this_thread::sleep_for(std::chrono::microseconds(c.args.u32()));
    c.ret(0);
}
B32_THUNK(_sleep) {
    std::this_thread::sleep_for(std::chrono::seconds(c.args.u32()));
    c.ret(0);
}
// struct timespec in the guest: two 32-bit words.
B32_THUNK(_nanosleep) {
    GuestAddr req = c.args.ptr(), rem = c.args.ptr();
    auto duration = std::chrono::seconds(c.mem.read<int32_t>(req)) + std::chrono::nanoseconds(c.mem.read<int32_t>(req + 4));
    std::this_thread::sleep_for(duration);
    if (rem) {
        c.mem.write<uint32_t>(rem, 0);
        c.mem.write<uint32_t>(rem + 4, 0);
    }
    c.ret(0);
}

// Guest threads are never cancelled.
B32_THUNK(_pthread_testcancel) {}
B32_THUNK(_pthread_setcanceltype) {
    c.args.i32();
    if (GuestAddr old = c.args.ptr()) c.mem.write<uint32_t>(old, PTHREAD_CANCEL_DEFERRED);
    c.ret(0);
}
B32_THUNK(_sched_get_priority_max) { c.ret(uint32_t(::sched_get_priority_max(c.args.i32()))); }
B32_THUNK(_sched_get_priority_min) { c.ret(uint32_t(::sched_get_priority_min(c.args.i32()))); }
// Guest signal handlers aren't installed, so there's nothing to mask.
B32_THUNK(_sigprocmask) {
    c.args.i32();
    c.args.ptr();
    if (GuestAddr old = c.args.ptr()) c.mem.write<uint32_t>(old, 0);
    c.ret(0);
}

B32_THUNK(_sched_yield) {
    std::this_thread::yield();
    c.ret(0);
}

// --- the rest of the API apps touch ---------------------------------------------------------

// void pthread_exit(void *value): unwinds to Runtime::runThread.
B32_THUNK(_pthread_exit) { throw Runtime::ThreadExit{c.args.ptr()}; }

namespace {
std::mutex onceLock;
std::unordered_map<GuestAddr, std::once_flag *> onces;
}  // namespace

// int pthread_once(pthread_once_t *, void (*init)(void))
B32_THUNK(_pthread_once) {
    GuestAddr control = c.args.ptr();
    GuestAddr init = c.args.ptr();
    std::once_flag *flag;
    {
        std::lock_guard guard(onceLock);
        auto &slot = onces[control];
        if (!slot) slot = new std::once_flag;
        flag = slot;
    }
    Cpu &cpu = c.cpu;
    std::call_once(*flag, [&] { cpu.call(init, {}); });
    c.ret(0);
}

// Attributes: threads get default stacks and are always joinable.
B32_THUNK(_pthread_attr_init) { c.ret(0); }
B32_THUNK(_pthread_attr_destroy) { c.ret(0); }
B32_THUNK(_pthread_attr_setstacksize) { c.ret(0); }
B32_THUNK(_pthread_attr_setdetachstate) { c.ret(0); }
B32_THUNK(_pthread_attr_setscope) { c.ret(0); }
B32_THUNK(_pthread_attr_setschedparam) { c.ret(0); }
B32_THUNK(_pthread_attr_getdetachstate) {
    c.args.ptr();
    c.mem.write<int32_t>(c.args.ptr(), 1);  // PTHREAD_CREATE_JOINABLE
    c.ret(0);
}
// int pthread_getschedparam(pthread_t, int *policy, struct sched_param *)
B32_THUNK(_pthread_getschedparam) {
    c.args.ptr();
    GuestAddr policy = c.args.ptr();
    GuestAddr param = c.args.ptr();
    if (policy) c.mem.write<int32_t>(policy, 1);  // SCHED_OTHER
    if (param) c.mem.write<int32_t>(param, 31);
    c.ret(0);
}
B32_THUNK(_pthread_setschedparam) { c.ret(0); }
B32_THUNK(_pthread_mutexattr_gettype) {
    GuestAddr attr = c.args.ptr();
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(objectsLock);
    c.mem.write<int32_t>(out, int32_t(mutexAttrTypes[attr]));
    c.ret(0);
}
B32_THUNK(_pthread_sigmask) { c.ret(0); }
B32_THUNK(_pthread_kill) { c.ret(0); }
