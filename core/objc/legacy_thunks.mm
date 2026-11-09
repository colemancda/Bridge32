// What only the legacy Objective-C runtime exports: setjmp-based exceptions
// and the garbage collector's write barriers.
//
// @try registers a buffer with objc_exception_try_enter and calls _setjmp on
// it; a throw longjmps to the innermost one. Guest frames and host frames can
// interleave (a guest @try around a host method that calls back into the
// guest), and a longjmp can't cross host frames, so each try buffer records
// how deep in Cpu::run nesting it was made. A throw that can't reach its
// buffer in this stretch of guest code becomes a host exception, which host
// @try blocks see as they would on a real Mac, and the guest-to-host call
// site below the buffer turns it back into a guest throw (deliverGuestException).

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/arch/i386/X86Cpu.h"

#include <cstring>

#import <Foundation/Foundation.h>

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }

// struct _objc_exception_data { int buf[18]; void *pointers[4]; }: where the
// throw leaves the exception for objc_exception_extract.
constexpr uint32_t kExceptionSlot = 72;

struct TryFrame {
    GuestAddr data;
    int depth;
};
thread_local std::vector<TryFrame> tryFrames;
}  // namespace

ExceptionDelivery b32::objc::deliverGuestException(Cpu &cpu, GuestAddr exception) {
    int depth = cpu.runDepth();
    while (!tryFrames.empty() && tryFrames.back().depth > depth) tryFrames.pop_back();  // their guest code is gone
    if (tryFrames.empty()) return ExceptionDelivery::NoFrame;
    if (tryFrames.back().depth < depth) return ExceptionDelivery::OuterFrame;
    GuestAddr data = tryFrames.back().data;
    tryFrames.pop_back();
    cpu.mem().write<uint32_t>(data + kExceptionSlot, exception);
    static_cast<X86Cpu &>(cpu).longjmpTo(data, 1);
    return ExceptionDelivery::Delivered;
}

B32_THUNK(_objc_exception_try_enter) { tryFrames.push_back({c.args.ptr(), c.cpu.runDepth()}); }

B32_THUNK(_objc_exception_try_exit) {
    GuestAddr data = c.args.ptr();
    while (!tryFrames.empty()) {
        bool found = tryFrames.back().data == data;
        tryFrames.pop_back();
        if (found) break;
    }
}

B32_THUNK(_objc_exception_extract) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + kExceptionSlot)); }

B32_THUNK(_objc_exception_throw) {
    GuestAddr exception = c.args.ptr();
    if (deliverGuestException(c.cpu, exception) != ExceptionDelivery::Delivered) @throw bridge(c).toHost(exception);
}

// int objc_exception_match(Class catchClass, id exception)
B32_THUNK(_objc_exception_match) {
    ClassInfo *cls = bridge(c).classInfo(c.args.ptr());
    id exception = bridge(c).toHost(c.args.ptr());
    c.ret(cls && cls->host && [exception isKindOfClass:cls->host] ? 1 : 0);
}

// --- garbage collection: no collector runs, so a barrier is its plain store ---------

B32_THUNK(_objc_collectingEnabled) { c.ret(0); }
B32_THUNK(_objc_collecting_enabled) { c.ret(0); }

// id objc_assign_ivar(id value, id dest, ptrdiff_t offset)
B32_THUNK(_objc_assign_ivar) {
    GuestAddr value = c.args.ptr(), dest = c.args.ptr();
    c.mem.write<uint32_t>(dest + c.args.u32(), value);
    c.ret(value);
}

namespace {
void assign(Call &c) {
    GuestAddr value = c.args.ptr();
    c.mem.write<uint32_t>(c.args.ptr(), value);
    c.ret(value);
}
}  // namespace

B32_THUNK(_objc_assign_global) { assign(c); }
B32_THUNK(_objc_assign_threadlocal) { assign(c); }
B32_THUNK(_objc_assign_strongCast) { assign(c); }
B32_THUNK(_objc_assign_weak) { assign(c); }
B32_THUNK(_objc_read_weak) { c.ret(c.mem.read<uint32_t>(c.args.ptr())); }

// void *objc_memmove_collectable(void *dst, const void *src, size_t size)
B32_THUNK(_objc_memmove_collectable) {
    GuestAddr dst = c.args.ptr(), src = c.args.ptr();
    std::memmove(c.mem.ptr<void>(dst), c.mem.ptr<void>(src), c.args.u32());
    c.ret(dst);
}
