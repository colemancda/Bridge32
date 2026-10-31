// Locales, collation, number parsing and wide characters: what GCC's
// libstdc++ needs from libSystem for its "generic" locale model, and the
// xlocale (*_l) functions LLVM's libc++ calls instead. The guest always runs
// in the C locale: newlocale hands out a token, and every *_l function runs
// as its plain counterpart. wchar_t, wint_t and mbstate_t (128 bytes)
// have the same layout in both ABIs, so their buffers pass straight through.

#include "Format.h"
#include "Thunks.h"
#include "core/Runtime.h"

#include <algorithm>
#include <clocale>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <runetype.h>
#include <string>

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

// --- xlocale (libc++) ------------------------------------------------------------------

namespace {
// The guest's only locale. LC_GLOBAL_LOCALE is (locale_t)-1, and 0 means failure.
constexpr uint32_t kCLocale = 0xC10CA1E0;

}  // namespace

B32_THUNK(_newlocale) { c.ret(kCLocale); }
B32_THUNK(_freelocale) { c.ret(0); }
B32_THUNK(_uselocale) { c.ret(kCLocale); }
B32_THUNK(_duplocale) { c.ret(kCLocale); }
B32_THUNK(____mb_cur_max_l) { c.ret(1); }

B32_THUNK(____tolower_l) { c.ret(uint32_t(__tolower(c.args.i32()))); }
B32_THUNK(____toupper_l) { c.ret(uint32_t(__toupper(c.args.i32()))); }
B32_THUNK(___maskrune_l) {
    int32_t ch = c.args.i32();
    c.ret(uint32_t(__maskrune(ch, c.args.u32())));
}

// struct lconv for the C locale: ten char * fields, then fourteen chars.
B32_THUNK(_localeconv_l) {
    static GuestAddr conv = 0;
    if (!conv) {
        conv = c.heap.calloc(1, 56);
        GuestAddr empty = c.rt.internString("");
        for (int i = 0; i < 10; i++) c.mem.write<uint32_t>(conv + i * 4, empty);
        c.mem.write<uint32_t>(conv, c.rt.internString("."));
        for (int i = 0; i < 14; i++) c.mem.write<uint8_t>(conv + 40 + i, CHAR_MAX);
    }
    c.ret(conv);
}

B32_THUNK(_strcoll_l) {
    const char *a = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::strcmp(a, c.mem.cstr(c.args.ptr()))));
}
B32_THUNK(_strxfrm_l) {
    char *dst = hostPtr(c, c.args.ptr());
    const char *src = c.mem.cstr(c.args.ptr());
    size_t n = c.args.u32(), len = std::strlen(src);
    if (dst && n) std::memcpy(dst, src, std::min(len + 1, n));
    c.ret(uint32_t(len));
}
B32_THUNK(_wcscoll_l) {
    const wchar_t *a = hostWide(c, c.args.ptr());
    c.ret(uint32_t(std::wcscmp(a, hostWide(c, c.args.ptr()))));
}
B32_THUNK(_wcsxfrm_l) {
    wchar_t *dst = hostWide(c, c.args.ptr());
    const wchar_t *src = hostWide(c, c.args.ptr());
    size_t n = c.args.u32(), len = std::wcslen(src);
    if (dst && n) std::wmemcpy(dst, src, std::min(len + 1, n));
    c.ret(uint32_t(len));
}

B32_THUNK(_btowc_l) { c.ret(uint32_t(std::btowc(c.args.i32()))); }
B32_THUNK(_wctob_l) { c.ret(uint32_t(std::wctob(wint_t(c.args.u32())))); }

// int mbtowc_l(wchar_t *, const char *, size_t, locale_t)
B32_THUNK(_mbtowc_l) {
    wchar_t *pwc = hostWide(c, c.args.ptr());
    const char *s = hostPtr(c, c.args.ptr());
    c.ret(uint32_t(std::mbtowc(pwc, s, c.args.u32())));
}
// size_t mbrlen_l(const char *, size_t, mbstate_t *, locale_t)
B32_THUNK(_mbrlen_l) {
    const char *s = hostPtr(c, c.args.ptr());
    size_t n = c.args.u32();
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    c.ret(uint32_t(std::mbrlen(s, n, ps)));
}
// size_t mbrtowc_l(wchar_t *, const char *, size_t, mbstate_t *, locale_t)
B32_THUNK(_mbrtowc_l) {
    wchar_t *pwc = hostWide(c, c.args.ptr());
    const char *s = hostPtr(c, c.args.ptr());
    size_t n = c.args.u32();
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    c.ret(uint32_t(std::mbrtowc(pwc, s, n, ps)));
}
// size_t wcrtomb_l(char *, wchar_t, mbstate_t *, locale_t)
B32_THUNK(_wcrtomb_l) {
    char *s = hostPtr(c, c.args.ptr());
    wchar_t wc = wchar_t(c.args.u32());
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    c.ret(uint32_t(std::wcrtomb(s, wc, ps)));
}

// The string conversions advance *src, a guest pointer to a guest string.
// size_t mbsnrtowcs_l(wchar_t *, const char **src, size_t nms, size_t len, mbstate_t *, locale_t)
B32_THUNK(_mbsnrtowcs_l) {
    wchar_t *dst = hostWide(c, c.args.ptr());
    GuestAddr src = c.args.ptr();
    size_t nms = c.args.u32(), len = c.args.u32();
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    GuestAddr start = c.mem.read<uint32_t>(src);
    const char *p = hostPtr(c, start), *begin = p;
    size_t r = ::mbsnrtowcs(dst, &p, nms, len, ps);
    c.mem.write<uint32_t>(src, p ? start + GuestAddr(p - begin) : 0);
    c.ret(uint32_t(r));
}
// size_t mbsrtowcs_l(wchar_t *, const char **src, size_t len, mbstate_t *, locale_t)
B32_THUNK(_mbsrtowcs_l) {
    wchar_t *dst = hostWide(c, c.args.ptr());
    GuestAddr src = c.args.ptr();
    size_t len = c.args.u32();
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    GuestAddr start = c.mem.read<uint32_t>(src);
    const char *p = hostPtr(c, start), *begin = p;
    size_t r = std::mbsrtowcs(dst, &p, len, ps);
    c.mem.write<uint32_t>(src, p ? start + GuestAddr(p - begin) : 0);
    c.ret(uint32_t(r));
}
// size_t wcsnrtombs_l(char *, const wchar_t **src, size_t nwc, size_t len, mbstate_t *, locale_t)
B32_THUNK(_wcsnrtombs_l) {
    char *dst = hostPtr(c, c.args.ptr());
    GuestAddr src = c.args.ptr();
    size_t nwc = c.args.u32(), len = c.args.u32();
    auto *ps = reinterpret_cast<mbstate_t *>(hostPtr(c, c.args.ptr()));
    GuestAddr start = c.mem.read<uint32_t>(src);
    const wchar_t *p = hostWide(c, start), *begin = p;
    size_t r = ::wcsnrtombs(dst, &p, nwc, len, ps);
    c.mem.write<uint32_t>(src, p ? start + GuestAddr((p - begin) * sizeof(wchar_t)) : 0);
    c.ret(uint32_t(r));
}

// --- numbers with a locale, and from wide strings ------------------------------------------

B32_THUNK(_strtold_l) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    const char *s = c.mem.cstr(str);
    char *end;
    double value = std::strtod(s, &end);  // long double is double on 32-bit iOS
    setEnd(c, endptr, str, s, end);
    c.retF64(value);
}
B32_THUNK(_strtoll_l) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const char *s = c.mem.cstr(str);
    char *end;
    long long value = std::strtoll(s, &end, base);
    setEnd(c, endptr, str, s, end);
    c.ret64(uint64_t(value));
}
B32_THUNK(_strtoull_l) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const char *s = c.mem.cstr(str);
    char *end;
    unsigned long long value = std::strtoull(s, &end, base);
    setEnd(c, endptr, str, s, end);
    c.ret64(value);
}

namespace {
void setWideEnd(Call &c, GuestAddr endptr, GuestAddr str, const wchar_t *hostStr, const wchar_t *hostEnd) {
    if (endptr) c.mem.write<uint32_t>(endptr, str + GuestAddr((hostEnd - hostStr) * sizeof(wchar_t)));
}
}  // namespace

B32_THUNK(_wcstod) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    const wchar_t *s = hostWide(c, str);
    wchar_t *end;
    double value = std::wcstod(s, &end);
    setWideEnd(c, endptr, str, s, end);
    c.retF64(value);
}
B32_THUNK(_wcstold) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    const wchar_t *s = hostWide(c, str);
    wchar_t *end;
    double value = std::wcstod(s, &end);
    setWideEnd(c, endptr, str, s, end);
    c.retF64(value);
}
// long is 32-bit in the guest.
B32_THUNK(_wcstol) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const wchar_t *s = hostWide(c, str);
    wchar_t *end;
    long long value = std::wcstoll(s, &end, base);
    setWideEnd(c, endptr, str, s, end);
    c.ret(uint32_t(int32_t(std::clamp<long long>(value, INT32_MIN, INT32_MAX))));
}
B32_THUNK(_wcstoul) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const wchar_t *s = hostWide(c, str);
    wchar_t *end;
    unsigned long long value = std::wcstoull(s, &end, base);
    setWideEnd(c, endptr, str, s, end);
    c.ret(uint32_t(std::min<unsigned long long>(value, UINT32_MAX)));
}
B32_THUNK(_wcstoll) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const wchar_t *s = hostWide(c, str);
    wchar_t *end;
    long long value = std::wcstoll(s, &end, base);
    setWideEnd(c, endptr, str, s, end);
    c.ret64(uint64_t(value));
}
B32_THUNK(_wcstoull) {
    GuestAddr str = c.args.ptr(), endptr = c.args.ptr();
    int base = c.args.i32();
    const wchar_t *s = hostWide(c, str);
    wchar_t *end;
    unsigned long long value = std::wcstoull(s, &end, base);
    setWideEnd(c, endptr, str, s, end);
    c.ret64(value);
}

// --- formatting with a locale ----------------------------------------------------------------

// int snprintf_l(char *, size_t, locale_t, const char *format, ...)
B32_THUNK(_snprintf_l) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    c.args.ptr();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    if (size) {
        size_t n = std::min<size_t>(s.size(), size - 1);
        c.mem.copyIn(buf, s.data(), n);
        c.mem.write<char>(buf + uint32_t(n), '\0');
    }
    c.ret(uint32_t(s.size()));
}
// int sprintf_l(char *, locale_t, const char *format, ...)
B32_THUNK(_sprintf_l) {
    GuestAddr buf = c.args.ptr();
    c.args.ptr();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    c.mem.copyIn(buf, s.c_str(), s.size() + 1);
    c.ret(uint32_t(s.size()));
}
// int asprintf_l(char **ret, locale_t, const char *format, ...)
B32_THUNK(_asprintf_l) {
    GuestAddr out = c.args.ptr();
    c.args.ptr();
    std::string s = formatGuest(c, c.mem.cstr(c.args.ptr()), c.args);
    GuestAddr str = c.heap.alloc(uint32_t(s.size() + 1));
    c.mem.copyIn(str, s.c_str(), s.size() + 1);
    c.mem.write<uint32_t>(out, str);
    c.ret(uint32_t(s.size()));
}

// int swprintf(wchar_t *, size_t, const wchar_t *format, ...): libc++ formats
// numbers with it, so the format is plain ASCII; it runs as printf and the
// result is widened.
B32_THUNK(_swprintf) {
    wchar_t *buf = hostWide(c, c.args.ptr());
    uint32_t size = c.args.u32();
    std::string format;
    for (const wchar_t *f = hostWide(c, c.args.ptr()); *f; f++) format += char(*f);
    std::string s = formatGuest(c, format.c_str(), c.args);
    if (!size || s.size() >= size) {
        if (size) buf[0] = 0;
        c.ret(uint32_t(-1));
        return;
    }
    for (size_t i = 0; i < s.size(); i++) buf[i] = wchar_t(static_cast<unsigned char>(s[i]));
    buf[s.size()] = 0;
    c.ret(uint32_t(s.size()));
}

// int vswprintf(wchar_t *, size_t, const wchar_t *format, va_list)
B32_THUNK(_vswprintf) {
    wchar_t *buf = hostWide(c, c.args.ptr());
    uint32_t size = c.args.u32();
    std::string format;
    for (const wchar_t *f = hostWide(c, c.args.ptr()); *f; f++) format += char(*f);
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format.c_str(), va);
    if (!size || s.size() >= size) {
        if (size) buf[0] = 0;
        c.ret(uint32_t(-1));
        return;
    }
    for (size_t i = 0; i < s.size(); i++) buf[i] = wchar_t(static_cast<unsigned char>(s[i]));
    buf[s.size()] = 0;
    c.ret(uint32_t(s.size()));
}

// --- message catalogs: none, so std::messages returns its defaults -------------------------

B32_THUNK(_catopen) { c.ret(uint32_t(-1)); }
B32_THUNK(_catclose) { c.ret(0); }
// char *catgets(nl_catd, int set, int msg, const char *default)
B32_THUNK(_catgets) {
    c.args.u32();
    c.args.i32();
    c.args.i32();
    c.ret(c.args.ptr());
}

// --- more wide strings -------------------------------------------------------------------

B32_THUNK(_wcsncmp) {
    const wchar_t *a = hostWide(c, c.args.ptr());
    const wchar_t *b = hostWide(c, c.args.ptr());
    c.ret(uint32_t(std::wcsncmp(a, b, c.args.u32())));
}
B32_THUNK(_wcscasecmp) {
    const wchar_t *a = hostWide(c, c.args.ptr());
    c.ret(uint32_t(::wcscasecmp(a, hostWide(c, c.args.ptr()))));
}
B32_THUNK(_wcsncasecmp) {
    const wchar_t *a = hostWide(c, c.args.ptr());
    const wchar_t *b = hostWide(c, c.args.ptr());
    c.ret(uint32_t(::wcsncasecmp(a, b, c.args.u32())));
}
B32_THUNK(_wcsstr) {
    GuestAddr s = c.args.ptr();
    const wchar_t *find = hostWide(c, c.args.ptr());
    c.ret(guestWide(s, hostWide(c, s), std::wcsstr(hostWide(c, s), find)));
}
B32_THUNK(_wcslcpy) {
    wchar_t *dst = hostWide(c, c.args.ptr());
    const wchar_t *src = hostWide(c, c.args.ptr());
    c.ret(uint32_t(::wcslcpy(dst, src, c.args.u32())));
}
B32_THUNK(_wcslcat) {
    wchar_t *dst = hostWide(c, c.args.ptr());
    const wchar_t *src = hostWide(c, c.args.ptr());
    c.ret(uint32_t(::wcslcat(dst, src, c.args.u32())));
}
