// Host implementations of imported symbols. Every import the loader binds gets
// a guest stub (arch::writeThunkStub) that traps to the host with its index,
// and the trap lands here.
#pragma once

#include "core/arch/Arch.h"
#include "core/cpu/Cpu.h"
#include "core/mem/GuestHeap.h"

#include <deque>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace b32 {

class Runtime;

// Arguments of a thunked call, as a stream of 32-bit words: every guest passes
// every argument in 4-byte words (iOS's APCS variant in r0-r3 then the
// stack, i386's cdecl on the stack, PowerPC's r3-r10 then the stack), and
// 64-bit values take the next two words with no alignment. PowerPC's floats
// and doubles also use up their words but come in f1-f13 when the function's
// prototype is fixed; a variadic call shadows them in the words (see
// beginVarArgs).
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
        uint64_t first = u32();
        uint64_t second = u32();
        return arch::kHighWordFirst ? first << 32 | second : first | second << 32;
    }
    float f32() {
        if (inFloatRegister()) {
            next_++;
            return float(cpu_.floatArg(floatRegisters_++));
        }
        uint32_t b = u32();
        float f;
        std::memcpy(&f, &b, 4);
        return f;
    }
    double f64() {
        if (inFloatRegister()) {
            next_ += 2;
            return cpu_.floatArg(floatRegisters_++);
        }
        uint64_t b = u64();
        double d;
        std::memcpy(&d, &b, 8);
        return d;
    }
    // The rest of the arguments are variadic: a caller shadows a float or
    // double in the words that follow, and that is where the callee reads it.
    void beginVarArgs() { variadic_ = true; }
    double longDouble() {
        uint32_t words[arch::kLongDoubleWords];
        for (uint32_t &w : words) w = u32();
        return arch::longDouble(words);
    }

    // Index of the next word; varargs start where the fixed arguments end.
    int position() const { return next_; }

private:
    // Whether the next float or double is in a floating-point register: the
    // ABI has them, the call isn't variadic, and there's one left.
    bool inFloatRegister() const {
        constexpr int kFloatRegisters = 13;
        return !vaList_ && !variadic_ && floatRegisters_ < kFloatRegisters && cpu_.floatArgsInRegisters();
    }

    Cpu &cpu_;
    int next_ = 0;
    int floatRegisters_ = 0;
    bool variadic_ = false;
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

// The result of a thunk standing in for a function that returns a struct of
// `size` bytes: a guest address to write it to. Declare it before reading any
// other argument, since a hidden result pointer comes first where the ABI
// uses one; when the object goes out of scope the struct is returned the way
// the ABI says, which pops that pointer or loads the result registers.
class StructResult {
public:
    StructResult(Call &c, uint32_t size);
    ~StructResult();
    StructResult(const StructResult &) = delete;
    StructResult &operator=(const StructResult &) = delete;
    operator GuestAddr() const { return addr_; }

private:
    Call &c_;
    bool inMemory_;
    GuestAddr addr_;
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
// _stat$INODE64, _open$NOCANCEL, _opendir$INODE64$UNIX2003, _nanosleep$1050...
// A symbol is served by a thunk under its own name, then under its name with
// only $INODE64 kept (where the guest struct's layout differs: see posix.cpp),
// then by the base name's, since the iOS thunks already implement the UNIX2003
// semantics. baseSymbol strips every variant suffix; it returns `symbol` itself
// when there are none.
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
