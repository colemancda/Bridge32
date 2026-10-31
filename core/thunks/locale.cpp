// Locales, collation, number parsing and wide characters: what GCC's
// libstdc++ needs from libSystem for its "generic" locale model. The guest
// always runs in the C locale. wchar_t, wint_t and mbstate_t (128 bytes)
// have the same layout in both ABIs, so their buffers pass straight through.

#include "Thunks.h"
#include "core/Runtime.h"

#include <algorithm>
#include <clocale>
#include <cstdlib>
#include <cstring>
#include <cwchar>

using namespace b32;

namespace {
char *hostPtr(Call &c, GuestAddr p) { return p ? c.mem.ptr<char>(p) : nullptr; }
wchar_t *hostWide(Call &c, GuestAddr p) { return p ? c.mem.ptr<wchar_t>(p) : nullptr; }
GuestAddr guestWide(GuestAddr base, const wchar_t *hostBase, const wchar_t *result) {
    return result ? GuestAddr(base + (result - hostBase) * sizeof(wchar_t)) : 0;
}

// Writes *endptr for the strto* family.
void setEnd(Call &c, GuestAddr endptr, GuestAddr str, const char *hostStr, const char *hostEnd) {
    if (endptr) c.mem.write<uint32_t>(endptr, str + GuestAddr(hostEnd - hostStr));
}
}  // namespace

// --- locale ---------------------------------------------------------------------------

// The C locale has one-byte multibyte characters.
B32_DATA(___mb_cur_max, 4) { rt.mem().write<int32_t>(addr, 1); }

// char *setlocale(int category, const char *locale): only "C" (and the
// equivalent "" and "POSIX") is available.
B32_THUNK(_setlocale) {
    c.args.i32();
    GuestAddr name = c.args.ptr();
    const char *requested = name ? c.mem.cstr(name) : nullptr;
    bool c_locale = !requested || !*requested || !std::strcmp(requested, "C") || !std::strcmp(requested, "POSIX");
    c.ret(c_locale ? c.rt.internString("C") : 0);
}

B32_THUNK(_strcoll) {
    const char *a = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::strcmp(a, c.mem.cstr(c.args.ptr()))));
}

// size_t strxfrm(char *dst, const char *src, size_t n): the identity in C.
B32_THUNK(_strxfrm) {
    char *dst = hostPtr(c, c.args.ptr());
    const char *src = c.mem.cstr(c.args.ptr());
    size_t n = c.args.u32(), len = std::strlen(src);
    if (dst && n) std::memcpy(dst, src, std::min(len + 1, n));
    c.ret(uint32_t(len));
}

B32_THUNK(_wcscoll) {
    const wchar_t *a = hostWide(c, c.args.ptr());
    c.ret(uint32_t(std::wcscmp(a, hostWide(c, c.args.ptr()))));
}

B32_THUNK(_wcsxfrm) {
    wchar_t *dst = hostWide(c, c.args.ptr());
    const wchar_t *src = hostWide(c, c.args.ptr());
    size_t n = c.args.u32(), len = std::wcslen(src);
    if (dst && n) std::wmemcpy(dst, src, std::min(len + 1, n));
    c.ret(uint32_t(len));
}

// --- numbers ---------------------------------------------------------------------------

B32_THUNK(_strtod) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    const char *s = c.mem.cstr(str);
    char *end;
    double value = std::strtod(s, &end);
    setEnd(c, endptr, str, s, end);
    c.retF64(value);
}

B32_THUNK(_strtof) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    const char *s = c.mem.cstr(str);
    char *end;
    float value = std::strtof(s, &end);
    setEnd(c, endptr, str, s, end);
    c.retF32(value);
}

// long double is double on 32-bit iOS.
B32_THUNK(_strtold) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    const char *s = c.mem.cstr(str);
    char *end;
    double value = std::strtod(s, &end);
    setEnd(c, endptr, str, s, end);
    c.retF64(value);
}

// --- wide characters -------------------------------------------------------------------

B32_THUNK(_btowc) { c.ret(uint32_t(std::btowc(c.args.i32()))); }
B32_THUNK(_wctob) { c.ret(uint32_t(std::wctob(wint_t(c.args.u32())))); }

// size_t mbrtowc(wchar_t *pwc, const char *s, size_t n, mbstate_t *ps)
B32_THUNK(_mbrtowc) {
    wchar_t *pwc = hostWide(c, c.args.ptr());
    const char *s = hostPtr(c, c.args.ptr());
    size_t n = c.args.u32();
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    c.ret(uint32_t(std::mbrtowc(pwc, s, n, ps)));
}

// size_t wcrtomb(char *s, wchar_t wc, mbstate_t *ps)
B32_THUNK(_wcrtomb) {
    char *s = hostPtr(c, c.args.ptr());
    wchar_t wc = wchar_t(c.args.u32());
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    c.ret(uint32_t(std::wcrtomb(s, wc, ps)));
}

B32_THUNK(_wcslen) { c.ret(uint32_t(std::wcslen(hostWide(c, c.args.ptr())))); }

B32_THUNK(_wmemchr) {
    GuestAddr s = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    size_t n = c.args.u32();
    c.ret(guestWide(s, hostWide(c, s), std::wmemchr(hostWide(c, s), ch, n)));
}

B32_THUNK(_wmemcmp) {
    const wchar_t *a = hostWide(c, c.args.ptr());
    const wchar_t *b = hostWide(c, c.args.ptr());
    c.ret(uint32_t(std::wmemcmp(a, b, c.args.u32())));
}

// wmemcpy, wmemmove and wmemset return their destination.
B32_THUNK(_wmemcpy) {
    GuestAddr dst = c.args.ptr();
    const wchar_t *src = hostWide(c, c.args.ptr());
    std::wmemcpy(hostWide(c, dst), src, c.args.u32());
    c.ret(dst);
}

B32_THUNK(_wmemmove) {
    GuestAddr dst = c.args.ptr();
    const wchar_t *src = hostWide(c, c.args.ptr());
    std::wmemmove(hostWide(c, dst), src, c.args.u32());
    c.ret(dst);
}

B32_THUNK(_wmemset) {
    GuestAddr dst = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    std::wmemset(hostWide(c, dst), ch, c.args.u32());
    c.ret(dst);
}
