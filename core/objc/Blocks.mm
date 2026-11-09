#include "Blocks.h"

#include "Bridge.h"
#include "Encoding.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <Block.h>
#include <ffi/ffi.h>
#include <objc/runtime.h>

#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <unordered_map>

using namespace b32;
using namespace b32::objc;

extern "C" {
extern void *_NSConcreteGlobalBlock[32];
extern void *_NSConcreteMallocBlock[32];
const char *_Block_signature(void *block);
id objc_autorelease(id);
}

namespace {

// Block_literal flags.
constexpr uint32_t kRefcountMask = 0xfffe;
constexpr uint32_t kNeedsFree = 1u << 24;
constexpr uint32_t kHasCopyDispose = 1u << 25;
constexpr uint32_t kIsGlobal = 1u << 28;
constexpr uint32_t kHasSignature = 1u << 30;

// Guest Block_literal and descriptor offsets.
constexpr uint32_t kIsa = 0, kFlags = 4, kInvoke = 12, kDescriptor = 16, kLiteralSize = 20;
constexpr uint32_t kDescSize = 4, kDescCopy = 8, kDescDispose = 12;

// libclosure's layout for the host blocks we build.
struct HostDescriptor {
    unsigned long reserved, size;
    void (*copy)(void *dst, const void *src);
    void (*dispose)(const void *block);
    const char *signature;
    const void *layout;
};
struct HostBlock {
    void *isa;
    int32_t flags, reserved;
    void *invoke;
    HostDescriptor *descriptor;
    GuestAddr guest;  // ours: the guest block this one calls
};

std::recursive_mutex lock;
// Host blocks made for guest blocks: guest global blocks and heap copies <-> host blocks.
std::unordered_map<GuestAddr, HostBlock *> hostByGuest;
std::unordered_map<const void *, GuestAddr> guestByHost;
// Guest blocks made for host blocks (the host block is held by its guest block).
std::unordered_map<const void *, GuestAddr> wrapperByHostBlock;
std::unordered_map<GuestAddr, void *> hostBlockByWrapper;

Bridge &bridge() { return *Bridge::shared(); }
GuestMemory &mem() { return bridge().runtime().mem(); }
GuestHeap &heap() { return bridge().runtime().heap(); }

struct GuestClasses {
    GuestAddr global, stack, malloc;
};
const GuestClasses &guestClasses() {
    static GuestClasses classes = [] {
        Runtime &rt = bridge().runtime();
        return GuestClasses{rt.dataSymbol("__NSConcreteGlobalBlock"), rt.dataSymbol("__NSConcreteStackBlock"),
                            rt.dataSymbol("__NSConcreteMallocBlock")};
    }();
    return classes;
}

GuestAddr guestDescriptorSlot(GuestAddr block, uint32_t offset) {
    return mem().read<uint32_t>(mem().read<uint32_t>(block + kDescriptor) + offset);
}

// The guest block's type encoding, e.g. "v12@?0@4i8".
std::string guestSignature(GuestAddr block) {
    uint32_t flags = mem().read<uint32_t>(block + kFlags);
    if (flags & kHasSignature) {
        GuestAddr descriptor = mem().read<uint32_t>(block + kDescriptor);
        GuestAddr slot = descriptor + 8 + ((flags & kHasCopyDispose) ? 8 : 0);
        if (GuestAddr signature = mem().read<uint32_t>(slot)) return mem().cstr(signature);
    }
    log("guest block at 0x%08x has no signature; calling it as void(void)", block);
    return "v4@?0";
}

bool isGeometry(const std::string &name) {
    return name.rfind("CG", 0) == 0 || name.rfind("UIEdgeInsets", 0) == 0 || name.rfind("UIOffset", 0) == 0 ||
           name == "_NSPoint" || name == "_NSSize" || name == "_NSRect";
}

// Guest encodings describe 32-bit types: a float is CGFloat as often as not
// (a double on the host), and 'q' really is 64-bit.
void hostify(Type &t, bool geometry) {
    if (t.code == 'f' && geometry) {
        t.code = 'd';
        t.cgfloat = true;
    }
    if (t.code == 'q' || t.code == 'Q') t.wide = true;
    if (t.isStruct())
        for (auto &f : t.fields) hostify(f, isGeometry(t.name));
}

// --- guest blocks called from the host ---------------------------------------------------

struct BlockCall {
    Signature sig;
    ffi_cif cif;
    std::vector<ffi_type *> argTypes;
    void *code = nullptr;
    HostDescriptor descriptor{};
    std::string signature;
};

void invokeGuest(ffi_cif *, void *ret, void **args, void *user) {
    auto *call = static_cast<BlockCall *>(user);
    const HostBlock *block = *static_cast<HostBlock **>(args[0]);
    Bridge &b = bridge();
    Runtime &rt = b.runtime();
    Cpu &cpu = Runtime::threadCpu();
    const Signature &sig = call->sig;

    std::vector<uint32_t> words;
    uint32_t retSize = sig.ret.guestSize();
    bool guestStret = guestReturnClass(sig.ret) == ReturnClass::Memory;
    GuestAddr retBuf = guestStret ? rt.heap().alloc(retSize) : 0;
    if (guestStret) words.push_back(retBuf);
    words.push_back(block->guest);
    // Out-pointers into host memory (BOOL *stop) go through guest temporaries.
    struct OutParam {
        const Type *type;
        GuestAddr guest;
        uint8_t *host;
    };
    std::vector<OutParam> outParams;
    for (size_t i = 1; i < sig.args.size(); i++) {
        const Type &type = sig.args[i];
        if (type.code == '^' && type.pointee && type.pointee->code != 'v' && type.pointee->code != '?') {
            auto *p = *static_cast<uint8_t **>(args[i]);
            uint8_t *base = rt.mem().base();
            GuestAddr g = 0;
            if (p >= base && p < base + (uint64_t(1) << 32)) {
                g = GuestAddr(p - base);
            } else if (p) {
                g = rt.heap().calloc(1, std::max(type.pointee->guestSize(), 4u));
                b.toGuestValue(*type.pointee, p, rt.mem().ptr<uint8_t>(g));
                outParams.push_back({type.pointee.get(), g, p});
            }
            words.push_back(g);
            continue;
        }
        std::vector<uint32_t> w((type.guestSize() + 3) / 4);
        b.toGuestValue(type, static_cast<const uint8_t *>(args[i]), reinterpret_cast<uint8_t *>(w.data()));
        words.insert(words.end(), w.begin(), w.end());
    }

    uint64_t r = cpu.call(rt.mem().read<uint32_t>(block->guest + kInvoke), words);
    for (const auto &out : outParams) {
        b.toHostValue(*out.type, rt.mem().ptr<uint8_t>(out.guest), out.host);
        rt.heap().free(out.guest);
    }

    const Type &rt_ = sig.ret;
    if (rt_.code == 'v') return;
    alignas(8) uint8_t guest[256] = {};
    if (guestStret) {
        std::memcpy(guest, rt.mem().ptr<uint8_t>(retBuf), retSize);
        rt.heap().free(retBuf);
    } else {
        b.resultFromGuest(cpu, rt_, r, guest);
    }
    alignas(16) uint8_t host[256] = {};
    b.toHostValue(rt_, guest, host);
    switch (rt_.code) {  // libffi wants small integers widened to a full ffi_arg
    case 'c': *static_cast<ffi_sarg *>(ret) = int8_t(host[0]); break;
    case 's': *static_cast<ffi_sarg *>(ret) = *reinterpret_cast<int16_t *>(host); break;
    case 'i': *static_cast<ffi_sarg *>(ret) = *reinterpret_cast<int32_t *>(host); break;
    case 'C': case 'B': *static_cast<ffi_arg *>(ret) = host[0]; break;
    case 'S': *static_cast<ffi_arg *>(ret) = *reinterpret_cast<uint16_t *>(host); break;
    case 'I': *static_cast<ffi_arg *>(ret) = *reinterpret_cast<uint32_t *>(host); break;
    default: std::memcpy(ret, host, rt_.hostSize()); break;
    }
}

void freeGuestCopy(GuestAddr copy) {
    if (mem().read<uint32_t>(copy + kFlags) & kHasCopyDispose)
        Runtime::threadCpu().call(guestDescriptorSlot(copy, kDescDispose), {copy});
    heap().free(copy);
}

// Host blocks are never on the stack, so libclosure never copies one.
void hostCopyHelper(void *, const void *) {}

// The last reference to a host block that owns a guest heap copy is gone.
void hostDisposeHelper(const void *p) {
    auto *block = static_cast<const HostBlock *>(p);
    {
        std::lock_guard guard(lock);
        hostByGuest.erase(block->guest);
        guestByHost.erase(block);
    }
    freeGuestCopy(block->guest);
}

// One closure and descriptor per guest signature.
BlockCall &blockCall(const std::string &signature) {
    static std::unordered_map<std::string, std::unique_ptr<BlockCall>> cache;
    std::lock_guard guard(lock);
    if (auto it = cache.find(signature); it != cache.end()) return *it->second;
    auto call = std::make_unique<BlockCall>();
    call->signature = signature;
    call->sig = parseSignature(signature.c_str());
    hostify(call->sig.ret, call->sig.ret.code == 'f');
    for (auto &a : call->sig.args) hostify(a, a.code == 'f');
    for (const auto &a : call->sig.args) call->argTypes.push_back(ffiType(a));
    if (ffi_prep_cif(&call->cif, FFI_DEFAULT_ABI, unsigned(call->argTypes.size()), ffiType(call->sig.ret),
                     call->argTypes.data()) != FFI_OK)
        fatal("libffi rejected the block signature %s", signature.c_str());
    auto *closure = static_cast<ffi_closure *>(ffi_closure_alloc(sizeof(ffi_closure), &call->code));
    if (!closure || ffi_prep_closure_loc(closure, &call->cif, invokeGuest, call.get(), call->code) != FFI_OK)
        fatal("could not create a closure for the block signature %s", signature.c_str());
    call->descriptor = {0, sizeof(HostBlock), hostCopyHelper, hostDisposeHelper, call->signature.c_str(), nullptr};
    return *cache.emplace(signature, std::move(call)).first->second;
}

HostBlock *makeHostBlock(GuestAddr guest, bool global) {
    BlockCall &call = blockCall(guestSignature(guest));
    auto *block = static_cast<HostBlock *>(calloc(1, sizeof(HostBlock)));
    block->isa = global ? _NSConcreteGlobalBlock : _NSConcreteMallocBlock;
    // A malloc'd block starts with one reference (libclosure counts in twos).
    block->flags = int32_t((global ? kIsGlobal : (kNeedsFree | 2)) | kHasCopyDispose | kHasSignature);
    block->invoke = call.code;
    block->descriptor = &call.descriptor;
    block->guest = guest;
    hostByGuest[guest] = block;
    guestByHost[block] = guest;
    return block;
}

// Block_copy of a guest stack block: a guest heap copy, its copy helper run.
GuestAddr copyToGuestHeap(GuestAddr src) {
    GuestMemory &m = mem();
    uint32_t size = m.read<uint32_t>(m.read<uint32_t>(src + kDescriptor) + kDescSize);
    GuestAddr copy = heap().alloc(size);
    std::memcpy(m.ptr<void>(copy), m.ptr<void>(src), size);
    m.write<uint32_t>(copy + kIsa, guestClasses().malloc);
    uint32_t flags = m.read<uint32_t>(src + kFlags);
    m.write<uint32_t>(copy + kFlags, (flags & ~kRefcountMask) | kNeedsFree | 2);
    if (flags & kHasCopyDispose) Runtime::threadCpu().call(guestDescriptorSlot(src, kDescCopy), {copy, src});
    return copy;
}

// --- host blocks called from the guest --------------------------------------------------------

GuestAddr guestWrapperDescriptor() {
    static GuestAddr descriptor = [] {
        GuestAddr d = heap().calloc(1, 8);
        mem().write<uint32_t>(d + kDescSize, kLiteralSize);
        return d;
    }();
    return descriptor;
}

GuestAddr makeGuestWrapper(void *hostBlock) {
    GuestAddr w = heap().calloc(1, kLiteralSize);
    mem().write<uint32_t>(w + kIsa, guestClasses().malloc);
    mem().write<uint32_t>(w + kFlags, kNeedsFree | 2);
    mem().write<uint32_t>(w + kInvoke, bridge().runtime().thunks().stubFor("__b32_invoke_host_block"));
    mem().write<uint32_t>(w + kDescriptor, guestWrapperDescriptor());
    hostBlockByWrapper[w] = hostBlock;
    return w;
}

void *hostBlockForWrapper(GuestAddr w) {
    std::lock_guard guard(lock);
    auto it = hostBlockByWrapper.find(w);
    return it == hostBlockByWrapper.end() ? nullptr : it->second;
}

bool isHostBlockClass(Class cls) {
    static Class global = objc_getClass("__NSGlobalBlock__"), malloc = objc_getClass("__NSMallocBlock__"),
                 stack = objc_getClass("__NSStackBlock__");
    return cls == global || cls == malloc || cls == stack;
}

}  // namespace

// --- the bridge's side ---------------------------------------------------------------------------

bool blocks::isGuestBlock(Bridge &bridge, GuestAddr object) {
    GuestMemory &m = bridge.runtime().mem();
    if (!object || !m.isMapped(object)) return false;
    GuestAddr isa = m.read<uint32_t>(object);
    const GuestClasses &c = guestClasses();
    return isa && (isa == c.global || isa == c.stack || isa == c.malloc);
}

bool blocks::isGuestStackBlock(Bridge &bridge, GuestAddr object) {
    return isGuestBlock(bridge, object) && bridge.runtime().mem().read<uint32_t>(object) == guestClasses().stack;
}

id blocks::toHost(Bridge &bridge, GuestAddr object) {
    if (!isGuestBlock(bridge, object)) return nil;
    GuestAddr isa = bridge.runtime().mem().read<uint32_t>(object);
    {
        std::lock_guard guard(lock);
        if (auto it = hostBlockByWrapper.find(object); it != hostBlockByWrapper.end()) return (id)it->second;
        if (auto it = hostByGuest.find(object); it != hostByGuest.end()) return (id)it->second;
        if (isa == guestClasses().global) return (id)makeHostBlock(object, true);
        if (isa == guestClasses().malloc) fatal("guest heap block 0x%08x wasn't made by Block_copy", object);
    }
    // A stack block: copied now (its copy helper runs guest code, so with no
    // lock held), owned by an autoreleased host block.
    GuestAddr copy = copyToGuestHeap(object);
    std::lock_guard guard(lock);
    return objc_autorelease((id)makeHostBlock(copy, false));
}

GuestAddr blocks::toGuest(Bridge &, id object) {
    if (!object || !isHostBlockClass(object_getClass(object))) return 0;
    std::lock_guard guard(lock);
    if (auto it = guestByHost.find(object); it != guestByHost.end()) return it->second;
    if (auto it = wrapperByHostBlock.find(object); it != wrapperByHostBlock.end()) return it->second;
    // A host block: its guest wrapper keeps a copy of it alive.
    void *held = _Block_copy(object);
    GuestAddr w = makeGuestWrapper(held);
    wrapperByHostBlock[object] = w;
    wrapperByHostBlock[held] = w;
    return w;
}

GuestAddr blocks::copy(Bridge &b, GuestAddr block) {
    if (!block) return 0;
    if (void *host = hostBlockForWrapper(block)) {
        _Block_copy(host);
        return block;
    }
    id host = toHost(b, block);
    if (!host) fatal("Block_copy of 0x%08x, which isn't a block", block);
    return toGuest(b, (id)_Block_copy(host));
}

void blocks::release(Bridge &b, GuestAddr block) {
    if (!block) return;
    if (void *host = hostBlockForWrapper(block)) {
        _Block_release(host);
        return;
    }
    if (!isGuestBlock(b, block) || b.runtime().mem().read<uint32_t>(block) == guestClasses().stack) return;
    _Block_release(toHost(b, block));
}

// --- the guest's block runtime --------------------------------------------------------------------

B32_DATA(__NSConcreteGlobalBlock, 32) {}
B32_DATA(__NSConcreteStackBlock, 32) {}
B32_DATA(__NSConcreteMallocBlock, 32) {}

B32_THUNK(__Block_copy) { c.ret(blocks::copy(c.rt.bridge(), c.args.ptr())); }
B32_THUNK(__Block_release) { blocks::release(c.rt.bridge(), c.args.ptr()); }
B32_THUNK(_objc_retainBlock) { c.ret(blocks::copy(c.rt.bridge(), c.args.ptr())); }

namespace {

// _Block_object_assign/_Block_object_dispose flags.
constexpr int kFieldIsObject = 3, kFieldIsBlock = 7, kFieldIsByref = 8, kFieldIsWeak = 16, kByrefCaller = 128;
constexpr int kFieldFlags = kFieldIsObject | kFieldIsBlock | kFieldIsByref | kFieldIsWeak | kByrefCaller;

// __block variables: { isa, forwarding, flags, size, [keep, destroy], [layout], variable... }
constexpr uint32_t kByrefForwarding = 4, kByrefFlags = 8, kByrefSize = 12, kByrefKeep = 16, kByrefDestroy = 20;
constexpr uint32_t kByrefLayout = 24, kByrefHeader = 16;
constexpr uint32_t kByrefNeedsFree = 1u << 24, kByrefHasCopyDispose = 1u << 25, kByrefLayoutExtended = 1u << 28;

GuestAddr byrefCopy(GuestAddr src) {
    GuestMemory &m = mem();
    std::unique_lock guard(lock);
    GuestAddr forwarding = m.read<uint32_t>(src + kByrefForwarding);
    uint32_t flags = m.read<uint32_t>(forwarding + kByrefFlags);
    if ((flags & kRefcountMask) == 0) {
        // Still on the stack: move it to the heap, with two references (the
        // stack frame's and the copier's).
        uint32_t size = m.read<uint32_t>(src + kByrefSize);
        GuestAddr copy = heap().calloc(1, size);
        m.write<uint32_t>(copy + kByrefForwarding, copy);
        m.write<uint32_t>(copy + kByrefFlags, flags | kByrefNeedsFree | 4);
        m.write<uint32_t>(copy + kByrefSize, size);
        m.write<uint32_t>(src + kByrefForwarding, copy);
        if (flags & kByrefHasCopyDispose) {
            m.write<uint32_t>(copy + kByrefKeep, m.read<uint32_t>(src + kByrefKeep));
            m.write<uint32_t>(copy + kByrefDestroy, m.read<uint32_t>(src + kByrefDestroy));
            if (flags & kByrefLayoutExtended) m.write<uint32_t>(copy + kByrefLayout, m.read<uint32_t>(src + kByrefLayout));
            guard.unlock();  // the keep helper is guest code
            Runtime::threadCpu().call(m.read<uint32_t>(src + kByrefKeep), {copy, src});
        } else {
            std::memcpy(m.ptr<uint8_t>(copy + kByrefHeader), m.ptr<uint8_t>(src + kByrefHeader), size - kByrefHeader);
        }
        return copy;
    }
    if (flags & kByrefNeedsFree) m.write<uint32_t>(forwarding + kByrefFlags, flags + 2);
    return forwarding;
}

void byrefRelease(GuestAddr byref) {
    GuestMemory &m = mem();
    std::unique_lock guard(lock);
    GuestAddr forwarding = m.read<uint32_t>(byref + kByrefForwarding);
    uint32_t flags = m.read<uint32_t>(forwarding + kByrefFlags);
    if (!(flags & kByrefNeedsFree)) return;
    if ((flags & kRefcountMask) > 2) {
        m.write<uint32_t>(forwarding + kByrefFlags, flags - 2);
        return;
    }
    guard.unlock();  // the destroy helper is guest code
    if (flags & kByrefHasCopyDispose) Runtime::threadCpu().call(m.read<uint32_t>(forwarding + kByrefDestroy), {forwarding});
    heap().free(forwarding);
}

}  // namespace

// void _Block_object_assign(void *dest, const void *object, int flags): what a
// block's copy helper calls for each captured object, block and __block variable.
B32_THUNK(__Block_object_assign) {
    GuestAddr dest = c.args.ptr(), object = c.args.ptr();
    int flags = c.args.i32() & kFieldFlags;
    Bridge &b = c.rt.bridge();
    GuestAddr value = object;
    switch (flags) {
    case kFieldIsObject:
        if (object) b.send(object, "retain");
        break;
    case kFieldIsBlock: value = blocks::copy(b, object); break;
    case kFieldIsByref:
    case kFieldIsByref | kFieldIsWeak: value = byrefCopy(object); break;
    default: break;  // __block variables' own fields (kByrefCaller): stored as is
    }
    c.mem.write<uint32_t>(dest, value);
}

// void _Block_object_dispose(const void *object, int flags)
B32_THUNK(__Block_object_dispose) {
    GuestAddr object = c.args.ptr();
    int flags = c.args.i32() & kFieldFlags;
    Bridge &b = c.rt.bridge();
    switch (flags) {
    case kFieldIsObject:
        if (object) b.send(object, "release");
        break;
    case kFieldIsBlock: blocks::release(b, object); break;
    case kFieldIsByref:
    case kFieldIsByref | kFieldIsWeak: byrefRelease(object); break;
    default: break;
    }
}

// The invoke function of a guest block that stands for a host block:
// converts the guest arguments by the host block's own signature and calls it.
B32_THUNK(__b32_invoke_host_block) {
    Bridge &b = c.rt.bridge();
    // A block returning a large struct takes the result pointer as its first argument.
    bool stret = !hostBlockForWrapper(c.cpu.arg(0));
    GuestAddr retPtr = stret ? c.args.ptr() : 0;
    void *host = hostBlockForWrapper(c.args.ptr());
    if (!host) fatal("host block thunk called without its block");
    const char *types = _Block_signature(host);
    if (!types) fatal("host block has no signature");

    struct Call {
        Signature sig;
        ffi_cif cif;
        std::vector<ffi_type *> argTypes;
    };
    static std::unordered_map<std::string, std::unique_ptr<Call>> cache;
    Call *call;
    {
        std::lock_guard guard(lock);
        auto it = cache.find(types);
        if (it == cache.end()) {
            if (getenv("B32_TRACE_CALLS")) log("host block signature %s", types);
            auto made = std::make_unique<Call>();
            made->sig = parseSignature(types);
            for (const auto &a : made->sig.args) made->argTypes.push_back(ffiType(a));
            if (ffi_prep_cif(&made->cif, FFI_DEFAULT_ABI, unsigned(made->argTypes.size()), ffiType(made->sig.ret),
                             made->argTypes.data()) != FFI_OK)
                fatal("libffi rejected the block signature %s", types);
            it = cache.emplace(types, std::move(made)).first;
        }
        call = it->second.get();
    }
    const Signature &sig = call->sig;

    std::vector<void *> values(sig.args.size());
    std::vector<std::vector<uint8_t>> storage(sig.args.size());
    values[0] = &host;
    for (size_t i = 1; i < sig.args.size(); i++) {
        const Type &t = sig.args[i];
        std::vector<uint32_t> words((t.guestSize() + 3) / 4);
        for (auto &w : words) w = c.args.u32();
        storage[i].resize(std::max<size_t>(t.hostSize(), 8));
        b.toHostValue(t, reinterpret_cast<const uint8_t *>(words.data()), storage[i].data());
        values[i] = storage[i].data();
    }
    alignas(16) uint8_t result[256] = {};
    ffi_call(&call->cif, FFI_FN(static_cast<HostBlock *>(host)->invoke), result, values.data());

    const Type &r = sig.ret;
    if (r.code == 'v') return;
    alignas(8) uint8_t guest[256] = {};
    b.toGuestValue(r, result, guest);
    b.returnToGuest(c, r, guest, retPtr);
}
