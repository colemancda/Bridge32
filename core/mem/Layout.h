// Fixed regions of the guest address space. The main executable loads at its
// preferred address (no slide) somewhere below kHeapBase.
#pragma once

#include "GuestMemory.h"

namespace b32::layout {

constexpr GuestAddr kHeapBase = 0x20000000;
constexpr GuestAddr kHeapEnd = 0xC0000000;
constexpr GuestAddr kStackBase = 0xD0000000;  // stacks grow down from the top of each slot
constexpr uint32_t kStackSize = 1 << 20;
constexpr uint32_t kMaxThreads = 64;
constexpr GuestAddr kStubBase = 0xF0000000;   // SVC thunk stubs, 8 bytes each
constexpr uint32_t kStubRegionSize = 0x00800000;
constexpr GuestAddr kSentinel = 0xF0800000;   // return address that stops a guest call

}  // namespace b32::layout
