// Host implementations of imported symbols. Every import the loader binds gets
// an 8-byte guest stub, `svc #index; bx lr`, and the SVC lands here.
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

// Arguments of a thunked call, read in the iOS armv7 calling convention
// (APCS: 64-bit values take the next two words with no even-register
// alignment, and stack words are 4-byte aligned).
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
        uint32_t v = next_ < 4 ? cpu_.reg(next_) : cpu_.mem().read<uint32_t>(cpu_.reg(Cpu::SP) + (next_ - 4) * 4);
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

    void ret(uint32_t v) { cpu.setReg(0, v); }
    void ret64(uint64_t v) { cpu.setReg(0, uint32_t(v)); cpu.setReg(1, uint32_t(v >> 32)); }
    void retF32(float f) { uint32_t b; std::memcpy(&b, &f, 4); ret(b); }
    void retF64(double d) { uint64_t b; std::memcpy(&b, &d, 8); ret64(b); }
};

using ThunkFn = void (*)(Call &);

// Static registry filled by B32_THUNK definitions across the thunk files.
struct ThunkRegistry {
    static std::unordered_map<std::string, ThunkFn> &all();
    ThunkRegistry(const char *symbol, ThunkFn fn) { all().emplace(symbol, fn); }
};

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

}  // namespace b32
