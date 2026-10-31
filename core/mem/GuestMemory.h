// Guest address space: one 4 GiB host reservation, so a guest address p lives
// at host address base() + p and host code can use guest buffers in place.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>

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

    template <typename T> T *ptr(GuestAddr addr) const {
        return reinterpret_cast<T *>(base_ + addr);
    }
    template <typename T> T read(GuestAddr addr) const {
        T value;
        std::memcpy(&value, base_ + addr, sizeof(T));
        return value;
    }
    template <typename T> void write(GuestAddr addr, T value) {
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
    uint8_t *base_ = nullptr;
    // One bit per page: committed or not.
    uint8_t *committed_ = nullptr;
};

}  // namespace b32
