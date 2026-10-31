// The ObjC bridge: the guest's 32-bit classes and objects on one side, the
// host's 64-bit runtime on the other.
//
// Object model:
//  - Every object the guest sees is laid out as the 32-bit compiler expects:
//    isa at offset 0, the guest's own ivars at their compiled offsets. Which
//    host object it stands for is kept outside guest memory, in a map from
//    guest address to a handle.
//  - A host object reaches the guest as a 4-byte proxy whose isa is a stub
//    class_t for its host class.
//  - Each guest class gets a host "shadow" class with the same name and the
//    corresponding host superclass. Guest-implemented methods are added to it
//    as libffi trampolines into the guest, so the host (nibs, delegates,
//    -description, ...) can call them.
//  - An instance of a guest class is a host object of its shadow class plus a
//    block of guest memory with the guest's ivars. Either half's lifetime is
//    the host object's: a sentinel associated object frees the guest half.
#pragma once

#include "Encoding.h"
#include "core/loader/MachO.h"
#include "core/thunks/Thunks.h"

#include <objc/objc.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace b32 {
class Runtime;
}

namespace b32::objc {

constexpr uint32_t kObjectHeaderSize = 4;  // isa

// -description of a guest object, for %@ in guest format strings.
std::string describeObject(Call &c, GuestAddr object);

struct GuestMethod {
    GuestAddr imp;
    std::string types;  // the guest's own (32-bit) encoding
};

struct GuestIvar {
    std::string name;
    GuestAddr offsetVar;  // the guest's OBJC_IVAR_$ variable
    std::string type;
};

struct ClassInfo {
    GuestAddr addr = 0;     // guest class_t
    std::string name;
    bool isMeta = false;
    bool isGuest = false;   // defined by the app, as opposed to a host-class stub
    ClassInfo *super = nullptr;
    ClassInfo *meta = nullptr;      // for classes: their metaclass
    ClassInfo *instance = nullptr;  // for metaclasses: their class
    Class host = nullptr;   // shadow class for guest classes; the host class for stubs
    uint32_t instanceSize = kObjectHeaderSize;
    std::unordered_map<GuestAddr, GuestMethod> methods;  // guest SEL -> method
    std::vector<GuestIvar> ivars;  // guest classes only
};

class Bridge {
public:
    explicit Bridge(Runtime &rt);

    // Loader: ObjC data imports (_OBJC_CLASS_$_..., __objc_empty_cache,
    // ___CFConstantStringClassReference). Returns 0 for other symbols.
    GuestAddr resolveDataSymbol(const std::string &symbol);
    // A host `extern id const` (NSString notification names and keys, mostly)
    // as a guest variable holding its proxy; 0 if the symbol isn't one.
    GuestAddr resolveHostConstant(const std::string &symbol);
    // Uniques selectors, realizes classes and categories, creates shadow classes.
    void setupImage(const Image &image);
    // Calls +load on guest classes and categories, as dyld does before initializers.
    void runLoadMethods(Cpu &cpu);

    // Selectors: a guest SEL is the guest address of its interned name.
    GuestAddr guestSel(const char *name);
    GuestAddr guestSel(SEL sel);
    SEL hostSel(GuestAddr sel);
    const char *selName(GuestAddr sel);

    // Object conversion in both directions. Identity is preserved: the same
    // host object always maps to the same guest address and back.
    id toHost(GuestAddr object);
    GuestAddr toGuest(id object);

    // Makes a guest address that isn't a bridged object (a framework's global,
    // like _dispatch_main_q) stand for a host object, both ways.
    void aliasObject(GuestAddr guest, id host);

    // Whether a class (guest or host) adopts the protocol named `protocol`,
    // directly, through a protocol it adopts, or through a superclass.
    bool conformsTo(ClassInfo *cls, const std::string &protocol);

    // The app's own classes (not metaclasses), for objc_getClassList.
    std::vector<GuestAddr> guestClasses();

    ClassInfo *classInfo(GuestAddr cls);
    ClassInfo *classOf(GuestAddr object);  // via the object's isa
    ClassInfo *stubFor(Class hostClass);

    // The objc_msgSend family. `stret` variants take the result pointer in r0;
    // super variants take a struct objc_super * instead of self, whose class
    // is where lookup starts (Super) or the class whose superclass it starts
    // at (Super2, what the compiler emits).
    enum class SuperKind { None, Super, Super2 };
    void msgSend(Call &c, bool stret, SuperKind kind = SuperKind::None);

    // Sends a message from host code through the guest's dispatch, so guest
    // overrides run. Arguments are guest words after self and _cmd.
    uint64_t send(GuestAddr receiver, const char *sel, std::initializer_list<uint32_t> args = {});

    // Guest copies of host memory, freed with `owner` (or never if nil).
    GuestAddr guestCString(const char *s, id owner);
    GuestAddr guestBytes(const void *bytes, uint32_t size, id owner);

    // Value conversion between the ABIs (see Encoding.h for the type rules).
    void toHostValue(const Type &type, const uint8_t *guest, uint8_t *host);
    void toGuestValue(const Type &type, const uint8_t *host, uint8_t *guest);

    // Called by the sentinel when a host object with a guest side deallocates.
    void forget(uint32_t handle);

    // The guest ivar named `key` or `_key` in the class chain of a guest
    // object, for KVC (nib outlets connected straight to ivars).
    const GuestIvar *ivarForKey(ClassInfo *cls, const std::string &key);

    static Bridge *shared();  // the process's bridge, for host callbacks
    bool isShadowClass(Class c);

    Runtime &runtime() { return rt_; }

    // A class by name: guest classes first, then host classes.
    ClassInfo *classNamed(const std::string &name);
    ClassInfo *stubForName(const std::string &name);

private:
    ClassInfo *makeStub(Class hostClass, const std::string &name);
    ClassInfo *realizeGuestClass(GuestAddr cls);
    void addGuestMethods(ClassInfo *info, GuestAddr methodList);
    void createShadowClass(ClassInfo *info, GuestAddr ro);
    void installTrampoline(Class target, GuestAddr sel, const GuestMethod &method, ClassInfo *owner);
    std::string hostTypesFor(Class lookup, SEL sel, ClassInfo *owner, const std::string &guestTypes);
    void collectProtocols(GuestAddr protocolList, std::vector<std::string> &names);
    GuestAddr allocObject(id object, ClassInfo *isa, uint32_t size);
    id cfstringToHost(GuestAddr addr);

    void hostDispatch(Call &c, GuestAddr receiver, GuestAddr sel, ClassInfo *superInfo, bool stret);

    Runtime &rt_;
    std::recursive_mutex lock_;

    std::unordered_map<std::string, GuestAddr> selByName_;
    std::unordered_map<GuestAddr, std::string> nameBySel_;

    std::unordered_map<GuestAddr, ClassInfo *> classes_;      // guest class_t -> info
    std::unordered_map<Class, ClassInfo *> byHostClass_;       // host or shadow class -> info
    std::unordered_map<std::string, ClassInfo *> stubsByName_;
    std::unordered_map<GuestAddr, std::vector<GuestAddr>> guestClassProtocols_;
    std::vector<std::pair<ClassInfo *, GuestAddr>> loadMethods_;  // (class, IMP)

    // Handle table: index -> host object and its guest address.
    std::vector<id> handleObjects_;
    std::vector<GuestAddr> handleGuests_;
    std::vector<uint32_t> freeHandles_;
    std::unordered_map<id, GuestAddr> guestByHost_;
    std::unordered_map<GuestAddr, uint32_t> handleByGuest_;

    // __cfstring constants: guest address -> immortal host string.
    GuestAddr cfstringIsa_ = 0;
    std::vector<std::pair<GuestAddr, GuestAddr>> cfstringSections_;
    std::unordered_map<GuestAddr, id> cfstrings_;

    GuestAddr emptyCache_ = 0;
    std::unordered_map<GuestAddr, id> aliases_;
    std::unordered_map<std::string, GuestAddr> hostConstants_;
};

}  // namespace b32::objc
