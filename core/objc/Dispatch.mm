// Message dispatch across the bridge.
//
// Guest -> guest: objc_msgSend finds the IMP in the guest class chain and
// jumps to it with the caller's registers untouched (a tail call).
// Guest -> host: the first host ancestor's method encoding drives argument
// conversion, and libffi makes the call.
// Host -> guest: guest methods are installed on shadow classes as libffi
// closures that convert the arguments back and run the guest IMP.

#include "Bridge.h"
#include "Dispatch.h"

#include "core/Log.h"
#include "core/Runtime.h"

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

namespace {

uint32_t wordsFor(uint32_t bytes) { return (bytes + 3) / 4; }

// '^{__CFString=}' and friends: opaque CF/CG struct pointers are objects.
bool isCFRef(const Type &t) {
    if (t.code != '^' || !t.pointee || !t.pointee->isStruct() || !t.pointee->fields.empty()) return false;
    const std::string &n = t.pointee->name;
    return n.rfind("__CF", 0) == 0 || n.rfind("CG", 0) == 0 || n.rfind("__CG", 0) == 0 || n.rfind("__CT", 0) == 0;
}

// Pointers whose target bytes are identical in both ABIs pass straight
// through (zero copy into guest memory).
bool passesThrough(const Type &t) {
    if (t.code != '^') return true;
    const Type &p = *t.pointee;
    return p.code == 'v' || p.code == '?' || p.sameLayout();
}

struct Override {
    OverrideFn fn;
    OverrideCondition when;
};

std::unordered_multimap<std::string, Override> &overrides() {
    static std::unordered_multimap<std::string, Override> table;
    return table;
}

}  // namespace

OverrideRegistry::OverrideRegistry(std::initializer_list<const char *> selectors, OverrideFn fn,
                                   OverrideCondition when) {
    for (const char *s : selectors) overrides().emplace(s, Override{fn, when});
}

// --- host call descriptions ---------------------------------------------------

namespace b32::objc {

struct HostCall {
    Signature sig;
    ffi_cif cif;
    std::vector<ffi_type *> argTypes;
};

HostCall &hostCall(const std::string &types, const char *selName) {
    static std::recursive_mutex lock;
    static std::unordered_map<std::string, std::unique_ptr<HostCall>> cache;
    // Selectors that take or return long long: the only 'q's that stay 64-bit
    // until the signature database exists.
    bool wide = std::strstr(selName, "LongLong") != nullptr;
    std::string key = (wide ? "W" : "N") + types;
    std::lock_guard guard(lock);
    if (auto it = cache.find(key); it != cache.end()) return *it->second;

    auto call = std::make_unique<HostCall>();
    call->sig = parseSignature(types.c_str());
    auto markWide = [&](Type &t) {
        if (wide && (t.code == 'q' || t.code == 'Q')) t.wide = true;
    };
    markWide(call->sig.ret);
    for (auto &a : call->sig.args) {
        markWide(a);
        a.code = isCFRef(a) ? '@' : a.code;
    }
    if (isCFRef(call->sig.ret)) call->sig.ret.code = '@';
    for (const auto &a : call->sig.args) call->argTypes.push_back(ffiType(a));
    if (ffi_prep_cif(&call->cif, FFI_DEFAULT_ABI, unsigned(call->argTypes.size()), ffiType(call->sig.ret),
                     call->argTypes.data()) != FFI_OK)
        fatal("libffi rejected the signature %s", types.c_str());
    return *cache.emplace(key, std::move(call)).first->second;
}

}  // namespace b32::objc

// --- guest -> host --------------------------------------------------------------

void Bridge::msgSend(Call &c, bool stret, SuperKind kind) {
    Cpu &cpu = c.cpu;
    GuestMemory &mem = rt_.mem();
    int selfReg = stret ? 1 : 0;
    GuestAddr first = cpu.reg(selfReg);
    GuestAddr sel = cpu.reg(selfReg + 1);

    GuestAddr receiver;
    ClassInfo *start;
    if (kind != SuperKind::None) {
        // struct objc_super { id receiver; Class class; }
        receiver = mem.read<uint32_t>(first);
        ClassInfo *cls = classInfo(mem.read<uint32_t>(first + 4));
        if (!cls) fatal("super send of %s with an unknown class", selName(sel));
        start = kind == SuperKind::Super2 ? cls->super : cls;
    } else {
        receiver = first;
        if (!receiver) {  // messages to nil return zero
            cpu.setReg(0, 0);
            cpu.setReg(1, 0);
            return;
        }
        start = classOf(receiver);
        if (!start) fatal("-%s sent to 0x%08x, which is not an object (from 0x%08x)", selName(sel), receiver, cpu.reg(Cpu::LR));
    }

    ClassInfo *info = start;
    for (; info && info->isGuest; info = info->super) {
        auto it = info->methods.find(sel);
        if (it == info->methods.end()) continue;
        if (kind != SuperKind::None) cpu.setReg(selfReg, receiver);
        cpu.jump(it->second.imp);
        return;
    }
    if (!info) fatal("guest class %s has no host ancestor for -%s", start->name.c_str(), selName(sel));
    // Ordinary sends to guest-class instances also land here when no guest
    // method matched; the shadow class has nothing else of its own, so a
    // plain host send finds the inherited host method.
    hostDispatch(c, receiver, sel, kind != SuperKind::None ? info : nullptr, stret);
}

void Bridge::hostDispatch(Call &c, GuestAddr receiver, GuestAddr sel, ClassInfo *superInfo, bool stret) {
    GuestMemory &mem = rt_.mem();
    id recv = toHost(receiver);
    const char *name = selName(sel);
    SEL hsel = sel_registerName(name);
    // B32_TRACE_SENDS=1 logs every guest-to-host message.
    static const bool trace = getenv("B32_TRACE_SENDS") != nullptr;
    if (trace)
        log("guest -> host %c[%s %s]%s", object_isClass(recv) ? '+' : '-', object_getClassName(recv), name,
            superInfo ? " (super)" : "");

    Args args(c.cpu);
    GuestAddr retPtr = stret ? args.ptr() : 0;
    args.u32();  // self or objc_super
    args.u32();  // _cmd

    for (auto [it, end] = overrides().equal_range(name); it != end; ++it) {
        if (it->second.when && !it->second.when(recv)) continue;
        if (superInfo) fatal("super send of overridden selector %s is not supported yet", name);
        OverrideCall oc{c, *this, recv, receiver, hsel, name, args, retPtr};
        it->second.fn(oc);
        return;
    }

    Class lookup = superInfo ? superInfo->host : object_getClass(recv);
    std::string types;
    if (Method m = class_getInstanceMethod(lookup, hsel)) {
        types = method_getTypeEncoding(m);
    } else if (NSMethodSignature *ms = [recv methodSignatureForSelector:hsel]) {
        types = ms.methodReturnType;
        for (NSUInteger i = 0; i < ms.numberOfArguments; i++) types += [ms getArgumentTypeAtIndex:i];
    } else {
        fatal("unrecognized selector %c[%s %s] (from 0x%08x)", object_isClass(recv) ? '+' : '-',
              class_getName(object_getClass(recv)), name, c.cpu.reg(Cpu::LR));
    }
    HostCall &hc = hostCall(types, name);
    const Signature &sig = hc.sig;

    struct objc_super superStruct{recv, superInfo ? superInfo->host : nil};
    void *self = superInfo ? static_cast<void *>(&superStruct) : static_cast<void *>(recv);
    std::vector<void *> values(sig.args.size());
    std::vector<std::vector<uint8_t>> storage(sig.args.size());
    values[0] = &self;
    values[1] = &hsel;

    struct OutParam {
        const Type *type;
        GuestAddr guest;
        uint8_t *host;
    };
    std::vector<OutParam> outParams;
    std::vector<std::vector<uint8_t>> outStorage;

    for (size_t i = 2; i < sig.args.size(); i++) {
        const Type &t = sig.args[i];
        std::vector<uint32_t> words(wordsFor(t.guestSize()));
        for (auto &w : words) w = args.u32();
        storage[i].resize(std::max<size_t>(t.hostSize(), 8));
        if (t.code == '^' && !passesThrough(t) && !isCFRef(t)) {
            // Copy in/out through a host temporary laid out for the host.
            GuestAddr p = words[0];
            uint8_t *temp = nullptr;
            if (p) {
                outStorage.emplace_back(std::max<size_t>(t.pointee->hostSize(), 8));
                temp = outStorage.back().data();
                // Object out-params (NSError **) are outputs only.
                if (!t.pointee->isObject()) toHostValue(*t.pointee, mem.ptr<uint8_t>(p), temp);
                outParams.push_back({t.pointee.get(), p, temp});
            }
            std::memcpy(storage[i].data(), &temp, sizeof temp);
        } else {
            toHostValue(t, reinterpret_cast<const uint8_t *>(words.data()), storage[i].data());
        }
        values[i] = storage[i].data();
    }

    alignas(16) uint8_t result[256] = {};
    if (sig.ret.hostSize() > sizeof result) fatal("return type of %s is too large", name);
    ffi_call(&hc.cif, superInfo ? FFI_FN(objc_msgSendSuper) : FFI_FN(objc_msgSend), result, values.data());

    for (const auto &out : outParams) toGuestValue(*out.type, out.host, mem.ptr<uint8_t>(out.guest));

    const Type &r = sig.ret;
    if (r.code == 'v') return;
    if (r.code == '*') {  // C strings: copy out, owned by the receiver
        c.ret(guestCString(*reinterpret_cast<const char **>(result), recv));
        return;
    }
    uint32_t size = r.guestSize();
    alignas(8) uint8_t guest[256] = {};
    toGuestValue(r, result, guest);
    if (r.isStruct() && size > 4) {
        if (!stret) fatal("%s returns a %u-byte struct but was sent with objc_msgSend", name, size);
        mem.copyIn(retPtr, guest, size);
        return;
    }
    uint32_t lo;
    switch (r.code) {
    case 'c': lo = uint32_t(int32_t(int8_t(guest[0]))); break;
    case 's': lo = uint32_t(int32_t(int16_t(guest[0] | guest[1] << 8))); break;
    case 'C': case 'B': lo = guest[0]; break;
    case 'S': lo = uint32_t(guest[0] | guest[1] << 8); break;
    default: std::memcpy(&lo, guest, 4); break;
    }
    c.cpu.setReg(0, lo);
    if (size > 4) {
        uint32_t hi;
        std::memcpy(&hi, guest + 4, 4);
        c.cpu.setReg(1, hi);
    }
}

uint64_t Bridge::send(GuestAddr receiver, const char *sel, std::initializer_list<uint32_t> args) {
    Cpu *cpu = &Runtime::threadCpu();
    std::vector<uint32_t> words = {receiver, guestSel(sel)};
    words.insert(words.end(), args);
    return cpu->call(rt_.thunks().stubFor("_objc_msgSend"), words);
}

// --- host -> guest ---------------------------------------------------------------

namespace {

struct Trampoline {
    Bridge *bridge;
    GuestAddr imp;
    GuestAddr sel;
    HostCall *call;
};

void trampolineEntry(ffi_cif *, void *ret, void **args, void *user) {
    auto *t = static_cast<Trampoline *>(user);
    Bridge &bridge = *t->bridge;
    // B32_TRACE_CALLS=1 logs every host-to-guest method call.
    static const bool trace = getenv("B32_TRACE_CALLS") != nullptr;
    if (trace)
        log("host -> guest %c[%s %s]", object_isClass(*static_cast<id *>(args[0])) ? '+' : '-',
            object_getClassName(*static_cast<id *>(args[0])), bridge.selName(t->sel));
    Runtime &rt = bridge.runtime();
    Cpu *cpu = &Runtime::threadCpu();
    const Signature &sig = t->call->sig;

    std::vector<uint32_t> words;
    uint32_t retSize = sig.ret.guestSize();
    bool guestStret = sig.ret.isStruct() && retSize > 4;
    GuestAddr retBuf = guestStret ? rt.heap().alloc(retSize) : 0;
    if (guestStret) words.push_back(retBuf);
    words.push_back(bridge.toGuest(*static_cast<id *>(args[0])));
    words.push_back(t->sel);
    for (size_t i = 2; i < sig.args.size(); i++) {
        const Type &type = sig.args[i];
        std::vector<uint32_t> w(wordsFor(type.guestSize()));
        bridge.toGuestValue(type, static_cast<const uint8_t *>(args[i]), reinterpret_cast<uint8_t *>(w.data()));
        words.insert(words.end(), w.begin(), w.end());
    }

    uint64_t r = cpu->call(t->imp, words);

    const Type &rt_ = sig.ret;
    if (rt_.code == 'v') return;
    alignas(8) uint8_t guest[256] = {};
    if (guestStret) {
        std::memcpy(guest, rt.mem().ptr<uint8_t>(retBuf), retSize);
        rt.heap().free(retBuf);
    } else {
        std::memcpy(guest, &r, 8);
    }
    alignas(16) uint8_t host[256] = {};
    bridge.toHostValue(rt_, guest, host);
    // libffi wants small integer results widened to a full ffi_arg.
    switch (rt_.code) {
    case 'c': *static_cast<ffi_sarg *>(ret) = int8_t(host[0]); break;
    case 's': *static_cast<ffi_sarg *>(ret) = *reinterpret_cast<int16_t *>(host); break;
    case 'i': *static_cast<ffi_sarg *>(ret) = *reinterpret_cast<int32_t *>(host); break;
    case 'C': case 'B': *static_cast<ffi_arg *>(ret) = host[0]; break;
    case 'S': *static_cast<ffi_arg *>(ret) = *reinterpret_cast<uint16_t *>(host); break;
    case 'I': *static_cast<ffi_arg *>(ret) = *reinterpret_cast<uint32_t *>(host); break;
    default: std::memcpy(ret, host, rt_.hostSize()); break;
    }
}

}  // namespace

void Bridge::installTrampoline(Class target, GuestAddr sel, const GuestMethod &method, ClassInfo *owner) {
    SEL hsel = hostSel(sel);
    std::string types = hostTypesFor(target, hsel, owner, method.types);
    HostCall &hc = hostCall(types, sel_getName(hsel));
    void *code = nullptr;
    auto *closure = static_cast<ffi_closure *>(ffi_closure_alloc(sizeof(ffi_closure), &code));
    auto *t = new Trampoline{this, method.imp, sel, &hc};
    if (!closure || ffi_prep_closure_loc(closure, &hc.cif, trampolineEntry, t, code) != FFI_OK)
        fatal("could not create a trampoline for %s", sel_getName(hsel));
    if (!owner->isGuest && class_getInstanceMethod(target, hsel))
        log("guest category replaces host method %c[%s %s]", owner->isMeta ? '+' : '-', owner->name.c_str(), sel_getName(hsel));
    class_replaceMethod(target, hsel, reinterpret_cast<IMP>(code), types.c_str());
}

void Bridge::runLoadMethods(Cpu &cpu) {
    for (auto [cls, imp] : loadMethods_) cpu.call(imp, {cls->addr, guestSel("load")});
    loadMethods_.clear();
}
