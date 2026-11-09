// GCC's copy-on-write basic_string representation, shared by the char and
// wchar_t shims. A string is one pointer to its characters, preceded in memory
// by { length, capacity, refcount }; inline guest code reads and shares these,
// so the layout is GCC's exactly. A refcount of 0 means one owner, and -1 that
// a reference to a character escaped, so the string must be copied rather than
// shared.
#pragma once

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <string_view>

namespace b32 {

constexpr uint32_t kRepHeader = 12, kNpos = 0xFFFFFFFF;

inline uint32_t found(size_t at) { return at == std::string_view::npos ? kNpos : uint32_t(at); }
inline size_t hostPos(uint32_t pos) { return pos == kNpos ? std::string_view::npos : pos; }

template <typename Ch>
struct CowStrings {
    using View = std::basic_string_view<Ch>;
    static constexpr uint32_t kUnit = sizeof(Ch);

    Call &c;
    GuestAddr emptyData = 0;

    CowStrings(Call &call, const char *emptySymbol) : c(call) { emptyData = c.rt.dataSymbol(emptySymbol) + kRepHeader; }

    GuestAddr data(GuestAddr self) const { return c.mem.template read<uint32_t>(self); }
    uint32_t length(GuestAddr d) const { return c.mem.template read<uint32_t>(d - 12); }
    uint32_t capacity(GuestAddr d) const { return c.mem.template read<uint32_t>(d - 8); }
    int32_t refcount(GuestAddr d) const { return c.mem.template read<int32_t>(d - 4); }
    // Adds to the refcount atomically; returns what it was.
    int32_t addRef(GuestAddr d, int32_t delta) const {
        return int32_t(c.mem.template atomicUpdate<uint32_t>(d - 4, [&](uint32_t v) { return v + uint32_t(delta); }));
    }
    Ch *chars(GuestAddr d) const { return c.mem.template ptr<Ch>(d); }
    View at(GuestAddr d) const { return {chars(d), length(d)}; }
    View view(GuestAddr self) const { return at(data(self)); }

    GuestAddr allocate(uint32_t cap) {
        GuestAddr rep = c.heap.alloc(kRepHeader + (cap + 1) * kUnit);
        c.mem.template write<uint32_t>(rep + 4, cap);
        c.mem.template write<int32_t>(rep + 8, 0);
        return rep + kRepHeader;
    }
    void setLength(GuestAddr d, uint32_t n) {
        c.mem.template write<uint32_t>(d - 12, n);
        c.mem.template write<Ch>(d + n * kUnit, Ch(0));
    }
    GuestAddr make(View text, uint32_t cap = 0) {
        if (text.empty() && !cap) return emptyData;
        GuestAddr d = allocate(std::max(uint32_t(text.size()), cap));
        std::memcpy(chars(d), text.data(), text.size() * kUnit);
        setLength(d, uint32_t(text.size()));
        return d;
    }
    void release(GuestAddr d) {
        if (d == emptyData) return;
        if (addRef(d, -1) <= 0) c.heap.free(d - kRepHeader);
    }
    // What a copy of the string at `d` should point at.
    GuestAddr share(GuestAddr d) {
        if (d == emptyData) return d;
        if (refcount(d) < 0) return make(at(d));
        addRef(d, 1);
        return d;
    }
    void set(GuestAddr self, GuestAddr d) {
        GuestAddr old = data(self);
        c.mem.template write<uint32_t>(self, d);
        release(old);
    }
    // Replaces [pos, pos + n) with text, in place when the string is unshared
    // and has the room. `text` must not point into the string.
    void splice(GuestAddr self, uint32_t pos, uint32_t n, View text) {
        GuestAddr d = data(self);
        uint32_t len = length(d);
        if (pos > len) fatal("std::basic_string position %u past length %u (from 0x%08x)", pos, len, c.cpu.returnAddress());
        n = std::min(n, len - pos);
        uint32_t newLength = len - n + uint32_t(text.size());
        if (d != emptyData && refcount(d) <= 0 && capacity(d) >= newLength) {
            Ch *p = chars(d);
            std::memmove(p + pos + text.size(), p + pos + n, (len - pos - n) * kUnit);
            std::memcpy(p + pos, text.data(), text.size() * kUnit);
            setLength(d, newLength);
            c.mem.template write<int32_t>(d - 4, 0);
            return;
        }
        // As GCC's _S_create: double only to make room, or copying a shared
        // string before each edit would double it every time.
        GuestAddr fresh = allocate(d != emptyData && newLength > capacity(d) ? std::max(newLength, capacity(d) * 2) : newLength);
        const Ch *p = chars(d);
        Ch *q = chars(fresh);
        std::memcpy(q, p, pos * kUnit);
        std::memcpy(q + pos, text.data(), text.size() * kUnit);
        std::memcpy(q + pos + text.size(), p + pos + n, (len - pos - n) * kUnit);
        setLength(fresh, newLength);
        set(self, fresh);
    }
    void assign(GuestAddr self, View text) { splice(self, 0, kNpos, text); }
    void append(GuestAddr self, View text) { splice(self, uint32_t(view(self).size()), 0, text); }
    void resize(GuestAddr self, uint32_t n, Ch fill) {
        uint32_t len = uint32_t(view(self).size());
        if (n <= len)
            splice(self, n, len - n, {});
        else
            append(self, std::basic_string<Ch>(n - len, fill));
    }
    void reserve(GuestAddr self, uint32_t wanted) {
        GuestAddr d = data(self);
        if (d == emptyData ? wanted : (wanted > capacity(d) || refcount(d) > 0))
            set(self, make(at(d), std::max(wanted, length(d))));
    }
    // Marks the string as having a reference to its characters at large, and
    // returns them: anything that hands out a mutable iterator does this.
    GuestAddr leak(GuestAddr self) {
        GuestAddr d = data(self);
        if (d == emptyData || refcount(d) < 0) return d;
        if (refcount(d) > 0) {
            set(self, make(at(d), capacity(d)));
            d = data(self);
        }
        c.mem.template write<int32_t>(d - 4, -1);
        return d;
    }
};

}  // namespace b32
