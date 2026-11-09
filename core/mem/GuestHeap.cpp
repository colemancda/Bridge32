#include "GuestHeap.h"

#include "Layout.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace b32 {

namespace {
constexpr uint32_t kGrain = 16;
constexpr uint32_t kRedzone = 16;
const bool redzones = std::getenv("B32_HEAP_REDZONE") != nullptr;
constexpr uint32_t kCommitChunk = 1 << 22;

uint32_t roundUp(uint32_t v, uint32_t a) { return (v + a - 1) & ~(a - 1); }
}  // namespace

GuestHeap::GuestHeap(GuestMemory &mem)
    : mem_(mem), top_(layout::kHeapBase), committed_(layout::kHeapBase) {}

GuestAddr GuestHeap::alloc(uint32_t size, uint32_t align) {
    std::lock_guard guard(lock_);
    if (!redzones) return allocLocked(size, align);
    uint32_t usable = roundUp(std::max(size, 1u), kGrain);
    GuestAddr addr = allocLocked(usable + kRedzone, align);
    std::memset(mem_.ptr<uint8_t>(addr + usable), 0xfd, kRedzone);
    Cpu *cpu = Runtime::currentCpu();
    redzones_[addr] = {usable, cpu ? cpu->returnAddress() : 0};
    return addr;
}

void GuestHeap::checkRedzone(GuestAddr addr) {
    auto it = redzones_.find(addr);
    if (it == redzones_.end()) return;
    const uint8_t *zone = mem_.ptr<uint8_t>(addr + it->second.size);
    for (uint32_t i = 0; i < kRedzone; i++)
        if (zone[i] != 0xfd) {
            char bytes[3 * kRedzone + 1] = {};
            for (uint32_t k = 0; k < kRedzone; k++) std::snprintf(bytes + k * 3, 4, "%02x ", zone[k]);
            fatal("guest heap block 0x%08x (%u bytes, allocated from 0x%08x) was written past its end: %s", addr,
                  it->second.size, it->second.caller, bytes);
        }
    redzones_.erase(it);
}

GuestAddr GuestHeap::allocLocked(uint32_t size, uint32_t align) {
    size = roundUp(std::max(size, 1u), kGrain);
    align = std::max(align, kGrain);

    // The smallest free block that fits: games make millions of small blocks,
    // and walking the fragments in address order takes most of their time.
    for (auto it = freeBySize_.lower_bound({size, 0}); it != freeBySize_.end(); ++it) {
        auto [freeSize, start] = *it;
        GuestAddr aligned = roundUp(start, align);
        if (aligned - start + uint64_t(size) > freeSize) continue;
        freeBySize_.erase(it);
        free_.erase(start);
        if (aligned > start) insertFree(start, aligned - start);
        uint32_t tail = start + freeSize - (aligned + size);
        if (tail) insertFree(aligned + size, tail);
        live_[aligned] = size;
        return aligned;
    }

    GuestAddr aligned = roundUp(top_, align);
    if (uint64_t(aligned) + size > layout::kHeapEnd) {
        Cpu *cpu = Runtime::currentCpu();
        fatal("guest heap exhausted (%u bytes, from 0x%08x)", size, cpu ? cpu->returnAddress() : 0);
    }
    if (aligned > top_) insertFree(top_, aligned - top_);
    top_ = aligned + size;
    if (top_ > committed_) {
        GuestAddr newCommitted = roundUp(top_, kCommitChunk);
        mem_.map(committed_, newCommitted - committed_);
        committed_ = newCommitted;
    }
    live_[aligned] = size;
    return aligned;
}

GuestAddr GuestHeap::calloc(uint32_t count, uint32_t size) {
    uint64_t total = uint64_t(count) * size;
    if (total > UINT32_MAX) return 0;
    GuestAddr addr = alloc(uint32_t(total));
    std::memset(mem_.ptr<uint8_t>(addr), 0, total);
    return addr;
}

GuestAddr GuestHeap::realloc(GuestAddr addr, uint32_t size) {
    if (!addr) return alloc(size);
    std::lock_guard guard(lock_);
    auto it = live_.find(addr);
    if (it == live_.end()) fatal("guest realloc of unknown pointer 0x%08x", addr);
    uint32_t oldSize = it->second;
    if (redzones) {
        auto zone = redzones_.find(addr);
        if (zone != redzones_.end()) oldSize = zone->second.size;
    }
    if (roundUp(size, kGrain) <= oldSize) return addr;
    GuestAddr fresh;
    if (redzones) {
        uint32_t usable = roundUp(std::max(size, 1u), kGrain);
        fresh = allocLocked(usable + kRedzone, kGrain);
        std::memset(mem_.ptr<uint8_t>(fresh + usable), 0xfd, kRedzone);
        Cpu *cpu = Runtime::currentCpu();
        redzones_[fresh] = {usable, cpu ? cpu->returnAddress() : 0};
    } else {
        fresh = allocLocked(size, kGrain);
    }
    std::memcpy(mem_.ptr<uint8_t>(fresh), mem_.ptr<uint8_t>(addr), oldSize);
    freeLocked(addr);
    return fresh;
}

void GuestHeap::free(GuestAddr addr) {
    if (!addr) return;
    std::lock_guard guard(lock_);
    freeLocked(addr);
}

void GuestHeap::freeLocked(GuestAddr addr) {
    if (redzones) checkRedzone(addr);
    auto it = live_.find(addr);
    if (it == live_.end()) {
#if defined(B32_GUEST_I386)
        // The Mac's malloc complains about a bad free and carries on, and
        // shipped games have got away with them ever since.
        Cpu *cpu = Runtime::currentCpu();
        log("guest free of unknown pointer 0x%08x (from 0x%08x); ignored, as the Mac's malloc does", addr, cpu ? cpu->returnAddress() : 0);
        return;
#else
        fatal("guest free of unknown pointer 0x%08x", addr);
#endif
    }
    uint32_t size = it->second;
    live_.erase(it);
    // Cleared, so a block comes back zeroed, padding to the grain included, as
    // fresh heap memory is: games read past what they asked for, counting on
    // that (cocos2d-x's base64Decode leaves its result unterminated, and
    // SuShi takes its strlen).
    // B32_HEAP_QUARANTINE=1, for chasing use-after-free: freed blocks are never
    // reused and are filled with 0xdeadbeef, so stale pointers fault or show it.
    static const bool quarantine = std::getenv("B32_HEAP_QUARANTINE") != nullptr;
    if (quarantine) {
        for (uint32_t i = 0; i + 4 <= size; i += 4) mem_.write<uint32_t>(addr + i, 0xdeadbeef);
        return;
    }
    std::memset(mem_.ptr<uint8_t>(addr), 0, size);
    insertFree(addr, size);
}

void GuestHeap::insertFree(GuestAddr addr, uint32_t size) {
    auto next = free_.lower_bound(addr);
    if (next != free_.end() && addr + size == next->first) {
        size += next->second;
        freeBySize_.erase({next->second, next->first});
        next = free_.erase(next);
    }
    if (next != free_.begin()) {
        auto prev = std::prev(next);
        if (prev->first + prev->second == addr) {
            freeBySize_.erase({prev->second, prev->first});
            prev->second += size;
            freeBySize_.insert({prev->second, prev->first});
            return;
        }
    }
    free_.emplace(addr, size);
    freeBySize_.insert({size, addr});
}

uint32_t GuestHeap::sizeOf(GuestAddr addr) const {
    std::lock_guard guard(lock_);
    auto it = live_.find(addr);
    return it == live_.end() ? 0 : it->second;
}

}  // namespace b32
