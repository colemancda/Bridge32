// Host implementations of imported symbols. Every import the loader binds gets
// a guest stub (arch::writeThunkStub) that traps to the host with its index,
// and the trap lands here.
#pragma once

#include "core/cpu/Cpu.h"
#include "core/mem/GuestHeap.h"

#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace b32 {

class Runtime;

// Arguments of a thunked call, as a stream of 32-bit words: both guests pass
// every argument in 4-byte words (iOS's APCS variant in r0-r3 then the
// stack, i386's cdecl on the stack), and 64-bit values take the next two
// words with no alignment.
class Args {
public:
    Args(Cpu &cpu) : cpu_(cpu) {}

    // Reads arguments from a guest va_list (a pointer to the next stack word).
    static Args fromVaList(Cpu &cpu, GuestAddr vaList) {
        Args args(cpu);
        args.vaList_ = vaList;
        return args;
    }

    uint32_t u32() {
        if (vaList_) {
            uint32_t v = cpu_.mem().read<uint32_t>(vaList_);
            vaList_ += 4;
            return v;
        }
        uint32_t v = cpu_.arg(next_);
        next_++;
        return v;
    }
    int32_t i32() { return int32_t(u32()); }
    GuestAddr ptr() { return u32(); }
    uint64_t u64() {
        uint64_t lo = u32();
        return lo | (uint64_t(u32()) << 32);
    }
    float f32() { uint32_t b = u32(); float f; std::memcpy(&f, &b, 4); return f; }
    double f64() { uint64_t b = u64(); double d; std::memcpy(&d, &b, 8); return d; }

    // Index of the next word; varargs start where the fixed arguments end.
    int position() const { return next_; }

private:
    Cpu &cpu_;
    int next_ = 0;
    GuestAddr vaList_ = 0;
};

struct Call {
    Runtime &rt;
    Cpu &cpu;
    GuestMemory &mem;
    GuestHeap &heap;
    Args args;
    const char *name;

    void ret(uint32_t v) { cpu.setResult(v); }
    void ret64(uint64_t v) { cpu.setResult64(v); }
    void retF32(float f) { cpu.setFloatResult(f); }
    void retF64(double d) { cpu.setDoubleResult(d); }
};

using ThunkFn = void (*)(Call &);

// Static registry filled by B32_THUNK definitions across the thunk files.
struct ThunkRegistry {
    static std::unordered_map<std::string, ThunkFn> &all();
    ThunkRegistry(const char *symbol, ThunkFn fn) { all().emplace(symbol, fn); }
    // The host implementation of `symbol`, or of its base name when the symbol
    // is a libSystem variant (see baseSymbol), or null.
    static ThunkFn find(const std::string &symbol);
};

// i386 Mac binaries import libSystem's variant symbols: _fputs$UNIX2003,
// _stat$INODE64, _open$NOCANCEL, _realpath$DARWIN_EXTSN, _nanosleep$1050...
// Unless a thunk exists under the variant's own name, it is served by the
// base name's: the iOS thunks already implement the UNIX2003 semantics and
// the 64-bit-inode stat layout. Returns `symbol` itself when it has no suffix.
std::string baseSymbol(const std::string &symbol);

// Defines the host side of a guest import. `symbol` is the Mach-O symbol name
// with its leading underscore, e.g. B32_THUNK(_strlen).
#define B32_THUNK(symbol)                                                       \
    static void thunk_##symbol(::b32::Call &c);                                 \
    static ::b32::ThunkRegistry registry_##symbol(#symbol, thunk_##symbol);     \
    static void thunk_##symbol(::b32::Call &c)

class ThunkTable {
public:
    explicit ThunkTable(GuestMemory &mem);

    // Guest address of the stub for an imported symbol. Symbols without a
    // host implementation still get a stub, which aborts with the name.
    GuestAddr stubFor(const std::string &symbol);

    void dispatch(Runtime &rt, Cpu &cpu, uint32_t index);

    // The import whose stub's SVC immediate is `index`, or "".
    std::string nameOf(uint32_t index) const;

    // Imports bound so far that have no host implementation.
    std::vector<std::string> missing() const;

private:
    struct Entry {
        std::string name;
        ThunkFn fn;
    };
    GuestMemory &mem_;
    mutable std::mutex lock_;  // guest threads bind (dlsym) and dispatch concurrently
    std::deque<Entry> entries_;
    std::unordered_map<std::string, uint32_t> byName_;
};

// Stores the host's errno in the calling guest thread's errno (libsystem.cpp).
void setGuestErrno(Call &c, int value);

}  // namespace b32
