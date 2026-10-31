// Classes, selectors and object identity. Message dispatch is in Dispatch.mm.

#include "Bridge.h"
#include "Blocks.h"

#include "core/Log.h"
#include "core/Runtime.h"

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <malloc/malloc.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <unordered_set>

using namespace b32;
using namespace b32::objc;

// Attached to every host object that has a guest side; its dealloc runs when
// the host object is destroyed, after the object's own -dealloc chain.
@interface B32Sentinel : NSObject {
@public
    Bridge *bridge;
    uint32_t handle;
}
@end

@implementation B32Sentinel
- (void)dealloc {
    bridge->forget(handle);
    [super dealloc];
}
@end

// Guest C strings handed out for a host object (UTF8String and friends).
@interface B32GuestBuffers : NSObject {
@public
    GuestHeap *heap;
    std::vector<GuestAddr> *buffers;
}
@end

@implementation B32GuestBuffers
- (void)dealloc {
    for (GuestAddr b : *buffers) heap->free(b);
    delete buffers;
    [super dealloc];
}
@end

namespace {

char sentinelKey;
char buffersKey;

// Guest 32-bit runtime structures (objc4's class_t, class_ro_t, ...).
namespace layout32 {
constexpr uint32_t kClassIsa = 0, kClassSuper = 4, kClassData = 16, kClassSize = 20;
constexpr uint32_t kRoFlags = 0, kRoInstanceStart = 4, kRoInstanceSize = 8, kRoName = 16, kRoMethods = 20,
                   kRoProtocols = 24, kRoIvars = 28;
constexpr uint32_t kRoMeta = 1;
constexpr uint32_t kCategoryName = 0, kCategoryClass = 4, kCategoryInstanceMethods = 8, kCategoryClassMethods = 12;
}  // namespace layout32

bool isTaggedPointer(id object) { return (reinterpret_cast<uintptr_t>(object) & (1ull << 63)) != 0; }

}  // namespace

namespace {
Bridge *sharedBridge = nullptr;

// Host KVC falls back to this when a key matches no method or host ivar.
// Guest ivars live in guest memory, so outlets connected to them land here.
void shadowSetValueForUndefinedKey(id self, SEL _cmd, id value, NSString *key) {
    Bridge &bridge = *Bridge::shared();
    GuestAddr guestSelf = bridge.toGuest(self);
    ClassInfo *cls = bridge.classOf(guestSelf);
    const GuestIvar *ivar = bridge.ivarForKey(cls, [key UTF8String]);
    if (!ivar || ivar->type.empty() || ivar->type[0] != '@') {
        // Not ours: let the first real host superclass raise as usual.
        Class super = object_getClass(self);
        while (bridge.isShadowClass(super)) super = class_getSuperclass(super);
        struct objc_super sup{self, super};
        reinterpret_cast<void (*)(struct objc_super *, SEL, id, NSString *)>(objc_msgSendSuper)(&sup, _cmd, value, key);
        return;
    }
    GuestMemory &mem = bridge.runtime().mem();
    GuestAddr slot = guestSelf + mem.read<uint32_t>(ivar->offsetVar);
    GuestAddr old = mem.read<uint32_t>(slot);
    GuestAddr fresh = bridge.toGuest(value);
    // KVC's direct ivar access retains the new value, as on iOS.
    [value retain];
    mem.write<uint32_t>(slot, fresh);
    if (old) [bridge.toHost(old) release];
}
}  // namespace

Bridge *Bridge::shared() { return sharedBridge; }

bool Bridge::isShadowClass(Class c) {
    std::lock_guard guard(lock_);
    auto it = byHostClass_.find(c);
    return it != byHostClass_.end() && it->second->isGuest;
}

const GuestIvar *Bridge::ivarForKey(ClassInfo *cls, const std::string &key) {
    for (ClassInfo *c = cls; c && c->isGuest; c = c->super)
        for (const auto &ivar : c->ivars)
            if (ivar.name == key || ivar.name == "_" + key) return &ivar;
    return nullptr;
}

Bridge::Bridge(Runtime &rt) : rt_(rt) {
    sharedBridge = this;
    handleObjects_.push_back(nil);  // handle 0 is never valid
    handleGuests_.push_back(0);
    emptyCache_ = rt_.heap().calloc(1, 16);
    cfstringIsa_ = rt_.heap().calloc(1, 32);
}

// --- selectors --------------------------------------------------------------

GuestAddr Bridge::guestSel(const char *name) {
    std::lock_guard guard(lock_);
    if (auto it = selByName_.find(name); it != selByName_.end()) return it->second;
    GuestAddr addr = rt_.internString(name);
    selByName_.emplace(name, addr);
    nameBySel_.emplace(addr, name);
    return addr;
}

GuestAddr Bridge::guestSel(SEL sel) { return guestSel(sel_getName(sel)); }

const char *Bridge::selName(GuestAddr sel) {
    std::lock_guard guard(lock_);
    if (auto it = nameBySel_.find(sel); it != nameBySel_.end()) return it->second.c_str();
    // Not interned (a selector string the guest built itself): intern it now.
    return nameBySel_.find(guestSel(rt_.mem().cstr(sel)))->second.c_str();
}

SEL Bridge::hostSel(GuestAddr sel) { return sel_registerName(selName(sel)); }

// --- classes ----------------------------------------------------------------

GuestAddr Bridge::resolveDataSymbol(const std::string &symbol) {
    static const std::string classPrefix = "_OBJC_CLASS_$_", metaPrefix = "_OBJC_METACLASS_$_";
    if (symbol.compare(0, classPrefix.size(), classPrefix) == 0)
        return stubForName(symbol.substr(classPrefix.size()))->addr;
    if (symbol.compare(0, metaPrefix.size(), metaPrefix) == 0)
        return stubForName(symbol.substr(metaPrefix.size()))->meta->addr;
    if (symbol == "__objc_empty_cache" || symbol == "__objc_empty_vtable") return emptyCache_;
    if (symbol == "___CFConstantStringClassReference") return cfstringIsa_;
    return 0;
}

namespace {
// Whether `address` lies in a data (not code) segment of a loaded image.
bool inDataSegment(const void *address) {
    Dl_info info;
    if (!dladdr(address, &info) || !info.dli_fbase) return false;
    auto *header = static_cast<const mach_header_64 *>(info.dli_fbase);
    auto cmd = reinterpret_cast<const uint8_t *>(header + 1);
    uintptr_t slide = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        auto *lc = reinterpret_cast<const load_command *>(cmd);
        if (lc->cmd == LC_SEGMENT_64) {
            auto *seg = reinterpret_cast<const segment_command_64 *>(cmd);
            if (std::strcmp(seg->segname, "__TEXT") == 0) slide = uintptr_t(header) - seg->vmaddr;
        }
        cmd += lc->cmdsize;
    }
    cmd = reinterpret_cast<const uint8_t *>(header + 1);
    auto addr = uintptr_t(address);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        auto *lc = reinterpret_cast<const load_command *>(cmd);
        if (lc->cmd == LC_SEGMENT_64) {
            auto *seg = reinterpret_cast<const segment_command_64 *>(cmd);
            if (addr >= seg->vmaddr + slide && addr < seg->vmaddr + slide + seg->vmsize)
                return std::strcmp(seg->segname, "__TEXT") != 0;
        }
        cmd += lc->cmdsize;
    }
    return false;
}

// Whether `cls` is a registered class or metaclass, decided without asking
// the runtime about it: for a non-object (C++ typeinfo, whose first word is a
// vtable) that would crash.
bool isRegisteredClass(Class cls) {
    static std::mutex lock;
    static std::unordered_set<Class> classes;
    static int known = 0;
    std::lock_guard guard(lock);
    if (classes.count(cls)) return true;
    int count = objc_getClassList(nullptr, 0);
    if (count == known) return false;
    std::vector<Class> list(size_t(count) + 64);
    count = objc_getClassList(list.data(), int(list.size()));
    for (int i = 0; i < count; i++) {
        classes.insert(list[size_t(i)]);
        classes.insert(object_getClass(list[size_t(i)]));
    }
    known = count;
    return classes.count(cls) != 0;
}

// Whether `p` is plausibly an ObjC object: a tagged pointer, or memory whose
// class the runtime knows.
bool looksLikeObject(void *p) {
    if (!p) return false;
    if (isTaggedPointer((id)p)) return true;
    if ((uintptr_t(p) & 7) != 0) return false;
    Dl_info info;
    bool inImage = dladdr(p, &info) != 0;
    if (!inImage && !malloc_zone_from_ptr(p)) return false;
    // Code (a function pointer variable such as libxml2's xmlFree) isn't an object.
    if (inImage && !inDataSegment(p)) return false;
    // The class from the isa word, masked as the arm64 runtime does, checked
    // before the runtime is asked anything about it.
    constexpr uintptr_t kIsaMask = 0x0000000ffffffff8;
    auto cls = reinterpret_cast<Class>(*static_cast<uintptr_t *>(p) & kIsaMask);
    return isRegisteredClass(cls);
}
}  // namespace

namespace {
bool endsWith(const std::string &s, const char *suffix) {
    size_t n = std::strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}
}  // namespace

GuestAddr Bridge::resolveHostConstant(const std::string &symbol) {
    if (symbol.size() < 2 || symbol[0] != '_') return 0;
    // C++ symbols (typeinfo, vtables) aren't ObjC objects, and their first
    // word would crash the runtime's class lookup.
    if (symbol.compare(0, 3, "__Z") == 0) return 0;
    void *address = dlsym(RTLD_DEFAULT, symbol.c_str() + 1);
    void *value = nullptr;
    if (address && inDataSegment(address)) {
        value = *static_cast<void **>(address);
        if (!looksLikeObject(value)) return 0;
    } else if (!address && (endsWith(symbol, "Notification") || endsWith(symbol, "Key"))) {
        // Gone from the host (MPMoviePlayerContentPreloadDidFinishNotification):
        // such names have always been strings equal to the symbol's name.
        value = [[NSString alloc] initWithUTF8String:symbol.c_str() + 1];
        log("host has no %s; using a string of its name", symbol.c_str() + 1);
    } else {
        return 0;
    }
    std::lock_guard guard(lock_);
    if (auto it = hostConstants_.find(symbol); it != hostConstants_.end()) return it->second;
    GuestAddr variable = rt_.heap().calloc(1, 4);
    rt_.mem().write<uint32_t>(variable, toGuest((id)value));
    hostConstants_.emplace(symbol, variable);
    return variable;
}

ClassInfo *Bridge::stubForName(const std::string &name) {
    std::lock_guard guard(lock_);
    if (auto it = stubsByName_.find(name); it != stubsByName_.end()) return it->second;
    // A class Mac Catalyst lacks or doesn't support (UIAlertView) can have a
    // compat replacement named B32Compat_<name>, which the guest gets instead.
    Class host = objc_getClass(("B32Compat_" + name).c_str());
    if (!host) host = objc_getClass(name.c_str());
    if (!host) log("class %s doesn't exist on the host; messages to it will fail", name.c_str());
    return makeStub(host, name);
}

ClassInfo *Bridge::stubFor(Class hostClass) {
    std::lock_guard guard(lock_);
    if (auto it = byHostClass_.find(hostClass); it != byHostClass_.end()) return it->second;
    return makeStub(hostClass, class_getName(hostClass));
}

ClassInfo *Bridge::makeStub(Class host, const std::string &name) {
    if (host && class_isMetaClass(host)) fatal("makeStub called with metaclass %s", name.c_str());
    ClassInfo *superInfo = nullptr;
    if (host)
        if (Class super = class_getSuperclass(host)) superInfo = stubFor(super);

    auto *cls = new ClassInfo;
    auto *meta = new ClassInfo;
    cls->name = meta->name = name;
    meta->isMeta = true;
    cls->meta = meta;
    meta->instance = cls;
    cls->host = host;
    meta->host = host ? object_getClass(host) : nullptr;
    cls->super = superInfo;
    // A root metaclass's superclass is the root class itself.
    meta->super = superInfo ? superInfo->meta : cls;

    GuestMemory &mem = rt_.mem();
    cls->addr = rt_.heap().calloc(1, layout32::kClassSize);
    meta->addr = rt_.heap().calloc(1, layout32::kClassSize);
    ClassInfo *rootMeta = meta;
    while (rootMeta->super && rootMeta->super->isMeta) rootMeta = rootMeta->super;
    mem.write<uint32_t>(cls->addr + layout32::kClassIsa, meta->addr);
    mem.write<uint32_t>(cls->addr + layout32::kClassSuper, superInfo ? superInfo->addr : 0);
    mem.write<uint32_t>(meta->addr + layout32::kClassIsa, rootMeta->addr);
    mem.write<uint32_t>(meta->addr + layout32::kClassSuper, meta->super->addr);

    classes_[cls->addr] = cls;
    classes_[meta->addr] = meta;
    if (host) {
        byHostClass_[host] = cls;
        byHostClass_[meta->host] = meta;
    }
    stubsByName_[name] = cls;
    return cls;
}

ClassInfo *Bridge::classNamed(const std::string &name) {
    {
        std::lock_guard guard(lock_);
        for (auto &[addr, info] : classes_)
            if (info->isGuest && !info->isMeta && info->name == name) return info;
    }
    if (!objc_getClass(name.c_str())) return nullptr;
    return stubForName(name);
}

ClassInfo *Bridge::classInfo(GuestAddr cls) {
    std::lock_guard guard(lock_);
    auto it = classes_.find(cls);
    return it == classes_.end() ? nullptr : it->second;
}

ClassInfo *Bridge::classOf(GuestAddr object) {
    GuestAddr isa = rt_.mem().read<uint32_t>(object);
    if (isa == cfstringIsa_) return stubForName("NSString");
    return classInfo(isa);
}

void Bridge::setupImage(const Image &image) {
    GuestMemory &mem = rt_.mem();

    for (const auto &s : image.sections) {
        if (s.name == "__cfstring") cfstringSections_.push_back({s.addr, s.addr + s.size});
        // Unique selector references: each points at a name string.
        if (s.name == "__objc_selrefs")
            for (uint32_t off = 0; off < s.size; off += 4)
                mem.write<uint32_t>(s.addr + off, guestSel(mem.cstr(mem.read<uint32_t>(s.addr + off))));
    }

    if (const Section *list = image.section("__DATA", "__objc_classlist"))
        for (uint32_t off = 0; off < list->size; off += 4) realizeGuestClass(mem.read<uint32_t>(list->addr + off));

    if (const Section *list = image.section("__DATA", "__objc_catlist")) {
        for (uint32_t off = 0; off < list->size; off += 4) {
            GuestAddr cat = mem.read<uint32_t>(list->addr + off);
            GuestAddr target = mem.read<uint32_t>(cat + layout32::kCategoryClass);
            ClassInfo *cls = classInfo(target);
            if (!cls) cls = realizeGuestClass(target);
            const char *catName = mem.cstr(mem.read<uint32_t>(cat + layout32::kCategoryName));

            for (auto [info, listOffset] : {std::pair{cls, layout32::kCategoryInstanceMethods},
                                            std::pair{cls->meta, layout32::kCategoryClassMethods}}) {
                GuestAddr methods = mem.read<uint32_t>(cat + listOffset);
                if (!methods) continue;
                ClassInfo staging;
                addGuestMethods(&staging, methods);
                for (auto &[sel, method] : staging.methods) {
                    info->methods[sel] = method;
                    if (selName(sel) == std::string("load") && info->isMeta) loadMethods_.push_back({info->instance, method.imp});
                    // Host code must see the category too.
                    if (info->host) installTrampoline(info->host, sel, method, info);
                }
            }
            log("category %s(%s) loaded", cls->name.c_str(), catName);
        }
    }
}

void Bridge::addGuestMethods(ClassInfo *info, GuestAddr list) {
    GuestMemory &mem = rt_.mem();
    uint32_t entsize = mem.read<uint32_t>(list) & ~3u;
    uint32_t count = mem.read<uint32_t>(list + 4);
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr m = list + 8 + i * entsize;
        GuestAddr sel = guestSel(mem.cstr(mem.read<uint32_t>(m)));
        info->methods[sel] = GuestMethod{mem.read<uint32_t>(m + 8), mem.cstr(mem.read<uint32_t>(m + 4))};
    }
}

ClassInfo *Bridge::realizeGuestClass(GuestAddr addr) {
    std::lock_guard guard(lock_);
    if (ClassInfo *existing = classInfo(addr)) return existing;
    GuestMemory &mem = rt_.mem();

    GuestAddr superAddr = mem.read<uint32_t>(addr + layout32::kClassSuper);
    // A root class of the app's own (no superclass) works between guest
    // objects; with no host ancestor it gets no shadow class.
    ClassInfo *super = superAddr ? classInfo(superAddr) : nullptr;
    if (superAddr && !super) super = realizeGuestClass(superAddr);

    GuestAddr metaAddr = mem.read<uint32_t>(addr + layout32::kClassIsa);
    GuestAddr ro = mem.read<uint32_t>(addr + layout32::kClassData) & ~3u;
    GuestAddr metaRo = mem.read<uint32_t>(metaAddr + layout32::kClassData) & ~3u;

    auto *cls = new ClassInfo;
    auto *meta = new ClassInfo;
    cls->addr = addr;
    meta->addr = metaAddr;
    cls->name = meta->name = mem.cstr(mem.read<uint32_t>(ro + layout32::kRoName));
    cls->isGuest = meta->isGuest = true;
    meta->isMeta = true;
    cls->meta = meta;
    meta->instance = cls;
    cls->super = super;
    meta->super = super ? super->meta : cls;  // a root metaclass's superclass is its class
    if (mem.read<uint32_t>(ro + layout32::kRoFlags) & layout32::kRoMeta) fatal("class list entry is a metaclass");

    // Ivars stay where the guest compiler put them (newer compilers hardcode
    // offsets past NSObject), so the guest half is the guest's instance size;
    // bytes for host superclass ivars just go unused.
    uint32_t instanceSize = mem.read<uint32_t>(ro + layout32::kRoInstanceSize);
    GuestAddr ivars = mem.read<uint32_t>(ro + layout32::kRoIvars);
    // ivar_list_t { entsize, count, ivar_t { offset *, name, type, alignment (log2), size } }
    uint32_t entsize = ivars ? mem.read<uint32_t>(ivars) : 0, count = ivars ? mem.read<uint32_t>(ivars + 4) : 0;
    // A guest superclass may be bigger than this class's compiler knew (its
    // ivars were private to its own file): slide this class's ivars past it,
    // as the iOS runtime does when it realizes the class.
    uint32_t instanceStart = mem.read<uint32_t>(ro + layout32::kRoInstanceStart);
    if (super && super->isGuest && super->instanceSize > instanceStart) {
        uint32_t align = 1;
        for (uint32_t i = 0; i < count; i++) {
            uint32_t log2 = mem.read<uint32_t>(ivars + 8 + i * entsize + 12);
            align = std::max(align, log2 == ~0u ? 4u : 1u << log2);
        }
        uint32_t slide = (super->instanceSize - instanceStart + align - 1) / align * align;
        for (uint32_t i = 0; i < count; i++)
            if (GuestAddr offset = mem.read<uint32_t>(ivars + 8 + i * entsize))
                mem.write<uint32_t>(offset, mem.read<uint32_t>(offset) + slide);
        instanceSize += slide;
    }
    cls->instanceSize = std::max(instanceSize, kObjectHeaderSize);
    if (ivars) {
        for (uint32_t i = 0; i < count; i++) {
            GuestAddr ivar = ivars + 8 + i * entsize;
            GuestAddr name = mem.read<uint32_t>(ivar + 4), type = mem.read<uint32_t>(ivar + 8);
            cls->ivars.push_back({name ? mem.cstr(name) : "", mem.read<uint32_t>(ivar), type ? mem.cstr(type) : ""});
        }
    }

    if (GuestAddr methods = mem.read<uint32_t>(ro + layout32::kRoMethods)) addGuestMethods(cls, methods);
    if (GuestAddr methods = mem.read<uint32_t>(metaRo + layout32::kRoMethods)) addGuestMethods(meta, methods);
    if (GuestAddr protocols = mem.read<uint32_t>(ro + layout32::kRoProtocols)) guestClassProtocols_[addr].push_back(protocols);

    classes_[addr] = cls;
    classes_[metaAddr] = meta;
    if (auto load = meta->methods.find(guestSel("load")); load != meta->methods.end())
        loadMethods_.push_back({cls, load->second.imp});

    createShadowClass(cls, ro);
    return cls;
}

void Bridge::collectProtocols(GuestAddr list, std::vector<std::string> &names) {
    GuestMemory &mem = rt_.mem();
    uint32_t count = mem.read<uint32_t>(list);
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr proto = mem.read<uint32_t>(list + 4 + i * 4);
        names.push_back(mem.cstr(mem.read<uint32_t>(proto + 4)));
        // protocol_t.protocols: the protocols this one adopts.
        if (GuestAddr inherited = mem.read<uint32_t>(proto + 8)) collectProtocols(inherited, names);
    }
}

void Bridge::createShadowClass(ClassInfo *cls, GuestAddr) {
    ClassInfo *super = cls->super;
    if (!super) {
        log("guest root class %s has no host counterpart", cls->name.c_str());
        return;
    }
    if (!super->host) {
        // No shadow class: the guest class works for guest-to-guest calls
        // only, and anything reaching the host fails with a clear message.
        log("class %s's superclass %s is missing on the host", cls->name.c_str(), super->name.c_str());
        return;
    }

    std::string name = cls->name;
    if (objc_getClass(name.c_str())) {
        // The app defines a class the host already has; nibs and
        // NSClassFromString won't find the guest one under its own name.
        name = "B32_" + name;
        log("guest class %s clashes with a host class; its shadow is %s", cls->name.c_str(), name.c_str());
    }
    Class shadow = objc_allocateClassPair(super->host, name.c_str(), 0);
    cls->host = shadow;
    cls->meta->host = object_getClass(shadow);
    // Register first: method lookups on an unregistered class pair abort, and
    // the trampolines look up the inherited host method's encoding.
    objc_registerClassPair(shadow);
    byHostClass_[shadow] = cls;
    byHostClass_[cls->meta->host] = cls->meta;
    for (auto &[sel, method] : cls->methods) installTrampoline(shadow, sel, method, cls);
    for (auto &[sel, method] : cls->meta->methods) installTrampoline(object_getClass(shadow), sel, method, cls->meta);
    // Subclasses of guest classes inherit this from their guest superclass.
    if (!super->isGuest && !cls->methods.count(guestSel("setValue:forUndefinedKey:")))
        class_addMethod(shadow, @selector(setValue:forUndefinedKey:), reinterpret_cast<IMP>(shadowSetValueForUndefinedKey),
                        "v@:@@");
}

std::string Bridge::hostTypesFor(Class lookup, SEL sel, ClassInfo *owner, const std::string &guestTypes) {
    // An override of a host method: the host's encoding is authoritative.
    if (Method m = class_getInstanceMethod(lookup, sel)) return method_getTypeEncoding(m);

    // A protocol method the host will call (delegates, data sources).
    ClassInfo *instanceInfo = owner->isMeta ? owner->instance : owner;
    for (ClassInfo *c = instanceInfo; c && c->isGuest; c = c->super) {
        for (GuestAddr list : guestClassProtocols_[c->addr]) {
            std::vector<std::string> names;
            collectProtocols(list, names);
            for (const auto &n : names) {
                Protocol *proto = objc_getProtocol(n.c_str());
                if (!proto) continue;
                for (BOOL required : {YES, NO}) {
                    objc_method_description d = protocol_getMethodDescription(proto, sel, required, !owner->isMeta);
                    if (d.types) return d.types;
                }
            }
        }
    }

    // A method only the guest knows: derive host types from the guest's,
    // widening geometry structs to CGFloat = double.
    std::string out;
    std::vector<bool> geometry;  // per open struct: are its floats CGFloat?
    for (size_t i = 0; i < guestTypes.size(); i++) {
        char ch = guestTypes[i];
        if (ch == '{') {
            size_t end = guestTypes.find_first_of("=}", i + 1);
            std::string sname = guestTypes.substr(i + 1, end - i - 1);
            bool isGeometry = sname == "CGPoint" || sname == "CGSize" || sname == "CGRect" ||
                              sname == "CGAffineTransform" || sname == "UIEdgeInsets" || sname == "CGVector" ||
                              sname == "UIOffset";
            geometry.push_back(isGeometry || (!geometry.empty() && geometry.back()));
        } else if (ch == '}') {
            geometry.pop_back();
        } else if (ch == 'f' && !geometry.empty() && geometry.back()) {
            ch = 'd';
        }
        out += ch;
    }
    return out;
}

// --- objects ----------------------------------------------------------------

GuestAddr Bridge::allocObject(id object, ClassInfo *isa, uint32_t size) {
    uint32_t handle;
    if (!freeHandles_.empty()) {
        handle = freeHandles_.back();
        freeHandles_.pop_back();
    } else {
        handle = uint32_t(handleObjects_.size());
        handleObjects_.push_back(nil);
        handleGuests_.push_back(0);
    }
    GuestAddr addr = rt_.heap().calloc(1, size);
    rt_.mem().write<uint32_t>(addr, isa->addr);
    handleByGuest_[addr] = handle;
    handleObjects_[handle] = object;
    handleGuests_[handle] = addr;
    guestByHost_[object] = addr;

    if (!isTaggedPointer(object)) {
        B32Sentinel *sentinel = [[B32Sentinel alloc] init];
        sentinel->bridge = this;
        sentinel->handle = handle;
        objc_setAssociatedObject(object, &sentinelKey, sentinel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [sentinel release];
    }
    return addr;
}

void Bridge::forget(uint32_t handle) {
    std::lock_guard guard(lock_);
    guestByHost_.erase(handleObjects_[handle]);
    handleByGuest_.erase(handleGuests_[handle]);
    rt_.heap().free(handleGuests_[handle]);
    handleObjects_[handle] = nil;
    handleGuests_[handle] = 0;
    freeHandles_.push_back(handle);
}

GuestAddr Bridge::toGuest(id object) {
    if (!object) return 0;
    std::lock_guard guard(lock_);
    if (object_isClass(object)) {
        Class c = (Class)object;
        if (auto it = byHostClass_.find(c); it != byHostClass_.end()) return it->second->addr;
        if (class_isMetaClass(c)) return stubFor(objc_getClass(class_getName(c)))->meta->addr;
        return stubFor(c)->addr;
    }
    if (auto it = guestByHost_.find(object); it != guestByHost_.end()) return it->second;
    if (GuestAddr block = blocks::toGuest(*this, object)) return block;

    // An instance of a guest class gets its guest half (with the guest's
    // ivars) the first time it crosses over; otherwise it's a plain proxy.
    Class cls = object_getClass(object);
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        auto it = byHostClass_.find(c);
        if (it != byHostClass_.end() && it->second->isGuest) {
            if (c != cls) log("instance of %s is a host subclass of guest class %s", class_getName(cls), class_getName(c));
            return allocObject(object, it->second, it->second->instanceSize);
        }
    }
    return allocObject(object, stubFor(cls), kObjectHeaderSize);
}

id Bridge::cfstringToHost(GuestAddr addr) {
    if (auto it = cfstrings_.find(addr); it != cfstrings_.end()) return it->second;
    GuestMemory &mem = rt_.mem();
    // struct { isa, flags, const char *bytes, long length }
    uint32_t flags = mem.read<uint32_t>(addr + 4);
    GuestAddr bytes = mem.read<uint32_t>(addr + 8);
    uint32_t length = mem.read<uint32_t>(addr + 12);
    NSString *s;
    if (flags == 0x7d0) {  // UTF-16 contents
        s = [[NSString alloc] initWithCharacters:mem.ptr<unichar>(bytes) length:length];
    } else {
        s = [[NSString alloc] initWithBytes:mem.ptr<char>(bytes) length:length encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithBytes:mem.ptr<char>(bytes) length:length encoding:NSMacOSRomanStringEncoding];
    }
    // Immortal, like the constant it stands for; maps back to the constant.
    cfstrings_[addr] = s;
    guestByHost_[s] = addr;
    return s;
}

bool Bridge::conformsTo(ClassInfo *cls, const std::string &protocol) {
    for (ClassInfo *c = cls; c; c = c->super) {
        if (!c->isGuest) {
            Protocol *p = objc_getProtocol(protocol.c_str());
            return p && c->host && class_conformsToProtocol(c->host, p);
        }
        std::vector<std::string> names;
        {
            std::lock_guard guard(lock_);
            for (GuestAddr list : guestClassProtocols_[c->addr]) collectProtocols(list, names);
        }
        if (std::find(names.begin(), names.end(), protocol) != names.end()) return true;
    }
    return false;
}

std::vector<GuestAddr> Bridge::guestClasses() {
    std::lock_guard guard(lock_);
    std::vector<GuestAddr> result;
    for (const auto &[addr, info] : classes_)
        if (info->isGuest && !info->isMeta) result.push_back(addr);
    return result;
}

void Bridge::aliasObject(GuestAddr guest, id host) {
    std::lock_guard guard(lock_);
    aliases_[guest] = host;
    guestByHost_[host] = guest;
}

id Bridge::toHost(GuestAddr addr) {
    if (!addr) return nil;
    std::lock_guard guard(lock_);
    if (auto it = aliases_.find(addr); it != aliases_.end()) return it->second;
    if (auto it = classes_.find(addr); it != classes_.end()) {
        if (!it->second->host) fatal("class %s doesn't exist on the host", it->second->name.c_str());
        return (id)it->second->host;
    }
    for (auto [begin, end] : cfstringSections_)
        if (addr >= begin && addr < end) return cfstringToHost(addr);

    auto it = handleByGuest_.find(addr);
    if (it == handleByGuest_.end()) {
        // An SVC instruction: the guest loaded a stub's code as data, so a
        // data import (a constant or variable) was bound as a function.
        if (id block = blocks::toHost(*this, addr)) return block;
        if ((addr & 0xff000000) == 0xef000000)
            fatal("guest used the code of import %s as an object; it's a data symbol that needs a B32_DATA definition",
                  rt_.thunks().nameOf(addr & 0xffffff).c_str());
        GuestMemory &mem = rt_.mem();
        ClassInfo *isa = mem.isMapped(addr) ? classInfo(mem.read<uint32_t>(addr)) : nullptr;
        if (mem.isMapped(addr))
            fatal("0x%08x is not a live object (from 0x%08x; isa %s; words %08x %08x %08x %08x)", addr,
                  Runtime::currentCpu() ? Runtime::currentCpu()->reg(Cpu::LR) : 0,
                  isa ? isa->name.c_str() : "unknown", mem.read<uint32_t>(addr), mem.read<uint32_t>(addr + 4),
                  mem.read<uint32_t>(addr + 8), mem.read<uint32_t>(addr + 12));
        fatal("0x%08x is not a live object (unmapped)", addr);
    }
    uint32_t handle = it->second;
    return handleObjects_[handle];
}

GuestAddr Bridge::guestCString(const char *s, id owner) {
    if (!s) return 0;
    return guestBytes(s, uint32_t(std::strlen(s) + 1), owner);
}

GuestAddr Bridge::guestBytes(const void *bytes, uint32_t size, id owner) {
    GuestAddr buf = rt_.heap().alloc(std::max(size, 1u));
    rt_.mem().copyIn(buf, bytes, size);
    if (owner && !isTaggedPointer(owner)) {
        std::lock_guard guard(lock_);
        B32GuestBuffers *buffers = objc_getAssociatedObject(owner, &buffersKey);
        if (!buffers) {
            buffers = [[B32GuestBuffers alloc] init];
            buffers->heap = &rt_.heap();
            buffers->buffers = new std::vector<GuestAddr>;
            objc_setAssociatedObject(owner, &buffersKey, buffers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [buffers release];
        }
        buffers->buffers->push_back(buf);
    }
    return buf;
}

// --- values -----------------------------------------------------------------

namespace {
template <typename T> T load(const uint8_t *p) {
    T v;
    std::memcpy(&v, p, sizeof v);
    return v;
}
template <typename T> void store(uint8_t *p, T v) { std::memcpy(p, &v, sizeof v); }
uint32_t alignTo(uint32_t v, uint32_t a) { return (v + a - 1) / a * a; }
}  // namespace

void Bridge::toHostValue(const Type &t, const uint8_t *g, uint8_t *h) {
    GuestMemory &mem = rt_.mem();
    switch (t.code) {
    case 'c': case 'C': case 'B': *h = *g; break;
    case 's': case 'S': std::memcpy(h, g, 2); break;
    case 'i': case 'I': case 'f': std::memcpy(h, g, 4); break;
    case 'l': case 'q': store<int64_t>(h, t.wide ? load<int64_t>(g) : load<int32_t>(g)); break;
    case 'L': case 'Q': store<uint64_t>(h, t.wide ? load<uint64_t>(g) : load<uint32_t>(g)); break;
    case 'd': store<double>(h, t.cgfloat ? double(load<float>(g)) : load<double>(g)); break;
    case '@': case '#': store<id>(h, toHost(load<uint32_t>(g))); break;
    case ':': {
        GuestAddr sel = load<uint32_t>(g);
        store<SEL>(h, sel ? hostSel(sel) : nullptr);
        break;
    }
    case '*': case '^': case '?': {
        GuestAddr p = load<uint32_t>(g);
        store<void *>(h, p ? mem.ptr<void>(p) : nullptr);
        break;
    }
    case '[':
        for (uint32_t i = 0; i < t.count; i++)
            toHostValue(t.fields[0], g + i * t.fields[0].guestSize(), h + i * t.fields[0].hostSize());
        break;
    case '{': {
        uint32_t goff = 0;
        size_t hoff = 0;
        for (const auto &f : t.fields) {
            goff = alignTo(goff, f.guestAlign());
            hoff = (hoff + f.hostAlign() - 1) / f.hostAlign() * f.hostAlign();
            toHostValue(f, g + goff, h + hoff);
            goff += f.guestSize();
            hoff += f.hostSize();
        }
        break;
    }
    default: fatal("can't convert type '%c' to the host", t.code);
    }
}

void Bridge::toGuestValue(const Type &t, const uint8_t *h, uint8_t *g) {
    GuestMemory &mem = rt_.mem();
    switch (t.code) {
    case 'c': case 'C': case 'B': *g = *h; break;
    case 's': case 'S': std::memcpy(g, h, 2); break;
    case 'i': case 'I': case 'f': std::memcpy(g, h, 4); break;
    case 'l': case 'q': case 'L': case 'Q':
        if (t.wide)
            std::memcpy(g, h, 8);
        else
            store<uint32_t>(g, uint32_t(load<uint64_t>(h)));
        break;
    case 'd':
        if (t.cgfloat)
            store<float>(g, float(load<double>(h)));
        else
            std::memcpy(g, h, 8);
        break;
    case '@': case '#': store<uint32_t>(g, toGuest(load<id>(h))); break;
    case ':': {
        SEL sel = load<SEL>(h);
        store<uint32_t>(g, sel ? guestSel(sel) : 0);
        break;
    }
    case '*': case '^': case '?': {
        void *p = load<void *>(h);
        auto *bytes = static_cast<uint8_t *>(p);
        if (!p)
            store<uint32_t>(g, 0);
        else if (bytes >= mem.base() && bytes < mem.base() + GuestMemory::kSize)
            store<uint32_t>(g, mem.guestAddrOf(p));
        else if (t.code == '*')
            store<uint32_t>(g, guestCString(static_cast<const char *>(p), nil));
        else
            fatal("host pointer %p (type '%c') can't be given to the guest", p, t.code);
        break;
    }
    case '[':
        for (uint32_t i = 0; i < t.count; i++)
            toGuestValue(t.fields[0], h + i * t.fields[0].hostSize(), g + i * t.fields[0].guestSize());
        break;
    case '{': {
        uint32_t goff = 0;
        size_t hoff = 0;
        for (const auto &f : t.fields) {
            goff = alignTo(goff, f.guestAlign());
            hoff = (hoff + f.hostAlign() - 1) / f.hostAlign() * f.hostAlign();
            toGuestValue(f, h + hoff, g + goff);
            goff += f.guestSize();
            hoff += f.hostSize();
        }
        break;
    }
    default: fatal("can't convert type '%c' to the guest", t.code);
    }
}
