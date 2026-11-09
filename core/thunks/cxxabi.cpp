// The C++ runtime old iOS apps import from libstdc++ and libgcc_s:
// operator new/delete, static-initialization guards, the SjLj exception
// registration chain and keymgr.
//
// Throwing is not supported yet: unwinding needs a personality routine that
// reads the guest's LSDA, and the plan is to run a real armv6 C++ runtime as
// guest code for that instead of reimplementing it here.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <mutex>
#include <unordered_map>

using namespace b32;

// --- operator new / delete (size_t is unsigned long on armv6/armv7) --------

B32_THUNK(__Znwm) { c.ret(c.heap.alloc(c.args.u32())); }
B32_THUNK(__Znam) { c.ret(c.heap.alloc(c.args.u32())); }
B32_THUNK(__ZnwmRKSt9nothrow_t) { c.ret(c.heap.alloc(c.args.u32())); }
B32_THUNK(__ZnamRKSt9nothrow_t) { c.ret(c.heap.alloc(c.args.u32())); }
B32_THUNK(__ZdlPv) { c.heap.free(c.args.ptr()); }
B32_THUNK(__ZdaPv) { c.heap.free(c.args.ptr()); }

// --- function-local statics ------------------------------------------------

namespace {
// Held from a successful acquire until release/abort. Recursive because an
// initializer may itself initialize another static.
std::recursive_mutex guardLock;
}  // namespace

// The guard's first byte is nonzero once the object is initialized.
B32_THUNK(___cxa_guard_acquire) {
    GuestAddr guard = c.args.ptr();
    if (c.mem.read<uint8_t>(guard)) {
        c.ret(0);
        return;
    }
    guardLock.lock();
    if (c.mem.read<uint8_t>(guard)) {
        guardLock.unlock();
        c.ret(0);
        return;
    }
    c.ret(1);
}

B32_THUNK(___cxa_guard_release) {
    c.mem.write<uint8_t>(c.args.ptr(), 1);
    guardLock.unlock();
}

B32_THUNK(___cxa_guard_abort) { guardLock.unlock(); }

B32_THUNK(___cxa_atexit) { c.ret(0); }  // the process never runs static destructors
B32_THUNK(___cxa_pure_virtual) { fatal("guest called a pure virtual function (from 0x%08x)", c.cpu.returnAddress()); }

// --- SjLj exception registration -------------------------------------------

namespace {
// Head of each guest thread's SjLj_Function_Context chain. The context's
// first word is its `prev` link.
thread_local GuestAddr sjljHead = 0;
}  // namespace

B32_THUNK(__Unwind_SjLj_Register) {
    GuestAddr context = c.args.ptr();
    c.mem.write<uint32_t>(context, sjljHead);
    sjljHead = context;
}

B32_THUNK(__Unwind_SjLj_Unregister) {
    GuestAddr context = c.args.ptr();
    sjljHead = c.mem.read<uint32_t>(context);
}

B32_THUNK(__Unwind_SjLj_Resume) { fatal("C++ exception unwinding is not supported yet (_Unwind_SjLj_Resume)"); }
B32_THUNK(__Unwind_SjLj_RaiseException) { fatal("C++ exception unwinding is not supported yet (_Unwind_SjLj_RaiseException)"); }
B32_THUNK(___gxx_personality_sj0) { fatal("C++ exception unwinding is not supported yet (__gxx_personality_sj0)"); }
B32_THUNK(___cxa_throw) {
    GuestAddr exception = c.args.ptr();
    GuestAddr typeInfo = c.args.ptr();
    // std::type_info is {vtable, const char *name}.
    GuestAddr name = typeInfo ? c.mem.read<uint32_t>(typeInfo + 4) : 0;
    fatal("guest threw a C++ exception of type %s (object 0x%08x, from 0x%08x); throwing is not supported yet",
          name ? c.mem.cstr(name) : "?", exception, c.cpu.returnAddress());
}

// --- keymgr (libgcc keeps its EH and atexit globals here) -------------------

namespace {
std::recursive_mutex keymgrLock;
std::unordered_map<uint32_t, GuestAddr> keymgrValues;
}  // namespace

B32_THUNK(__keymgr_get_and_lock_processwide_ptr) {
    uint32_t key = c.args.u32();
    keymgrLock.lock();
    c.ret(keymgrValues[key]);
}

B32_THUNK(__keymgr_get_and_lock_processwide_ptr_2) {
    uint32_t key = c.args.u32();
    GuestAddr out = c.args.ptr();
    keymgrLock.lock();
    c.mem.write<uint32_t>(out, keymgrValues[key]);
    c.ret(0);
}

B32_THUNK(__keymgr_set_and_unlock_processwide_ptr) {
    uint32_t key = c.args.u32();
    keymgrValues[key] = c.args.ptr();
    keymgrLock.unlock();
    c.ret(0);
}

B32_THUNK(__keymgr_unlock_processwide_ptr) {
    keymgrLock.unlock();
    c.ret(0);
}

// --- RTTI vtables -----------------------------------------------------------
// The guest's type_info objects point 8 bytes into these. Their virtual
// functions only run for exception matching and dynamic_cast across
// hierarchies, neither of which works yet, so the slots stay zero.

B32_DATA(__ZTVN10__cxxabiv117__class_type_infoE, 64) {}
B32_DATA(__ZTVN10__cxxabiv120__si_class_type_infoE, 64) {}
B32_DATA(__ZTVN10__cxxabiv121__vmi_class_type_infoE, 64) {}
B32_DATA(__ZTVN10__cxxabiv123__fundamental_type_infoE, 64) {}

// Typeinfo for fundamental types lives in the runtime: {vtable + 8, name}.
namespace {
void fundamentalTypeInfo(Runtime &rt, GuestAddr addr, const char *mangled) {
    rt.mem().write<uint32_t>(addr, rt.dataSymbol("__ZTVN10__cxxabiv123__fundamental_type_infoE") + 8);
    rt.mem().write<uint32_t>(addr + 4, rt.internString(mangled));
}
}  // namespace

B32_DATA(__ZTIi, 8) { fundamentalTypeInfo(rt, addr, "i"); }
B32_DATA(__ZTIj, 8) { fundamentalTypeInfo(rt, addr, "j"); }
B32_DATA(__ZTIf, 8) { fundamentalTypeInfo(rt, addr, "f"); }
B32_DATA(__ZTIPKc, 8) { fundamentalTypeInfo(rt, addr, "PKc"); }

// Only reached once something throws, which ___cxa_throw already rejects.
B32_THUNK(___cxa_allocate_exception) { fatal("guest is about to throw a C++ exception; throwing is not supported yet"); }
B32_THUNK(___cxa_begin_catch) { fatal("___cxa_begin_catch without a supported throw"); }
B32_THUNK(___cxa_end_catch) { fatal("___cxa_end_catch without a supported throw"); }
