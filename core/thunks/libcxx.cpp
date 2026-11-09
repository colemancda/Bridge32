// The few out-of-line parts of LLVM's libc++ (iOS 6+) that apps call: most
// of the library is templates compiled into the app. There's no guest build
// of libc++ to load, so these work on guest memory directly, in the 32-bit
// layouts the app's inline code also uses. (Compiled out for the PowerPC guest:
// libc++ came with Mac OS X 10.7, which never ran on a PowerPC, and these copy
// wide characters in the host's byte order.)
//
// std::wstring (12 bytes, libc++'s standard layout on armv7):
//   long:  { capacity + 1 | 1, size, wchar_t *data }
//   short: { (size << 1) in the first byte, wchar_t data[2] at offset 4 }
// The low bit of the first byte tells them apart. Buffers come from operator
// new, which is the guest heap.

#if !defined(B32_GUEST_BIG_ENDIAN)

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <algorithm>
#include <cstring>
#include <vector>

using namespace b32;

namespace {

constexpr uint32_t kShortCapacity = 1;  // (12 - 1) / sizeof(wchar_t) - 1

struct WString {
    Call &c;
    GuestAddr self;

    bool isLong() const { return c.mem.read<uint8_t>(self) & 1; }
    uint32_t size() const { return isLong() ? c.mem.read<uint32_t>(self + 4) : c.mem.read<uint8_t>(self) >> 1; }
    uint32_t capacity() const { return isLong() ? (c.mem.read<uint32_t>(self) & ~1u) - 1 : kShortCapacity; }
    GuestAddr data() const { return isLong() ? c.mem.read<uint32_t>(self + 8) : self + 4; }

    std::vector<uint32_t> chars() const {
        std::vector<uint32_t> v(size());
        if (!v.empty()) std::memcpy(v.data(), c.mem.ptr<void>(data()), v.size() * 4);
        return v;
    }

    // libc++'s __recommend: room for 16-byte multiples of characters.
    static uint32_t recommend(uint32_t n) { return n <= kShortCapacity ? kShortCapacity : ((n + 1 + 3) & ~3u) - 1; }

    void setSize(uint32_t n) {
        if (isLong()) c.mem.write<uint32_t>(self + 4, n);
        else c.mem.write<uint8_t>(self, uint8_t(n << 1));
        c.mem.write<uint32_t>(data() + n * 4, 0);
    }

    // Makes the contents `text`, growing the buffer if it doesn't fit.
    void assign(const std::vector<uint32_t> &text) {
        uint32_t n = uint32_t(text.size());
        if (n > capacity()) {
            uint32_t cap = recommend(n);
            GuestAddr buffer = c.heap.alloc((cap + 1) * 4);
            if (isLong()) c.heap.free(data());
            c.mem.write<uint32_t>(self, (cap + 1) | 1);
            c.mem.write<uint32_t>(self + 8, buffer);
        }
        if (n) std::memcpy(c.mem.ptr<void>(data()), text.data(), n * 4);
        setSize(n);
    }
};

}  // namespace

// void basic_string<wchar_t>::__init(const wchar_t *s, size_t n): constructs.
B32_THUNK(__ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE6__initEPKwm) {
    GuestAddr self = c.args.ptr(), s = c.args.ptr();
    uint32_t n = c.args.u32();
    std::vector<uint32_t> text(n);
    if (n) std::memcpy(text.data(), c.mem.ptr<void>(s), n * 4);
    c.mem.write<uint8_t>(self, 0);  // starts empty and short
    WString{c, self}.assign(text);
}

B32_THUNK(__ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEED1Ev) {
    GuestAddr self = c.args.ptr();
    WString w{c, self};
    if (w.isLong()) c.heap.free(w.data());
    c.ret(self);
}

B32_THUNK(__ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE9push_backEw) {
    GuestAddr self = c.args.ptr();
    uint32_t ch = c.args.u32();
    WString w{c, self};
    std::vector<uint32_t> text = w.chars();
    text.push_back(ch);
    w.assign(text);
}

// basic_string &erase(size_type pos, size_type n)
B32_THUNK(__ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE5eraseEmm) {
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32(), n = c.args.u32();
    WString w{c, self};
    std::vector<uint32_t> text = w.chars();
    if (pos > text.size()) fatal("std::wstring::erase out of range");
    n = std::min<uint32_t>(n, uint32_t(text.size()) - pos);
    text.erase(text.begin() + pos, text.begin() + pos + n);
    w.assign(text);
    c.ret(self);
}

// basic_string &replace(size_type pos, size_type n1, const wchar_t *s, size_type n2)
B32_THUNK(__ZNSt3__112basic_stringIwNS_11char_traitsIwEENS_9allocatorIwEEE7replaceEmmPKwm) {
    GuestAddr self = c.args.ptr();
    uint32_t pos = c.args.u32(), n1 = c.args.u32();
    GuestAddr s = c.args.ptr();
    uint32_t n2 = c.args.u32();
    WString w{c, self};
    std::vector<uint32_t> text = w.chars();
    if (pos > text.size()) fatal("std::wstring::replace out of range");
    n1 = std::min<uint32_t>(n1, uint32_t(text.size()) - pos);
    std::vector<uint32_t> insert(n2);
    if (n2) std::memcpy(insert.data(), c.mem.ptr<void>(s), n2 * 4);  // s may point into the string itself
    text.erase(text.begin() + pos, text.begin() + pos + n1);
    text.insert(text.begin() + pos, insert.begin(), insert.end());
    w.assign(text);
    c.ret(self);
}

B32_THUNK(__ZNKSt3__121__basic_string_commonILb1EE20__throw_length_errorEv) { fatal("guest std::string length error"); }
B32_THUNK(__ZNKSt3__120__vector_base_commonILb1EE20__throw_length_errorEv) { fatal("guest std::vector length error"); }

// --- exceptions ----------------------------------------------------------------------------------
// Guest C++ exceptions don't unwind yet; these let code that never throws run.

namespace {
GuestAddr terminateHandler = 0;
}
B32_THUNK(__ZSt13set_terminatePFvvE) {
    GuestAddr previous = terminateHandler;
    terminateHandler = c.args.ptr();
    c.ret(previous);
}
// std::exception_ptr is one pointer, never set here: there's no current exception.
B32_THUNK(__ZSt17current_exceptionv) { c.mem.write<uint32_t>(c.args.ptr(), 0); }
B32_THUNK(__ZNSt13exception_ptrC1ERKS_) {
    GuestAddr self = c.args.ptr(), other = c.args.ptr();
    c.mem.write<uint32_t>(self, c.mem.read<uint32_t>(other));
    c.ret(self);
}
B32_THUNK(__ZNSt13exception_ptrD1Ev) { c.ret(c.args.ptr()); }
B32_THUNK(__ZSt17rethrow_exceptionSt13exception_ptr) { fatal("guest rethrew a C++ exception; they aren't supported yet"); }

// Type info the app's own type info points at (the rest is in cxxabi.cpp).
B32_DATA(__ZTVN10__cxxabiv119__pointer_type_infoE, 64) {}
B32_DATA(__ZTISt9exception, 8) {
    rt.mem().write<uint32_t>(addr, rt.dataSymbol("__ZTVN10__cxxabiv117__class_type_infoE") + 8);
    rt.mem().write<uint32_t>(addr + 4, rt.internString("St9exception"));
}

#endif  // !B32_GUEST_BIG_ENDIAN
