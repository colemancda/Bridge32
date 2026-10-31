// Darwin below the C library: atomics and spin locks, dyld's image list, and
// the Mach calls that crash reporters and analytics SDKs make at launch.
// Crash reporters (PLCrashReporter and friends) set up exception ports and
// read thread state; those calls fail with KERN_FAILURE, and the reporters
// give up quietly. Guest memory is all in one region, so vm_read_overwrite
// is a copy and vm_protect has nothing to do.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <mach/mach.h>
#include <pthread.h>
#include <unistd.h>

#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cwctype>
#include <mutex>
#include <thread>
#include <unordered_map>

using namespace b32;

namespace {
std::atomic<int32_t> &atomicAt(Call &c, GuestAddr p) { return *reinterpret_cast<std::atomic<int32_t> *>(c.mem.ptr<int32_t>(p)); }
}  // namespace

// --- OSAtomic and OSSpinLock --------------------------------------------------------------------

// int32_t OSAtomicAdd32(int32_t amount, volatile int32_t *value): returns the new value.
B32_THUNK(_OSAtomicAdd32) {
    int32_t amount = c.args.i32();
    c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_add(amount) + amount));
}
B32_THUNK(_OSAtomicAdd32Barrier) {
    int32_t amount = c.args.i32();
    c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_add(amount) + amount));
}
B32_THUNK(_OSAtomicIncrement32Barrier) { c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_add(1) + 1)); }
B32_THUNK(_OSAtomicDecrement32Barrier) { c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_sub(1) - 1)); }
B32_THUNK(_OSAtomicIncrement32) { c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_add(1) + 1)); }
B32_THUNK(_OSAtomicDecrement32) { c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_sub(1) - 1)); }
B32_THUNK(_OSAtomicAnd32Barrier) {
    int32_t mask = c.args.i32();
    c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_and(mask) & mask));
}
B32_THUNK(_OSAtomicOr32Barrier) {
    int32_t mask = c.args.i32();
    c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_or(mask) | mask));
}

// bool OSAtomicCompareAndSwap32(int32_t old, int32_t new, volatile int32_t *value),
// and the pointer, int and long flavors, which are all 32-bit in the guest.
#define B32_ATOMIC_CAS(symbol)                                          \
    B32_THUNK(symbol) {                                                 \
        int32_t expected = c.args.i32(), desired = c.args.i32();        \
        c.ret(atomicAt(c, c.args.ptr()).compare_exchange_strong(expected, desired) ? 1 : 0); \
    }
B32_ATOMIC_CAS(_OSAtomicCompareAndSwap32)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwap32Barrier)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwapPtr)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwapPtrBarrier)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwapInt)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwapIntBarrier)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwapLong)
B32_ATOMIC_CAS(_OSAtomicCompareAndSwapLongBarrier)

B32_THUNK(_OSMemoryBarrier) { std::atomic_thread_fence(std::memory_order_seq_cst); }

// OSSpinLock is an int32_t: 0 unlocked.
B32_THUNK(_OSSpinLockLock) {
    auto &lock = atomicAt(c, c.args.ptr());
    for (int32_t expected = 0; !lock.compare_exchange_weak(expected, 1); expected = 0) std::this_thread::yield();
}
B32_THUNK(_OSSpinLockTry) {
    int32_t expected = 0;
    c.ret(atomicAt(c, c.args.ptr()).compare_exchange_strong(expected, 1) ? 1 : 0);
}
B32_THUNK(_OSSpinLockUnlock) { atomicAt(c, c.args.ptr()).store(0); }

// --- dyld's image list: just the app ---------------------------------------------------------------

B32_THUNK(__dyld_image_count) { c.ret(1); }
B32_THUNK(__dyld_get_image_header) { c.ret(c.args.u32() == 0 ? c.rt.image().base : 0); }
B32_THUNK(__dyld_get_image_name) { c.ret(c.args.u32() == 0 ? c.rt.internString(c.rt.image().path) : 0); }
B32_THUNK(__dyld_get_image_vmaddr_slide) { c.ret(0); }
// void _dyld_register_func_for_add_image(void (*)(const struct mach_header *, intptr_t slide)):
// called right away for the images already loaded.
B32_THUNK(__dyld_register_func_for_add_image) { c.cpu.call(c.args.ptr(), {c.rt.image().base, 0}); }
B32_THUNK(__dyld_register_func_for_remove_image) {}
B32_THUNK(_getsectdatafromheader_64) { c.ret(0); }  // the guest has no 64-bit images

// int _NSGetExecutablePath(char *buf, uint32_t *bufsize)
B32_THUNK(__NSGetExecutablePath) {
    GuestAddr buf = c.args.ptr(), size = c.args.ptr();
    const std::string &path = c.rt.image().path;
    if (c.mem.read<uint32_t>(size) < path.size() + 1) {
        c.mem.write<uint32_t>(size, uint32_t(path.size() + 1));
        c.ret(uint32_t(-1));
        return;
    }
    c.mem.copyIn(buf, path.c_str(), path.size() + 1);
    c.ret(0);
}

B32_THUNK(_getprogname) {
    const std::string &path = c.rt.image().path;
    c.ret(c.rt.internString(path.substr(path.rfind('/') + 1)));
}

// --- Mach ----------------------------------------------------------------------------------------

#define B32_MACH_FAILS(symbol) \
    B32_THUNK(symbol) { c.ret(KERN_FAILURE); }
B32_MACH_FAILS(_task_swap_exception_ports)
B32_MACH_FAILS(_task_get_exception_ports)
B32_MACH_FAILS(_task_set_exception_ports)
B32_MACH_FAILS(_thread_swap_exception_ports)
B32_MACH_FAILS(_thread_get_exception_ports)
B32_MACH_FAILS(_thread_set_exception_ports)
B32_MACH_FAILS(_mach_port_allocate)
B32_MACH_FAILS(_mach_port_insert_right)
B32_MACH_FAILS(_mach_port_mod_refs)
B32_MACH_FAILS(_mach_port_move_member)
B32_MACH_FAILS(_mach_port_request_notification)
B32_MACH_FAILS(_mach_msg)
B32_MACH_FAILS(_exception_raise)
B32_MACH_FAILS(_exception_raise_state)
B32_MACH_FAILS(_exception_raise_state_identity)
B32_MACH_FAILS(_thread_get_state)
B32_MACH_FAILS(_thread_suspend)
B32_MACH_FAILS(_thread_resume)
B32_MACH_FAILS(_thread_info)
B32_MACH_FAILS(_task_threads)
B32_MACH_FAILS(_task_info)
B32_MACH_FAILS(_host_statistics)
B32_MACH_FAILS(_mach_make_memory_entry_64)
B32_MACH_FAILS(_vm_map)
B32_THUNK(_mach_port_deallocate) { c.ret(KERN_SUCCESS); }
B32_THUNK(_mach_thread_self) { c.ret(mach_thread_self()); }
B32_THUNK(_mach_host_self) { c.ret(mach_host_self()); }
B32_THUNK(_pthread_mach_thread_np) { c.ret(mach_thread_self()); }

B32_DATA(_vm_page_size, 4) { rt.mem().write<uint32_t>(addr, 4096); }
B32_DATA(_vm_page_mask, 4) { rt.mem().write<uint32_t>(addr, 4095); }
B32_DATA(_NDR_record, 8) {}

// kern_return_t host_page_size(host_t, vm_size_t *)
B32_THUNK(_host_page_size) {
    c.args.u32();
    c.mem.write<uint32_t>(c.args.ptr(), 4096);
    c.ret(KERN_SUCCESS);
}

// kern_return_t vm_allocate(vm_map_t, vm_address_t *address, vm_size_t size, int flags):
// page-aligned guest heap memory.
namespace {
std::mutex vmLock;
std::unordered_map<GuestAddr, GuestAddr> vmBlocks;  // aligned address -> heap allocation
}  // namespace
B32_THUNK(_vm_allocate) {
    c.args.u32();
    GuestAddr out = c.args.ptr();
    uint32_t size = c.args.u32();
    GuestAddr raw = c.heap.calloc(1, size + 4096);
    GuestAddr aligned = (raw + 4095) & ~4095u;
    {
        std::lock_guard guard(vmLock);
        vmBlocks[aligned] = raw;
    }
    c.mem.write<uint32_t>(out, aligned);
    c.ret(KERN_SUCCESS);
}
B32_THUNK(_vm_deallocate) {
    c.args.u32();
    GuestAddr addr = c.args.ptr();
    std::lock_guard guard(vmLock);
    if (auto it = vmBlocks.find(addr); it != vmBlocks.end()) {
        c.heap.free(it->second);
        vmBlocks.erase(it);
    }
    c.ret(KERN_SUCCESS);
}
B32_THUNK(_vm_protect) { c.ret(KERN_SUCCESS); }
// kern_return_t vm_read_overwrite(vm_map_t, vm_address_t address, vm_size_t size,
//                                 vm_address_t data, vm_size_t *outsize)
B32_THUNK(_vm_read_overwrite) {
    c.args.u32();
    GuestAddr from = c.args.ptr();
    uint32_t size = c.args.u32();
    GuestAddr to = c.args.ptr(), outSize = c.args.ptr();
    if (!c.mem.isMapped(from) || !c.mem.isMapped(from + size - 1)) {
        c.ret(KERN_INVALID_ADDRESS);
        return;
    }
    std::memmove(c.mem.ptr<void>(to), c.mem.ptr<void>(from), size);
    if (outSize) c.mem.write<uint32_t>(outSize, size);
    c.ret(KERN_SUCCESS);
}

// --- processes and threads -----------------------------------------------------------------------

B32_THUNK(_fork) {
    setGuestErrno(c, ENOSYS);
    c.ret(uint32_t(-1));
}
B32_THUNK(_getloadavg) { c.ret(uint32_t(-1)); }
B32_THUNK(_backtrace) { c.ret(0); }
B32_THUNK(_sigaltstack) { c.ret(0); }
B32_THUNK(_pthread_setname_np) { c.ret(uint32_t(pthread_setname_np(c.mem.cstr(c.args.ptr())))); }

// --- odds and ends of the C library --------------------------------------------------------------

B32_THUNK(_srandom) { srandom(c.args.u32()); }
B32_THUNK(_random) { c.ret(uint32_t(random())); }
B32_THUNK(_arc4random_buf) {
    GuestAddr buf = c.args.ptr();
    arc4random_buf(c.mem.ptr<void>(buf), c.args.u32());
}
B32_THUNK(_isdigit) { c.ret(uint32_t(std::isdigit(c.args.i32()))); }
B32_THUNK(_isspace) { c.ret(uint32_t(std::isspace(c.args.i32()))); }
B32_THUNK(_iswspace) { c.ret(uint32_t(std::iswspace(wint_t(c.args.u32())))); }

// char *strnstr(const char *big, const char *little, size_t len)
B32_THUNK(_strnstr) {
    GuestAddr big = c.args.ptr();
    const char *little = c.mem.cstr(c.args.ptr());
    const char *found = strnstr(c.mem.ptr<char>(big), little, c.args.u32());
    c.ret(found ? big + GuestAddr(found - c.mem.ptr<char>(big)) : 0);
}

// void *bsearch(const void *key, const void *base, size_t n, size_t size, int (*compare)(const void *, const void *))
B32_THUNK(_bsearch) {
    GuestAddr key = c.args.ptr(), base = c.args.ptr();
    uint32_t n = c.args.u32(), size = c.args.u32();
    GuestAddr compare = c.args.ptr();
    uint32_t lo = 0, hi = n;
    while (lo < hi) {
        uint32_t mid = lo + (hi - lo) / 2;
        GuestAddr element = base + mid * size;
        auto order = int32_t(c.cpu.call(compare, {key, element}));
        if (order == 0) {
            c.ret(element);
            return;
        }
        if (order < 0) hi = mid;
        else lo = mid + 1;
    }
    c.ret(0);
}

// int mkstemp(char *template): fills in the template in place.
B32_THUNK(_mkstemp) { c.ret(uint32_t(mkstemp(c.mem.ptr<char>(c.args.ptr())))); }

// time_t mktime(struct tm *): the guest's tm is nine ints, tm_gmtoff and tm_zone.
B32_THUNK(_mktime) {
    GuestAddr p = c.args.ptr();
    struct tm t{};
    int32_t ints[9];
    std::memcpy(ints, c.mem.ptr<void>(p), sizeof ints);
    t.tm_sec = ints[0], t.tm_min = ints[1], t.tm_hour = ints[2], t.tm_mday = ints[3], t.tm_mon = ints[4];
    t.tm_year = ints[5], t.tm_wday = ints[6], t.tm_yday = ints[7], t.tm_isdst = ints[8];
    time_t result = mktime(&t);
    const int32_t normalized[9] = {t.tm_sec, t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon, t.tm_year, t.tm_wday, t.tm_yday, t.tm_isdst};
    c.mem.copyIn(p, normalized, sizeof normalized);
    c.mem.write<int32_t>(p + 36, int32_t(t.tm_gmtoff));
    c.ret(uint32_t(int32_t(result)));
}

// struct lconv *localeconv(void): the C locale's, built once.
B32_THUNK(_localeconv) {
    static GuestAddr lconv = [&] {
        // Ten char * fields, then fourteen chars (CHAR_MAX: not available).
        GuestAddr l = c.heap.calloc(1, 40 + 16);
        GuestAddr dot = c.rt.internString("."), empty = c.rt.internString("");
        c.mem.write<uint32_t>(l, dot);
        for (uint32_t i = 1; i < 10; i++) c.mem.write<uint32_t>(l + i * 4, empty);
        for (uint32_t i = 0; i < 14; i++) c.mem.write<uint8_t>(l + 40 + i, 127);
        return l;
    }();
    c.ret(lconv);
}

// long long llroundl(long double): long double is double here.
B32_THUNK(_llroundl) { c.ret64(uint64_t(std::llround(c.args.f64()))); }

// --- compiler helpers ----------------------------------------------------------------------------

// unsigned __udivmodsi4(unsigned a, unsigned b, unsigned *remainder)
B32_THUNK(___udivmodsi4) {
    uint32_t a = c.args.u32(), b = c.args.u32();
    GuestAddr remainder = c.args.ptr();
    uint32_t q = b ? a / b : 0;
    if (remainder) c.mem.write<uint32_t>(remainder, b ? a % b : a);
    c.ret(q);
}
B32_THUNK(___exp10) { c.retF64(std::pow(10.0, c.args.f64())); }
B32_THUNK(___exp10f) { c.retF32(std::pow(10.0f, c.args.f32())); }
// struct { float sin, cos; } __sincosf_stret(float): 8 bytes, returned through r0.
B32_THUNK(___sincosf_stret) {
    GuestAddr out = c.args.ptr();
    float x = c.args.f32();
    c.mem.write<float>(out, std::sin(x));
    c.mem.write<float>(out + 4, std::cos(x));
}
B32_THUNK(___sincos_stret) {
    GuestAddr out = c.args.ptr();
    double x = c.args.f64();
    c.mem.write<double>(out, std::sin(x));
    c.mem.write<double>(out + 8, std::cos(x));
}
