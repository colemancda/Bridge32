// libSystem: the C library. Functions that only touch memory run on the host
// with guest pointers translated in place; allocation goes to the guest heap.

#include "Format.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <sys/time.h>

#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
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

B32_THUNK(_sprintf) {
    GuestAddr buf = c.args.ptr();
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
B32_THUNK(_malloc_size) { c.ret(c.heap.sizeOf(c.args.ptr())); }

B32_THUNK(_exit) { c.rt.exit(c.args.i32()); }
B32_THUNK(__exit) { c.rt.exit(c.args.i32()); }
B32_THUNK(_abort) { fatal("guest called abort() from 0x%08x", c.cpu.reg(Cpu::LR)); }

B32_THUNK(_atoi) { c.ret(uint32_t(std::atoi(c.mem.cstr(c.args.ptr())))); }

// --- string.h --------------------------------------------------------------

B32_THUNK(_strlen) { c.ret(uint32_t(std::strlen(c.mem.cstr(c.args.ptr())))); }

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

B32_THUNK(_dlopen) {
    GuestAddr path = c.args.ptr();
    log("dlopen(%s)", path ? c.mem.cstr(path) : "NULL");
    c.ret(kDlHandle);
}

B32_THUNK(_dlsym) {
    c.args.ptr();  // handle: every library shares the one thunk table
    std::string name = std::string("_") + c.mem.cstr(c.args.ptr());
    bool known = ThunkRegistry::all().count(name) != 0;
    log("dlsym(%s) -> %s", name.c_str(), known ? "thunk" : "not found");
    c.ret(known ? c.rt.thunks().stubFor(name) : 0);
}

B32_THUNK(_dlclose) { c.ret(0); }
B32_THUNK(_dlerror) { c.ret(0); }

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
    c.ret(wrapFile(c, f));
}

B32_THUNK(_fclose) {
    GuestAddr f = c.args.ptr();
    FILE *host = hostFile(c, f);
    {
        std::lock_guard guard(filesLock);
        files.erase(f);
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

B32_THUNK(_fprintf) {
    FILE *f = hostFile(c, c.args.ptr());
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
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
