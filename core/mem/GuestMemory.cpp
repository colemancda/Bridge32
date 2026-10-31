#include "GuestMemory.h"

#include "core/Log.h"

#include <sys/mman.h>

namespace b32 {

GuestMemory::GuestMemory() {
    void *p = mmap(nullptr, kSize, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) fatal("could not reserve 4 GiB guest address space");
    base_ = static_cast<uint8_t *>(p);
    committed_ = new uint8_t[kSize / kPageSize / 8]();
}

GuestMemory::~GuestMemory() {
    munmap(base_, kSize);
    delete[] committed_;
}

void GuestMemory::map(GuestAddr addr, uint32_t size) {
    if (size == 0) return;
    uint64_t start = addr & ~uint64_t(kPageSize - 1);
    uint64_t end = (uint64_t(addr) + size + kPageSize - 1) & ~uint64_t(kPageSize - 1);
    // iPhone OS 2-3 binaries have a 4 KiB __PAGEZERO and load __TEXT at
    // 0x1000, inside the first 16 KiB host page. Allow it, at the cost of
    // null reads in 0x0-0xfff no longer faulting.
    if (addr < 0x1000) fatal("guest tried to map page zero (0x%08x)", addr);
    if (end > kSize) fatal("guest mapping 0x%08x+0x%x runs past 4 GiB", addr, size);
    if (mprotect(base_ + start, end - start, PROT_READ | PROT_WRITE) != 0)
        fatal("mprotect failed for guest 0x%08llx-0x%08llx", start, end);
    for (uint64_t page = start / kPageSize; page < end / kPageSize; page++)
        committed_[page / 8] |= uint8_t(1u << (page % 8));
}

bool GuestMemory::isMapped(GuestAddr addr) const {
    uint32_t page = addr / kPageSize;
    return committed_[page / 8] & (1u << (page % 8));
}

GuestAddr GuestMemory::guestAddrOf(const void *host) const {
    auto p = static_cast<const uint8_t *>(host);
    if (p < base_ || p >= base_ + kSize) fatal("host pointer %p is not in guest memory", host);
    return GuestAddr(p - base_);
}

}  // namespace b32
