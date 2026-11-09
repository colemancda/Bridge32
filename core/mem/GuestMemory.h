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
        static_assert(std::is_void_v<T> || sizeof(T) == 1,
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
