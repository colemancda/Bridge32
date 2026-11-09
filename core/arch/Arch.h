// The guest architecture is chosen when Bridge32 is built: B32_GUEST_ARM
// (armv6/armv7 iOS apps, run by dynarmic), B32_GUEST_I386 (i386 Mac apps, run
// by Unicorn) or B32_GUEST_PPC (32-bit PowerPC Mac apps, run by Unicorn, and
// the one big-endian guest: B32_GUEST_BIG_ENDIAN). Code that is the same for
// all of them goes through Cpu; what
// differs (stub encodings, shims) is here, implemented once per architecture
// in core/arch/<arch>/.
#pragma once

#include "core/mem/GuestMemory.h"

#include <cstdint>
#include <string>

#if !defined(B32_GUEST_ARM) && !defined(B32_GUEST_I386) && !defined(B32_GUEST_PPC)
#error "Define B32_GUEST_ARM, B32_GUEST_I386 or B32_GUEST_PPC (CMake's B32_GUEST_ARCH)"
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
#if defined(B32_GUEST_PPC)
constexpr uint32_t kMethodStubSize = 24;  // six instructions: two 32-bit immediates and a jump
#else
constexpr uint32_t kMethodStubSize = 16;
#endif
void writeMethodStub(GuestMemory &mem, GuestAddr stub, uint32_t context, GuestAddr target);

// A few imports are better as real guest code than as a trap, for speed or
// because guest code reads their instructions: the guest address of such
// code for `symbol`, or 0.
GuestAddr nativeFunction(GuestMemory &mem, GuestHeap &heap, const std::string &symbol);

// How a function returns a value, where the two guests differ.
#if defined(B32_GUEST_I386)
// Struct results: Darwin's i386 ABI returns 1, 2, 4 and 8-byte structs in
// EAX:EDX and the rest through a hidden pointer the callee pops.
inline bool structReturnedInMemory(uint32_t size) { return size != 0 && size != 1 && size != 2 && size != 4 && size != 8; }
// float and double, and a struct holding just one of them, come back in ST(0).
constexpr bool kFloatResultsInFpu = true;
// long double is the x87's 80 bits, in 16 bytes of argument words.
constexpr uint32_t kLongDoubleWords = 4;
#elif defined(B32_GUEST_PPC)
// Darwin's PowerPC ABI, from GCC's rule for it (rs6000_return_in_memory, with
// AIX's struct return off): an aggregate of up to 8 bytes comes back in
// r3:r4, a larger one through a hidden pointer in r3. Not yet checked against
// a real binary (docs/ppc-mac-plan.md, Phase 1).
inline bool structReturnedInMemory(uint32_t size) { return size > 8; }
// float and double come back in f1 (a float widened to a double).
constexpr bool kFloatResultsInFpu = true;
// long double from Mac OS X 10.4 (the $LDBL128 symbols) is a pair of doubles
// in 16 bytes of argument words; older ones are a plain double.
constexpr uint32_t kLongDoubleWords = 4;
#else
// armv7: anything over a word goes through r0.
inline bool structReturnedInMemory(uint32_t size) { return size > 4; }
// The soft-float ABI uses the integer registers.
constexpr bool kFloatResultsInFpu = false;
// long double is double.
constexpr uint32_t kLongDoubleWords = 2;
#endif

// The value of a long double argument, as kLongDoubleWords argument words.
double longDouble(const uint32_t *words);

}  // namespace b32::arch
