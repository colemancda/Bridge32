// libSystem: the C library. Functions that only touch memory run on the host
// with guest pointers translated in place; allocation goes to the guest heap.

#include "Format.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <sys/time.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <climits>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <unordered_map>

using namespace b32;

namespace {
char *hostPtr(Call &c, GuestAddr p) { return p ? c.mem.ptr<char>(p) : nullptr; }
GuestAddr guestPtr(Call &c, GuestAddr base, const char *hostBase, const char *result) {
    return result ? GuestAddr(base + (result - hostBase)) : 0;
}
}  // namespace

// --- stdio -----------------------------------------------------------------

B32_THUNK(_printf) {
    const char *format = c.mem.cstr(c.args.ptr());
    std::string s = formatGuest(c, format, c.args);
    std::fwrite(s.data(), 1, s.size(), stdout);
    c.ret(uint32_t(s.size()));
}

B32_THUNK(_puts) {
    int r = std::puts(c.mem.cstr(c.args.ptr()));
    c.ret(uint32_t(r));
}

B32_THUNK(_putchar) { c.ret(uint32_t(std::putchar(c.args.i32()))); }

B32_THUNK(_snprintf) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    if (size) {
        size_t n = std::min<size_t>(s.size(), size - 1);
        c.mem.copyIn(buf, s.data(), n);
        c.mem.write<char>(buf + uint32_t(n), '\0');
    }
    c.ret(uint32_t(s.size()));
}

// int asprintf(char **ret, const char *format, ...): the string is allocated in
// guest memory, for the guest to free.
B32_THUNK(_asprintf) {
    GuestAddr out = c.args.ptr();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    GuestAddr str = c.heap.alloc(uint32_t(s.size() + 1));
    c.mem.copyIn(str, s.c_str(), s.size() + 1);
    if (out) c.mem.write<uint32_t>(out, str);
    c.ret(uint32_t(s.size()));
}

B32_THUNK(_sprintf) {
    GuestAddr buf = c.args.ptr();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    c.mem.copyIn(buf, s.c_str(), s.size() + 1);
    c.ret(uint32_t(s.size()));
}

// The _FORTIFY_SOURCE variants carry the destination size, which the host
// doesn't need to check again.
B32_THUNK(___sprintf_chk) {
    GuestAddr buf = c.args.ptr();
    c.args.i32();  // flag
    c.args.u32();  // destination size
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    c.mem.copyIn(buf, s.c_str(), s.size() + 1);
    c.ret(uint32_t(s.size()));
}

// --- stdlib ----------------------------------------------------------------

B32_THUNK(_malloc) { c.ret(c.heap.alloc(c.args.u32())); }
B32_THUNK(_free) { c.heap.free(c.args.ptr()); }
B32_THUNK(_calloc) {
    uint32_t count = c.args.u32();
    c.ret(c.heap.calloc(count, c.args.u32()));
}
B32_THUNK(_realloc) {
    GuestAddr p = c.args.ptr();
    c.ret(c.heap.realloc(p, c.args.u32()));
}
// int posix_memalign(void **out, size_t alignment, size_t size)
B32_THUNK(_posix_memalign) {
    GuestAddr out = c.args.ptr();
    uint32_t alignment = c.args.u32(), size = c.args.u32();
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) {
        c.ret(EINVAL);
        return;
    }
    GuestAddr p = c.heap.alloc(size ? size : 1, alignment);
    c.mem.write<uint32_t>(out, p);
    c.ret(p ? 0 : ENOMEM);
}
B32_THUNK(_malloc_size) { c.ret(c.heap.sizeOf(c.args.ptr())); }

// int *_NSGetArgc(void) and char ***_NSGetArgv(void): the process as the
// guest sees it, launched with no arguments but its executable's path.
namespace {
GuestAddr processArgs(Call &c) {
    static GuestAddr args = [&] {
        // int argc; char **argv; then argv's two entries.
        GuestAddr block = c.heap.calloc(1, 16);
        c.mem.write<int32_t>(block, 1);
        c.mem.write<uint32_t>(block + 4, block + 8);
        c.mem.write<uint32_t>(block + 8, c.rt.internString(c.rt.image().path));
        return block;
    }();
    return args;
}
}  // namespace
B32_THUNK(__NSGetArgc) { c.ret(processArgs(c)); }
B32_THUNK(__NSGetArgv) { c.ret(processArgs(c) + 4); }

B32_THUNK(_exit) { c.rt.exit(c.args.i32()); }
B32_THUNK(__exit) { c.rt.exit(c.args.i32()); }
B32_THUNK(_abort) { fatal("guest called abort() from 0x%08x", c.cpu.reg(Cpu::LR)); }

B32_THUNK(_atol) { c.ret(uint32_t(std::atol(c.mem.cstr(c.args.ptr())))); }
B32_THUNK(_atof) { c.retF64(std::atof(c.mem.cstr(c.args.ptr()))); }

// long strtol(const char *, char **end, int base) and strtoul: long is 32-bit.
B32_THUNK(_strtol) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const char *s = c.mem.cstr(str);
    char *end;
    long long value = std::strtoll(s, &end, base);
    if (endptr) c.mem.write<uint32_t>(endptr, str + GuestAddr(end - s));
    c.ret(uint32_t(int32_t(std::clamp<long long>(value, INT32_MIN, INT32_MAX))));
}
B32_THUNK(_strtoul) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const char *s = c.mem.cstr(str);
    char *end;
    unsigned long long value = std::strtoull(s, &end, base);
    if (endptr) c.mem.write<uint32_t>(endptr, str + GuestAddr(end - s));
    c.ret(uint32_t(std::min<unsigned long long>(value, UINT32_MAX)));
}

B32_THUNK(_atoi) { c.ret(uint32_t(std::atoi(c.mem.cstr(c.args.ptr())))); }

// --- string.h --------------------------------------------------------------

B32_THUNK(_strlen) {
    GuestAddr s = c.args.ptr();
    if (!c.mem.isMapped(s)) {
        std::string frames;
        for (uint32_t fp = c.cpu.reg(7), i = 0; i < 12 && fp && c.mem.isMapped(fp); i++, fp = c.mem.read<uint32_t>(fp))
            frames += " " + std::to_string(c.mem.read<uint32_t>(fp + 4));
        fatal("strlen(0x%08x): unmapped (from 0x%08x; frames%s)", s, c.cpu.reg(Cpu::LR), frames.c_str());
    }
    c.ret(uint32_t(std::strlen(c.mem.cstr(s))));
}

B32_THUNK(_strcpy) {
    GuestAddr dst = c.args.ptr();
    std::strcpy(hostPtr(c, dst), c.mem.cstr(c.args.ptr()));
    c.ret(dst);
}

B32_THUNK(_strncpy) {
    GuestAddr dst = c.args.ptr();
    const char *src = c.mem.cstr(c.args.ptr());
    std::strncpy(hostPtr(c, dst), src, c.args.u32());
    c.ret(dst);
}

B32_THUNK(_strcmp) {
    const char *a = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::strcmp(a, c.mem.cstr(c.args.ptr()))));
}

B32_THUNK(_strncmp) {
    const char *a = c.mem.cstr(c.args.ptr());
    const char *b = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::strncmp(a, b, c.args.u32())));
}

B32_THUNK(_strchr) {
    GuestAddr s = c.args.ptr();
    const char *host = c.mem.cstr(s);
    c.ret(guestPtr(c, s, host, std::strchr(host, c.args.i32())));
}

B32_THUNK(_strrchr) {
    GuestAddr s = c.args.ptr();
    const char *host = c.mem.cstr(s);
    c.ret(guestPtr(c, s, host, std::strrchr(host, c.args.i32())));
}

B32_THUNK(_strstr) {
    GuestAddr s = c.args.ptr();
    const char *host = c.mem.cstr(s);
    c.ret(guestPtr(c, s, host, std::strstr(host, c.mem.cstr(c.args.ptr()))));
}

B32_THUNK(_strdup) {
    const char *s = c.mem.cstr(c.args.ptr());
    size_t n = std::strlen(s) + 1;
    GuestAddr copy = c.heap.alloc(uint32_t(n));
    c.mem.copyIn(copy, s, n);
    c.ret(copy);
}

B32_THUNK(_memcpy) {
    GuestAddr dst = c.args.ptr();
    GuestAddr src = c.args.ptr();
    std::memcpy(hostPtr(c, dst), hostPtr(c, src), c.args.u32());
    c.ret(dst);
}

B32_THUNK(_memmove) {
    GuestAddr dst = c.args.ptr();
    GuestAddr src = c.args.ptr();
    std::memmove(hostPtr(c, dst), hostPtr(c, src), c.args.u32());
    c.ret(dst);
}

B32_THUNK(_memset) {
    GuestAddr dst = c.args.ptr();
    int value = c.args.i32();
    std::memset(hostPtr(c, dst), value, c.args.u32());
    c.ret(dst);
}

B32_THUNK(_bzero) {
    GuestAddr dst = c.args.ptr();
    std::memset(hostPtr(c, dst), 0, c.args.u32());
}

// errno_t memset_s(void *s, rsize_t smax, int c, rsize_t n)
B32_THUNK(_memset_s) {
    GuestAddr dst = c.args.ptr();
    uint32_t max = c.args.u32();
    int value = c.args.i32();
    uint32_t n = c.args.u32();
    if (dst) std::memset(hostPtr(c, dst), value, std::min(max, n));
    c.ret(n > max ? EOVERFLOW : 0);
}
B32_THUNK(___memcpy_chk) {
    GuestAddr dst = c.args.ptr(), src = c.args.ptr();
    std::memcpy(hostPtr(c, dst), hostPtr(c, src), c.args.u32());
    c.ret(dst);
}
B32_THUNK(___memset_chk) {
    GuestAddr dst = c.args.ptr();
    int value = c.args.i32();
    std::memset(hostPtr(c, dst), value, c.args.u32());
    c.ret(dst);
}
B32_THUNK(___strcat_chk) {
    GuestAddr dst = c.args.ptr();
    std::strcat(hostPtr(c, dst), c.mem.cstr(c.args.ptr()));
    c.ret(dst);
}
B32_THUNK(_strlcat) {
    char *dst = hostPtr(c, c.args.ptr());
    const char *src = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::strlcat(dst, src, c.args.u32())));
}
B32_THUNK(_strcasestr) {
    GuestAddr s = c.args.ptr();
    const char *find = c.mem.cstr(c.args.ptr());
    c.ret(guestPtr(c, s, hostPtr(c, s), ::strcasestr(hostPtr(c, s), find)));
}
// char *strtok_r(char *str, const char *sep, char **last): *last is a guest pointer.
B32_THUNK(_strtok_r) {
    GuestAddr str = c.args.ptr();
    const char *sep = c.mem.cstr(c.args.ptr());
    GuestAddr last = c.args.ptr();
    GuestAddr p = str ? str : c.mem.read<uint32_t>(last);
    if (!p) {
        c.ret(0);
        return;
    }
    p += GuestAddr(std::strspn(hostPtr(c, p), sep));
    if (!*hostPtr(c, p)) {
        c.mem.write<uint32_t>(last, 0);
        c.ret(0);
        return;
    }
    GuestAddr token = p;
    p += GuestAddr(std::strcspn(hostPtr(c, p), sep));
    if (*hostPtr(c, p)) {
        *hostPtr(c, p) = '\0';
        c.mem.write<uint32_t>(last, p + 1);
    } else {
        c.mem.write<uint32_t>(last, 0);
    }
    c.ret(token);
}
B32_THUNK(_ldexpf) {
    float x = c.args.f32();
    c.retF32(std::ldexp(x, c.args.i32()));
}
B32_THUNK(_scalbnf) {
    float x = c.args.f32();
    c.retF32(std::scalbn(x, c.args.i32()));
}
B32_THUNK(_scalbn) {
    double x = c.args.f64();
    c.retF64(std::scalbn(x, c.args.i32()));
}

// The _FORTIFY_SOURCE forms carry the destination's size too.
B32_THUNK(___strlcpy_chk) {
    char *dst = hostPtr(c, c.args.ptr());
    const char *src = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::strlcpy(dst, src, c.args.u32())));
}
B32_THUNK(___strlcat_chk) {
    char *dst = hostPtr(c, c.args.ptr());
    const char *src = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::strlcat(dst, src, c.args.u32())));
}
B32_THUNK(_strlcpy) {
    char *dst = hostPtr(c, c.args.ptr());
    const char *src = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::strlcpy(dst, src, c.args.u32())));
}
B32_THUNK(_strpbrk) {
    GuestAddr s = c.args.ptr();
    const char *accept = c.mem.cstr(c.args.ptr());
    c.ret(guestPtr(c, s, hostPtr(c, s), std::strpbrk(hostPtr(c, s), accept)));
}
// char *strtok(char *str, const char *sep), with its position kept per thread
// in guest terms.
B32_THUNK(_strtok) {
    static thread_local GuestAddr next = 0;
    GuestAddr str = c.args.ptr();
    const char *sep = c.mem.cstr(c.args.ptr());
    GuestAddr p = str ? str : next;
    if (!p) {
        c.ret(0);
        return;
    }
    p += GuestAddr(std::strspn(hostPtr(c, p), sep));
    if (!*hostPtr(c, p)) {
        next = 0;
        c.ret(0);
        return;
    }
    GuestAddr token = p;
    p += GuestAddr(std::strcspn(hostPtr(c, p), sep));
    if (*hostPtr(c, p)) {
        *hostPtr(c, p) = '\0';
        next = p + 1;
    } else {
        next = 0;
    }
    c.ret(token);
}
B32_THUNK(_strerror_r) {
    int err = c.args.i32();
    char *buf = hostPtr(c, c.args.ptr());
    c.ret(uint32_t(::strerror_r(err, buf, c.args.u32())));
}
B32_THUNK(_perror) {
    GuestAddr s = c.args.ptr();
    std::perror(s ? c.mem.cstr(s) : nullptr);
}
B32_THUNK(_wcscpy) {
    GuestAddr dst = c.args.ptr();
    std::wcscpy(c.mem.ptr<wchar_t>(dst), c.mem.ptr<wchar_t>(c.args.ptr()));
    c.ret(dst);
}
B32_THUNK(_wcscmp) {
    const wchar_t *a = c.mem.ptr<wchar_t>(c.args.ptr());
    c.ret(uint32_t(std::wcscmp(a, c.mem.ptr<wchar_t>(c.args.ptr()))));
}

B32_THUNK(_memcmp) {
    GuestAddr a = c.args.ptr();
    GuestAddr b = c.args.ptr();
    c.ret(uint32_t(std::memcmp(hostPtr(c, a), hostPtr(c, b), c.args.u32())));
}

// --- math.h (doubles travel in core register pairs on iOS armv7) -----------

B32_THUNK(_sqrt) { c.retF64(std::sqrt(c.args.f64())); }
B32_THUNK(_sin) { c.retF64(std::sin(c.args.f64())); }
B32_THUNK(_cos) { c.retF64(std::cos(c.args.f64())); }
B32_THUNK(_sqrtf) { c.retF32(std::sqrt(c.args.f32())); }
B32_THUNK(_sinf) { c.retF32(std::sin(c.args.f32())); }
B32_THUNK(_cosf) { c.retF32(std::cos(c.args.f32())); }

// --- stack protector -------------------------------------------------------

B32_DATA(___stack_chk_guard, 4) { rt.mem().write<uint32_t>(addr, 0xB32C0DE5); }
B32_THUNK(___stack_chk_fail) { fatal("guest stack smashing detected (from 0x%08x)", c.cpu.reg(Cpu::LR)); }

// --- dyld (iPhone OS 2-3 binaries call these from crt1) --------------------

// Initializers already ran before the entry point, so this does nothing.
B32_THUNK(__dyld_make_delayed_module_initializer_calls) {}
B32_THUNK(__dyld_mod_term_funcs) { c.ret(0); }

// crt1 asks for names like "__dyld_mod_term_funcs", which are symbol names.
B32_THUNK(__dyld_func_lookup) {
    std::string name = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    c.mem.write<uint32_t>(out, c.rt.thunks().stubFor(name));
    c.ret(1);
}

B32_THUNK(__dyld_lazy_symbol_binding_entry_point) {
    fatal("lazy binding requested, but every symbol pointer is bound at load time");
}

// --- dlfcn: system libraries resolve into the thunk table --------------------

namespace {
constexpr GuestAddr kDlHandle = 0xD1000000;  // any non-null value; never dereferenced
}  // namespace

// Guest libraries get real handles (their index in the runtime's library
// list, so they're small numbers); anything else, a system library, gets
// kDlHandle, and dlsym on it searches every symbol the loader would bind.
namespace {
thread_local GuestAddr dlErrorMessage = 0;
constexpr uint32_t kMaxLibraryHandle = 0x10000;
}  // namespace

B32_THUNK(_dlopen) {
    GuestAddr path = c.args.ptr();
    if (!path) {
        c.ret(kDlHandle);
        return;
    }
    std::string name = c.mem.cstr(path);
    if (name.rfind("/System/", 0) == 0 || name.rfind("/usr/lib/", 0) == 0) {
        log("dlopen(%s)", name.c_str());
        c.ret(kDlHandle);
        return;
    }
    uint32_t handle = c.rt.openLibrary(name, c.cpu);
    log("dlopen(%s) -> %s", name.c_str(), handle ? "guest library" : "not found");
    if (!handle) dlErrorMessage = c.rt.internString("dlopen(" + name + "): image not found");
    c.ret(handle);
}

B32_THUNK(_dlsym) {
    uint32_t handle = c.args.u32();
    std::string name = std::string("_") + c.mem.cstr(c.args.ptr());
    GuestAddr addr = handle && handle < kMaxLibraryHandle ? c.rt.librarySymbol(handle, name) : c.rt.lookUp(name);
    log("dlsym(%s) -> 0x%08x", name.c_str(), addr);
    if (!addr) dlErrorMessage = c.rt.internString("dlsym: symbol not found: " + name);
    c.ret(addr);
}

B32_THUNK(_dlclose) { c.ret(0); }

// libobjc's id objc_unsafeClaimAutoreleasedReturnValue(id): ARC's way of
// taking an autoreleased return value without retaining it, which here is
// the value itself.
B32_THUNK(_objc_unsafeClaimAutoreleasedReturnValue) { c.ret(c.args.ptr()); }

// int dladdr(const void *addr, Dl_info *info): answers for the app's own
// image, which is what games ask about (to find their bundle). Guest
// Dl_info is { dli_fname, dli_fbase, dli_sname, dli_saddr }.
B32_THUNK(_dladdr) {
    GuestAddr addr = c.args.ptr(), info = c.args.ptr();
    const Image &image = c.rt.image();
    if (!info || addr < image.base || addr >= image.end) {
        c.ret(0);
        return;
    }
    c.mem.write<uint32_t>(info, c.rt.internString(image.path));
    c.mem.write<uint32_t>(info + 4, image.base);
    c.mem.write<uint32_t>(info + 8, 0);
    c.mem.write<uint32_t>(info + 12, 0);
    c.ret(1);
}
B32_THUNK(_dlerror) {
    c.ret(dlErrorMessage);
    dlErrorMessage = 0;
}

// --- stdio streams ------------------------------------------------------------
// A guest FILE * is a zeroed guest block (sizeof(FILE) on 32-bit iOS) that
// stands for a host FILE *. Paths need no translation: the guest builds them
// from host NSBundle and NSSearchPath results.

namespace {
constexpr uint32_t kGuestFileSize = 88;
std::mutex filesLock;
std::unordered_map<GuestAddr, FILE *> files;

GuestAddr wrapFile(Call &c, FILE *host) {
    if (!host) return 0;
    GuestAddr f = c.heap.calloc(1, kGuestFileSize);
    std::lock_guard guard(filesLock);
    files[f] = host;
    return f;
}

FILE *hostFile(Call &c, GuestAddr f) {
    std::lock_guard guard(filesLock);
    auto it = files.find(f);
    if (it == files.end()) fatal("0x%08x is not an open FILE (from 0x%08x)", f, c.cpu.reg(Cpu::LR));
    return it->second;
}

void standardStream(Runtime &rt, GuestAddr variable, FILE *host) {
    GuestAddr f = rt.heap().calloc(1, kGuestFileSize);
    {
        std::lock_guard guard(filesLock);
        files[f] = host;
    }
    rt.mem().write<uint32_t>(variable, f);
}
}  // namespace

B32_DATA(___stdinp, 4) { standardStream(rt, addr, stdin); }
B32_DATA(___stdoutp, 4) { standardStream(rt, addr, stdout); }
B32_DATA(___stderrp, 4) { standardStream(rt, addr, stderr); }

B32_THUNK(_fopen) {
    const char *path = c.mem.cstr(c.args.ptr());
    const char *mode = c.mem.cstr(c.args.ptr());
    FILE *f = std::fopen(path, mode);
    if (!f) log("fopen(%s, %s) failed: %s", path, mode, std::strerror(errno));
    if (getenv("B32_TRACE_FILES")) log("fopen(%s, %s) = %p", path, mode, (void *)f);
    c.ret(wrapFile(c, f));
}

// Closing a FILE twice (RSDKv4 does) is an error, not a crash.
B32_THUNK(_fclose) {
    GuestAddr f = c.args.ptr();
    FILE *host = nullptr;
    {
        std::lock_guard guard(filesLock);
        auto it = files.find(f);
        if (it != files.end()) {
            host = it->second;
            files.erase(it);
        }
    }
    if (!host) {
        log("fclose(0x%08x): not an open FILE (from 0x%08x)", f, c.cpu.reg(Cpu::LR));
        setGuestErrno(c, EBADF);
        c.ret(uint32_t(EOF));
        return;
    }
    c.heap.free(f);
    c.ret(uint32_t(std::fclose(host)));
}

// size_t fread(void *ptr, size_t size, size_t nitems, FILE *stream)
B32_THUNK(_fread) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32(), count = c.args.u32();
    c.ret(uint32_t(std::fread(c.mem.ptr<void>(buf), size, count, hostFile(c, c.args.ptr()))));
}

B32_THUNK(_fwrite) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32(), count = c.args.u32();
    c.ret(uint32_t(std::fwrite(c.mem.ptr<void>(buf), size, count, hostFile(c, c.args.ptr()))));
}

// int fseek(FILE *stream, long offset, int whence)
B32_THUNK(_fseek) {
    FILE *f = hostFile(c, c.args.ptr());
    long offset = c.args.i32();
    c.ret(uint32_t(std::fseek(f, offset, c.args.i32())));
}

B32_THUNK(_ftell) { c.ret(uint32_t(std::ftell(hostFile(c, c.args.ptr())))); }

// int fseeko(FILE *, off_t, int) and off_t ftello(FILE *): off_t is 64-bit,
// for files past 2 GB (and engines that read big data packs with them).
B32_THUNK(_fseeko) {
    FILE *f = hostFile(c, c.args.ptr());
    off_t offset = off_t(c.args.u64());
    c.ret(uint32_t(::fseeko(f, offset, c.args.i32())));
}
B32_THUNK(_ftello) { c.ret64(uint64_t(::ftello(hostFile(c, c.args.ptr())))); }
B32_THUNK(_rewind) { std::rewind(hostFile(c, c.args.ptr())); }
B32_THUNK(_feof) { c.ret(uint32_t(std::feof(hostFile(c, c.args.ptr())))); }
B32_THUNK(_ferror) { c.ret(uint32_t(std::ferror(hostFile(c, c.args.ptr())))); }
B32_THUNK(_fflush) {
    GuestAddr f = c.args.ptr();
    c.ret(uint32_t(std::fflush(f ? hostFile(c, f) : nullptr)));
}
B32_THUNK(_fgetc) { c.ret(uint32_t(std::fgetc(hostFile(c, c.args.ptr())))); }
B32_THUNK(_getc) { c.ret(uint32_t(std::fgetc(hostFile(c, c.args.ptr())))); }

B32_THUNK(_fputc) {
    int ch = c.args.i32();
    c.ret(uint32_t(std::fputc(ch, hostFile(c, c.args.ptr()))));
}

B32_THUNK(_fputs) {
    const char *s = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::fputs(s, hostFile(c, c.args.ptr()))));
}

// char *fgets(char *str, int size, FILE *stream)
B32_THUNK(_fgets) {
    GuestAddr buf = c.args.ptr();
    int size = c.args.i32();
    char *r = std::fgets(c.mem.ptr<char>(buf), size, hostFile(c, c.args.ptr()));
    c.ret(r ? buf : 0);
}

B32_THUNK(_putc) {
    int ch = c.args.i32();
    c.ret(uint32_t(std::fputc(ch, hostFile(c, c.args.ptr()))));
}
B32_THUNK(_ungetc) {
    int ch = c.args.i32();
    c.ret(uint32_t(std::ungetc(ch, hostFile(c, c.args.ptr()))));
}
// FILE *freopen(const char *path, const char *mode, FILE *): the guest handle stays the same.
B32_THUNK(_freopen) {
    GuestAddr path = c.args.ptr();
    const char *mode = c.mem.cstr(c.args.ptr());
    GuestAddr f = c.args.ptr();
    FILE *host = ::freopen(path ? c.mem.cstr(path) : nullptr, mode, hostFile(c, f));
    if (!host) {
        c.ret(0);
        return;
    }
    {
        std::lock_guard guard(filesLock);
        files[f] = host;
    }
    c.ret(f);
}
B32_THUNK(_fileno) { c.ret(uint32_t(::fileno(hostFile(c, c.args.ptr())))); }
B32_THUNK(_fdopen) {
    int fd = c.args.i32();
    c.ret(wrapFile(c, ::fdopen(fd, c.mem.cstr(c.args.ptr()))));
}
// int setvbuf(FILE *, char *buf, int mode, size_t size): the buffer is guest
// memory, which never moves.
// void setbuf(FILE *, char *buf): a BUFSIZ buffer, or none.
B32_THUNK(_setbuf) {
    FILE *f = hostFile(c, c.args.ptr());
    GuestAddr buf = c.args.ptr();
    std::setvbuf(f, buf ? c.mem.ptr<char>(buf) : nullptr, buf ? _IOFBF : _IONBF, BUFSIZ);
}

// int fscanf(FILE *, const char *format, ...): scans what follows in the
// file, then leaves it positioned just after what the scan used.
B32_THUNK(_fscanf) {
    FILE *f = hostFile(c, c.args.ptr());
    const char *format = c.mem.cstr(c.args.ptr());
    long start = std::ftell(f);
    char chunk[4096];
    size_t got = std::fread(chunk, 1, sizeof chunk - 1, f);
    chunk[got] = '\0';
    if (got == 0) {
        c.ret(uint32_t(-1));  // EOF
        return;
    }
    size_t used = 0;
    int result = scanGuest(c, c.args, chunk, format, &used);
    std::fseek(f, start + long(used), SEEK_SET);
    c.ret(uint32_t(result));
}

B32_THUNK(_setvbuf) {
    FILE *f = hostFile(c, c.args.ptr());
    char *buf = hostPtr(c, c.args.ptr());
    int mode = c.args.i32();
    c.ret(uint32_t(std::setvbuf(f, buf, mode, c.args.u32())));
}
// Wide characters are 4 bytes in both ABIs.
B32_THUNK(_getwc) { c.ret(uint32_t(std::getwc(hostFile(c, c.args.ptr())))); }
B32_THUNK(_putwc) {
    wchar_t ch = wchar_t(c.args.u32());
    c.ret(uint32_t(std::putwc(ch, hostFile(c, c.args.ptr()))));
}
B32_THUNK(_ungetwc) {
    wint_t ch = c.args.u32();
    c.ret(uint32_t(std::ungetwc(ch, hostFile(c, c.args.ptr()))));
}

B32_THUNK(_fprintf) {
    FILE *f = hostFile(c, c.args.ptr());
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    c.ret(uint32_t(std::fwrite(s.data(), 1, s.size(), f)));
}

// int vfprintf(FILE *, const char *, va_list)
B32_THUNK(_vfprintf) {
    FILE *f = hostFile(c, c.args.ptr());
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    c.ret(uint32_t(std::fwrite(s.data(), 1, s.size(), f)));
}

// --- misc used by games ---------------------------------------------------------

B32_THUNK(_strcat) {
    GuestAddr dst = c.args.ptr();
    std::strcat(hostPtr(c, dst), c.mem.cstr(c.args.ptr()));
    c.ret(dst);
}

B32_THUNK(_srand) { std::srand(c.args.u32()); }
B32_THUNK(_rand) { c.ret(uint32_t(std::rand())); }
B32_THUNK(_atan2f) {
    float y = c.args.f32();
    c.retF32(std::atan2(y, c.args.f32()));
}

// int gettimeofday(struct timeval *tp, void *tzp): 32-bit time_t and suseconds_t.
B32_THUNK(_gettimeofday) {
    GuestAddr tv = c.args.ptr();
    struct timeval now;
    ::gettimeofday(&now, nullptr);
    if (tv) {
        c.mem.write<int32_t>(tv, int32_t(now.tv_sec));
        c.mem.write<int32_t>(tv + 4, int32_t(now.tv_usec));
    }
    c.ret(0);
}

// --- stdio odds and ends --------------------------------------------------------------------------

// ssize_t getline(char **linep, size_t *capp, FILE *): the line buffer is
// guest memory, grown with the guest heap.
B32_THUNK(_getline) {
    GuestAddr linep = c.args.ptr(), capp = c.args.ptr();
    FILE *f = hostFile(c, c.args.ptr());
    std::string line;
    int ch;
    while ((ch = std::fgetc(f)) != EOF) {
        line += char(ch);
        if (ch == '\n') break;
    }
    if (line.empty()) {
        c.ret(uint32_t(-1));
        return;
    }
    GuestAddr buf = c.mem.read<uint32_t>(linep);
    uint32_t cap = c.mem.read<uint32_t>(capp);
    if (!buf || cap < line.size() + 1) {
        if (buf) c.heap.free(buf);
        cap = uint32_t(line.size() + 1);
        buf = c.heap.alloc(cap);
        c.mem.write<uint32_t>(linep, buf);
        c.mem.write<uint32_t>(capp, cap);
    }
    c.mem.copyIn(buf, line.c_str(), line.size() + 1);
    c.ret(uint32_t(line.size()));
}
B32_THUNK(_flockfile) { ::flockfile(hostFile(c, c.args.ptr())); }
B32_THUNK(_funlockfile) { ::funlockfile(hostFile(c, c.args.ptr())); }

// int vasprintf(char **ret, const char *format, va_list)
B32_THUNK(_vasprintf) {
    GuestAddr out = c.args.ptr();
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format, va);
    GuestAddr str = c.heap.alloc(uint32_t(s.size() + 1));
    c.mem.copyIn(str, s.c_str(), s.size() + 1);
    c.mem.write<uint32_t>(out, str);
    c.ret(uint32_t(s.size()));
}

// --- atomics the compiler calls out to --------------------------------------------------------------

// int64_t OSAtomicAdd64(int64_t amount, volatile int64_t *value)
B32_THUNK(_OSAtomicAdd64) {
    int64_t amount = int64_t(c.args.u64());
    auto *value = c.mem.ptr<std::atomic<int64_t>>(c.args.ptr());
    c.ret64(uint64_t(value->fetch_add(amount) + amount));
}
// void __atomic_load(size_t size, void *src, void *dst, int order) and
// __atomic_store(size_t size, void *dst, void *src, int order): for sizes
// without lock-free instructions; a lock makes them atomic with each other.
namespace {
std::mutex atomicLock;
}
B32_THUNK(___atomic_load) {
    uint32_t size = c.args.u32();
    void *src = c.mem.ptr<void>(c.args.ptr()), *dst = c.mem.ptr<void>(c.args.ptr());
    std::lock_guard guard(atomicLock);
    std::memcpy(dst, src, size);
}
B32_THUNK(___atomic_store) {
    uint32_t size = c.args.u32();
    void *dst = c.mem.ptr<void>(c.args.ptr()), *src = c.mem.ptr<void>(c.args.ptr());
    std::lock_guard guard(atomicLock);
    std::memcpy(dst, src, size);
}

// --- more math ------------------------------------------------------------------------------------

B32_THUNK(___fpclassifyd) { c.ret(uint32_t(std::fpclassify(c.args.f64()))); }
B32_THUNK(___fpclassify) { c.ret(uint32_t(std::fpclassify(c.args.f64()))); }  // long double is double
B32_THUNK(___fpclassifyf) { c.ret(uint32_t(std::fpclassify(c.args.f32()))); }
B32_THUNK(_remainderf) {
    float x = c.args.f32();
    c.retF32(std::remainder(x, c.args.f32()));
}
B32_THUNK(_fmaf) {
    float x = c.args.f32(), y = c.args.f32();
    c.retF32(std::fma(x, y, c.args.f32()));
}
B32_THUNK(_nextafter) {
    double x = c.args.f64();
    c.retF64(std::nextafter(x, c.args.f64()));
}
B32_THUNK(_fmodl) {
    double x = c.args.f64();
    c.retF64(std::fmod(x, c.args.f64()));
}
