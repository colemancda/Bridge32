// Guest address space: one 4 GiB host reservation, so a guest address p lives
// at host address base() + p and host code can use guest buffers in place.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

namespace b32 {

using GuestAddr = uint32_t;

class GuestMemory {
public:
    static constexpr uint64_t kSize = 1ull << 32;
    static constexpr uint32_t kPageSize = 0x4000;  // host page size on arm64

    GuestMemory();
    ~GuestMemory();
    GuestMemory(const GuestMemory &) = delete;
    GuestMemory &operator=(const GuestMemory &) = delete;

    uint8_t *base() const { return base_; }

    // Commits [addr, addr + size) read/write. Page 0 is never committable so
    // null dereferences in the guest fault.
    void map(GuestAddr addr, uint32_t size);
    bool isMapped(GuestAddr addr) const;

    // A pointer into guest memory for host code to use in place. For a
    // big-endian guest (B32_GUEST_BIG_ENDIAN) only bytes and opaque data may
    // be viewed this way: any wider T would be read with the wrong byte order,
    // so it doesn't compile; use read<T>, or copy through the type's own
    // field-by-field conversion.
    template <typename T> T *ptr(GuestAddr addr) const {
#if defined(B32_GUEST_BIG_ENDIAN)
        static_assert(sizeof(std::conditional_t<std::is_void_v<T>, char, T>) == 1,
                      "guest memory is big-endian: view it as bytes, or read<T>() the values");
#endif
        return reinterpret_cast<T *>(base_ + addr);
    }
    // Scalars are converted to and from the guest's byte order. Guest memory
    // itself stays in the guest's order, so whatever the JIT stores and the
    // host copies in and out agree.
    template <typename T> T read(GuestAddr addr) const {
        T value;
        std::memcpy(&value, base_ + addr, sizeof(T));
        return swapped(value);
    }
    template <typename T> void write(GuestAddr addr, T value) {
        value = swapped(value);
        std::memcpy(base_ + addr, &value, sizeof(T));
    }
    // A scalar as the guest stores it, for host code that builds bytes in the
    // guest's order itself (a reply copied out with copyIn).
    template <typename T> static T inGuestOrder(T value) { return swapped(value); }

    // Arrays of scalars, converted element by element: what a host call that
    // wants a native array (UTF-16 text, glyphs, floats) gets, and what it
    // returns goes back through writeArray.
    template <typename T> std::vector<T> readArray(GuestAddr addr, size_t count) const {
        std::vector<T> values(count);
        for (size_t i = 0; i < count; i++) values[i] = read<T>(addr + GuestAddr(i * sizeof(T)));
        return values;
    }
    template <typename T> void writeArray(GuestAddr addr, const T *values, size_t count) {
        for (size_t i = 0; i < count; i++) write<T>(addr + GuestAddr(i * sizeof(T)), values[i]);
    }
    // A host struct or array that is nothing but 32-bit words (a Mach info
    // structure, a tm's ints), to and from the guest's byte order.
    void writeWords(GuestAddr addr, const void *words, size_t bytes) {
        const uint32_t *w = static_cast<const uint32_t *>(words);
        for (size_t i = 0; i < bytes / 4; i++) write<uint32_t>(addr + GuestAddr(i * 4), w[i]);
    }
    void readWords(GuestAddr addr, void *words, size_t bytes) const {
        uint32_t *w = static_cast<uint32_t *>(words);
        for (size_t i = 0; i < bytes / 4; i++) w[i] = read<uint32_t>(addr + GuestAddr(i * 4));
    }
    // A NUL-terminated string of the guest's wchar_t (4 bytes on the Mac), as
    // the host's, and the reverse, terminator included.
    std::wstring readWide(GuestAddr addr) const {
        std::wstring text;
        for (;; addr += 4) {
            wchar_t ch = wchar_t(read<uint32_t>(addr));
            if (!ch) return text;
            text.push_back(ch);
        }
    }
    void writeWide(GuestAddr addr, const std::wstring &text) {
        for (wchar_t ch : text) {
            write<uint32_t>(addr, uint32_t(ch));
            addr += 4;
        }
        write<uint32_t>(addr, 0);
    }

    // Atomic operations on a 4 or 8-byte guest word, in the guest's byte
    // order: the host's atomic instructions on the raw storage, with the value
    // converted around them. atomicUpdate returns the previous value; `f` maps
    // the old value to the new one and may run more than once.
    template <typename T, typename F> T atomicUpdate(GuestAddr addr, F f) {
        static_assert(sizeof(T) == 4 || sizeof(T) == 8);
        T *word = reinterpret_cast<T *>(base_ + addr);
        T raw = __atomic_load_n(word, __ATOMIC_RELAXED);
        for (;;) {
            T old = swapped(raw);
            T next = swapped(T(f(old)));
            if (__atomic_compare_exchange_n(word, &raw, next, true, __ATOMIC_SEQ_CST, __ATOMIC_RELAXED)) return old;
        }
    }
    // Stores `desired` if the word holds `expected`; whether it did.
    template <typename T> bool atomicCompareExchange(GuestAddr addr, T expected, T desired) {
        static_assert(sizeof(T) == 4 || sizeof(T) == 8);
        T *word = reinterpret_cast<T *>(base_ + addr);
        T raw = swapped(expected);
        return __atomic_compare_exchange_n(word, &raw, swapped(desired), false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }
    template <typename T> T atomicLoad(GuestAddr addr) const {
        static_assert(sizeof(T) == 4 || sizeof(T) == 8);
        return swapped(__atomic_load_n(reinterpret_cast<const T *>(base_ + addr), __ATOMIC_SEQ_CST));
    }
    template <typename T> void atomicStore(GuestAddr addr, T value) {
        static_assert(sizeof(T) == 4 || sizeof(T) == 8);
        __atomic_store_n(reinterpret_cast<T *>(base_ + addr), swapped(value), __ATOMIC_SEQ_CST);
    }

    void copyIn(GuestAddr dst, const void *src, size_t size) {
        std::memcpy(base_ + dst, src, size);
    }

    const char *cstr(GuestAddr addr) const {
        return reinterpret_cast<const char *>(base_ + addr);
    }

    // Converts a host pointer that points into the reservation back to a guest
    // address. Aborts for pointers outside it.
    GuestAddr guestAddrOf(const void *host) const;

private:
    // Reverses the bytes of a scalar when the guest is big-endian; decided at
    // compile time, so the other guests are unchanged.
    template <typename T> static T swapped(T value) {
#if defined(B32_GUEST_BIG_ENDIAN)
        static_assert(std::is_trivially_copyable_v<T>);
        if constexpr (sizeof(T) > 1) {
            uint8_t bytes[sizeof(T)];
            std::memcpy(bytes, &value, sizeof(T));
            for (size_t i = 0; i < sizeof(T) / 2; i++) std::swap(bytes[i], bytes[sizeof(T) - 1 - i]);
            std::memcpy(&value, bytes, sizeof(T));
        }
#endif
        return value;
    }

    uint8_t *base_ = nullptr;
    // One bit per page: committed or not.
    uint8_t *committed_ = nullptr;
};

}  // namespace b32
