// GCC's copy-on-write std::wstring for i386 Mac guests. wchar_t is 32 bits on
// both sides, so a guest's characters can be read in place. See
// libstdcxx_cow.h for the layout.

#include "libstdcxx_cow.h"

using namespace b32;

namespace {
struct Wide : CowStrings<wchar_t> {
    explicit Wide(Call &call) : CowStrings(call, "__ZNSbIwSt11char_traitsIwESaIwEE4_Rep20_S_empty_rep_storageE") {}
};

// A guest's NUL-terminated string, copied so it can't alias the string it's spliced into.
std::wstring text(Call &c, GuestAddr p) {
    std::wstring out;
    for (;; p += 4) {
        wchar_t ch = c.mem.read<wchar_t>(p);
        if (!ch) return out;
        out.push_back(ch);
    }
}
std::wstring text(Call &c, GuestAddr p, uint32_t n) { return std::wstring(c.mem.ptr<wchar_t>(p), n); }
std::wstring_view one(const wchar_t &ch) { return {&ch, 1}; }
}  // namespace

B32_DATA(__ZNSbIwSt11char_traitsIwESaIwEE4_Rep20_S_empty_rep_storageE, 16) {}

B32_THUNK(__ZNSaIwEC1Ev) {}
B32_THUNK(__ZNSaIwEC1ERKS_) {}
B32_THUNK(__ZNSaIwEC2ERKS_) {}
B32_THUNK(__ZNSaIwED1Ev) {}
B32_THUNK(__ZNSaIwED2Ev) {}

B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEC1Ev) { c.mem.write<uint32_t>(c.args.ptr(), Wide(c).emptyData); }
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEC1EPKwRKS1_) {
    GuestAddr self = c.args.ptr();
    c.mem.write<uint32_t>(self, Wide(c).make(text(c, c.args.ptr())));
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEC1EPKwmRKS1_) {
    GuestAddr self = c.args.ptr(), from = c.args.ptr();
    c.mem.write<uint32_t>(self, Wide(c).make(text(c, from, c.args.u32())));
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEC1ERKS2_) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    c.mem.write<uint32_t>(self, s.share(s.data(c.args.ptr())));
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEC1EmwRKS1_) {
    GuestAddr self = c.args.ptr();
    uint32_t n = c.args.u32();
    c.mem.write<uint32_t>(self, Wide(c).make(std::wstring(n, wchar_t(c.args.u32()))));
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEED1Ev) {
    Wide s(c);
    s.release(s.data(c.args.ptr()));
}

B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE4sizeEv) { c.ret(uint32_t(Wide(c).view(c.args.ptr()).size())); }
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE6lengthEv) { c.ret(uint32_t(Wide(c).view(c.args.ptr()).size())); }
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE5emptyEv) { c.ret(Wide(c).view(c.args.ptr()).empty()); }
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE5c_strEv) { c.ret(c.mem.read<uint32_t>(c.args.ptr())); }
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEEixEm) {
    GuestAddr d = c.mem.read<uint32_t>(c.args.ptr());
    c.ret(d + c.args.u32() * 4);
}
// A reverse_iterator has a copy constructor, so it comes back through a hidden pointer.
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE6rbeginEv) {
    Wide s(c);
    GuestAddr out = c.args.ptr(), d = s.data(c.args.ptr());
    c.mem.write<uint32_t>(out, d + s.length(d) * 4);
    c.ret(out);
    c.cpu.popStructPointer();
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE4rendEv) {
    Wide s(c);
    GuestAddr out = c.args.ptr();
    c.mem.write<uint32_t>(out, s.data(c.args.ptr()));
    c.ret(out);
    c.cpu.popStructPointer();
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE6substrEmm) {
    Wide s(c);
    GuestAddr out = c.args.ptr(), self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    c.mem.write<uint32_t>(out, s.make(s.view(self).substr(pos, n)));
    c.ret(out);
    c.cpu.popStructPointer();
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE4findEPKwm) {
    Wide s(c);
    GuestAddr self = c.args.ptr(), what = c.args.ptr();
    c.ret(found(s.view(self).find(text(c, what), c.args.u32())));
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE4findEwm) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    c.ret(found(s.view(self).find(ch, c.args.u32())));
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE5rfindEwm) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    c.ret(found(s.view(self).rfind(ch, hostPos(c.args.u32()))));
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE13find_first_ofEwm) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    c.ret(found(s.view(self).find_first_of(ch, c.args.u32())));
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE7compareEPKw) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    c.ret(uint32_t(s.view(self).compare(text(c, c.args.ptr()))));
}
B32_THUNK(__ZNKSbIwSt11char_traitsIwESaIwEE7compareERKS2_) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    c.ret(uint32_t(s.view(self).compare(s.view(c.args.ptr()))));
}

// Every mutator returns *this, and copies its source first: it may be this string.
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE6appendEPKw) {
    GuestAddr self = c.args.ptr();
    Wide(c).append(self, text(c, c.args.ptr()));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE6appendEPKwm) {
    GuestAddr self = c.args.ptr(), from = c.args.ptr();
    Wide(c).append(self, text(c, from, c.args.u32()));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE6appendERKS2_) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    s.append(self, std::wstring(s.view(c.args.ptr())));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE6appendEmw) {
    GuestAddr self = c.args.ptr();
    uint32_t n = c.args.u32();
    Wide(c).append(self, std::wstring(n, wchar_t(c.args.u32())));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEpLEPKw) {
    GuestAddr self = c.args.ptr();
    Wide(c).append(self, text(c, c.args.ptr()));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEpLERKS2_) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    s.append(self, std::wstring(s.view(c.args.ptr())));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEpLEw) {
    GuestAddr self = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    Wide(c).append(self, one(ch));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE9push_backEw) {
    GuestAddr self = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    Wide(c).append(self, one(ch));
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEaSEPKw) {
    GuestAddr self = c.args.ptr();
    Wide(c).assign(self, text(c, c.args.ptr()));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEaSEw) {
    GuestAddr self = c.args.ptr();
    wchar_t ch = wchar_t(c.args.u32());
    Wide(c).assign(self, one(ch));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEaSERKS2_) {
    Wide s(c);
    GuestAddr self = c.args.ptr(), other = c.args.ptr();
    if (s.data(self) != s.data(other)) s.set(self, s.share(s.data(other)));
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE5clearEv) { Wide(c).assign(c.args.ptr(), {}); }
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE6resizeEm) {
    GuestAddr self = c.args.ptr();
    Wide(c).resize(self, c.args.u32(), 0);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE7reserveEm) {
    GuestAddr self = c.args.ptr();
    Wide(c).reserve(self, c.args.u32());
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE5eraseEmm) {
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32();
    Wide(c).splice(self, pos, c.args.u32(), {});
    c.ret(self);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE7replaceEmmRKS2_) {
    Wide s(c);
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    s.splice(self, pos, n, std::wstring(s.view(c.args.ptr())));
    c.ret(self);
}

// The mutable accessors. Iterators are one pointer and come back in EAX.
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEEixEm) {
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32();
    c.ret(Wide(c).leak(self) + pos * 4);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE5beginEv) { c.ret(Wide(c).leak(c.args.ptr())); }
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE3endEv) {
    Wide s(c);
    GuestAddr d = s.leak(c.args.ptr());
    c.ret(d + s.length(d) * 4);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE5eraseEN9__gnu_cxx17__normal_iteratorIPwS2_EE) {
    Wide s(c);
    GuestAddr self = c.args.ptr(), it = c.args.ptr();
    uint32_t pos = (it - s.data(self)) / 4;
    s.splice(self, pos, 1, {});
    c.ret(s.leak(self) + pos * 4);
}
B32_THUNK(__ZNSbIwSt11char_traitsIwESaIwEE5eraseEN9__gnu_cxx17__normal_iteratorIPwS2_EES6_) {
    Wide s(c);
    GuestAddr self = c.args.ptr(), first = c.args.ptr(), last = c.args.ptr();
    uint32_t pos = (first - s.data(self)) / 4;
    s.splice(self, pos, (last - first) / 4, {});
    c.ret(s.leak(self) + pos * 4);
}
