// libobjc and the Foundation C functions that take or return objects.

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Format.h"

#import <Foundation/Foundation.h>
#include <objc/objc-sync.h>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

extern "C" void *objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void *);

namespace {

Bridge &bridge(Call &c) { return c.rt.bridge(); }

// Turns the current call into a send of `sel` to the object in r0, keeping
// any further arguments in place (objc_alloc(cls) -> [cls alloc]).
void sendFromR0(Call &c, const char *sel) {
    c.cpu.setReg(1, bridge(c).guestSel(sel));
    bridge(c).msgSend(c, false);
}

}  // namespace

std::string b32::objc::describeObject(Call &c, GuestAddr object) {
    if (!object) return "(null)";
    id host = bridge(c).toHost(object);
    const char *s = [[host description] UTF8String];
    return s ? s : "";
}

// --- messaging -----------------------------------------------------------------

B32_THUNK(_objc_msgSend) { bridge(c).msgSend(c, false); }
B32_THUNK(_objc_msgSend_stret) { bridge(c).msgSend(c, true); }
B32_THUNK(_objc_msgSendSuper) { bridge(c).msgSend(c, false, Bridge::SuperKind::Super); }
B32_THUNK(_objc_msgSendSuper_stret) { bridge(c).msgSend(c, true, Bridge::SuperKind::Super); }
B32_THUNK(_objc_msgSendSuper2) { bridge(c).msgSend(c, false, Bridge::SuperKind::Super2); }
B32_THUNK(_objc_msgSendSuper2_stret) { bridge(c).msgSend(c, true, Bridge::SuperKind::Super2); }

// --- memory management entry points (newer compilers call these directly) ----

B32_THUNK(_objc_alloc) { sendFromR0(c, "alloc"); }
B32_THUNK(_objc_allocWithZone) { sendFromR0(c, "alloc"); }
B32_THUNK(_objc_alloc_init) {
    GuestAddr cls = c.args.ptr();
    GuestAddr obj = GuestAddr(bridge(c).send(cls, "alloc"));
    c.ret(GuestAddr(bridge(c).send(obj, "init")));
}
B32_THUNK(_objc_retain) { sendFromR0(c, "retain"); }
B32_THUNK(_objc_release) { sendFromR0(c, "release"); }
B32_THUNK(_objc_autorelease) { sendFromR0(c, "autorelease"); }
B32_THUNK(_objc_retainAutoreleasedReturnValue) { sendFromR0(c, "retain"); }
B32_THUNK(_objc_autoreleaseReturnValue) { sendFromR0(c, "autorelease"); }
B32_THUNK(_objc_retainAutorelease) {
    GuestAddr obj = c.args.ptr();
    bridge(c).send(obj, "retain");
    c.ret(GuestAddr(bridge(c).send(obj, "autorelease")));
}

namespace {
// Host pool tokens are 64-bit; the guest gets an index.
std::vector<void *> poolTokens;
}  // namespace

B32_THUNK(_objc_autoreleasePoolPush) {
    poolTokens.push_back(objc_autoreleasePoolPush());
    c.ret(uint32_t(poolTokens.size()));
}
B32_THUNK(_objc_autoreleasePoolPop) {
    uint32_t token = c.args.u32();
    if (token == 0 || token > poolTokens.size()) fatal("bad autorelease pool token %u", token);
    objc_autoreleasePoolPop(poolTokens[token - 1]);
    poolTokens.resize(token - 1);
}

// --- properties --------------------------------------------------------------

namespace {
void storeProperty(Call &c, GuestAddr self, uint32_t offset, GuestAddr value, int copy) {
    Bridge &b = bridge(c);
    GuestAddr slot = self + offset;
    GuestAddr old = c.mem.read<uint32_t>(slot);
    if (value) value = GuestAddr(b.send(value, copy == 2 ? "mutableCopy" : copy ? "copy" : "retain"));
    c.mem.write<uint32_t>(slot, value);
    if (old) b.send(old, "release");
}
}  // namespace

// void objc_setProperty(id self, SEL _cmd, ptrdiff_t offset, id newValue, BOOL atomic, signed char shouldCopy)
B32_THUNK(_objc_setProperty) {
    GuestAddr self = c.args.ptr();
    c.args.ptr();
    uint32_t offset = c.args.u32();
    GuestAddr value = c.args.ptr();
    c.args.u32();
    int copy = int8_t(c.args.u32());
    storeProperty(c, self, offset, value, copy);
}

// The iOS 6+ variants: (self, _cmd, newValue, offset).
#define B32_SET_PROPERTY(symbol, copy)                       \
    B32_THUNK(symbol) {                                      \
        GuestAddr self = c.args.ptr();                       \
        c.args.ptr();                                        \
        GuestAddr value = c.args.ptr();                      \
        storeProperty(c, self, c.args.u32(), value, copy);   \
    }
B32_SET_PROPERTY(_objc_setProperty_nonatomic, 0)
B32_SET_PROPERTY(_objc_setProperty_atomic, 0)
B32_SET_PROPERTY(_objc_setProperty_nonatomic_copy, 1)
B32_SET_PROPERTY(_objc_setProperty_atomic_copy, 1)

// id objc_getProperty(id self, SEL _cmd, ptrdiff_t offset, BOOL atomic)
B32_THUNK(_objc_getProperty) {
    GuestAddr self = c.args.ptr();
    c.args.ptr();
    c.ret(c.mem.read<uint32_t>(self + c.args.u32()));
}

// void objc_copyStruct(void *dest, const void *src, ptrdiff_t size, BOOL atomic, BOOL hasStrong)
B32_THUNK(_objc_copyStruct) {
    GuestAddr dst = c.args.ptr();
    GuestAddr src = c.args.ptr();
    std::memmove(c.mem.ptr<uint8_t>(dst), c.mem.ptr<uint8_t>(src), c.args.u32());
}

// --- runtime queries -----------------------------------------------------------

B32_THUNK(_objc_getClass) {
    ClassInfo *info = bridge(c).classNamed(c.mem.cstr(c.args.ptr()));
    c.ret(info ? info->addr : 0);
}
B32_THUNK(_objc_lookUpClass) {
    ClassInfo *info = bridge(c).classNamed(c.mem.cstr(c.args.ptr()));
    c.ret(info ? info->addr : 0);
}
B32_THUNK(_object_getClass) {
    GuestAddr obj = c.args.ptr();
    c.ret(obj ? c.mem.read<uint32_t>(obj) : 0);
}
B32_THUNK(_class_getName) {
    ClassInfo *info = bridge(c).classInfo(c.args.ptr());
    c.ret(info ? c.rt.internString(info->name) : 0);
}
B32_THUNK(_sel_registerName) { c.ret(bridge(c).guestSel(c.mem.cstr(c.args.ptr()))); }
B32_THUNK(_sel_getUid) { c.ret(bridge(c).guestSel(c.mem.cstr(c.args.ptr()))); }
B32_THUNK(_sel_getName) { c.ret(c.args.ptr()); }  // a guest SEL is its name string

B32_THUNK(_objc_enumerationMutation) { fatal("collection mutated during fast enumeration (from 0x%08x)", c.cpu.reg(Cpu::LR)); }

B32_THUNK(_objc_exception_throw) {
    id exception = bridge(c).toHost(c.args.ptr());
    fatal("guest threw %s: %s (exceptions are not supported yet)", [[exception description] UTF8String],
          [exception respondsToSelector:@selector(reason)] ? [[exception reason] UTF8String] : "");
}

// --- Foundation functions ---------------------------------------------------------

B32_THUNK(_NSLog) {
    NSString *format = bridge(c).toHost(c.args.ptr());
    std::string s = formatGuest(c, [format UTF8String], c.args, describeObject);
    NSLog(@"%s", s.c_str());
}

B32_THUNK(_NSStringFromClass) {
    ClassInfo *info = bridge(c).classInfo(c.args.ptr());
    c.ret(info ? bridge(c).toGuest([NSString stringWithUTF8String:info->name.c_str()]) : 0);
}
B32_THUNK(_NSClassFromString) {
    NSString *name = bridge(c).toHost(c.args.ptr());
    ClassInfo *info = name ? bridge(c).classNamed([name UTF8String]) : nullptr;
    c.ret(info ? info->addr : 0);
}
B32_THUNK(_NSStringFromSelector) {
    GuestAddr sel = c.args.ptr();
    c.ret(sel ? bridge(c).toGuest([NSString stringWithUTF8String:bridge(c).selName(sel)]) : 0);
}
B32_THUNK(_NSSelectorFromString) {
    NSString *name = bridge(c).toHost(c.args.ptr());
    c.ret(name ? bridge(c).guestSel([name UTF8String]) : 0);
}

// NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL)
B32_THUNK(_NSSearchPathForDirectoriesInDomains) {
    NSSearchPathDirectory dir = NSSearchPathDirectory(c.args.u32());
    NSSearchPathDomainMask mask = NSSearchPathDomainMask(c.args.u32());
    BOOL expand = c.args.u32() != 0;
    c.ret(bridge(c).toGuest(NSSearchPathForDirectoriesInDomains(dir, mask, expand)));
}

// --- @synchronized ------------------------------------------------------------------

B32_THUNK(_objc_sync_enter) { c.ret(uint32_t(objc_sync_enter(bridge(c).toHost(c.args.ptr())))); }
B32_THUNK(_objc_sync_exit) { c.ret(uint32_t(objc_sync_exit(bridge(c).toHost(c.args.ptr())))); }

// --- @try/@catch support: only reached once something throws -----------------------

B32_THUNK(_objc_begin_catch) { fatal("ObjC exception caught; exceptions are not supported yet"); }
B32_THUNK(_objc_end_catch) { fatal("ObjC exception caught; exceptions are not supported yet"); }
B32_THUNK(_objc_exception_rethrow) { fatal("ObjC exception rethrown; exceptions are not supported yet"); }
B32_THUNK(___objc_personality_v0) { fatal("ObjC exception unwinding is not supported yet"); }
// struct objc_typeinfo { const void *vtable; const char *name; Class cls; }
B32_DATA(_OBJC_EHTYPE_$_NSException, 12) {}
B32_THUNK(dyld_stub_binder) { fatal("lazy binding requested, but every symbol pointer is bound at load time"); }
