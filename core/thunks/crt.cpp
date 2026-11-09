// What a Mac OS X 10.3 and 10.4 program's start-up code calls in libSystem:
// crt1 and crtbegin initialize the key manager libgcc registers its unwind
// tables with, and old code finds optional functions with the NSModule calls
// instead of dlsym. None of it has a job here beyond answering.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <mutex>
#include <unordered_map>

using namespace b32;

// --- the key manager ------------------------------------------------------------------------

B32_THUNK(__init_keymgr) {}
B32_THUNK(__cthread_init_routine) {}
B32_THUNK(__mach_init_routine) {}
B32_THUNK(___keymgr_dwarf2_register_sections) {}
// An array of the process-wide pointers libgcc keeps there.
B32_DATA(___keymgr_global, 64) {}

namespace {
std::mutex keymgrLock;
std::unordered_map<uint32_t, uint32_t> processWide;
}  // namespace

// void *_keymgr_get_and_lock_processwide_ptr(unsigned key)
B32_THUNK(__keymgr_get_and_lock_processwide_ptr) {
    uint32_t key = c.args.u32();
    std::lock_guard guard(keymgrLock);
    auto it = processWide.find(key);
    c.ret(it == processWide.end() ? 0 : it->second);
}
// void _keymgr_set_and_unlock_processwide_ptr(unsigned key, void *ptr)
B32_THUNK(__keymgr_set_and_unlock_processwide_ptr) {
    uint32_t key = c.args.u32();
    uint32_t pointer = c.args.u32();
    std::lock_guard guard(keymgrLock);
    processWide[key] = pointer;
}
// int _keymgr_get_and_lock_processwide_ptr_2(unsigned key, void **ptr): 0 on success
B32_THUNK(__keymgr_get_and_lock_processwide_ptr_2) {
    uint32_t key = c.args.u32();
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(keymgrLock);
    auto it = processWide.find(key);
    c.mem.write<uint32_t>(out, it == processWide.end() ? 0 : it->second);
    c.ret(0);
}

// --- NSModule: finding a symbol by name ---------------------------------------------------------
// Names come with their leading underscore, as the registry spells them. A
// symbol is the address of its stub.

B32_THUNK(_NSIsSymbolNameDefinedWithHint) { c.ret(ThunkRegistry::find(c.mem.cstr(c.args.ptr())) ? 1 : 0); }
B32_THUNK(_NSLookupAndBindSymbolWithHint) {
    std::string name = c.mem.cstr(c.args.ptr());
    c.ret(ThunkRegistry::find(name) ? c.rt.thunks().stubFor(name) : 0);
}
B32_THUNK(_NSAddressOfSymbol) { c.ret(c.args.u32()); }

// --- C++ unwinding -------------------------------------------------------------------------------
// Reached only by an exception that unwinds through guest frames, which isn't supported.

B32_THUNK(__Unwind_Resume) { fatal("C++ exception unwinding is not supported yet (_Unwind_Resume)"); }
B32_THUNK(___gxx_personality_v0) { fatal("C++ exception unwinding is not supported yet (__gxx_personality_v0)"); }
