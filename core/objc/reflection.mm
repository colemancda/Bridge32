// The ObjC runtime's reflection functions (class_getInstanceMethod,
// method_exchangeImplementations, class_getInstanceVariable...) against the
// guest's own class metadata, so SDKs that swizzle methods or poke at ivars
// change what both the guest and the host actually call.
//
// A Method is a guest method_t { SEL name, const char *types, IMP imp }. A
// guest class's methods are its own method_t entries. A host method gets one
// made up the first time it's asked for, whose IMP is a small stub
// (arch::writeMethodStub) that passes the method_t to the __b32_call_host_imp
// thunk, so calling it runs the host implementation the method had at that
// moment, as swizzling code expects when it calls "the original".

#include "Blocks.h"
#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/arch/Arch.h"

#import <Foundation/Foundation.h>
#include <objc/runtime.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

using namespace b32;
using namespace b32::objc;

namespace {
constexpr uint32_t kMethodSel = 0, kMethodTypes = 4, kMethodImp = 8, kMethodSize = 12;
constexpr uint32_t kStubSize = arch::kMethodStubSize;
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
    arch::writeMethodStub(mem, stub, m, thunk);
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
    // Swizzling code passes method_getName of a method a class lacks: NULL.
    if (!sel) return 0;
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
    // A struct result too big for registers comes back through the first
    // argument, with self second.
    GuestAddr method = c.cpu.stubContext();
    const char *types = rt_.mem().cstr(rt_.mem().read<uint32_t>(method + kMethodTypes));
    const char *p = types;
    Type ret = parseType(p);
    bool stret = guestReturnClass(ret) == ReturnClass::Memory;
    GuestAddr receiver = c.cpu.arg(stret ? 1 : 0);
    hostDispatch(c, receiver, guestSel(sel), nullptr, stret, imp);
}

// The made-up IMP of a host method (see the top of this file): the stub left
// its method_t in the stub context register.
B32_THUNK(__b32_call_host_imp) {
    IMP imp;
    SEL sel;
    if (!c.rt.bridge().hostMethodFor(c.cpu.stubContext(), imp, sel)) fatal("host method stub called without its method");
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

// Like the runtime, these answer NULL (or do nothing) for a NULL method, ivar
// or property: SDKs swizzle methods a class may not have.
namespace {
uint32_t fieldOf(Call &c, GuestAddr p, uint32_t offset) { return p ? c.mem.read<uint32_t>(p + offset) : 0; }
}  // namespace

B32_THUNK(_method_getName) { c.ret(fieldOf(c, c.args.ptr(), kMethodSel)); }
B32_THUNK(_method_getTypeEncoding) { c.ret(fieldOf(c, c.args.ptr(), kMethodTypes)); }
B32_THUNK(_method_getImplementation) {
    GuestAddr m = c.args.ptr();
    c.ret(m ? c.mem.read<uint32_t>(m + kMethodImp) : 0);
}
B32_THUNK(_method_setImplementation) {
    GuestAddr m = c.args.ptr(), imp = c.args.ptr();
    if (!m) {
        c.ret(0);
        return;
    }
    GuestAddr previous = c.mem.read<uint32_t>(m + kMethodImp);
    bridge(c).setMethodImp(m, imp);
    c.ret(previous);
}
B32_THUNK(_method_exchangeImplementations) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    if (!a || !b) return;
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
// const char **objc_copyImageNames(unsigned int *outCount): the app's own
// executable, the image SDKs search for their classes.
B32_THUNK(_objc_copyImageNames) {
    GuestAddr outCount = c.args.ptr();
    GuestAddr list = c.heap.calloc(2, 4);
    c.mem.write<uint32_t>(list, c.rt.internString(c.rt.image().path));
    if (outCount) c.mem.write<uint32_t>(outCount, 1);
    c.ret(list);
}

// Ivar *class_copyIvarList(Class, unsigned int *outCount): the class's own
// ivars (not its superclasses'), as their ivar_t entries; none for host classes.
B32_THUNK(_class_copyIvarList) {
    ClassInfo *cls = classArg(c);
    GuestAddr outCount = c.args.ptr();
    std::vector<GuestAddr> entries;
    if (cls && cls->isGuest)
        for (const auto &ivar : cls->ivars)
            if (ivar.entry) entries.push_back(ivar.entry);
    if (outCount) c.mem.write<uint32_t>(outCount, uint32_t(entries.size()));
    if (entries.empty()) {
        c.ret(0);
        return;
    }
    GuestAddr list = c.heap.calloc(uint32_t(entries.size() + 1), 4);
    for (size_t i = 0; i < entries.size(); i++) c.mem.write<uint32_t>(list + uint32_t(i) * 4, entries[i]);
    c.ret(list);
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
B32_THUNK(_ivar_getName) { c.ret(fieldOf(c, c.args.ptr(), 4)); }
B32_THUNK(_ivar_getTypeEncoding) { c.ret(fieldOf(c, c.args.ptr(), 8)); }
B32_THUNK(_ivar_getOffset) {
    GuestAddr ivar = c.args.ptr();
    c.ret(ivar ? ivarOffset(c, ivar) : 0);
}
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
// Ivar object_setInstanceVariable(id, const char *name, void *value)
B32_THUNK(_object_setInstanceVariable) {
    GuestAddr object = c.args.ptr(), name = c.args.ptr(), value = c.args.ptr();
    ClassInfo *cls = object ? bridge(c).classOf(object) : nullptr;
    const GuestIvar *ivar = cls ? findIvar(cls, c.mem.cstr(name)) : nullptr;
    if (ivar) c.mem.write<uint32_t>(object + c.mem.read<uint32_t>(ivar->offsetVar), value);
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
// Class objc_allocateClassPair(Class superclass, const char *name, size_t extraBytes)
B32_THUNK(_objc_allocateClassPair) {
    ClassInfo *super = classArg(c);
    c.ret(bridge(c).allocateClassPair(super, c.mem.cstr(c.args.ptr())));
}
B32_THUNK(_objc_registerClassPair) {}
// BOOL class_addIvar(Class, const char *name, size_t size, uint8_t alignment, const char *types)
B32_THUNK(_class_addIvar) {
    ClassInfo *cls = classArg(c);
    std::string name = c.mem.cstr(c.args.ptr());
    uint32_t size = c.args.u32(), align = c.args.u32() & 0xFF;
    c.ret(cls && bridge(c).addIvar(cls, name, size, align, c.mem.cstr(c.args.ptr())) ? 1 : 0);
}
B32_THUNK(_class_addProtocol) { c.ret(1); }
B32_THUNK(_class_addProperty) { c.ret(1); }
// objc_property_t class_getProperty(Class, const char *name): a guest class's
// property_t from its class_ro_t (or a superclass's); a host class's property
// gets a guest property_t made once, with its name and attributes.
B32_THUNK(_class_getProperty) {
    ClassInfo *cls = classArg(c);
    GuestAddr nameAddr = c.args.ptr();
    if (!cls || !nameAddr) {
        c.ret(0);
        return;
    }
    std::string name = c.mem.cstr(nameAddr);
    for (ClassInfo *k = cls; k; k = k->super) {
        if (!k->isGuest) {
            objc_property_t host = k->host ? class_getProperty(k->host, name.c_str()) : nullptr;
            if (!host) break;
            static std::mutex lock;
            static std::unordered_map<objc_property_t, GuestAddr> made;
            std::lock_guard guard(lock);
            GuestAddr &p = made[host];
            if (!p) {
                p = c.heap.calloc(1, 8);
                c.mem.write<uint32_t>(p, c.rt.internString(property_getName(host)));
                c.mem.write<uint32_t>(p + 4, c.rt.internString(property_getAttributes(host) ?: ""));
            }
            c.ret(p);
            return;
        }
        GuestAddr ro = k->ro;
        if (GuestAddr list = c.mem.read<uint32_t>(ro + 36)) {
            uint32_t entsize = c.mem.read<uint32_t>(list) & ~3u, count = c.mem.read<uint32_t>(list + 4);
            for (uint32_t i = 0; i < count; i++) {
                GuestAddr property = list + 8 + i * entsize;
                if (name == c.mem.cstr(c.mem.read<uint32_t>(property))) {
                    c.ret(property);
                    return;
                }
            }
        }
    }
    log("class_getProperty(%s, %s): not found", cls->name.c_str(), name.c_str());
    c.ret(0);
}
namespace {
// A property's attribute string split at its commas ("T@\"NSString\",&,N,V_name"
// has T, &, N and V); commas inside a quoted type name ("T@\"<P1,P2>\"") don't count.
std::vector<std::string> splitAttributes(const std::string &all) {
    std::vector<std::string> parts;
    for (size_t start = 0; start < all.size();) {
        size_t end = start;
        bool quoted = false;
        for (; end < all.size() && (quoted || all[end] != ','); end++)
            if (all[end] == '"') quoted = !quoted;
        if (end > start) parts.push_back(all.substr(start, end - start));
        start = end + 1;
    }
    return parts;
}
}  // namespace

// objc_property_attribute_t *property_copyAttributeList(objc_property_t, unsigned *outCount):
// one block the guest frees, holding the { name, value } pairs (two words each,
// then a null pair) and their strings after them.
B32_THUNK(_property_copyAttributeList) {
    GuestAddr attributes = fieldOf(c, c.args.ptr(), 4);
    GuestAddr outCount = c.args.ptr();
    std::vector<std::string> parts = attributes ? splitAttributes(c.mem.cstr(attributes)) : std::vector<std::string>{};
    if (outCount) c.mem.write<uint32_t>(outCount, uint32_t(parts.size()));
    if (parts.empty()) {
        c.ret(0);
        return;
    }
    uint32_t size = uint32_t(parts.size() + 1) * 8;
    for (const std::string &part : parts) size += uint32_t(part.size()) + 2;  // "N\0" and "value\0"
    GuestAddr block = c.heap.calloc(1, size);
    GuestAddr strings = block + uint32_t(parts.size() + 1) * 8;
    for (size_t i = 0; i < parts.size(); i++) {
        std::string name = parts[i].substr(0, 1), value = parts[i].substr(1);
        c.mem.copyIn(strings, name.c_str(), 2);
        c.mem.write<uint32_t>(block + uint32_t(i) * 8, strings);
        strings += 2;
        c.mem.copyIn(strings, value.c_str(), value.size() + 1);
        c.mem.write<uint32_t>(block + uint32_t(i) * 8 + 4, strings);
        strings += uint32_t(value.size()) + 1;
    }
    c.ret(block);
}
// property_t { const char *name, *attributes }
B32_THUNK(_property_getName) { c.ret(fieldOf(c, c.args.ptr(), 0)); }
B32_THUNK(_property_getAttributes) { c.ret(fieldOf(c, c.args.ptr(), 4)); }

// char *property_copyAttributeValue(objc_property_t, const char *name): the
// value of one attribute ("T@\"NSString\",&,N,V_name" has T, &, N and V), in
// a buffer the guest frees; NULL when the property doesn't have it.
B32_THUNK(_property_copyAttributeValue) {
    GuestAddr attributes = fieldOf(c, c.args.ptr(), 4);
    GuestAddr nameAddr = c.args.ptr();
    if (!attributes || !nameAddr) {
        c.ret(0);
        return;
    }
    std::string name = c.mem.cstr(nameAddr);
    for (const std::string &attribute : splitAttributes(c.mem.cstr(attributes))) {
        if (attribute.compare(0, name.size(), name) == 0) {
            std::string value = attribute.substr(name.size());
            GuestAddr out = c.heap.alloc(uint32_t(value.size() + 1));
            c.mem.copyIn(out, value.c_str(), value.size() + 1);
            c.ret(out);
            return;
        }
    }
    c.ret(0);
}

// protocol_t { isa, const char *name, ... }
B32_THUNK(_protocol_getName) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 4)); }
// BOOL protocol_isEqual(Protocol *, Protocol *): the same protocol, or two of the same name.
B32_THUNK(_protocol_isEqual) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    if (a == b) {
        c.ret(a != 0);
        return;
    }
    if (!a || !b) {
        c.ret(0);
        return;
    }
    c.ret(std::strcmp(c.mem.cstr(c.mem.read<uint32_t>(a + 4)), c.mem.cstr(c.mem.read<uint32_t>(b + 4))) == 0);
}
B32_THUNK(_NSStringFromProtocol) {
    GuestAddr protocol = c.args.ptr();
    c.ret(protocol ? bridge(c).toGuest(@(c.mem.cstr(c.mem.read<uint32_t>(protocol + 4)))) : 0);
}
B32_THUNK(_NSProtocolFromString) { c.ret(0); }

// --- blocks as methods ----------------------------------------------------------------------------

// IMP imp_implementationWithBlock(id block): an IMP that calls the block with
// self in place of _cmd, as the runtime's does. A small ARM stub:
//     mov r1, r0          ; self moves to the block's first argument
//     ldr r0, [pc]        ; the block
//     ldr pc, [r0, #12]   ; its invoke
//     .word block
B32_THUNK(_imp_implementationWithBlock) {
    GuestAddr block = objc::blocks::copy(bridge(c), c.args.ptr());
    GuestAddr stub = c.heap.alloc(16);
    const uint32_t code[4] = {0xe1a01000, 0xe59f0000, 0xe590f00c, block};
    c.mem.copyIn(stub, code, sizeof code);
    c.ret(stub);
}
B32_THUNK(_imp_getBlock) {
    GuestAddr imp = c.args.ptr();
    c.ret(c.mem.read<uint32_t>(imp) == 0xe1a01000 ? c.mem.read<uint32_t>(imp + 12) : 0);
}
B32_THUNK(_imp_removeBlock) { c.ret(0); }

B32_THUNK(_class_isMetaClass) {
    ClassInfo *cls = classArg(c);
    c.ret(cls && cls->isMeta ? 1 : 0);
}
B32_THUNK(_sel_isEqual) {
    GuestAddr a = c.args.u32();
    c.ret(a == c.args.u32() ? 1 : 0);
}

// objc_property_t *class_copyPropertyList(Class, unsigned *outCount): the
// class's own declared properties (class_ro_t baseProperties at 36), each a
// guest property_t { name, attributes }.
B32_THUNK(_class_copyPropertyList) {
    ClassInfo *cls = classArg(c);
    GuestAddr outCount = c.args.ptr();
    std::vector<GuestAddr> properties;
    if (cls && cls->isGuest) {
        GuestAddr ro = cls->ro;
        if (GuestAddr list = c.mem.read<uint32_t>(ro + 36)) {
            uint32_t entsize = c.mem.read<uint32_t>(list), count = c.mem.read<uint32_t>(list + 4);
            for (uint32_t i = 0; i < count; i++) properties.push_back(list + 8 + i * entsize);
        }
    }
    if (outCount) c.mem.write<uint32_t>(outCount, uint32_t(properties.size()));
    if (properties.empty()) {
        c.ret(0);
        return;
    }
    GuestAddr array = c.heap.calloc(uint32_t(properties.size() + 1), 4);
    for (size_t i = 0; i < properties.size(); i++) c.mem.write<uint32_t>(array + uint32_t(i) * 4, properties[i]);
    c.ret(array);
}

// --- protocols ---------------------------------------------------------------------------------------
// A guest protocol_t: { isa, name, protocols, instanceMethods, classMethods,
// optionalInstanceMethods, optionalClassMethods, instanceProperties, ... };
// method lists are { entsize, count, { SEL, types, IMP }... }. A protocol that
// stands for a host one has only its name; its details come from the host.

namespace {
constexpr uint32_t kProtoName = 4, kProtoProtocols = 8, kProtoInstance = 12, kProtoClass = 16;
constexpr uint32_t kProtoOptionalInstance = 20, kProtoOptionalClass = 24;

std::string protocolName(Call &c, GuestAddr p) { return c.mem.cstr(c.mem.read<uint32_t>(p + kProtoName)); }

uint32_t methodListOffset(bool required, bool instance) {
    return required ? (instance ? kProtoInstance : kProtoClass) : (instance ? kProtoOptionalInstance : kProtoOptionalClass);
}

// The protocol's own list of adopted protocols: { count, protocol_t *... }.
std::vector<GuestAddr> adopted(Call &c, GuestAddr p) {
    std::vector<GuestAddr> result;
    if (GuestAddr list = c.mem.read<uint32_t>(bridge(c).protocolData(p) + kProtoProtocols)) {
        uint32_t count = c.mem.read<uint32_t>(list);
        for (uint32_t i = 0; i < count; i++) result.push_back(c.mem.read<uint32_t>(list + 4 + i * 4));
    } else if (Protocol *host = objc_getProtocol(protocolName(c, p).c_str())) {
        unsigned count = 0;
        Protocol *__unsafe_unretained *list = protocol_copyProtocolList(host, &count);
        for (unsigned i = 0; i < count; i++) result.push_back(bridge(c).toGuest((id)list[i]));
        free(list);
    }
    return result;
}
}  // namespace

B32_THUNK(_objc_getProtocol) { c.ret(bridge(c).protocolNamed(c.mem.cstr(c.args.ptr()))); }

// struct objc_method_description protocol_getMethodDescription(Protocol *, SEL, BOOL required,
//     BOOL instance): { SEL name; char *types }, 8 bytes, returned through r0.
B32_THUNK(_protocol_getMethodDescription) {
    StructResult out(c, 8);
    GuestAddr p = c.args.ptr(), sel = c.args.u32();
    bool required = c.args.u32() != 0, instance = c.args.u32() != 0;
    c.mem.write<uint32_t>(out, 0);
    c.mem.write<uint32_t>(out + 4, 0);
    if (!p) return;
    if (GuestAddr list = c.mem.read<uint32_t>(bridge(c).protocolData(p) + methodListOffset(required, instance))) {
        uint32_t entsize = c.mem.read<uint32_t>(list) & ~3u, count = c.mem.read<uint32_t>(list + 4);
        for (uint32_t i = 0; i < count; i++) {
            GuestAddr m = list + 8 + i * entsize;
            if (bridge(c).guestSel(c.mem.cstr(c.mem.read<uint32_t>(m))) != sel) continue;
            c.mem.write<uint32_t>(out, sel);
            c.mem.write<uint32_t>(out + 4, c.mem.read<uint32_t>(m + 4));
            return;
        }
        return;
    }
    if (Protocol *host = objc_getProtocol(protocolName(c, p).c_str())) {
        objc_method_description d = protocol_getMethodDescription(host, bridge(c).hostSel(sel), required, instance);
        if (d.name) {
            c.mem.write<uint32_t>(out, sel);
            c.mem.write<uint32_t>(out + 4, d.types ? c.rt.internString(d.types) : 0);
        }
    }
}

// struct objc_method_description *protocol_copyMethodDescriptionList(Protocol *, BOOL required,
//     BOOL instance, unsigned *outCount)
B32_THUNK(_protocol_copyMethodDescriptionList) {
    GuestAddr p = c.args.ptr();
    bool required = c.args.u32() != 0, instance = c.args.u32() != 0;
    GuestAddr outCount = c.args.ptr();
    std::vector<std::pair<GuestAddr, GuestAddr>> descriptions;  // SEL, types
    if (p) {
        if (GuestAddr list = c.mem.read<uint32_t>(bridge(c).protocolData(p) + methodListOffset(required, instance))) {
            uint32_t entsize = c.mem.read<uint32_t>(list) & ~3u, count = c.mem.read<uint32_t>(list + 4);
            for (uint32_t i = 0; i < count; i++) {
                GuestAddr m = list + 8 + i * entsize;
                descriptions.push_back({bridge(c).guestSel(c.mem.cstr(c.mem.read<uint32_t>(m))), c.mem.read<uint32_t>(m + 4)});
            }
        } else if (Protocol *host = objc_getProtocol(protocolName(c, p).c_str())) {
            unsigned count = 0;
            objc_method_description *list = protocol_copyMethodDescriptionList(host, required, instance, &count);
            for (unsigned i = 0; i < count; i++)
                descriptions.push_back({bridge(c).guestSel(list[i].name), list[i].types ? c.rt.internString(list[i].types) : 0});
            free(list);
        }
    }
    if (outCount) c.mem.write<uint32_t>(outCount, uint32_t(descriptions.size()));
    if (descriptions.empty()) {
        c.ret(0);
        return;
    }
    GuestAddr array = c.heap.calloc(uint32_t(descriptions.size() + 1), 8);
    for (size_t i = 0; i < descriptions.size(); i++) {
        c.mem.write<uint32_t>(array + uint32_t(i) * 8, descriptions[i].first);
        c.mem.write<uint32_t>(array + uint32_t(i) * 8 + 4, descriptions[i].second);
    }
    c.ret(array);
}

// Protocol **protocol_copyProtocolList(Protocol *, unsigned *outCount)
B32_THUNK(_protocol_copyProtocolList) {
    GuestAddr p = c.args.ptr(), outCount = c.args.ptr();
    std::vector<GuestAddr> list = p ? adopted(c, p) : std::vector<GuestAddr>{};
    if (outCount) c.mem.write<uint32_t>(outCount, uint32_t(list.size()));
    if (list.empty()) {
        c.ret(0);
        return;
    }
    GuestAddr array = c.heap.calloc(uint32_t(list.size() + 1), 4);
    for (size_t i = 0; i < list.size(); i++) c.mem.write<uint32_t>(array + uint32_t(i) * 4, list[i]);
    c.ret(array);
}

// BOOL protocol_conformsToProtocol(Protocol *, Protocol *other): by name, through adopted protocols.
B32_THUNK(_protocol_conformsToProtocol) {
    GuestAddr p = c.args.ptr(), other = c.args.ptr();
    if (!p || !other) {
        c.ret(0);
        return;
    }
    std::string want = protocolName(c, other);
    std::vector<GuestAddr> pending = {p};
    for (size_t i = 0; i < pending.size() && i < 256; i++) {
        if (protocolName(c, pending[i]) == want) {
            c.ret(1);
            return;
        }
        for (GuestAddr a : adopted(c, pending[i])) pending.push_back(a);
    }
    c.ret(0);
}
