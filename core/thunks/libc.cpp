// libSystem: the C library. Functions that only touch memory run on the host
// with guest pointers translated in place; allocation goes to the guest heap.

#include "Format.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <cmath>
#include <cstdio>
#include <cstring>

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
