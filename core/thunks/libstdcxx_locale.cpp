// The locale facets i386 Mac guests ask for by name. A locale is a single null
// pointer here and every one of them behaves as the C locale, which is what the
// system's libstdc++ gave a GUI app. Guests call a facet's members through its
// vtable, and read ctype<char>'s widen and narrow tables inline.
//
//   facet: vptr, refcount, size 8
//   ctype<char>: table 24, widen_ok 28, widen 29, narrow 285, narrow_ok 541

#include "libstdcxx_cow.h"

#include <cwchar>
#include <cwctype>

using namespace b32;

namespace {
constexpr uint32_t kCharWidenOk = 28, kCharWiden = 29, kCharNarrow = 285, kCharNarrowOk = 541;

void setVtable(Runtime &rt, GuestAddr facet, std::initializer_list<const char *> slots) {
    GuestAddr vtable = rt.heap().calloc(uint32_t(slots.size()) + 2, 4), slot = vtable + 8;
    for (const char *name : slots) {
        rt.mem().write<uint32_t>(slot, rt.thunks().stubFor(name));
        slot += 4;
    }
    rt.mem().write<uint32_t>(facet, vtable + 8);
    rt.mem().write<uint32_t>(facet + 4, 1);
}
}  // namespace

B32_THUNK(__ZNSt6localeC1EPKc) { c.mem.write<uint32_t>(c.args.ptr(), 0); }
B32_THUNK(__ZNSt9exceptionD2Ev) {}
B32_THUNK(__ZNKSt9exception4whatEv) { c.ret(c.rt.internString("std::exception")); }

B32_THUNK(__b32_facet_dtor) { c.ret(c.args.ptr()); }

// --- ctype<char>: { dtor, dtor, toupper, toupper range, tolower, tolower range,
//                    widen, widen range, narrow, narrow range } ---------------------

B32_THUNK(__b32_ctype_char_toupper) {
    c.args.ptr();
    c.ret(uint32_t(int8_t(std::toupper(uint8_t(c.args.u32())))));
}
B32_THUNK(__b32_ctype_char_tolower) {
    c.args.ptr();
    c.ret(uint32_t(int8_t(std::tolower(uint8_t(c.args.u32())))));
}
B32_THUNK(__b32_ctype_char_toupper_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    for (GuestAddr p = lo; p < hi; p++) c.mem.write<uint8_t>(p, uint8_t(std::toupper(c.mem.read<uint8_t>(p))));
    c.ret(hi);
}
B32_THUNK(__b32_ctype_char_tolower_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    for (GuestAddr p = lo; p < hi; p++) c.mem.write<uint8_t>(p, uint8_t(std::tolower(c.mem.read<uint8_t>(p))));
    c.ret(hi);
}
B32_THUNK(__b32_ctype_char_widen) {
    c.args.ptr();
    c.ret(uint32_t(int8_t(c.args.u32())));
}
B32_THUNK(__b32_ctype_char_widen_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr(), to = c.args.ptr();
    std::memmove(c.mem.ptr<char>(to), c.mem.ptr<char>(lo), hi - lo);
    c.ret(hi);
}
B32_THUNK(__b32_ctype_char_narrow) {
    c.args.ptr();
    c.ret(uint32_t(int8_t(c.args.u32())));
}
B32_THUNK(__b32_ctype_char_narrow_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    c.args.u32();
    GuestAddr to = c.args.ptr();
    std::memmove(c.mem.ptr<char>(to), c.mem.ptr<char>(lo), hi - lo);
    c.ret(hi);
}
B32_DATA(__b32_ctype_char, 544) {
    setVtable(rt, addr,
              {"__b32_facet_dtor", "__b32_facet_dtor", "__b32_ctype_char_toupper", "__b32_ctype_char_toupper_range",
               "__b32_ctype_char_tolower", "__b32_ctype_char_tolower_range", "__b32_ctype_char_widen",
               "__b32_ctype_char_widen_range", "__b32_ctype_char_narrow", "__b32_ctype_char_narrow_range"});
    for (uint32_t i = 0; i < 256; i++) {
        rt.mem().write<uint8_t>(addr + kCharWiden + i, uint8_t(i));
        rt.mem().write<uint8_t>(addr + kCharNarrow + i, uint8_t(i));
    }
    rt.mem().write<uint8_t>(addr + kCharWidenOk, 1);
    rt.mem().write<uint8_t>(addr + kCharNarrowOk, 1);
}
B32_THUNK(__ZSt9use_facetISt5ctypeIcEERKT_RKSt6locale) { c.ret(c.rt.dataSymbol("__b32_ctype_char")); }

// --- ctype<wchar_t>: { dtor, dtor, is, is range, scan_is, scan_not, toupper,
//                       toupper range, tolower, tolower range, widen, widen range,
//                       narrow, narrow range } -----------------------------------
// Darwin's ctype_base masks are its wctype_t values.

B32_THUNK(__b32_ctype_wide_is) {
    c.args.ptr();
    uint32_t mask = c.args.u32();
    c.ret(std::iswctype(wint_t(c.args.u32()), mask) != 0);
}
B32_THUNK(__b32_ctype_wide_is_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr(), out = c.args.ptr();
    static const uint32_t kClasses[] = {_CTYPE_U, _CTYPE_L, _CTYPE_A, _CTYPE_D, _CTYPE_X, _CTYPE_S, _CTYPE_R, _CTYPE_C, _CTYPE_P, _CTYPE_G};
    for (GuestAddr p = lo; p < hi; p += 4, out += 4) {
        uint32_t mask = 0;
        for (uint32_t bit : kClasses)
            if (std::iswctype(c.mem.read<uint32_t>(p), bit)) mask |= bit;
        c.mem.write<uint32_t>(out, mask);
    }
    c.ret(hi);
}
B32_THUNK(__b32_ctype_wide_scan_is) {
    c.args.ptr();
    uint32_t mask = c.args.u32();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    while (lo < hi && !std::iswctype(c.mem.read<uint32_t>(lo), mask)) lo += 4;
    c.ret(lo);
}
B32_THUNK(__b32_ctype_wide_scan_not) {
    c.args.ptr();
    uint32_t mask = c.args.u32();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    while (lo < hi && std::iswctype(c.mem.read<uint32_t>(lo), mask)) lo += 4;
    c.ret(lo);
}
B32_THUNK(__b32_ctype_wide_toupper) {
    c.args.ptr();
    c.ret(uint32_t(std::towupper(wint_t(c.args.u32()))));
}
B32_THUNK(__b32_ctype_wide_tolower) {
    c.args.ptr();
    c.ret(uint32_t(std::towlower(wint_t(c.args.u32()))));
}
B32_THUNK(__b32_ctype_wide_toupper_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    for (GuestAddr p = lo; p < hi; p += 4) c.mem.write<uint32_t>(p, std::towupper(c.mem.read<uint32_t>(p)));
    c.ret(hi);
}
B32_THUNK(__b32_ctype_wide_tolower_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    for (GuestAddr p = lo; p < hi; p += 4) c.mem.write<uint32_t>(p, std::towlower(c.mem.read<uint32_t>(p)));
    c.ret(hi);
}
B32_THUNK(__b32_ctype_wide_widen) {
    c.args.ptr();
    c.ret(c.args.u32() & 0xff);
}
B32_THUNK(__b32_ctype_wide_widen_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr(), to = c.args.ptr();
    for (GuestAddr p = lo; p < hi; p++, to += 4) c.mem.write<uint32_t>(to, c.mem.read<uint8_t>(p));
    c.ret(hi);
}
B32_THUNK(__b32_ctype_wide_narrow) {
    c.args.ptr();
    uint32_t ch = c.args.u32(), dfault = c.args.u32();
    c.ret(ch < 128 ? ch : dfault & 0xff);
}
B32_THUNK(__b32_ctype_wide_narrow_range) {
    c.args.ptr();
    GuestAddr lo = c.args.ptr(), hi = c.args.ptr();
    uint8_t dfault = uint8_t(c.args.u32());
    GuestAddr to = c.args.ptr();
    for (GuestAddr p = lo; p < hi; p += 4, to++) {
        uint32_t ch = c.mem.read<uint32_t>(p);
        c.mem.write<uint8_t>(to, ch < 128 ? uint8_t(ch) : dfault);
    }
    c.ret(hi);
}
B32_DATA(__b32_ctype_wide, 8) {
    setVtable(rt, addr,
              {"__b32_facet_dtor", "__b32_facet_dtor", "__b32_ctype_wide_is", "__b32_ctype_wide_is_range",
               "__b32_ctype_wide_scan_is", "__b32_ctype_wide_scan_not", "__b32_ctype_wide_toupper",
               "__b32_ctype_wide_toupper_range", "__b32_ctype_wide_tolower", "__b32_ctype_wide_tolower_range",
               "__b32_ctype_wide_widen", "__b32_ctype_wide_widen_range", "__b32_ctype_wide_narrow",
               "__b32_ctype_wide_narrow_range"});
}
B32_THUNK(__ZSt9use_facetISt5ctypeIwEERKT_RKSt6locale) { c.ret(c.rt.dataSymbol("__b32_ctype_wide")); }

// --- numpunct<wchar_t>: { dtor, dtor, decimal_point, thousands_sep, grouping,
//                          truename, falsename }, the C locale's values ----------

B32_THUNK(__b32_numpunct_decimal) { c.ret(uint32_t(L'.')); }
B32_THUNK(__b32_numpunct_thousands) { c.ret(uint32_t(L',')); }
B32_THUNK(__b32_numpunct_grouping) {
    GuestAddr out = c.args.ptr();
    CowStrings<char> s(c, "__ZNSs4_Rep20_S_empty_rep_storageE");
    c.mem.write<uint32_t>(out, s.emptyData);
    c.ret(out);
    c.cpu.popStructPointer();
}
namespace {
void wideResult(Call &c, std::wstring_view text) {
    GuestAddr out = c.args.ptr();
    CowStrings<wchar_t> s(c, "__ZNSbIwSt11char_traitsIwESaIwEE4_Rep20_S_empty_rep_storageE");
    c.mem.write<uint32_t>(out, s.make(text));
    c.ret(out);
    c.cpu.popStructPointer();
}
}  // namespace
B32_THUNK(__b32_numpunct_true) { wideResult(c, L"true"); }
B32_THUNK(__b32_numpunct_false) { wideResult(c, L"false"); }
B32_DATA(__b32_numpunct_wide, 16) {
    setVtable(rt, addr,
              {"__b32_facet_dtor", "__b32_facet_dtor", "__b32_numpunct_decimal", "__b32_numpunct_thousands",
               "__b32_numpunct_grouping", "__b32_numpunct_true", "__b32_numpunct_false"});
}
B32_THUNK(__ZSt9use_facetISt8numpunctIwEERKT_RKSt6locale) { c.ret(c.rt.dataSymbol("__b32_numpunct_wide")); }
