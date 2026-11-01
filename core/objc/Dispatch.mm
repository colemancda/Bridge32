// Message dispatch across the bridge.
//
// Guest -> guest: objc_msgSend finds the IMP in the guest class chain and
// jumps to it with the caller's registers untouched (a tail call).
// Guest -> host: the first host ancestor's method encoding drives argument
// conversion, and libffi makes the call.
// Host -> guest: guest methods are installed on shadow classes as libffi
// closures that convert the arguments back and run the guest IMP.

#include "Bridge.h"
#include "Blocks.h"
#include "Dispatch.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <pthread.h>

#include <cstring>

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <cctype>
#include <string>
#include <string_view>

using namespace b32;
using namespace b32::objc;

namespace {

uint32_t wordsFor(uint32_t bytes) { return (bytes + 3) / 4; }

// '^{__CFString=}' and friends: opaque CF-style struct pointers are objects.
bool isCFRef(const Type &t) {
    if (t.code != '^' || !t.pointee || !t.pointee->isStruct() || !t.pointee->fields.empty()) return false;
    const std::string &n = t.pointee->name;
    // CoreFoundation-style types from CF, CG, CoreText, Security, SystemConfiguration, CoreVideo, CoreMedia.
    for (const char *prefix : {"__CF", "CG", "__CG", "__CT", "__Sec", "__SC", "__CV", "opaqueCM"})
        if (n.rfind(prefix, 0) == 0) return true;
    return false;
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

// Whether a selector keyword names a value that is a double in the 32-bit
// SDK too (NSTimeInterval, dates, CLLocation values, doubleValue...) rather
// than a CGFloat, which is a float there.
static bool namesDouble(std::string_view keyword) {
    static const char *const kDoubleWords[] = {"duration", "delay", "interval", "time",     "date",
                                               "double",   "latitude", "longitude", "degrees", "distance",
                                               "accuracy", "altitude", "speed",    "course",  "heading",
                                               "seconds",  "samplerate", "latency"};
    std::string lower(keyword);
    for (char &ch : lower) ch = char(std::tolower(ch));
    for (const char *word : kDoubleWords)
        if (lower.find(word) != std::string::npos) return true;
    return false;
}

// The host encodes CGFloat as 'd' like double. Arguments and results that
// the selector doesn't name as a double are CGFloats: a float in the guest.
static void markCGFloats(Signature &sig, const char *selName) {
    std::string_view name(selName);
    if (sig.ret.code == 'd' && !namesDouble(name)) sig.ret.cgfloat = true;
    size_t start = 0;
    for (size_t i = 2; i < sig.args.size(); i++) {
        size_t colon = name.find(':', start);
        std::string_view keyword = name.substr(start, colon == std::string_view::npos ? std::string_view::npos : colon - start);
        if (sig.args[i].code == 'd' && !namesDouble(keyword)) sig.args[i].cgfloat = true;
        if (colon == std::string_view::npos) break;
        start = colon + 1;
    }
}

// Marks which host doubles are CGFloats from the guest's own encoding of the
// same method, where 'f' is a CGFloat and 'd' a real double.
static void markCGFloatsFromGuest(Signature &sig, const std::string &guestTypes) {
    Signature guest = parseSignature(guestTypes.c_str());
    if (sig.ret.code == 'd') sig.ret.cgfloat = guest.ret.code == 'f';
    for (size_t i = 0; i < sig.args.size() && i < guest.args.size(); i++)
        if (sig.args[i].code == 'd') sig.args[i].cgfloat = guest.args[i].code == 'f';
}

HostCall &hostCall(const std::string &types, const char *selName, const std::string *guestTypes) {
    static std::recursive_mutex lock;
    static std::unordered_map<std::string, std::unique_ptr<HostCall>> cache;
    // Selectors that take or return long long or int64_t (encodeInt64:forKey:):
    // the only 'q's that stay 64-bit until the signature database exists.
    bool wide = std::strstr(selName, "LongLong") != nullptr || std::strstr(selName, "Int64") != nullptr;
    std::string key = (wide ? "W" : "N") + types;
    // Which doubles are CGFloats depends on the guest's encoding, or else the selector.
    if (types.find('d') != std::string::npos) key += guestTypes ? "|" + *guestTypes : std::string("/") + selName;
    std::lock_guard guard(lock);
    if (auto it = cache.find(key); it != cache.end()) return *it->second;

    auto call = std::make_unique<HostCall>();
    call->sig = parseSignature(types.c_str());
    if (guestTypes) markCGFloatsFromGuest(call->sig, *guestTypes);
    else markCGFloats(call->sig, selName);
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

namespace {
// The guest encoding of the method behind a trampoline IMP, or null.
const std::string *trampolineGuestTypes(IMP imp);
// The guest IMP behind a trampoline IMP, or 0.
GuestAddr trampolineGuestImp(IMP imp);
}  // namespace

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
        if (!start && guestProtocols_.count(receiver)) {
            // Protocols are objects that live forever: their memory
            // management does nothing, as the runtime's does; anything else
            // goes to the host's protocol of the same name.
            const char *name = selName(sel);
            if (!std::strcmp(name, "retain") || !std::strcmp(name, "autorelease") || !std::strcmp(name, "copy")) {
                cpu.setReg(0, receiver);
                return;
            }
            if (!std::strcmp(name, "release")) return;
            hostDispatch(c, receiver, sel, nullptr, stret);
            return;
        }
        if (!start && (blocks::isGuestBlock(*this, receiver) || isAlias(receiver))) {
            // Blocks answer copy, retain, release... as their host blocks, and
            // framework globals (&_dispatch_main_q) as the host objects they stand for.
            hostDispatch(c, receiver, sel, nullptr, stret);
            return;
        }
        if (!start) {
            GuestAddr isa = mem.isMapped(receiver) ? mem.read<uint32_t>(receiver) : 0;
            ClassInfo *asClass = classInfo(receiver);
            fatal("-%s sent to 0x%08x, which is not an object (isa 0x%08x; as a class: %s; from 0x%08x)", selName(sel),
                  receiver, isa, asClass ? asClass->name.c_str() : "unknown", cpu.reg(Cpu::LR));
        }
        if (!start->initialized && start->isGuest) ensureInitialized(start);
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

void Bridge::hostDispatch(Call &c, GuestAddr receiver, GuestAddr sel, ClassInfo *superInfo, bool stret, IMP direct) {
    GuestMemory &mem = rt_.mem();
    id recv = toHost(receiver);
    const char *name = selName(sel);
    SEL hsel = sel_registerName(name);
    // B32_TRACE_SENDS=1 logs every guest-to-host message.
    static const bool trace = getenv("B32_TRACE_SENDS") != nullptr;
    if (trace)
        log("guest -> host %c[%s %s]%s (thread %x)", object_isClass(recv) ? '+' : '-', object_getClassName(recv), name,
            superInfo ? " (super)" : "", pthread_mach_thread_np(pthread_self()));

    // A guest method behind a trampoline (a guest category on a host class)
    // runs here in the guest, as the guest's own runtime would run it, rather
    // than through the host and back: that would hand it host pointers for
    // its out-parameters (NSError **).
    if (recv) {
        IMP target = direct ? direct
                            : class_getMethodImplementation(superInfo ? superInfo->host : object_getClass(recv), hsel);
        if (GuestAddr guestImp = trampolineGuestImp(target)) {
            c.cpu.setReg(stret ? 1 : 0, receiver);
            c.cpu.jump(guestImp);
            return;
        }
    }

    Args args(c.cpu);
    GuestAddr retPtr = stret ? args.ptr() : 0;
    args.u32();  // self or objc_super
    args.u32();  // _cmd

    for (auto [it, end] = overrides().equal_range(name); !direct && it != end; ++it) {
        if (it->second.when && !it->second.when(recv)) continue;
        if (superInfo) fatal("super send of overridden selector %s is not supported yet", name);
        OverrideCall oc{c, *this, recv, receiver, hsel, name, args, retPtr};
        it->second.fn(oc);
        return;
    }

    Class lookup = superInfo ? superInfo->host : object_getClass(recv);
    std::string types;
    const std::string *guestTypes = nullptr;  // when the method is a guest one behind a trampoline
    if (Method m = class_getInstanceMethod(lookup, hsel)) {
        types = method_getTypeEncoding(m);
        guestTypes = trampolineGuestTypes(direct ? direct : method_getImplementation(m));
    } else if (NSMethodSignature *ms = [recv methodSignatureForSelector:hsel]) {
        types = ms.methodReturnType;
        for (NSUInteger i = 0; i < ms.numberOfArguments; i++) types += [ms getArgumentTypeAtIndex:i];
    } else {
        fatal("unrecognized selector %c[%s %s] (from 0x%08x)", object_isClass(recv) ? '+' : '-',
              class_getName(object_getClass(recv)), name, c.cpu.reg(Cpu::LR));
    }
    if (trace) log("    types %s%s", types.c_str(), guestTypes ? " (a guest method)" : "");
    HostCall &hc = hostCall(types, name, guestTypes);
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
        if (trace) log("    arg %zu '%c'%s: %zu word(s), first %08x", i, t.code, t.cgfloat ? " (CGFloat)" : "", words.size(), words.empty() ? 0 : words[0]);
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
    // The guest can't catch a host exception (no unwinding into guest
    // frames), so one thrown right here reads as the call returning zero:
    // the guest's @catch doesn't run, but code like SWRevealViewController,
    // which tries segues that may not exist, carries on.
    @try {
        ffi_call(&hc.cif, direct ? FFI_FN(direct) : superInfo ? FFI_FN(objc_msgSendSuper) : FFI_FN(objc_msgSend),
                 result, values.data());
    } @catch (NSException *e) {
        log("%c[%s %s] threw %s: %s; returning zero to the guest", object_isClass(recv) ? '+' : '-',
            object_getClassName(recv), name, e.name.UTF8String, e.reason.UTF8String);
        std::memset(result, 0, sizeof result);
    }

    for (const auto &out : outParams) toGuestValue(*out.type, out.host, mem.ptr<uint8_t>(out.guest));

    const Type &r = sig.ret;
    if (r.code == 'v') return;
    if (r.code == '@') {
        // Host objects live above 4 GB on arm64 macOS (tagged pointers have the top bit).
        auto value = *reinterpret_cast<uintptr_t *>(result);
        if (value && value < (uint64_t(1) << 32))
            fatal("%c[%s %s] returned 0x%lx, which isn't an object (type %s)", object_isClass(recv) ? '+' : '-',
                  object_getClassName(recv), name, (unsigned long)value, types.c_str());
    }
    if (r.code == '^' && !isCFRef(r)) {
        auto *p = *reinterpret_cast<uint8_t **>(result);
        uint8_t *base = mem.base();
        if (p && (p < base || p >= base + (uint64_t(1) << 32)))
            fatal("%c[%s %s] returned host pointer %p (type %s), which the guest can't use",
                  object_isClass(recv) ? '+' : '-', object_getClassName(recv), name, p, types.c_str());
    }
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
    std::string guestTypes;
    bool fastEnumeration = false;  // -countByEnumeratingWithState:objects:count:
};

std::mutex trampolinesLock;
std::unordered_map<void *, Trampoline *> trampolines;  // closure code -> its trampoline

// A host pointer argument (a stack buffer or out-parameter) that the guest
// can't reach: the guest gets a copy in its heap, copied back after the call.
struct Bounce {
    void *host;
    GuestAddr guest;
    uint32_t size;
    const Type *pointee;  // converted value by value; null for raw bytes
};

GuestAddr bounceIn(Bridge &bridge, GuestAddr sel, const Signature &sig, void **args, size_t i,
                   std::vector<Bounce> &bounces) {
    const Type &type = sig.args[i];
    if (type.code != '^') return 0;
    void *p = *static_cast<void **>(args[i]);
    GuestMemory &mem = bridge.runtime().mem();
    auto *bytes = static_cast<uint8_t *>(p);
    if (!p || (bytes >= mem.base() && bytes < mem.base() + GuestMemory::kSize)) return 0;
    GuestHeap &heap = bridge.runtime().heap();
    // -getCharacters:range: fills a unichar buffer as long as the range.
    if (i == 2 && sig.args.size() == 4 && std::strcmp(bridge.selName(sel), "getCharacters:range:") == 0) {
        uint32_t size = uint32_t(static_cast<NSRange *>(args[3])->length * 2);
        GuestAddr buffer = heap.alloc(size ? size : 1);
        bounces.push_back({p, buffer, size, nullptr});
        return buffer;
    }
    const Type *pointee = type.pointee.get();
    if (!pointee || pointee->code == 'v' || pointee->code == '?' || !pointee->guestSize()) return 0;
    GuestAddr buffer = heap.calloc(1, pointee->guestSize());
    // Objects are out-parameters (NSError **): their incoming value may be garbage.
    if (!pointee->isObject())
        bridge.toGuestValue(*pointee, bytes, mem.ptr<uint8_t>(buffer));
    bounces.push_back({p, buffer, pointee->guestSize(), pointee});
    return buffer;
}

void bounceOut(Bridge &bridge, const std::vector<Bounce> &bounces) {
    for (const Bounce &b : bounces) {
        uint8_t *guest = bridge.runtime().mem().ptr<uint8_t>(b.guest);
        if (b.pointee)
            bridge.toHostValue(*b.pointee, guest, static_cast<uint8_t *>(b.host));
        else
            std::memcpy(b.host, guest, b.size);
        bridge.runtime().heap().free(b.guest);
    }
}

// -countByEnumeratingWithState:objects:count: called by the host on a guest
// collection: the guest fills a 32-bit NSFastEnumerationState whose items
// are guest objects. The guest's state lives in the host state's extra[0..3]
// (32 bytes, untouched by the caller) between calls, the mutations word the
// host watches is a copy in extra[4], and the items are converted into the
// host's buffer, or a larger autoreleased one if the guest returns more.
NSUInteger fastEnumerate(Bridge &bridge, Trampoline *t, void **args) {
    id self = *static_cast<id *>(args[0]);
    auto *state = *static_cast<NSFastEnumerationState **>(args[2]);
    auto *buffer = *static_cast<__unsafe_unretained id **>(args[3]);
    auto len = uint32_t(*static_cast<NSUInteger *>(args[4]));
    Runtime &rt = bridge.runtime();
    GuestMemory &mem = rt.mem();
    GuestAddr guestState = rt.heap().calloc(1, 32);
    GuestAddr guestBuffer = rt.heap().calloc(len ? len : 1, 4);
    std::memcpy(mem.ptr<uint8_t>(guestState), state->extra, 32);
    uint32_t n = uint32_t(Runtime::threadCpu().call(
        t->imp, {bridge.toGuest(self), t->sel, guestState, guestBuffer, len}));
    std::memcpy(state->extra, mem.ptr<uint8_t>(guestState), 32);
    GuestAddr items = mem.read<uint32_t>(guestState + 4), mutations = mem.read<uint32_t>(guestState + 8);
    state->state = 1;
    state->extra[4] = mutations ? mem.read<uint32_t>(mutations) : 0;
    state->mutationsPtr = &state->extra[4];
    __unsafe_unretained id *out = buffer;
    if (n > len) out = (__unsafe_unretained id *)[NSMutableData dataWithLength:n * sizeof(id)].mutableBytes;
    for (uint32_t i = 0; i < n; i++) out[i] = bridge.toHost(mem.read<uint32_t>(items + i * 4));
    state->itemsPtr = out;
    rt.heap().free(guestState);
    rt.heap().free(guestBuffer);
    return n;
}

void trampolineEntry(ffi_cif *, void *ret, void **args, void *user) {
    auto *t = static_cast<Trampoline *>(user);
    if (t->fastEnumeration) {
        *static_cast<ffi_arg *>(ret) = fastEnumerate(*t->bridge, t, args);
        return;
    }
    Bridge &bridge = *t->bridge;
    // B32_TRACE_CALLS=1 logs every host-to-guest method call; any other
    // value logs the calls whose selector contains it.
    static const char *trace = getenv("B32_TRACE_CALLS");
    static const bool traceAll = trace && std::strcmp(trace, "1") == 0;
    if (trace && (traceAll || std::strstr(bridge.selName(t->sel), trace)))
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
    GuestAddr self = bridge.toGuest(*static_cast<id *>(args[0]));
    if (ClassInfo *cls = bridge.classOf(self); cls && cls->isGuest && !cls->initialized) bridge.ensureInitialized(cls);
    words.push_back(self);
    words.push_back(t->sel);
    std::vector<Bounce> bounces;
    for (size_t i = 2; i < sig.args.size(); i++) {
        const Type &type = sig.args[i];
        if (GuestAddr buffer = bounceIn(bridge, t->sel, sig, args, i, bounces)) {
            words.push_back(buffer);
            continue;
        }
        std::vector<uint32_t> w(wordsFor(type.guestSize()));
        bridge.toGuestValue(type, static_cast<const uint8_t *>(args[i]), reinterpret_cast<uint8_t *>(w.data()));
        words.insert(words.end(), w.begin(), w.end());
    }

    uint64_t r = cpu->call(t->imp, words);
    bounceOut(bridge, bounces);

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

namespace {
const std::string *trampolineGuestTypes(IMP imp) {
    std::lock_guard guard(trampolinesLock);
    auto it = trampolines.find(reinterpret_cast<void *>(imp));
    return it == trampolines.end() ? nullptr : &it->second->guestTypes;
}
GuestAddr trampolineGuestImp(IMP imp) {
    std::lock_guard guard(trampolinesLock);
    auto it = trampolines.find(reinterpret_cast<void *>(imp));
    return it == trampolines.end() ? 0 : it->second->imp;
}
}  // namespace

void Bridge::installTrampoline(Class target, GuestAddr sel, const GuestMethod &method, ClassInfo *owner) {
    // A guest +resolveInstanceMethod: would be called by the host runtime from
    // the method lookups that set up later classes, running guest code before
    // the image is ready; resolvers go in once setupImage is done.
    if (settingUp_ && owner->isMeta) {
        std::string name = selName(sel);
        if (name == "resolveInstanceMethod:" || name == "resolveClassMethod:") {
            deferredResolvers_.push_back({target, sel, method, owner});
            return;
        }
    }
    SEL hsel = hostSel(sel);
    std::string types = hostTypesFor(target, hsel, owner, method.types);
    HostCall &hc = hostCall(types, sel_getName(hsel), &method.types);
    void *code = nullptr;
    auto *closure = static_cast<ffi_closure *>(ffi_closure_alloc(sizeof(ffi_closure), &code));
    auto *t = new Trampoline{this, method.imp, sel, &hc, method.types};
    t->fastEnumeration = std::strcmp(selName(sel), "countByEnumeratingWithState:objects:count:") == 0;
    if (!closure || ffi_prep_closure_loc(closure, &hc.cif, trampolineEntry, t, code) != FFI_OK)
        fatal("could not create a trampoline for %s", sel_getName(hsel));
    {
        std::lock_guard guard(trampolinesLock);
        trampolines[code] = t;
    }
    if (!owner->isGuest && class_getInstanceMethod(target, hsel))
        log("guest category replaces host method %c[%s %s]", owner->isMeta ? '+' : '-', owner->name.c_str(), sel_getName(hsel));
    class_replaceMethod(target, hsel, reinterpret_cast<IMP>(code), types.c_str());
}

void Bridge::runLoadMethods(Cpu &cpu) {
    running_ = true;  // from here on, +initialize runs as classes are first used
    for (auto [cls, imp] : loadMethods_) cpu.call(imp, {cls->addr, guestSel("load")});
    loadMethods_.clear();
}
