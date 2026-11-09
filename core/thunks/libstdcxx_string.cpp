// GCC's copy-on-write std::string for i386 Mac guests, which link the system's
// libstdc++ and no longer have one to run. A string is one pointer to its
// characters, preceded in memory by { length, capacity, refcount }; inline
// guest code reads and shares these, so the layout is GCC's exactly. A
// refcount of 0 means one owner, and -1 that a reference to a character
// escaped, so the string must be copied rather than shared.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <string_view>

using namespace b32;

namespace {
constexpr uint32_t kRepHeader = 12, kNpos = 0xFFFFFFFF;

struct Strings {
    Call &c;
    GuestAddr emptyData = 0;

    explicit Strings(Call &call) : c(call) { emptyData = c.rt.dataSymbol("__ZNSs4_Rep20_S_empty_rep_storageE") + kRepHeader; }

    GuestAddr data(GuestAddr self) const { return c.mem.read<uint32_t>(self); }
    uint32_t length(GuestAddr d) const { return c.mem.read<uint32_t>(d - 12); }
    uint32_t capacity(GuestAddr d) const { return c.mem.read<uint32_t>(d - 8); }
    int32_t refcount(GuestAddr d) const { return c.mem.read<int32_t>(d - 4); }
    std::atomic<int32_t> &count(GuestAddr d) const { return *reinterpret_cast<std::atomic<int32_t> *>(c.mem.ptr<int32_t>(d - 4)); }
    std::string_view view(GuestAddr self) const {
        GuestAddr d = data(self);
        return {c.mem.ptr<char>(d), length(d)};
    }

    GuestAddr allocate(uint32_t capacity) {
        GuestAddr rep = c.heap.alloc(kRepHeader + capacity + 1);
        c.mem.write<uint32_t>(rep + 4, capacity);
        c.mem.write<int32_t>(rep + 8, 0);
        return rep + kRepHeader;
    }
    void setLength(GuestAddr d, uint32_t n) {
        c.mem.write<uint32_t>(d - 12, n);
        c.mem.write<uint8_t>(d + n, 0);
    }
    GuestAddr make(std::string_view text, uint32_t capacity = 0) {
        if (text.empty() && !capacity) return emptyData;
        GuestAddr d = allocate(std::max(uint32_t(text.size()), capacity));
        c.mem.copyIn(d, text.data(), text.size());
        setLength(d, uint32_t(text.size()));
        return d;
    }
    void release(GuestAddr d) {
        if (d == emptyData) return;
        if (count(d).fetch_sub(1) <= 0) c.heap.free(d - kRepHeader);
    }
    // What a copy of the string at `d` should point at.
    GuestAddr share(GuestAddr d) {
        if (d == emptyData) return d;
        if (refcount(d) < 0) return make({c.mem.ptr<char>(d), length(d)});
        count(d).fetch_add(1);
        return d;
    }
    void set(GuestAddr self, GuestAddr d) {
        GuestAddr old = data(self);
        c.mem.write<uint32_t>(self, d);
        release(old);
    }
    // Replaces [pos, pos + n) with text, in place when the string is unshared
    // and has the room. `text` must not point into the string.
    void splice(GuestAddr self, uint32_t pos, uint32_t n, std::string_view text) {
        GuestAddr d = data(self);
        uint32_t len = length(d);
        if (pos > len) fatal("std::string position %u past length %u (from 0x%08x)", pos, len, c.cpu.returnAddress());
        n = std::min(n, len - pos);
        uint32_t newLength = len - n + uint32_t(text.size());
        if (d != emptyData && refcount(d) <= 0 && capacity(d) >= newLength) {
            char *p = c.mem.ptr<char>(d);
            std::memmove(p + pos + text.size(), p + pos + n, len - pos - n);
            std::memcpy(p + pos, text.data(), text.size());
            setLength(d, newLength);
            c.mem.write<int32_t>(d - 4, 0);
            return;
        }
        GuestAddr fresh = allocate(std::max(newLength, d == emptyData ? newLength : capacity(d) * 2));
        const char *p = c.mem.ptr<char>(d);
        char *q = c.mem.ptr<char>(fresh);
        std::memcpy(q, p, pos);
        std::memcpy(q + pos, text.data(), text.size());
        std::memcpy(q + pos + text.size(), p + pos + n, len - pos - n);
        setLength(fresh, newLength);
        set(self, fresh);
    }
    void assign(GuestAddr self, std::string_view text) { splice(self, 0, kNpos, text); }
};

std::string cstring(Call &c, GuestAddr p) { return c.mem.cstr(p); }
std::string bytes(Call &c, GuestAddr p, uint32_t n) { return std::string(c.mem.ptr<char>(p), n); }
uint32_t found(size_t at) { return at == std::string_view::npos ? kNpos : uint32_t(at); }
}  // namespace

B32_THUNK(__ZNSaIcEC1Ev) {}
B32_THUNK(__ZNSaIcED1Ev) {}

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

B32_THUNK(__ZNSs12_M_leak_hardEv) {
    Strings s(c);
    GuestAddr self = c.args.ptr(), d = s.data(self);
    if (d == s.emptyData) return;
    if (s.refcount(d) > 0) {
        s.set(self, s.make({c.mem.ptr<char>(d), s.length(d)}, s.capacity(d)));
        d = s.data(self);
    }
    c.mem.write<int32_t>(d - 4, -1);
}

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
    Strings s(c);
    GuestAddr self = c.args.ptr();
    uint32_t wanted = c.args.u32();
    GuestAddr d = s.data(self);
    if (d == s.emptyData ? wanted : (wanted > s.capacity(d) || s.refcount(d) > 0))
        s.set(self, s.make({c.mem.ptr<char>(d), s.length(d)}, std::max(wanted, s.length(d))));
}

B32_DATA(__ZSt7nothrow, 1) {}
