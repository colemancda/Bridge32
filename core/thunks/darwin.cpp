// Darwin below the C library: atomics and spin locks, dyld's image list, and
// the Mach calls that crash reporters and analytics SDKs make at launch.
// Crash reporters (PLCrashReporter and friends) set up exception ports and
// read thread state; those calls fail with KERN_FAILURE, and the reporters
// give up quietly. Guest memory is all in one region, so vm_read_overwrite
// is a copy and vm_protect has nothing to do.

#include "Format.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <mach/clock.h>
#include <mach/mach.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/xattr.h>
#include <unistd.h>

#include <algorithm>
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
#include <vector>

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

// void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t offset)
// Guest memory is one fixed region, so mappings come from the guest heap:
// anonymous ones zeroed, file ones as a private copy of the file's bytes.
// Shared file mappings aren't written back.
namespace {
struct Mapping {
    GuestAddr raw;  // the heap allocation behind it
    uint32_t size;
};
std::unordered_map<GuestAddr, Mapping> mappings;  // under vmLock
}  // namespace
namespace {
// The mapping that holds [addr, addr + length), or none. Under vmLock.
const Mapping *mappingHolding(GuestAddr addr, uint32_t length) {
    for (const auto &[start, m] : mappings)
        if (addr >= start && uint64_t(addr) + length <= uint64_t(start) + m.size) return &m;
    return nullptr;
}
}  // namespace
B32_THUNK(_mmap) {
    GuestAddr addr = c.args.ptr();  // a hint, unless MAP_FIXED
    uint32_t length = c.args.u32();
    c.args.i32();  // protection: guest memory is always read/write/execute
    int flags = c.args.i32();
    int fd = c.args.i32();
    off_t offset = off_t(c.args.u64());
    if (flags & MAP_FIXED) {
        // Garbage collectors reserve a region with one mmap and commit pages
        // in it with MAP_FIXED. The region is already real guest memory, so
        // committing gives fresh pages at the same address.
        std::lock_guard guard(vmLock);
        if (!mappingHolding(addr, length)) {
            setGuestErrno(c, ENOMEM);
            c.ret(uint32_t(-1));  // MAP_FAILED
            return;
        }
        if ((flags & MAP_ANON) || fd < 0) std::memset(c.mem.ptr<void>(addr), 0, length);
        else if (::pread(fd, c.mem.ptr<void>(addr), length, offset) < 0) {
            setGuestErrno(c, errno);
            c.ret(uint32_t(-1));
            return;
        }
        c.ret(addr);
        return;
    }
    GuestAddr raw = c.heap.calloc(1, length + 4096);
    if (!raw) {
        setGuestErrno(c, ENOMEM);
        c.ret(uint32_t(-1));
        return;
    }
    GuestAddr aligned = (raw + 4095) & ~4095u;
    if (!(flags & MAP_ANON) && fd >= 0) {
        ssize_t read = ::pread(fd, c.mem.ptr<void>(aligned), length, offset);
        if (read < 0) {
            setGuestErrno(c, errno);
            c.heap.free(raw);
            c.ret(uint32_t(-1));
            return;
        }
    }
    std::lock_guard guard(vmLock);
    mappings[aligned] = {raw, length};
    c.ret(aligned);
}
// int munmap(void *addr, size_t len): whole mappings are freed; trimming or
// decommitting part of one leaves the memory in place.
B32_THUNK(_munmap) {
    GuestAddr addr = c.args.ptr();
    uint32_t length = c.args.u32();
    std::lock_guard guard(vmLock);
    if (auto it = mappings.find(addr); it != mappings.end() && length >= it->second.size) {
        c.heap.free(it->second.raw);
        mappings.erase(it);
    }
    c.ret(0);
}
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
// int __divmodsi4(int a, int b, int *remainder)
B32_THUNK(___divmodsi4) {
    int32_t a = c.args.i32(), b = c.args.i32();
    GuestAddr remainder = c.args.ptr();
    // Division by zero is undefined; INT_MIN / -1 wraps, as the ARM helpers do.
    int32_t q = b == 0 ? 0 : (b == -1 ? int32_t(0u - uint32_t(a)) : a / b);
    if (remainder) c.mem.write<int32_t>(remainder, b == 0 ? a : (b == -1 ? 0 : a % b));
    c.ret(uint32_t(q));
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

// --- the rest of the _FORTIFY_SOURCE family -------------------------------------------------------
// The extra size argument is the destination's, which the host needn't check again.

namespace {
char *hostChars(Call &c, GuestAddr p) { return p ? c.mem.ptr<char>(p) : nullptr; }

void writeFormatted(Call &c, GuestAddr buffer, uint32_t size, const std::string &s) {
    if (!size) return;
    size_t n = std::min<size_t>(s.size(), size - 1);
    c.mem.copyIn(buffer, s.data(), n);
    c.mem.write<char>(buffer + uint32_t(n), '\0');
}
}  // namespace

B32_THUNK(___strcpy_chk) {
    GuestAddr dst = c.args.ptr();
    std::strcpy(hostChars(c, dst), c.mem.cstr(c.args.ptr()));
    c.ret(dst);
}
B32_THUNK(___strncpy_chk) {
    GuestAddr dst = c.args.ptr();
    const char *src = c.mem.cstr(c.args.ptr());
    std::strncpy(hostChars(c, dst), src, c.args.u32());
    c.ret(dst);
}
B32_THUNK(___strncat_chk) {
    GuestAddr dst = c.args.ptr();
    const char *src = c.mem.cstr(c.args.ptr());
    std::strncat(hostChars(c, dst), src, c.args.u32());
    c.ret(dst);
}
B32_THUNK(___memmove_chk) {
    GuestAddr dst = c.args.ptr(), src = c.args.ptr();
    std::memmove(hostChars(c, dst), hostChars(c, src), c.args.u32());
    c.ret(dst);
}
// int __snprintf_chk(char *s, size_t maxlen, int flag, size_t slen, const char *format, ...)
B32_THUNK(___snprintf_chk) {
    GuestAddr buffer = c.args.ptr();
    uint32_t size = c.args.u32();
    c.args.i32();
    c.args.u32();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    writeFormatted(c, buffer, size, s);
    c.ret(uint32_t(s.size()));
}
// int __vsnprintf_chk(char *s, size_t maxlen, int flag, size_t slen, const char *format, va_list)
B32_THUNK(___vsnprintf_chk) {
    GuestAddr buffer = c.args.ptr();
    uint32_t size = c.args.u32();
    c.args.i32();
    c.args.u32();
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    writeFormatted(c, buffer, size, s);
    c.ret(uint32_t(s.size()));
}
// int __vsprintf_chk(char *s, int flag, size_t slen, const char *format, va_list)
B32_THUNK(___vsprintf_chk) {
    GuestAddr buffer = c.args.ptr();
    c.args.i32();
    c.args.u32();
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    c.mem.copyIn(buffer, s.c_str(), s.size() + 1);
    c.ret(uint32_t(s.size()));
}

// --- system logging, notifications and extended attributes ------------------------------------

// Apple System Log: messages go to the log; there's nothing to search.
B32_THUNK(_asl_open) { c.ret(1); }
B32_THUNK(_asl_new) { c.ret(1); }
B32_THUNK(_asl_free) {}
B32_THUNK(_asl_set_filter) { c.ret(0); }
B32_THUNK(_asl_add_output_file) { c.ret(0); }
B32_THUNK(_asl_set) { c.ret(0); }
B32_THUNK(_asl_set_query) { c.ret(0); }
B32_THUNK(_asl_get) { c.ret(0); }
B32_THUNK(_asl_search) { c.ret(0); }
B32_THUNK(_aslresponse_next) { c.ret(0); }
B32_THUNK(_aslresponse_free) {}
// int asl_log(aslclient, aslmsg, int level, const char *format, ...)
B32_THUNK(_asl_log) {
    c.args.u32();
    c.args.u32();
    c.args.i32();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    log("asl: %s", s.c_str());
    c.ret(0);
}

// Darwin notifications aren't delivered to the guest; registering succeeds.
// uint32_t notify_register_dispatch(const char *name, int *token, dispatch_queue_t, notify_handler_t)
B32_THUNK(_notify_register_dispatch) {
    static std::atomic<int32_t> nextToken{1};
    c.args.ptr();
    if (GuestAddr token = c.args.ptr()) c.mem.write<int32_t>(token, nextToken++);
    c.ret(0);
}
B32_THUNK(_notify_cancel) { c.ret(0); }

// No extended attributes on the guest's files.
B32_THUNK(_getxattr) {
    setGuestErrno(c, ENOATTR);
    c.ret(uint32_t(-1));
}
B32_THUNK(_removexattr) { c.ret(0); }

B32_THUNK(_host_info) { c.ret(KERN_FAILURE); }
B32_THUNK(_atoll) { c.ret64(uint64_t(std::atoll(c.mem.cstr(c.args.ptr())))); }

// Unsigned 64-bit integers to floating point.
B32_THUNK(___floatundidf) { c.retF64(double(c.args.u64())); }
B32_THUNK(___floatundisf) { c.retF32(float(c.args.u64())); }

// --- more of the C library ---------------------------------------------------------------------

// void *reallocf(void *, size_t): realloc that frees the block when it fails.
B32_THUNK(_reallocf) {
    GuestAddr p = c.args.ptr();
    uint32_t size = c.args.u32();
    GuestAddr q = c.heap.realloc(p, size);
    if (!q && p && size) c.heap.free(p);
    c.ret(q);
}
B32_THUNK(_isatty) { c.ret(uint32_t(::isatty(c.args.i32()))); }
B32_THUNK(_isxdigit) { c.ret(uint32_t(std::isxdigit(c.args.i32()))); }
B32_THUNK(_digittoint) {
    int ch = c.args.i32();
    c.ret(uint32_t(std::isdigit(ch) ? ch - '0' : std::isxdigit(ch) ? (std::tolower(ch) - 'a' + 10) : 0));
}

// int pthread_attr_getstacksize(const pthread_attr_t *, size_t *): guest threads get 1 MB.
B32_THUNK(_pthread_attr_getstacksize) {
    c.args.ptr();
    if (GuestAddr out = c.args.ptr()) c.mem.write<uint32_t>(out, 1 << 20);
    c.ret(0);
}

// void qsort_b(void *base, size_t n, size_t size, int (^compare)(const void *, const void *))
B32_THUNK(_qsort_b) {
    GuestAddr base = c.args.ptr();
    uint32_t n = c.args.u32(), size = c.args.u32();
    GuestAddr block = c.args.ptr();
    GuestAddr invoke = c.mem.read<uint32_t>(block + 12);
    // Insertion into a sorted copy keeps the comparisons in guest memory; n is small in practice.
    std::vector<uint8_t> tmp(size);
    for (uint32_t i = 1; i < n; i++) {
        std::memcpy(tmp.data(), c.mem.ptr<void>(base + i * size), size);
        GuestAddr key = c.heap.alloc(size);
        c.mem.copyIn(key, tmp.data(), size);
        uint32_t j = i;
        while (j > 0 && int32_t(c.cpu.call(invoke, {block, base + (j - 1) * size, key})) > 0) {
            std::memmove(c.mem.ptr<void>(base + j * size), c.mem.ptr<void>(base + (j - 1) * size), size);
            j--;
        }
        c.mem.copyIn(base + j * size, tmp.data(), size);
        c.heap.free(key);
    }
}

B32_THUNK(_OSAtomicOr32Orig) {
    int32_t mask = c.args.i32();
    c.ret(uint32_t(atomicAt(c, c.args.ptr()).fetch_or(mask)));
}

// The clock service: mach_timespec_t { unsigned tv_sec; int tv_nsec } is the same in both.
B32_THUNK(_host_get_clock_service) {
    c.args.u32();
    int id = c.args.i32();
    clock_serv_t clock = 0;
    kern_return_t kr = host_get_clock_service(mach_host_self(), id, &clock);
    if (GuestAddr out = c.args.ptr()) c.mem.write<uint32_t>(out, clock);
    c.ret(uint32_t(kr));
}
B32_THUNK(_clock_get_time) {
    clock_serv_t clock = c.args.u32();
    c.ret(uint32_t(clock_get_time(clock, c.mem.ptr<mach_timespec_t>(c.args.ptr()))));
}

B32_DATA(_in6addr_any, 16) {}
B32_DATA(_in6addr_loopback, 16) { rt.mem().write<uint8_t>(addr + 15, 1); }
