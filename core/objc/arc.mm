// The ARC entry points (iOS 5+ compilers call these directly) and associated
// objects.
//
// A __weak guest variable is a 32-bit slot the guest only touches through
// objc_*Weak calls, so each one gets a host weak slot that does the zeroing;
// the guest slot holds the last stored value, for debuggers' sake.

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"

#import <Foundation/Foundation.h>
#include <objc/runtime.h>

#include <mutex>
#include <set>
#include <unordered_map>

using namespace b32;
using namespace b32::objc;

extern "C" {
id objc_loadWeakRetained(id *location);
id objc_initWeak(id *location, id value);
id objc_storeWeak(id *location, id value);
void objc_destroyWeak(id *location);
id objc_autorelease(id value);
}

namespace {

Bridge &bridge(Call &c) { return c.rt.bridge(); }

std::mutex weakLock;
std::unordered_map<GuestAddr, id *> weakSlots;  // guest __weak variable -> host weak slot

id *weakSlot(GuestAddr location) {
    std::lock_guard guard(weakLock);
    auto it = weakSlots.find(location);
    if (it != weakSlots.end()) return it->second;
    id *slot = new id(nil);
    objc_initWeak(slot, nil);
    weakSlots[location] = slot;
    return slot;
}

void storeWeak(Call &c, GuestAddr location, GuestAddr value) {
    objc_storeWeak(weakSlot(location), bridge(c).toHost(value));
    c.mem.write<uint32_t>(location, value);
}

// +1, like objc_loadWeakRetained.
GuestAddr loadWeakRetained(Call &c, GuestAddr location) {
    id *slot;
    {
        std::lock_guard guard(weakLock);
        auto it = weakSlots.find(location);
        if (it == weakSlots.end()) return 0;
        slot = it->second;
    }
    id object = objc_loadWeakRetained(slot);
    return bridge(c).toGuest(object);  // the guest owns the retain
}

void destroyWeak(Call &c, GuestAddr location) {
    id *slot = nullptr;
    {
        std::lock_guard guard(weakLock);
        auto it = weakSlots.find(location);
        if (it != weakSlots.end()) {
            slot = it->second;
            weakSlots.erase(it);
        }
    }
    if (slot) {
        objc_destroyWeak(slot);
        delete slot;
    }
    c.mem.write<uint32_t>(location, 0);
}

}  // namespace

// id objc_initWeak(id *location, id value)
B32_THUNK(_objc_initWeak) {
    GuestAddr location = c.args.ptr(), value = c.args.ptr();
    storeWeak(c, location, value);
    c.ret(value);
}
B32_THUNK(_objc_storeWeak) {
    GuestAddr location = c.args.ptr(), value = c.args.ptr();
    storeWeak(c, location, value);
    c.ret(value);
}
B32_THUNK(_objc_loadWeakRetained) { c.ret(loadWeakRetained(c, c.args.ptr())); }
B32_THUNK(_objc_loadWeak) {
    GuestAddr object = loadWeakRetained(c, c.args.ptr());
    if (object) objc_autorelease(bridge(c).toHost(object));
    c.ret(object);
}
B32_THUNK(_objc_destroyWeak) { destroyWeak(c, c.args.ptr()); }
// void objc_copyWeak(id *to, id *from)
B32_THUNK(_objc_copyWeak) {
    GuestAddr to = c.args.ptr(), from = c.args.ptr();
    GuestAddr object = loadWeakRetained(c, from);
    storeWeak(c, to, object);
    if (object) [bridge(c).toHost(object) release];
}
// void objc_moveWeak(id *to, id *from)
B32_THUNK(_objc_moveWeak) {
    GuestAddr to = c.args.ptr(), from = c.args.ptr();
    GuestAddr object = loadWeakRetained(c, from);
    storeWeak(c, to, object);
    if (object) [bridge(c).toHost(object) release];
    destroyWeak(c, from);
}

// void objc_storeStrong(id *location, id value)
B32_THUNK(_objc_storeStrong) {
    GuestAddr location = c.args.ptr(), value = c.args.ptr();
    GuestAddr old = c.mem.read<uint32_t>(location);
    if (value == old) return;
    if (value) bridge(c).send(value, "retain");
    c.mem.write<uint32_t>(location, value);
    if (old) bridge(c).send(old, "release");
}

B32_THUNK(_objc_retainAutoreleaseReturnValue) {
    GuestAddr object = c.args.ptr();
    if (object) {
        bridge(c).send(object, "retain");
        bridge(c).send(object, "autorelease");
    }
    c.ret(object);
}

B32_THUNK(_objc_terminate) { fatal("guest called objc_terminate (uncaught exception) from 0x%08x", c.cpu.reg(Cpu::LR)); }

// --- associated objects ------------------------------------------------------------------------
// Keys are guest addresses. The bridge keeps its own associated object on
// bridged objects, so objc_removeAssociatedObjects only removes the guest's.

namespace {
std::mutex associationsLock;
std::unordered_map<id, std::set<const void *>> guestKeys;  // host object -> keys the guest set
const void *hostKey(GuestAddr key) { return reinterpret_cast<const void *>(uintptr_t(key)); }
}  // namespace

// void objc_setAssociatedObject(id object, const void *key, id value, objc_AssociationPolicy)
B32_THUNK(_objc_setAssociatedObject) {
    id object = bridge(c).toHost(c.args.ptr());
    const void *key = hostKey(c.args.ptr());
    id value = bridge(c).toHost(c.args.ptr());
    auto policy = objc_AssociationPolicy(c.args.u32());
    objc_setAssociatedObject(object, key, value, policy);
    std::lock_guard guard(associationsLock);
    guestKeys[object].insert(key);
}

B32_THUNK(_objc_getAssociatedObject) {
    id object = bridge(c).toHost(c.args.ptr());
    c.ret(bridge(c).toGuest(objc_getAssociatedObject(object, hostKey(c.args.ptr()))));
}

B32_THUNK(_objc_removeAssociatedObjects) {
    id object = bridge(c).toHost(c.args.ptr());
    std::set<const void *> keys;
    {
        std::lock_guard guard(associationsLock);
        keys = std::move(guestKeys[object]);
        guestKeys.erase(object);
    }
    for (const void *key : keys) objc_setAssociatedObject(object, key, nil, OBJC_ASSOCIATION_ASSIGN);
}
