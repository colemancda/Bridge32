// malloc for the guest: every allocation the guest can see lives in guest
// memory, so this manages [kHeapBase, kHeapEnd) on the host side.
#pragma once

#include "GuestMemory.h"

#include <map>
#include <mutex>
#include <set>
#include <unordered_map>
#include <utility>

namespace b32 {

class GuestHeap {
public:
    explicit GuestHeap(GuestMemory &mem);

    GuestAddr alloc(uint32_t size, uint32_t align = 16);
    GuestAddr calloc(uint32_t count, uint32_t size);
    GuestAddr realloc(GuestAddr addr, uint32_t size);
    void free(GuestAddr addr);
    // Usable size of a live allocation, 0 for anything else.
    uint32_t sizeOf(GuestAddr addr) const;

private:
    GuestAddr allocLocked(uint32_t size, uint32_t align);
    void freeLocked(GuestAddr addr);
    void insertFree(GuestAddr addr, uint32_t size);

    GuestMemory &mem_;
    mutable std::mutex lock_;
    GuestAddr top_;       // first never-allocated address
    GuestAddr committed_; // memory below this is mapped
    std::map<GuestAddr, uint32_t> free_;          // start -> size, coalesced
    std::set<std::pair<uint32_t, GuestAddr>> freeBySize_;  // the same blocks, smallest first
    std::unordered_map<GuestAddr, uint32_t> live_;  // start -> size

    // B32_HEAP_REDZONE=1: 16 bytes of 0xfd after each block (past its 16-byte
    // rounding), checked when it's freed, to find writes past the end.
    struct Redzone {
        uint32_t size;      // rounded size the caller can use
        GuestAddr caller;   // guest return address of the allocating call
    };
    std::unordered_map<GuestAddr, Redzone> redzones_;
    void checkRedzone(GuestAddr addr);
};

}  // namespace b32
