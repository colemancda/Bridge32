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
#include <net/if.h>
#include <mach/mach_time.h>
#include <mach/mach_error.h>
#include <sys/resource.h>
#include <sys/utsname.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <csignal>
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
    } else if (name == "kern.ostype" || name == "kern.osrelease") {
        const char *value = name == "kern.ostype" ? "Darwin" : "13.0.0";  // the kernel of iOS 6
        reply(value, uint32_t(std::strlen(value) + 1));
    } else if (name == "kern.osversion") {
        const char *build = "10B329";  // iOS 6.1.3
        reply(build, uint32_t(std::strlen(build) + 1));
    } else if (name == "hw.pagesize") {
        int32_t bytes = 4096;
        reply(&bytes, 4);
    } else if (name == "hw.cpufrequency") {
        int32_t hz = 1000000000;
        reply(&hz, 4);
#if defined(B32_GUEST_I386)
    } else if (name == "hw.cpufrequency_max") {
        // What a 2006-era game wants to see of an Intel Mac; 32 or 64 bits as asked.
        uint64_t hz = 2400000000ull;
        reply(&hz, lenp && c.mem.read<uint32_t>(lenp) >= 8 ? 8 : 4);
    } else if (name == "hw.optional.altivec") {
        int32_t none = 0;
        reply(&none, 4);
#endif
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
        {int64_t(CTL_KERN) << 32 | KERN_OSTYPE, "kern.ostype"}, {int64_t(CTL_KERN) << 32 | KERN_OSRELEASE, "kern.osrelease"},
        {int64_t(CTL_KERN) << 32 | KERN_OSVERSION, "kern.osversion"},
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
B32_THUNK(_getppid) { c.ret(uint32_t(getppid())); }
// Games call ptrace(PT_DENY_ATTACH) to keep debuggers off (Sonic & All-Stars
// Racing Transformed, through dlsym); it succeeds and does nothing.
B32_THUNK(_ptrace) { c.ret(0); }
B32_THUNK(_getdtablesize) { c.ret(uint32_t(getdtablesize())); }

B32_THUNK(_time) {
    GuestAddr out = c.args.ptr();
    int32_t now = int32_t(std::time(nullptr));
    if (out) c.mem.write<int32_t>(out, now);
    c.ret(uint32_t(now));
}

// The guest's struct statfs (64-bit inode variant) has the host's layout:
// its 8-byte fields happen to sit at 8-byte-aligned offsets.
#if defined(B32_GUEST_I386)
B32_THUNK(_statfs$INODE64) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::statfs(path, c.mem.ptr<struct statfs>(c.args.ptr()))));
}
// i386 Mac's plain struct statfs, 272 bytes: otype 0, oflags 2, bsize 4,
// iosize 8, blocks 12, bfree 16, bavail 20, files 24, ffree 28, fsid 32,
// owner 40, reserved1 44, type 46, flags 48, reserved2 52, fstypename[15] 60,
// mntonname[90] 75, mntfromname[90] 165.
B32_THUNK(_statfs) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    struct statfs st;
    int rc = ::statfs(path, &st);
    if (rc == 0) {
        std::memset(c.mem.ptr<uint8_t>(out), 0, 272);
        c.mem.write<int32_t>(out + 4, int32_t(st.f_bsize));
        c.mem.write<int32_t>(out + 8, int32_t(st.f_iosize));
        const uint64_t counts[] = {st.f_blocks, st.f_bfree, st.f_bavail, st.f_files, st.f_ffree};
        for (int i = 0; i < 5; i++) c.mem.write<int32_t>(out + 12 + i * 4, int32_t(std::min<uint64_t>(counts[i], INT32_MAX)));
        c.mem.copyIn(out + 32, &st.f_fsid, 8);
        c.mem.write<uint32_t>(out + 40, st.f_owner);
        c.mem.write<int16_t>(out + 46, int16_t(st.f_type));
        c.mem.write<int32_t>(out + 48, int32_t(st.f_flags));
        strlcpy(c.mem.ptr<char>(out + 60), st.f_fstypename, 15);
        strlcpy(c.mem.ptr<char>(out + 75), st.f_mntonname, 90);
        strlcpy(c.mem.ptr<char>(out + 165), st.f_mntfromname, 90);
    }
    c.ret(uint32_t(rc));
}
#else
B32_THUNK(_statfs) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::statfs(path, c.mem.ptr<struct statfs>(c.args.ptr()))));
}
#endif

// Used for "don't back up" flags; nothing to back up from here.
B32_THUNK(_setxattr) { c.ret(0); }

// int sigaction(int sig, const struct sigaction *act, struct sigaction *oact):
// the guest's struct is { handler, sa_mask, sa_flags }. Handlers are only
// recorded; Cpu calls the SIGSEGV/SIGBUS one for guest faults, and no other
// signal is ever delivered.
B32_THUNK(_sigaction) {
    int sig = c.args.i32();
    GuestAddr act = c.args.ptr(), oact = c.args.ptr();
    Cpu::SignalAction old = Cpu::signalAction(sig);
    if (act) {
        Cpu::SignalAction action{c.mem.read<uint32_t>(act), c.mem.read<uint32_t>(act + 4), c.mem.read<uint32_t>(act + 8)};
        Cpu::setSignalAction(sig, action);
        if ((sig == SIGSEGV || sig == SIGBUS) && action.handler > 1)
            log("guest handles signal %d at 0x%08x", sig, action.handler);
    }
    if (oact) {
        c.mem.write<uint32_t>(oact, old.handler);
        c.mem.write<uint32_t>(oact + 4, old.mask);
        c.mem.write<uint32_t>(oact + 8, old.flags);
    }
    c.ret(0);
}

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
// int pipe(int fds[2]): host descriptors, like every other.
B32_THUNK(_pipe) { c.ret(uint32_t(::pipe(c.mem.ptr<int>(c.args.ptr())))); }

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
B32_THUNK(_memset_pattern4) {
    GuestAddr dst = c.args.ptr();
    GuestAddr pattern = c.args.ptr();
    memset_pattern4(c.mem.ptr<void>(dst), c.mem.ptr<void>(pattern), c.args.u32());
}
B32_THUNK(_memset_pattern8) {
    GuestAddr dst = c.args.ptr();
    GuestAddr pattern = c.args.ptr();
    memset_pattern8(c.mem.ptr<void>(dst), c.mem.ptr<void>(pattern), c.args.u32());
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
B32_THUNK(_llround) { c.ret64(uint64_t(std::llround(c.args.f64()))); }
B32_THUNK(_ilogb) { c.ret(uint32_t(std::ilogb(c.args.f64()))); }
B32_THUNK(_remainder) {
    double x = c.args.f64();
    c.retF64(std::remainder(x, c.args.f64()));
}

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
B32_THUNK(_modf) {
    double x = c.args.f64();
    GuestAddr ip = c.args.ptr();
    double whole;
    double frac = std::modf(x, &whole);
    c.mem.write<double>(ip, whole);
    c.retF64(frac);
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

// Incremental digests: CC_MD5_CTX and CC_SHA256_CTX are all 32-bit words on
// both sides, so the host works on the guest's context in place.
#define B32_CC_DIGEST(name, Ctx)                                                           \
    B32_THUNK(_CC_##name##_Init) { c.ret(uint32_t(CC_##name##_Init(c.mem.ptr<Ctx>(c.args.ptr())))); } \
    B32_THUNK(_CC_##name##_Update) {                                                       \
        auto *ctx = c.mem.ptr<Ctx>(c.args.ptr());                                          \
        GuestAddr data = c.args.ptr();                                                     \
        c.ret(uint32_t(CC_##name##_Update(ctx, c.mem.ptr<void>(data), c.args.u32())));     \
    }                                                                                      \
    B32_THUNK(_CC_##name##_Final) {                                                        \
        auto *md = c.mem.ptr<unsigned char>(c.args.ptr());                                 \
        c.ret(uint32_t(CC_##name##_Final(md, c.mem.ptr<Ctx>(c.args.ptr()))));              \
    }
B32_CC_DIGEST(MD5, CC_MD5_CTX)
B32_CC_DIGEST(SHA256, CC_SHA256_CTX)

// --- odds and ends ---------------------------------------------------------------------------

// Page-aligned allocation from the guest heap.
B32_THUNK(_valloc) {
    uint32_t size = c.args.u32();
    c.ret(c.heap.alloc(size, 4096));
}

B32_THUNK(_lrint) { c.ret(uint32_t(int32_t(std::lrint(c.args.f64())))); }
B32_THUNK(_lrintf) { c.ret(uint32_t(int32_t(std::lrint(c.args.f32())))); }
B32_THUNK(_srandomdev) { ::srandomdev(); }

// int getrusage(int who, struct rusage *): two 32-bit timevals and fourteen longs.
B32_THUNK(_getrusage) {
    int who = c.args.i32();
    GuestAddr out = c.args.ptr();
    struct rusage usage{};
    int r = ::getrusage(who, &usage);
    if (r == 0 && out) {
        int32_t words[18] = {int32_t(usage.ru_utime.tv_sec), usage.ru_utime.tv_usec, int32_t(usage.ru_stime.tv_sec),
                             usage.ru_stime.tv_usec, int32_t(usage.ru_maxrss)};
        const long rest[] = {usage.ru_ixrss, usage.ru_idrss, usage.ru_isrss, usage.ru_minflt, usage.ru_majflt,
                             usage.ru_nswap, usage.ru_inblock, usage.ru_oublock, usage.ru_msgsnd, usage.ru_msgrcv,
                             usage.ru_nsignals, usage.ru_nvcsw, usage.ru_nivcsw};
        for (int i = 0; i < 13; i++) words[5 + i] = int32_t(rest[i]);
        c.mem.copyIn(out, words, sizeof words);
    }
    c.ret(uint32_t(r));
}

// size_t confstr(int name, char *buf, size_t len)
B32_THUNK(_confstr) {
    int name = c.args.i32();
    GuestAddr buf = c.args.ptr();
    uint32_t len = c.args.u32();
    c.ret(uint32_t(::confstr(name, buf ? c.mem.ptr<char>(buf) : nullptr, len)));
}

B32_THUNK(_mach_error) {
    const char *message = c.mem.cstr(c.args.ptr());
    log("mach_error: %s %s", message, ::mach_error_string(c.args.i32()));
}
// Scheduling hints for guest threads aren't passed on.
B32_THUNK(_thread_policy_set) { c.ret(0); }
// Guest memory isn't described by host VM regions; engines asking for their
// own stack bounds fall back to pthread_get_stackaddr_np.
B32_THUNK(_vm_region_64) { c.ret(1 /* KERN_INVALID_ADDRESS */); }

// Guest threads run with the host's scheduling.
B32_THUNK(_pthread_attr_setschedpolicy) { c.ret(0); }

// bool OSAtomicTestAndSet[Barrier](uint32_t n, volatile void *address) and the
// Clear forms: bit n counts from the top bit of the first byte.
namespace {
uint32_t testAndChangeBit(Call &c, bool set) {
    uint32_t n = c.args.u32();
    GuestAddr address = c.args.ptr();
    auto *byte = c.mem.ptr<uint8_t>(address + (n >> 3));
    uint8_t mask = uint8_t(0x80u >> (n & 7));
    std::atomic_ref<uint8_t> value(*byte);
    uint8_t old = set ? value.fetch_or(mask) : value.fetch_and(uint8_t(~mask));
    return (old & mask) != 0;
}
}  // namespace
B32_THUNK(_OSAtomicTestAndSet) { c.ret(testAndChangeBit(c, true)); }
B32_THUNK(_OSAtomicTestAndSetBarrier) { c.ret(testAndChangeBit(c, true)); }
B32_THUNK(_OSAtomicTestAndClear) { c.ret(testAndChangeBit(c, false)); }
B32_THUNK(_OSAtomicTestAndClearBarrier) { c.ret(testAndChangeBit(c, false)); }

// --- more of libSystem (Angry Birds Friends) ------------------------------------------------

// int atexit_b(void (^)(void)): guest exit handlers aren't run.
B32_THUNK(_atexit_b) { c.ret(0); }
B32_THUNK(_getegid) { c.ret(getegid()); }
B32_THUNK(_srand48) { ::srand48(c.args.i32()); }
B32_THUNK(_drand48) { c.retF64(::drand48()); }
B32_THUNK(___isnand) { c.ret(std::isnan(c.args.f64()) ? 1 : 0); }
B32_THUNK(___isnanf) { c.ret(std::isnan(c.args.f32()) ? 1 : 0); }
B32_THUNK(_logbf) { c.retF32(std::logb(c.args.f32())); }
// kern_return_t mach_wait_until(uint64_t deadline): in mach_absolute_time units.
B32_THUNK(_mach_wait_until) { c.ret(::mach_wait_until(c.args.u64())); }
// Condition variables carry no attributes the guest can set.
B32_THUNK(_pthread_condattr_init) { c.ret(0); }
B32_THUNK(_pthread_condattr_destroy) { c.ret(0); }
// long pathconf(const char *, int): long is 32-bit in the guest.
B32_THUNK(_pathconf) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(int32_t(::pathconf(path, c.args.i32()))));
}
// char *if_indextoname(unsigned, char *name): name holds IF_NAMESIZE bytes.
B32_THUNK(_if_indextoname) {
    unsigned index = c.args.u32();
    GuestAddr name = c.args.ptr();
    c.ret(::if_indextoname(index, c.mem.ptr<char>(name)) ? name : 0);
}
// clock_t clock(void): a 32-bit count of CLOCKS_PER_SEC (1,000,000) ticks in the guest.
B32_THUNK(_clock) { c.ret(uint32_t(::clock())); }
