// The guest architecture is chosen when Bridge32 is built: B32_GUEST_ARM
// (armv6/armv7 iOS apps, run by dynarmic) or B32_GUEST_I386 (i386 Mac apps,
// run by Unicorn). Code that is the same for both goes through Cpu; what
// differs (stub encodings, shims) is here, implemented once per architecture
// in core/arch/<arch>/.
#pragma once

#include "core/mem/GuestMemory.h"

#include <cstdint>

#if !defined(B32_GUEST_ARM) && !defined(B32_GUEST_I386)
#error "Define B32_GUEST_ARM or B32_GUEST_I386 (CMake's B32_GUEST_ARCH)"
#endif

namespace b32 {
class GuestHeap;
}

namespace b32::arch {

// The architecture's name as the guest's own tools would say it, for logs.
const char *name();

// Every imported symbol gets a stub of this many bytes in the stub region
// (Layout.h); running one traps to the host with the stub's index.
constexpr uint32_t kThunkStubSize = 8;
void writeThunkStub(GuestMemory &mem, GuestAddr stub, uint32_t index);
// The trap at layout::kSentinel that ends a Cpu::call().
void writeSentinel(GuestMemory &mem, GuestAddr addr);

// Apple's armv7 ABI has C++ constructors and destructors return `this`, and
// clang-built apps use the result; a GCC-built guest libstdc++ returns
// nothing. On arm this is a shim around `target` that preserves r0; on i386,
// where nothing returns `this`, it's `target` itself.
GuestAddr thisReturningShim(GuestMemory &mem, GuestHeap &heap, GuestAddr target);

// The IMP of a made-up method (reflection.mm): code that puts `context` where
// Cpu::stubContext() reads it and jumps to `target`.
constexpr uint32_t kMethodStubSize = 16;
void writeMethodStub(GuestMemory &mem, GuestAddr stub, uint32_t context, GuestAddr target);

}  // namespace b32::arch
