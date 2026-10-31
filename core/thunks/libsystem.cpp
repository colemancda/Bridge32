// More of libSystem: system information, ctype, math, sorting, hashing and
// the parts of the BSD socket API apps touch on launch. Networking isn't
// bridged yet: sockets fail cleanly.

#include "Format.h"
#include "Thunks.h"
#include "core/Device.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <CommonCrypto/CommonDigest.h>
#include <runetype.h>
#include <sys/mount.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <ctime>
#include <unistd.h>

#include <unordered_map>
#include <vector>

using namespace b32;

// --- errno: one guest int per host thread ------------------------------------------

namespace {
thread_local GuestAddr errnoSlot = 0;
}  // namespace

B32_THUNK(___error) {
    if (!errnoSlot) errnoSlot = c.heap.calloc(1, 4);
    c.ret(errnoSlot);
}

void b32::setGuestErrno(Call &c, int value) {
    if (!errnoSlot) errnoSlot = c.heap.calloc(1, 4);
    c.mem.write<int32_t>(errnoSlot, value);
}

B32_THUNK(___assert_rtn) {
    const char *function = c.mem.cstr(c.args.ptr());
    const char *file = c.mem.cstr(c.args.ptr());
    int line = c.args.i32();
    GuestAddr expr = c.args.ptr();
    fatal("guest assertion failed: %s, %s:%d: %s", function, file, line, expr ? c.mem.cstr(expr) : "");
}

// --- system information -----------------------------------------------------------------

// struct utsname is five char[256] arrays in both ABIs.
B32_THUNK(_uname) {
    auto *u = c.mem.ptr<struct utsname>(c.args.ptr());
    std::memset(u, 0, sizeof *u);
    std::strcpy(u->sysname, "Darwin");
    std::strcpy(u->nodename, "Bridge32");
    std::strcpy(u->release, "11.0.0");  // the kernel of iOS 5
    std::strcpy(u->version, "Darwin Kernel Version 11.0.0");
    std::strcpy(u->machine, device::current().machine);
    c.ret(0);
}

namespace {
// The device profile's answers, by sysctl name; false when there's none.
bool sysctlAnswer(Call &c, const std::string &name, GuestAddr out, GuestAddr lenp) {
    auto reply = [&](const void *data, uint32_t size) {
        if (lenp) {
            uint32_t room = c.mem.read<uint32_t>(lenp);
            if (out) c.mem.copyIn(out, data, std::min(room, size));
            c.mem.write<uint32_t>(lenp, size);
        }
    };
    if (name == "hw.machine" || name == "hw.model") {
        const char *s = name == "hw.machine" ? device::current().machine : device::current().model;
        reply(s, uint32_t(std::strlen(s) + 1));
    } else if (name == "hw.ncpu" || name == "hw.physicalcpu" || name == "hw.activecpu" || name == "hw.logicalcpu") {
        int32_t n = 2;
        reply(&n, 4);
    } else if (name == "hw.physmem" || name == "hw.usermem") {
        int32_t bytes = 512 << 20;
        reply(&bytes, 4);
    } else if (name == "hw.memsize") {
        int64_t bytes = int64_t(512) << 20;
        reply(&bytes, 8);
    } else if (name == "hw.cputype" || name == "hw.cpusubtype") {
        int32_t value = name == "hw.cputype" ? 12 /* CPU_TYPE_ARM */ : 9 /* CPU_SUBTYPE_ARM_V7 */;
        reply(&value, 4);
    } else if (name == "hw.physicalcpu_max" || name == "hw.logicalcpu_max") {
        int32_t n = 2;
        reply(&n, 4);
    } else if (name == "kern.osversion") {
        const char *build = "10B329";  // iOS 6.1.3
        reply(build, uint32_t(std::strlen(build) + 1));
    } else if (name == "hw.pagesize") {
        int32_t bytes = 4096;
        reply(&bytes, 4);
    } else if (name == "hw.cpufrequency") {
        int32_t hz = 1000000000;
        reply(&hz, 4);
    } else if (name == "kern.boottime") {
        // struct timeval: two 32-bit words in the guest.
        int32_t tv[2] = {int32_t(std::time(nullptr) - 3600), 0};
        reply(tv, 8);
    } else {
        return false;
    }
    return true;
}
}  // namespace

// int sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
B32_THUNK(_sysctlbyname) {
    std::string name = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    GuestAddr lenp = c.args.ptr();
    if (sysctlAnswer(c, name, out, lenp)) {
        c.ret(0);
        return;
    }
    log("sysctlbyname(%s) not supported", name.c_str());
    c.ret(uint32_t(-1));
}

// int sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen)
B32_THUNK(_sysctl) {
    GuestAddr mib = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr out = c.args.ptr(), lenp = c.args.ptr();
    int32_t top = length > 0 ? c.mem.read<int32_t>(mib) : 0, second = length > 1 ? c.mem.read<int32_t>(mib + 4) : 0;
    static const std::unordered_map<int64_t, const char *> names = {
        {int64_t(CTL_HW) << 32 | HW_MACHINE, "hw.machine"}, {int64_t(CTL_HW) << 32 | HW_MODEL, "hw.model"},
        {int64_t(CTL_HW) << 32 | HW_NCPU, "hw.ncpu"}, {int64_t(CTL_HW) << 32 | HW_PHYSMEM, "hw.physmem"},
        {int64_t(CTL_HW) << 32 | HW_USERMEM, "hw.usermem"}, {int64_t(CTL_HW) << 32 | HW_MEMSIZE, "hw.memsize"},
        {int64_t(CTL_HW) << 32 | HW_PAGESIZE, "hw.pagesize"}, {int64_t(CTL_HW) << 32 | HW_CPU_FREQ, "hw.cpufrequency"},
        {int64_t(CTL_KERN) << 32 | KERN_BOOTTIME, "kern.boottime"},
    };
    if (auto it = names.find(int64_t(top) << 32 | uint32_t(second)); it != names.end() && sysctlAnswer(c, it->second, out, lenp)) {
        c.ret(0);
        return;
    }
    if (top == CTL_KERN && second == KERN_PROC) {
        // kinfo_proc, asked for to see whether a debugger is attached: all zeros
        // (not traced) in whatever size the guest's struct is.
        if (out && lenp) std::memset(c.mem.ptr<void>(out), 0, c.mem.read<uint32_t>(lenp));
        c.ret(0);
        return;
    }
    log("sysctl {%d, %d} not supported", top, second);
    setGuestErrno(c, ENOENT);
    c.ret(uint32_t(-1));
}

B32_THUNK(_getgid) { c.ret(getgid()); }
B32_THUNK(_getuid) { c.ret(getuid()); }
B32_THUNK(_getpid) { c.ret(uint32_t(getpid())); }

B32_THUNK(_time) {
    GuestAddr out = c.args.ptr();
    int32_t now = int32_t(std::time(nullptr));
    if (out) c.mem.write<int32_t>(out, now);
    c.ret(uint32_t(now));
}

// The guest's struct statfs (64-bit inode variant) has the host's layout:
// its 8-byte fields happen to sit at 8-byte-aligned offsets.
B32_THUNK(_statfs) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::statfs(path, c.mem.ptr<struct statfs>(c.args.ptr()))));
}

// Used for "don't back up" flags; nothing to back up from here.
B32_THUNK(_setxattr) { c.ret(0); }
B32_THUNK(_sigaction) { c.ret(0); }

// --- file descriptors -----------------------------------------------------------------------

B32_THUNK(_write) {
    int fd = c.args.i32();
    GuestAddr buf = c.args.ptr();
    c.ret(uint32_t(::write(fd, c.mem.ptr<void>(buf), c.args.u32())));
}
B32_THUNK(_read) {
    int fd = c.args.i32();
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    ssize_t n = ::read(fd, c.mem.ptr<void>(buf), size);
    if (getenv("B32_TRACE_FILES")) log("read(%d, %u) = %zd", fd, size, n);
    c.ret(uint32_t(n));
}
B32_THUNK(_close) { c.ret(uint32_t(::close(c.args.i32()))); }

// --- ctype ----------------------------------------------------------------------------------

B32_THUNK(___maskrune) {
    int32_t ch = c.args.i32();
    c.ret(uint32_t(__maskrune(ch, c.args.u32())));
}
B32_THUNK(___tolower) { c.ret(uint32_t(__tolower(c.args.i32()))); }
B32_THUNK(___toupper) { c.ret(uint32_t(__toupper(c.args.i32()))); }

// _RuneLocale for inline ctype macros, which index __runetype directly. Laid
// out for 32 bits: magic[8], encoding[32], two function pointers,
// invalid_rune, then the 256-entry runetype, maplower and mapupper tables.
B32_DATA(__DefaultRuneLocale, 4096) {
    GuestMemory &mem = rt.mem();
    std::memcpy(mem.ptr<char>(addr), _DefaultRuneLocale.__magic, 8);
    std::memcpy(mem.ptr<char>(addr + 8), _DefaultRuneLocale.__encoding, 32);
    mem.write<int32_t>(addr + 48, _DefaultRuneLocale.__invalid_rune);
    for (int i = 0; i < 256; i++) {
        mem.write<uint32_t>(addr + 52 + i * 4, _DefaultRuneLocale.__runetype[i]);
        mem.write<int32_t>(addr + 52 + 1024 + i * 4, _DefaultRuneLocale.__maplower[i]);
        mem.write<int32_t>(addr + 52 + 2048 + i * 4, _DefaultRuneLocale.__mapupper[i]);
    }
}

// --- strings ----------------------------------------------------------------------------------

B32_THUNK(_strcasecmp) {
    const char *a = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::strcasecmp(a, c.mem.cstr(c.args.ptr()))));
}
B32_THUNK(_strncasecmp) {
    const char *a = c.mem.cstr(c.args.ptr());
    const char *b = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::strncasecmp(a, b, c.args.u32())));
}
B32_THUNK(_strcspn) {
    const char *a = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::strcspn(a, c.mem.cstr(c.args.ptr()))));
}
B32_THUNK(_strspn) {
    const char *a = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::strspn(a, c.mem.cstr(c.args.ptr()))));
}
B32_THUNK(_strncat) {
    GuestAddr dst = c.args.ptr();
    const char *src = c.mem.cstr(c.args.ptr());
    std::strncat(c.mem.ptr<char>(dst), src, c.args.u32());
    c.ret(dst);
}
B32_THUNK(_bcopy) {
    GuestAddr src = c.args.ptr();
    GuestAddr dst = c.args.ptr();
    std::memmove(c.mem.ptr<void>(dst), c.mem.ptr<void>(src), c.args.u32());
}
B32_THUNK(_memset_pattern16) {
    GuestAddr dst = c.args.ptr();
    GuestAddr pattern = c.args.ptr();
    memset_pattern16(c.mem.ptr<void>(dst), c.mem.ptr<void>(pattern), c.args.u32());
}
B32_THUNK(_memchr) {
    GuestAddr s = c.args.ptr();
    int ch = c.args.i32();
    auto *found = static_cast<const char *>(std::memchr(c.mem.ptr<void>(s), ch, c.args.u32()));
    c.ret(found ? c.mem.guestAddrOf(found) : 0);
}

// int vfprintf(FILE *, const char *, va_list), etc.: the va_list is a pointer
// to the next stack word.
B32_THUNK(_vsnprintf) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    if (size) {
        size_t n = std::min<size_t>(s.size(), size - 1);
        c.mem.copyIn(buf, s.data(), n);
        c.mem.write<char>(buf + uint32_t(n), '\0');
    }
    c.ret(uint32_t(s.size()));
}
B32_THUNK(_vsprintf) {
    GuestAddr buf = c.args.ptr();
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    c.mem.copyIn(buf, s.c_str(), s.size() + 1);
    c.ret(uint32_t(s.size()));
}
B32_THUNK(_vprintf) {
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    std::fwrite(s.data(), 1, s.size(), stdout);
    c.ret(uint32_t(s.size()));
}

// --- math (single precision in r0, doubles in r0:r1) ----------------------------------------

#define B32_MATHF1(name) \
    B32_THUNK(_##name) { c.retF32(::name(c.args.f32())); }
#define B32_MATHF2(name)               \
    B32_THUNK(_##name) {               \
        float a = c.args.f32();        \
        c.retF32(::name(a, c.args.f32())); \
    }
#define B32_MATH1(name) \
    B32_THUNK(_##name) { c.retF64(::name(c.args.f64())); }
#define B32_MATH2(name)                \
    B32_THUNK(_##name) {               \
        double a = c.args.f64();       \
        c.retF64(::name(a, c.args.f64())); \
    }
B32_MATHF1(acosf) B32_MATHF1(asinf) B32_MATHF1(atanf) B32_MATHF1(tanf) B32_MATHF1(floorf) B32_MATHF1(ceilf)
B32_MATHF1(roundf) B32_MATHF1(log10f) B32_MATHF1(logf) B32_MATHF1(expf) B32_MATHF1(fabsf) B32_MATHF1(truncf)
B32_MATHF2(powf) B32_MATHF2(fmodf) B32_MATHF2(copysignf) B32_MATHF2(fmaxf) B32_MATHF2(fminf)
B32_MATH1(floor) B32_MATH1(ceil) B32_MATH1(round) B32_MATH1(log) B32_MATH1(log10) B32_MATH1(exp) B32_MATH1(fabs)
B32_MATH1(tan) B32_MATH1(atan) B32_MATH1(acos) B32_MATH1(asin)
B32_MATH2(pow) B32_MATH2(fmod) B32_MATH2(atan2)
B32_MATHF1(log2f) B32_MATHF1(exp2f) B32_MATHF1(cbrtf) B32_MATHF1(sinhf) B32_MATHF1(coshf) B32_MATHF1(tanhf)
B32_MATHF1(log1pf) B32_MATHF1(expm1f) B32_MATHF1(rintf) B32_MATHF1(nearbyintf) B32_MATHF1(asinhf) B32_MATHF1(acoshf)
B32_MATHF1(atanhf) B32_MATHF2(hypotf)
B32_MATH1(log2) B32_MATH1(exp2) B32_MATH1(cbrt) B32_MATH1(sinh) B32_MATH1(cosh) B32_MATH1(tanh) B32_MATH1(trunc)
B32_MATH1(log1p) B32_MATH1(expm1) B32_MATH1(rint) B32_MATH1(nearbyint)
B32_MATH2(hypot) B32_MATH2(fmax) B32_MATH2(fmin) B32_MATH2(copysign)

B32_THUNK(_lroundf) { c.ret(uint32_t(int32_t(std::lround(c.args.f32())))); }
B32_THUNK(_lround) { c.ret(uint32_t(int32_t(std::lround(c.args.f64())))); }

// struct tm *localtime_r(const time_t *, struct tm *) and gmtime_r: time_t is
// 32-bit, and the guest's struct tm is nine ints, then long tm_gmtoff and
// char *tm_zone (44 bytes).
namespace {
void timeToGuestTm(Call &c, bool local) {
    time_t t = c.mem.read<int32_t>(c.args.ptr());
    GuestAddr out = c.args.ptr();
    struct tm r;
    if (!(local ? ::localtime_r(&t, &r) : ::gmtime_r(&t, &r))) {
        c.ret(0);
        return;
    }
    const int32_t ints[] = {r.tm_sec, r.tm_min, r.tm_hour, r.tm_mday, r.tm_mon, r.tm_year, r.tm_wday, r.tm_yday, r.tm_isdst};
    c.mem.copyIn(out, ints, sizeof ints);
    c.mem.write<int32_t>(out + 36, int32_t(r.tm_gmtoff));
    c.mem.write<uint32_t>(out + 40, r.tm_zone ? c.rt.internString(r.tm_zone) : 0);
    c.ret(out);
}
}  // namespace
B32_THUNK(_localtime_r) { timeToGuestTm(c, true); }
B32_THUNK(_gmtime_r) { timeToGuestTm(c, false); }
B32_THUNK(_modff) {
    float x = c.args.f32();
    GuestAddr ip = c.args.ptr();
    float whole;
    float frac = std::modf(x, &whole);
    c.mem.write<float>(ip, whole);
    c.retF32(frac);
}
B32_THUNK(_frexp) {
    double x = c.args.f64();
    GuestAddr exp = c.args.ptr();
    int e;
    double m = std::frexp(x, &e);
    c.mem.write<int32_t>(exp, e);
    c.retF64(m);
}
B32_THUNK(_ldexp) {
    double x = c.args.f64();
    c.retF64(std::ldexp(x, c.args.i32()));
}

B32_THUNK(_arc4random) { c.ret(arc4random()); }
B32_THUNK(_arc4random_uniform) { c.ret(arc4random_uniform(c.args.u32())); }

// --- qsort with a guest comparator -------------------------------------------------------------

// void qsort(void *base, size_t nel, size_t width, int (*compar)(const void *, const void *))
B32_THUNK(_qsort) {
    GuestAddr base = c.args.ptr();
    uint32_t count = c.args.u32(), width = c.args.u32();
    GuestAddr compare = c.args.ptr();
    if (count < 2) return;
    // Sort indexes with the guest comparing elements in place, then permute.
    std::vector<uint32_t> order(count);
    for (uint32_t i = 0; i < count; i++) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) {
        return int32_t(c.cpu.call(compare, {base + a * width, base + b * width})) < 0;
    });
    std::vector<uint8_t> sorted(size_t(count) * width);
    for (uint32_t i = 0; i < count; i++) std::memcpy(&sorted[i * width], c.mem.ptr<uint8_t>(base + order[i] * width), width);
    c.mem.copyIn(base, sorted.data(), sorted.size());
}

// --- CommonCrypto digests (data and result stay in guest memory) --------------------------------

B32_THUNK(_CC_MD5) {
    GuestAddr data = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr md = c.args.ptr();
    CC_MD5(c.mem.ptr<void>(data), length, c.mem.ptr<unsigned char>(md));
    c.ret(md);
}
B32_THUNK(_CC_SHA1) {
    GuestAddr data = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr md = c.args.ptr();
    CC_SHA1(c.mem.ptr<void>(data), length, c.mem.ptr<unsigned char>(md));
    c.ret(md);
}
B32_THUNK(_CC_SHA256) {
    GuestAddr data = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr md = c.args.ptr();
    CC_SHA256(c.mem.ptr<void>(data), length, c.mem.ptr<unsigned char>(md));
    c.ret(md);
}
