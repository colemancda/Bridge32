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
#include <objc/runtime.h>

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

B32_THUNK(_objc_collectingEnabled) { c.ret(bridge(c).collecting()); }
// The collector's hint to clear the stack below the caller, for conservative scanning: nothing to do.
B32_THUNK(_objc_clear_stack) {}
B32_THUNK(_objc_collecting_enabled) { c.ret(bridge(c).collecting()); }

namespace {
// Ivars of host classes that a guest's category on the class assigns directly, by their offset
// in the 32-bit layout: the store has to reach the host object, not its guest stand-in. (Xcode's
// -[NSNibConnector setDestination:] sets _destination itself, and nib connections it makes
// otherwise lose their destination.) The store is the class's own setter as the host had it
// before any guest category took its place, so the host's memory management of the ivar holds.
struct HostIvar {
    const char *cls;
    uint32_t offset;
    const char *setter;
    IMP hostSetter;
};
HostIvar hostIvars[] = {
    {"NSNibConnector", 4, "setSource:", nullptr},
    {"NSNibConnector", 8, "setDestination:", nullptr},
    {"NSNibConnector", 12, "setLabel:", nullptr},
};
// Taken as the process starts, before any guest image adds its categories.
[[maybe_unused]] const bool hostSettersKept = [] {
    for (HostIvar &known : hostIvars)
        if (Class cls = objc_getClass(known.cls))
            known.hostSetter = class_getMethodImplementation(cls, sel_registerName(known.setter));
    return true;
}();

bool assignHostIvar(Call &c, GuestAddr dest, uint32_t offset, GuestAddr value) {
    ClassInfo *info = bridge(c).classOf(dest);
    if (!info || info->isGuest) return false;
    for (const HostIvar &known : hostIvars) {
        if (known.offset != offset || !known.hostSetter) continue;
        id object = bridge(c).toHost(dest);
        Class cls = objc_getClass(known.cls);
        if (!cls || ![object isKindOfClass:cls]) continue;
        reinterpret_cast<void (*)(id, SEL, id)>(known.hostSetter)(object, sel_registerName(known.setter),
                                                                   bridge(c).toHost(value));
        return true;
    }
    return false;
}
}  // namespace

// id objc_assign_ivar(id value, id dest, ptrdiff_t offset)
B32_THUNK(_objc_assign_ivar) {
    GuestAddr value = c.args.ptr(), dest = c.args.ptr();
    uint32_t offset = c.args.u32();
    if (!assignHostIvar(c, dest, offset, value)) c.mem.write<uint32_t>(dest + offset, value);
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
