// The ObjC runtime's reflection functions (class_getInstanceMethod,
// method_exchangeImplementations, class_getInstanceVariable...) against the
// guest's own class metadata, so SDKs that swizzle methods or poke at ivars
// change what both the guest and the host actually call.
//
// A Method is a guest method_t { SEL name, const char *types, IMP imp }. A
// guest class's methods are its own method_t entries. A host method gets one
// made up the first time it's asked for, whose IMP is a small ARM stub:
//     ldr r12, [pc]     ; this method_t
//     .word method_t
//     ldr pc, [pc]      ; the thunk (out of branch range)
//     .word thunk
// so calling it runs the host implementation the method had at that moment,
// as swizzling code expects when it calls "the original".

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"

#import <Foundation/Foundation.h>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

namespace {
constexpr uint32_t kMethodSel = 0, kMethodTypes = 4, kMethodImp = 8, kMethodSize = 12;
constexpr uint32_t kStubSize = 16;
}  // namespace

GuestAddr Bridge::findMethod(ClassInfo *cls, GuestAddr sel) {
    std::lock_guard guard(lock_);
    ClassInfo *c = cls;
    for (; c && c->isGuest; c = c->super)
        if (auto it = c->methods.find(sel); it != c->methods.end() && it->second.entry) return it->second.entry;
    if (!c || !c->host) return 0;
    // A host class: methods the guest added to it first (categories, class_addMethod).
    if (auto it = c->methods.find(sel); it != c->methods.end() && it->second.entry) return it->second.entry;
    Method hostMethod = class_getInstanceMethod(c->host, hostSel(sel));
    if (!hostMethod) return 0;
    if (auto it = guestMethodForHost_.find(static_cast<void *>(hostMethod)); it != guestMethodForHost_.end()) return it->second;

    GuestMemory &mem = rt_.mem();
    GuestAddr m = rt_.heap().calloc(1, kMethodSize + kStubSize);
    GuestAddr stub = m + kMethodSize;
    GuestAddr thunk = rt_.thunks().stubFor("__b32_call_host_imp");
    mem.write<uint32_t>(m + kMethodSel, sel);
    mem.write<uint32_t>(m + kMethodTypes, rt_.internString(method_getTypeEncoding(hostMethod)));
    mem.write<uint32_t>(m + kMethodImp, stub);
    mem.write<uint32_t>(stub, 0xe59fc000);      // ldr r12, [pc]   (the word at +8)
    mem.write<uint32_t>(stub + 4, 0xe59ff000);  // ldr pc, [pc]    (the word at +12)
    mem.write<uint32_t>(stub + 8, m);
    mem.write<uint32_t>(stub + 12, thunk);
    hostMethods_[m] = {method_getImplementation(hostMethod), hostSel(sel)};
    methodOwners_[m] = {c, sel};
    guestMethodForHost_[static_cast<void *>(hostMethod)] = m;
    return m;
}

bool Bridge::hostMethodFor(GuestAddr method, IMP &imp, SEL &sel) {
    std::lock_guard guard(lock_);
    auto it = hostMethods_.find(method);
    if (it == hostMethods_.end()) return false;
    imp = it->second.imp;
    sel = it->second.sel;
    return true;
}

void Bridge::setMethodImp(GuestAddr method, GuestAddr imp) {
    std::lock_guard guard(lock_);
    GuestMemory &mem = rt_.mem();
    mem.write<uint32_t>(method + kMethodImp, imp);
    auto owner = methodOwners_.find(method);
    if (owner == methodOwners_.end()) return;
    ClassInfo *cls = owner->second.cls;
    GuestAddr sel = owner->second.sel;
    std::string types = mem.cstr(mem.read<uint32_t>(method + kMethodTypes));
    if (cls->isGuest) cls->methods[sel] = GuestMethod{imp, types, method};
    if (!cls->host) return;
    // The host side: another host method's original implementation goes in
    // as is; guest code gets a trampoline.
    IMP hostImp;
    SEL unused;
    if (imp >= kMethodSize && hostMethodFor(imp - kMethodSize, hostImp, unused)) {
        Method current = class_getInstanceMethod(cls->host, hostSel(sel));
        class_replaceMethod(cls->host, hostSel(sel), hostImp, current ? method_getTypeEncoding(current) : types.c_str());
    } else {
        installTrampoline(cls->host, sel, GuestMethod{imp, types, method}, cls);
    }
}

GuestAddr Bridge::addMethod(ClassInfo *cls, GuestAddr sel, GuestAddr imp, const std::string &types, bool replace) {
    std::lock_guard guard(lock_);
    if (auto it = cls->methods.find(sel); it != cls->methods.end() && it->second.entry) {
        if (!replace) return 0;
        GuestAddr previous = it->second.imp;
        setMethodImp(it->second.entry, imp);
        return previous;
    }
    if (!cls->isGuest && cls->host && !replace) {
        // class_addMethod fails if the class itself (not a superclass) has it.
        Method own = class_getInstanceMethod(cls->host, hostSel(sel));
        Class super = class_getSuperclass(cls->host);
        if (own && (!super || class_getInstanceMethod(super, hostSel(sel)) != own)) return 0;
    }
    GuestMemory &mem = rt_.mem();
    GuestAddr m = rt_.heap().calloc(1, kMethodSize);
    mem.write<uint32_t>(m + kMethodSel, sel);
    mem.write<uint32_t>(m + kMethodTypes, rt_.internString(types));
    methodOwners_[m] = {cls, sel};
    if (!cls->isGuest) cls->methods[sel] = GuestMethod{imp, types, m};
    setMethodImp(m, imp);
    return replace ? 0 : 1;
}

void Bridge::callHostImp(Call &c, IMP imp, SEL sel) {
    // A struct result too big for registers comes back through r0, with self in r1.
    GuestAddr method = c.cpu.reg(12);
    const char *types = rt_.mem().cstr(rt_.mem().read<uint32_t>(method + kMethodTypes));
    const char *p = types;
    Type ret = parseType(p);
    bool stret = ret.isStruct() && ret.guestSize() > 4;
    GuestAddr receiver = c.cpu.reg(stret ? 1 : 0);
    hostDispatch(c, receiver, guestSel(sel), nullptr, stret, imp);
}

// The made-up IMP of a host method (see the top of this file): r12 holds its method_t.
B32_THUNK(__b32_call_host_imp) {
    IMP imp;
    SEL sel;
    if (!c.rt.bridge().hostMethodFor(c.cpu.reg(12), imp, sel)) fatal("host method stub called without its method");
    c.rt.bridge().callHostImp(c, imp, sel);
}

// --- methods -----------------------------------------------------------------------------------

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }
ClassInfo *classArg(Call &c) { return bridge(c).classInfo(c.args.ptr()); }
}  // namespace

B32_THUNK(_class_getInstanceMethod) {
    ClassInfo *cls = classArg(c);
    GuestAddr sel = c.args.u32();
    c.ret(cls ? bridge(c).findMethod(cls, sel) : 0);
}
B32_THUNK(_class_getClassMethod) {
    ClassInfo *cls = classArg(c);
    GuestAddr sel = c.args.u32();
    ClassInfo *meta = cls ? (cls->isMeta ? cls : cls->meta) : nullptr;
    c.ret(meta ? bridge(c).findMethod(meta, sel) : 0);
}
B32_THUNK(_class_respondsToSelector) {
    ClassInfo *cls = classArg(c);
    GuestAddr sel = c.args.u32();
    c.ret(cls && bridge(c).findMethod(cls, sel) ? 1 : 0);
}

B32_THUNK(_method_getName) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + kMethodSel)); }
B32_THUNK(_method_getTypeEncoding) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + kMethodTypes)); }
B32_THUNK(_method_getImplementation) {
    GuestAddr m = c.args.ptr();
    c.ret(m ? c.mem.read<uint32_t>(m + kMethodImp) : 0);
}
B32_THUNK(_method_setImplementation) {
    GuestAddr m = c.args.ptr(), imp = c.args.ptr();
    GuestAddr previous = c.mem.read<uint32_t>(m + kMethodImp);
    bridge(c).setMethodImp(m, imp);
    c.ret(previous);
}
B32_THUNK(_method_exchangeImplementations) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    GuestAddr impA = c.mem.read<uint32_t>(a + kMethodImp), impB = c.mem.read<uint32_t>(b + kMethodImp);
    bridge(c).setMethodImp(a, impB);
    bridge(c).setMethodImp(b, impA);
}

// BOOL class_addMethod(Class, SEL, IMP, const char *types)
B32_THUNK(_class_addMethod) {
    ClassInfo *cls = classArg(c);
    GuestAddr sel = c.args.u32(), imp = c.args.ptr(), types = c.args.ptr();
    c.ret(cls && bridge(c).addMethod(cls, sel, imp, types ? c.mem.cstr(types) : "", false) ? 1 : 0);
}
// IMP class_replaceMethod(Class, SEL, IMP, const char *types)
B32_THUNK(_class_replaceMethod) {
    ClassInfo *cls = classArg(c);
    GuestAddr sel = c.args.u32(), imp = c.args.ptr(), types = c.args.ptr();
    c.ret(cls ? bridge(c).addMethod(cls, sel, imp, types ? c.mem.cstr(types) : "", true) : 0);
}

// Method *class_copyMethodList(Class, unsigned *outCount): the class's own
// guest methods, in a malloc'd guest array.
B32_THUNK(_class_copyMethodList) {
    ClassInfo *cls = classArg(c);
    GuestAddr outCount = c.args.ptr();
    std::vector<GuestAddr> entries;
    if (cls)
        for (const auto &[sel, method] : cls->methods)
            if (method.entry) entries.push_back(method.entry);
    if (outCount) c.mem.write<uint32_t>(outCount, uint32_t(entries.size()));
    if (entries.empty()) {
        c.ret(0);
        return;
    }
    GuestAddr list = c.heap.calloc(uint32_t(entries.size() + 1), 4);
    for (size_t i = 0; i < entries.size(); i++) c.mem.write<uint32_t>(list + uint32_t(i) * 4, entries[i]);
    c.ret(list);
}

// --- ivars --------------------------------------------------------------------------------------

namespace {
const GuestIvar *findIvar(ClassInfo *cls, const std::string &name) {
    for (ClassInfo *c = cls; c && c->isGuest; c = c->super)
        for (const auto &ivar : c->ivars)
            if (ivar.name == name) return &ivar;
    return nullptr;
}
uint32_t ivarOffset(Call &c, GuestAddr ivar) { return c.mem.read<uint32_t>(c.mem.read<uint32_t>(ivar)); }
}  // namespace

B32_THUNK(_class_getInstanceVariable) {
    ClassInfo *cls = classArg(c);
    GuestAddr name = c.args.ptr();
    const GuestIvar *ivar = cls && name ? findIvar(cls, c.mem.cstr(name)) : nullptr;
    c.ret(ivar ? ivar->entry : 0);
}
B32_THUNK(_class_getInstanceSize) {
    ClassInfo *cls = classArg(c);
    if (cls && !cls->isGuest && cls->host) {
        c.ret(uint32_t(class_getInstanceSize(cls->host)));
        return;
    }
    c.ret(cls ? cls->instanceSize : 0);
}
B32_THUNK(_class_getIvarLayout) { c.ret(0); }
B32_THUNK(_ivar_getName) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 4)); }
B32_THUNK(_ivar_getTypeEncoding) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 8)); }
B32_THUNK(_ivar_getOffset) { c.ret(ivarOffset(c, c.args.ptr())); }
// The guest's own ivars live in the object's guest half, at their offsets.
B32_THUNK(_object_getIvar) {
    GuestAddr object = c.args.ptr(), ivar = c.args.ptr();
    c.ret(object && ivar ? c.mem.read<uint32_t>(object + ivarOffset(c, ivar)) : 0);
}
B32_THUNK(_object_setIvar) {
    GuestAddr object = c.args.ptr(), ivar = c.args.ptr(), value = c.args.ptr();
    if (object && ivar) c.mem.write<uint32_t>(object + ivarOffset(c, ivar), value);
}
// Ivar object_getInstanceVariable(id, const char *name, void **outValue)
B32_THUNK(_object_getInstanceVariable) {
    GuestAddr object = c.args.ptr(), name = c.args.ptr(), out = c.args.ptr();
    ClassInfo *cls = object ? bridge(c).classOf(object) : nullptr;
    const GuestIvar *ivar = cls ? findIvar(cls, c.mem.cstr(name)) : nullptr;
    if (out) c.mem.write<uint32_t>(out, ivar ? c.mem.read<uint32_t>(object + c.mem.read<uint32_t>(ivar->offsetVar)) : 0);
    c.ret(ivar ? ivar->entry : 0);
}
B32_THUNK(_object_getIndexedIvars) {
    GuestAddr object = c.args.ptr();
    ClassInfo *cls = bridge(c).classOf(object);
    c.ret(object + (cls ? cls->instanceSize : 4));
}

// --- classes, protocols, properties ---------------------------------------------------------------

B32_THUNK(_objc_getMetaClass) {
    ClassInfo *cls = bridge(c).classNamed(c.mem.cstr(c.args.ptr()));
    c.ret(cls && cls->meta ? cls->meta->addr : 0);
}
B32_THUNK(_objc_getRequiredClass) {
    const char *name = c.mem.cstr(c.args.ptr());
    ClassInfo *cls = bridge(c).classNamed(name);
    if (!cls) fatal("objc_getRequiredClass: no class %s", name);
    c.ret(cls->addr);
}
B32_THUNK(_objc_copyClassNamesForImage) {
    c.args.ptr();
    if (GuestAddr outCount = c.args.ptr()) c.mem.write<uint32_t>(outCount, 0);
    c.ret(0);
}

// Protocols and properties the guest adds at run time only matter to code
// that asks about them again; they're accepted.
B32_THUNK(_class_addProtocol) { c.ret(1); }
B32_THUNK(_class_addProperty) { c.ret(1); }
B32_THUNK(_class_getProperty) { c.ret(0); }
B32_THUNK(_property_copyAttributeList) {
    c.args.ptr();
    if (GuestAddr outCount = c.args.ptr()) c.mem.write<uint32_t>(outCount, 0);
    c.ret(0);
}
// property_t { const char *name, *attributes }
B32_THUNK(_property_getName) { c.ret(c.mem.read<uint32_t>(c.args.ptr())); }
B32_THUNK(_property_getAttributes) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 4)); }

// protocol_t { isa, const char *name, ... }
B32_THUNK(_protocol_getName) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 4)); }
B32_THUNK(_NSStringFromProtocol) {
    GuestAddr protocol = c.args.ptr();
    c.ret(protocol ? bridge(c).toGuest(@(c.mem.cstr(c.mem.read<uint32_t>(protocol + 4)))) : 0);
}
B32_THUNK(_NSProtocolFromString) { c.ret(0); }
