// GCC's copy-on-write std::string for i386 Mac guests, which link the system's
// libstdc++ and no longer have one to run. See libstdcxx_cow.h for the layout.

#include "libstdcxx_cow.h"

using namespace b32;

namespace {
struct Strings : CowStrings<char> {
    explicit Strings(Call &call) : CowStrings(call, "__ZNSs4_Rep20_S_empty_rep_storageE") {}
};

std::string cstring(Call &c, GuestAddr p) { return c.mem.cstr(p); }
std::string bytes(Call &c, GuestAddr p, uint32_t n) { return std::string(c.mem.ptr<char>(p), n); }
}  // namespace

B32_THUNK(__ZNSaIcEC1Ev) {}
B32_THUNK(__ZNSaIcED1Ev) {}
B32_THUNK(__ZNSaIcED2Ev) {}
B32_THUNK(__ZNSaIcEC1ERKS_) {}
B32_THUNK(__ZNSaIcEC2ERKS_) {}

B32_THUNK(__ZNSsC1Ev) {
    Strings s(c);
    c.mem.write<uint32_t>(c.args.ptr(), s.emptyData);
}
// basic_string(const char *, const allocator &)
B32_THUNK(__ZNSsC1EPKcRKSaIcE) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    c.mem.write<uint32_t>(self, s.make(cstring(c, c.args.ptr())));
}
B32_THUNK(__ZNSsC1ERKSs) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), other = c.args.ptr();
    c.mem.write<uint32_t>(self, s.share(s.data(other)));
}
// basic_string(const string &, pos, n)
B32_THUNK(__ZNSsC1ERKSsmm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), other = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    c.mem.write<uint32_t>(self, s.make(s.view(other).substr(pos, n)));
}

// _Rep *_Rep::_S_create(size_type capacity, size_type old_capacity, const allocator &)
B32_THUNK(__ZNSs4_Rep9_S_createEmmRKSaIcE) {
    Strings s(c);
    c.ret(s.allocate(c.args.u32()) - kRepHeader);
}
B32_THUNK(__ZNSs4_Rep10_M_destroyERKSaIcE) { c.heap.free(c.args.ptr()); }

B32_THUNK(__ZNSs12_M_leak_hardEv) { Strings(c).leak(c.args.ptr()); }

B32_THUNK(__ZNKSs4sizeEv) { c.ret(Strings(c).view(c.args.ptr()).size()); }
B32_THUNK(__ZNKSs6lengthEv) { c.ret(Strings(c).view(c.args.ptr()).size()); }
B32_THUNK(__ZNKSs5emptyEv) { c.ret(Strings(c).view(c.args.ptr()).empty()); }
B32_THUNK(__ZNKSs5c_strEv) { c.ret(c.mem.read<uint32_t>(c.args.ptr())); }
B32_THUNK(__ZNKSsixEm) {
    GuestAddr d = c.mem.read<uint32_t>(c.args.ptr());
    c.ret(d + c.args.u32());
}
B32_THUNK(__ZNSs2atEm) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32();
    if (pos >= s.view(self).size()) fatal("std::string::at(%u) out of range", pos);
    c.ret(s.data(self) + pos);
}

// string substr(pos, n) const: a class result comes through a hidden pointer.
B32_THUNK(__ZNKSs6substrEmm) {
    Strings s(c);
    GuestAddr out = c.args.ptr(), self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    c.mem.write<uint32_t>(out, s.make(s.view(self).substr(pos, n)));
    c.ret(out);
    c.cpu.popStructPointer();
}

B32_THUNK(__ZNKSs4findEPKcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), text = c.args.ptr();
    c.ret(found(s.view(self).find(cstring(c, text), c.args.u32())));
}
B32_THUNK(__ZNKSs4findEPKcmm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), text = c.args.ptr();
    uint32_t pos = c.args.u32();
    c.ret(found(s.view(self).find(bytes(c, text, c.args.u32()), pos)));
}
B32_THUNK(__ZNKSs4findEcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    char ch = char(c.args.u32());
    c.ret(found(s.view(self).find(ch, c.args.u32())));
}
B32_THUNK(__ZNKSs5rfindEcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    char ch = char(c.args.u32());
    uint32_t pos = c.args.u32();
    c.ret(found(s.view(self).rfind(ch, pos == kNpos ? std::string_view::npos : pos)));
}
B32_THUNK(__ZNKSs12find_last_ofEPKcmm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), text = c.args.ptr();
    uint32_t pos = c.args.u32();
    std::string set = bytes(c, text, c.args.u32());
    c.ret(found(s.view(self).find_last_of(set, pos == kNpos ? std::string_view::npos : pos)));
}
B32_THUNK(__ZNKSs12find_last_ofEcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    char ch = char(c.args.u32());
    c.ret(found(s.view(self).find_last_of(ch, hostPos(c.args.u32()))));
}
B32_THUNK(__ZNKSs13find_first_ofEPKcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), set = c.args.ptr();
    c.ret(found(s.view(self).find_first_of(cstring(c, set), c.args.u32())));
}
B32_THUNK(__ZNKSs7compareEPKc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    c.ret(uint32_t(s.view(self).compare(cstring(c, c.args.ptr()))));
}
B32_THUNK(__ZNKSs7compareERKSs) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    c.ret(uint32_t(s.view(self).compare(s.view(c.args.ptr()))));
}
B32_THUNK(__ZNKSs7compareEmmRKSs) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    c.ret(uint32_t(s.view(self).substr(pos, n).compare(s.view(c.args.ptr()))));
}

namespace {
// Every mutator returns *this. Sources are copied first: they may be this string.
void finish(Call &c, GuestAddr self) { c.ret(self); }
}  // namespace

B32_THUNK(__ZNSs6appendEPKcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), text = c.args.ptr();
    s.splice(self, uint32_t(s.view(self).size()), 0, bytes(c, text, c.args.u32()));
    finish(c, self);
}
B32_THUNK(__ZNSs6appendERKSs) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    s.splice(self, uint32_t(s.view(self).size()), 0, std::string(s.view(c.args.ptr())));
    finish(c, self);
}
B32_THUNK(__ZNSspLEPKc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    s.splice(self, uint32_t(s.view(self).size()), 0, cstring(c, c.args.ptr()));
    finish(c, self);
}
B32_THUNK(__ZNSspLERKSs) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    s.splice(self, uint32_t(s.view(self).size()), 0, std::string(s.view(c.args.ptr())));
    finish(c, self);
}
B32_THUNK(__ZNSspLEc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    char ch = char(c.args.u32());
    s.splice(self, uint32_t(s.view(self).size()), 0, std::string_view(&ch, 1));
    finish(c, self);
}
B32_THUNK(__ZNSs6assignEPKcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), text = c.args.ptr();
    s.assign(self, bytes(c, text, c.args.u32()));
    finish(c, self);
}
namespace {
void assignString(Call &c) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), other = c.args.ptr();
    if (s.data(self) != s.data(other)) s.set(self, s.share(s.data(other)));
    finish(c, self);
}
}  // namespace
B32_THUNK(__ZNSs6assignERKSs) { assignString(c); }
B32_THUNK(__ZNSsaSERKSs) { assignString(c); }
B32_THUNK(__ZNSsaSEPKc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    s.assign(self, cstring(c, c.args.ptr()));
    finish(c, self);
}
B32_THUNK(__ZNSs5eraseEmm) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32();
    s.splice(self, pos, c.args.u32(), {});
    finish(c, self);
}
B32_THUNK(__ZNSs7replaceEmmPKc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    s.splice(self, pos, n, cstring(c, c.args.ptr()));
    finish(c, self);
}
B32_THUNK(__ZNSs7replaceEmmPKcm) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    GuestAddr text = c.args.ptr();
    s.splice(self, pos, n, bytes(c, text, c.args.u32()));
    finish(c, self);
}
B32_THUNK(__ZNSs7reserveEm) {
    GuestAddr self = c.args.ptr();
    Strings(c).reserve(self, c.args.u32());
}
B32_THUNK(__ZNSs5clearEv) { Strings(c).assign(c.args.ptr(), {}); }
B32_THUNK(__ZNSs6resizeEm) {
    GuestAddr self = c.args.ptr();
    Strings(c).resize(self, c.args.u32(), 0);
}
B32_THUNK(__ZNSs6appendEPKc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    s.append(self, cstring(c, c.args.ptr()));
    finish(c, self);
}
B32_THUNK(__ZNSs6appendEmc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t n = c.args.u32();
    s.append(self, std::string(n, char(c.args.u32())));
    finish(c, self);
}
B32_THUNK(__ZNSs9push_backEc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    char ch = char(c.args.u32());
    s.append(self, std::string_view(&ch, 1));
}
B32_THUNK(__ZNSsaSEc) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    char ch = char(c.args.u32());
    s.assign(self, std::string_view(&ch, 1));
    finish(c, self);
}

// The mutable accessors. Iterators are one pointer and come back in EAX.
B32_THUNK(__ZNSsixEm) {
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32();
    c.ret(Strings(c).leak(self) + pos);
}
B32_THUNK(__ZNSs5beginEv) { c.ret(Strings(c).leak(c.args.ptr())); }
B32_THUNK(__ZNSs3endEv) {
    Strings s(c);
    GuestAddr self = c.args.ptr();
    GuestAddr d = s.leak(self);
    c.ret(d + s.length(d));
}
B32_THUNK(__ZNSs5eraseEN9__gnu_cxx17__normal_iteratorIPcSsEE) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), it = c.args.ptr();
    uint32_t pos = it - s.data(self);
    s.splice(self, pos, 1, {});
    c.ret(s.leak(self) + pos);
}
B32_THUNK(__ZNSs5eraseEN9__gnu_cxx17__normal_iteratorIPcSsEES2_) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), first = c.args.ptr(), last = c.args.ptr();
    uint32_t pos = first - s.data(self);
    s.splice(self, pos, last - first, {});
    c.ret(s.leak(self) + pos);
}
B32_THUNK(__ZNSs6insertEN9__gnu_cxx17__normal_iteratorIPcSsEEc) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), it = c.args.ptr();
    char ch = char(c.args.u32());
    uint32_t pos = it - s.data(self);
    s.splice(self, pos, 0, std::string_view(&ch, 1));
    c.ret(s.leak(self) + pos);
}
// replace(first, last, sourceFirst, sourceLast), mutable iterators throughout.
B32_THUNK(__ZNSs7replaceEN9__gnu_cxx17__normal_iteratorIPcSsEES2_S2_S2_) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), first = c.args.ptr(), last = c.args.ptr(), from = c.args.ptr(), to = c.args.ptr();
    s.splice(self, first - s.data(self), last - first, bytes(c, from, to - from));
    finish(c, self);
}

B32_DATA(__ZSt7nothrow, 1) {}
