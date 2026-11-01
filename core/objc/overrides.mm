// Host methods that need hand-written argument handling.

#include "Dispatch.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Format.h"

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

namespace {

NSString *formatted(OverrideCall &o) {
    NSString *format = o.bridge.toHost(o.args.ptr());
    std::string s = formatGuest(o.c, [format UTF8String], o.args, describeObject);
    return [NSString stringWithUTF8String:s.c_str()];
}

// Guest objects up to a nil terminator, as host objects.
NSMutableArray *nilTerminated(OverrideCall &o) {
    NSMutableArray *objects = [NSMutableArray array];
    for (GuestAddr obj = o.args.ptr(); obj; obj = o.args.ptr()) [objects addObject:o.bridge.toHost(obj)];
    return objects;
}

std::vector<id> guestIdArray(OverrideCall &o, GuestAddr array, uint32_t count) {
    std::vector<id> objects(count);
    for (uint32_t i = 0; i < count; i++) objects[i] = o.bridge.toHost(o.c.mem.read<uint32_t>(array + i * 4));
    return objects;
}

template <typename... Args> id send(OverrideCall &o, Args... args) {
    return reinterpret_cast<id (*)(id, SEL, Args...)>(objc_msgSend)(o.receiver, o.sel, args...);
}
template <typename... Args> id sendSel(OverrideCall &o, SEL sel, Args... args) {
    return reinterpret_cast<id (*)(id, SEL, Args...)>(objc_msgSend)(o.receiver, sel, args...);
}

void returnObject(OverrideCall &o, id result) { o.c.ret(o.bridge.toGuest(result)); }

}  // namespace

// --- printf-style formats -------------------------------------------------------
// The format is rendered in the guest's calling convention, then handed to
// the host method as "%@" so the host never sees guest varargs.

B32_OVERRIDE("stringWithFormat:", "initWithFormat:", "stringByAppendingFormat:", "localizedStringWithFormat:") {
    NSString *text = formatted(o);
    returnObject(o, reinterpret_cast<id (*)(id, SEL, NSString *, ...)>(objc_msgSend)(o.receiver, o.sel, @"%@", text));
}

// -initWithFormat:arguments: and friends take a va_list: a guest pointer to
// the next stack word. The locale versions render the same way.
B32_OVERRIDE("initWithFormat:arguments:") {
    NSString *format = o.bridge.toHost(o.args.ptr());
    Args va = Args::fromVaList(o.c.cpu, o.args.ptr());
    std::string s = formatGuest(o.c, [format UTF8String], va, describeObject);
    returnObject(o, [static_cast<NSString *>(o.receiver) initWithString:[NSString stringWithUTF8String:s.c_str()]]);
}
B32_OVERRIDE("initWithFormat:locale:arguments:") {
    NSString *format = o.bridge.toHost(o.args.ptr());
    o.args.ptr();  // locale
    Args va = Args::fromVaList(o.c.cpu, o.args.ptr());
    std::string s = formatGuest(o.c, [format UTF8String], va, describeObject);
    returnObject(o, [static_cast<NSString *>(o.receiver) initWithString:[NSString stringWithUTF8String:s.c_str()]]);
}
B32_OVERRIDE("initWithFormat:locale:", "stringWithFormat:locale:") {
    NSString *format = o.bridge.toHost(o.args.ptr());
    o.args.ptr();  // locale
    std::string s = formatGuest(o.c, [format UTF8String], o.args, describeObject);
    NSString *text = [NSString stringWithUTF8String:s.c_str()];
    returnObject(o, o.sel == @selector(stringWithFormat:locale:)
                        ? [static_cast<Class>(o.receiver) stringWithString:text]
                        : [static_cast<NSString *>(o.receiver) initWithString:text]);
}

B32_OVERRIDE("appendFormat:") {
    NSString *text = formatted(o);
    reinterpret_cast<void (*)(id, SEL, NSString *, ...)>(objc_msgSend)(o.receiver, o.sel, @"%@", text);
}

// --- nil-terminated object lists --------------------------------------------------

B32_OVERRIDE("arrayWithObjects:") { returnObject(o, sendSel(o, @selector(arrayWithArray:), nilTerminated(o))); }
B32_OVERRIDE("setWithObjects:") { returnObject(o, sendSel(o, @selector(setWithArray:), nilTerminated(o))); }
B32_OVERRIDE("initWithObjects:") { returnObject(o, sendSel(o, @selector(initWithArray:), nilTerminated(o))); }

B32_OVERRIDE("dictionaryWithObjectsAndKeys:", "initWithObjectsAndKeys:") {
    NSMutableArray *values = [NSMutableArray array], *keys = [NSMutableArray array];
    for (GuestAddr value = o.args.ptr(); value; value = o.args.ptr()) {
        [values addObject:o.bridge.toHost(value)];
        [keys addObject:o.bridge.toHost(o.args.ptr())];
    }
    SEL sel = std::strncmp(o.name, "init", 4) == 0 ? @selector(initWithObjects:forKeys:)
                                                   : @selector(dictionaryWithObjects:forKeys:);
    returnObject(o, sendSel(o, sel, values, keys));
}

// --- id buffers with a count --------------------------------------------------------

B32_OVERRIDE("arrayWithObjects:count:", "initWithObjects:count:", "setWithObjects:count:") {
    GuestAddr array = o.args.ptr();
    uint32_t count = o.args.u32();
    std::vector<id> objects = guestIdArray(o, array, count);
    returnObject(o, send(o, objects.data(), NSUInteger(count)));
}

B32_OVERRIDE("dictionaryWithObjects:forKeys:count:", "initWithObjects:forKeys:count:") {
    GuestAddr values = o.args.ptr();
    GuestAddr keys = o.args.ptr();
    uint32_t count = o.args.u32();
    std::vector<id> hostValues = guestIdArray(o, values, count), hostKeys = guestIdArray(o, keys, count);
    returnObject(o, send(o, hostValues.data(), hostKeys.data(), NSUInteger(count)));
}

// --- fast enumeration ----------------------------------------------------------------
// The guest's NSFastEnumerationState is 32-bit: {state, itemsPtr,
// mutationsPtr, extra[5]}. The host collection is snapshotted on the first
// call and handed out in chunks of guest pointers.

namespace {
struct Snapshot {
    std::vector<GuestAddr> items;
    size_t next = 0;
};
std::unordered_map<GuestAddr, Snapshot> snapshots;
GuestAddr mutationsWord = 0;
}  // namespace

B32_OVERRIDE("countByEnumeratingWithState:objects:count:") {
    GuestMemory &mem = o.c.mem;
    GuestAddr state = o.args.ptr();
    GuestAddr buffer = o.args.ptr();
    uint32_t length = o.args.u32();
    if (!mutationsWord) mutationsWord = o.c.heap.calloc(1, 4);

    if (mem.read<uint32_t>(state) == 0) {
        Snapshot s;
        for (id item in (id<NSFastEnumeration>)o.receiver) s.items.push_back(o.bridge.toGuest(item));
        snapshots[state] = std::move(s);
        mem.write<uint32_t>(state, 1);
        mem.write<uint32_t>(state + 8, mutationsWord);
    }
    Snapshot &s = snapshots[state];
    uint32_t n = uint32_t(std::min<size_t>(length, s.items.size() - s.next));
    for (uint32_t i = 0; i < n; i++) mem.write<uint32_t>(buffer + i * 4, s.items[s.next + i]);
    s.next += n;
    mem.write<uint32_t>(state + 4, buffer);
    if (n == 0) snapshots.erase(state);
    o.c.ret(n);
}

// --- NSData's bytes --------------------------------------------------------------------------
// The guest gets a copy in guest memory, freed with the data. An immutable
// object's bytes never change, so its copy is made once; a mutable one's is
// its mutableBytes buffer (see Bridge::mutableBytes).

namespace {
bool isData(id receiver) { return [receiver isKindOfClass:[NSData class]]; }
char immutableCopyKey;

GuestAddr guestCopyOfBytes(OverrideCall &o) {
    NSData *data = o.receiver;
    bool isMutable = [data isKindOfClass:[NSMutableData class]];
    // Bytes the guest is writing through mutableBytes: the same buffer.
    if (isMutable) return o.bridge.mutableBytes(data);
    if (!isMutable)
        if (NSNumber *cached = objc_getAssociatedObject(data, &immutableCopyKey)) return cached.unsignedIntValue;
    GuestAddr copy = o.bridge.guestBytes(data.bytes, uint32_t(data.length), data);
    if (!isMutable) objc_setAssociatedObject(data, &immutableCopyKey, @(copy), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return copy;
}
}  // namespace

B32_OVERRIDE_WHEN(isData, "bytes") { o.c.ret(guestCopyOfBytes(o)); }
B32_OVERRIDE_WHEN(isData, "mutableBytes") { o.c.ret(o.bridge.mutableBytes(o.receiver)); }

// - (void)enumerateByteRangesUsingBlock:(void (^)(const void *bytes, NSRange, BOOL *stop))
// Host data (dispatch_data from NSURLSession) may be in several pieces, but
// the guest's copy is contiguous: one range, the whole of it.
B32_OVERRIDE_WHEN(isData, "enumerateByteRangesUsingBlock:") {
    GuestAddr block = o.args.ptr();
    NSData *data = o.receiver;
    if (!block || data.length == 0) return;
    GuestAddr stop = o.c.heap.alloc(1);
    o.c.mem.write<uint8_t>(stop, 0);
    Runtime::threadCpu().call(o.c.mem.read<uint32_t>(block + 12),
                              {block, guestCopyOfBytes(o), 0, uint32_t(data.length), stop});
    o.c.heap.free(stop);
}

// --- method lookup ------------------------------------------------------------------------------
// An IMP the guest can call: a guest class's own method, or else
// objc_msgSend itself, which reaches the method (on the host) for any
// receiver of the class.

namespace {
GuestAddr guestImp(Bridge &bridge, ClassInfo *cls, GuestAddr sel) {
    for (ClassInfo *c = cls; c && c->isGuest; c = c->super)
        if (auto it = c->methods.find(sel); it != c->methods.end()) return it->second.imp;
    return bridge.runtime().thunks().stubFor("_objc_msgSend");
}
}  // namespace

// - (IMP)methodForSelector:(SEL)
B32_OVERRIDE("methodForSelector:") {
    GuestAddr sel = o.args.u32();
    ClassInfo *cls = o.bridge.classOf(o.guestReceiver);
    o.c.ret(guestImp(o.bridge, cls, sel));
}

// + (IMP)instanceMethodForSelector:(SEL)
B32_OVERRIDE("instanceMethodForSelector:") {
    GuestAddr sel = o.args.u32();
    ClassInfo *cls = o.bridge.classInfo(o.guestReceiver);
    o.c.ret(guestImp(o.bridge, cls, sel));
}

// IMP class_getMethodImplementation(Class, SEL)
B32_THUNK(_class_getMethodImplementation) {
    ClassInfo *cls = c.rt.bridge().classInfo(c.args.ptr());
    c.ret(guestImp(c.rt.bridge(), cls, c.args.u32()));
}

// --- NSPredicate formats -----------------------------------------------------------------------
// The format's arguments are read in the guest's calling convention and
// handed to the host as an argument array: %@ and %K are objects, integer
// conversions numbers, floating point doubles.

namespace {
NSArray *predicateArguments(OverrideCall &o, NSString *format, Args &args) {
    NSMutableArray *values = [NSMutableArray array];
    const char *p = format.UTF8String;
    while (p && *p) {
        if (*p++ != '%') continue;
        if (*p == '%') {
            p++;
            continue;
        }
        bool wide = false;
        while (*p == 'l' || *p == 'h' || *p == 'q') {
            if (*p == 'q' || (p[0] == 'l' && p[1] == 'l')) wide = true;
            p += (p[0] == 'l' && p[1] == 'l') ? 2 : 1;
        }
        switch (*p++) {
        case '@': case 'K': {
            id value = o.bridge.toHost(args.ptr());
            [values addObject:value ?: [NSNull null]];
            break;
        }
        case 'd': case 'i': case 'c':
            [values addObject:wide ? @(int64_t(args.u64())) : @(args.i32())];
            break;
        case 'u': case 'x': case 'X': case 'o':
            [values addObject:wide ? @(args.u64()) : @(args.u32())];
            break;
        case 'f': case 'e': case 'g': case 'E': case 'G':
            [values addObject:@(args.f64())];
            break;
        case 's': {
            GuestAddr str = args.ptr();
            [values addObject:str ? @(o.c.mem.cstr(str)) : [NSNull null]];
            break;
        }
        default: break;
        }
    }
    return values;
}
}  // namespace

// + (NSPredicate *)predicateWithFormat:(NSString *)format, ...
B32_OVERRIDE("predicateWithFormat:") {
    NSString *format = o.bridge.toHost(o.args.ptr());
    NSArray *values = predicateArguments(o, format, o.args);
    returnObject(o, [NSPredicate predicateWithFormat:format argumentArray:values]);
}
// + (NSPredicate *)predicateWithFormat:(NSString *)format arguments:(va_list)
B32_OVERRIDE("predicateWithFormat:arguments:") {
    NSString *format = o.bridge.toHost(o.args.ptr());
    Args va = Args::fromVaList(o.c.cpu, o.args.ptr());
    returnObject(o, [NSPredicate predicateWithFormat:format argumentArray:predicateArguments(o, format, va)]);
}
// + (NSExpression *)expressionWithFormat:(NSString *)format, ...
B32_OVERRIDE("expressionWithFormat:") {
    NSString *format = o.bridge.toHost(o.args.ptr());
    NSArray *values = predicateArguments(o, format, o.args);
    returnObject(o, [NSExpression expressionWithFormat:format argumentArray:values]);
}

// --- conformsToProtocol: ------------------------------------------------------------------------
// The protocols a guest class adopts are in its guest metadata (shadow
// classes don't adopt them on the host).

// - (BOOL)conformsToProtocol:(Protocol *) and the class method
B32_OVERRIDE("conformsToProtocol:") {
    GuestAddr protocol = o.args.ptr();
    ClassInfo *cls = o.bridge.classOf(o.guestReceiver);
    if (cls && cls->isMeta) cls = cls->instance;
    bool conforms = false;
    if (cls && protocol) conforms = o.bridge.conformsTo(cls, o.c.mem.cstr(o.c.mem.read<uint32_t>(protocol + 4)));
    if (!conforms && protocol)
        conforms = reinterpret_cast<BOOL (*)(id, SEL, id)>(objc_msgSend)(o.receiver, o.sel, o.bridge.toHost(protocol));
    o.c.ret(conforms ? 1 : 0);
}

// --- performSelector: -------------------------------------------------------------------------
// Run as an ordinary guest message send: the result comes back as the
// guest's raw r0, as on iOS, where callers cast performSelector: results
// that aren't objects (the host would try to bridge them as objects).

B32_OVERRIDE("performSelector:") {
    GuestAddr sel = o.args.u32();
    o.c.ret(uint32_t(o.bridge.send(o.guestReceiver, o.bridge.selName(sel))));
}
B32_OVERRIDE("performSelector:withObject:") {
    GuestAddr sel = o.args.u32(), a = o.args.ptr();
    o.c.ret(uint32_t(o.bridge.send(o.guestReceiver, o.bridge.selName(sel), {a})));
}
B32_OVERRIDE("performSelector:withObject:withObject:") {
    GuestAddr sel = o.args.u32(), a = o.args.ptr(), b = o.args.ptr();
    o.c.ret(uint32_t(o.bridge.send(o.guestReceiver, o.bridge.selName(sel), {a, b})));
}

// --- buffers the guest hands over (bytesNoCopy) ------------------------------------------------------
// Host NSData and NSString keep pointing at the guest's bytes, with no copy;
// when they're done (freeWhenDone, the default) the bytes go back to the
// guest heap, not to the host's free(), which doesn't know them.

namespace {
id dataNoCopy(OverrideCall &o, NSData *allocated, bool hasFreeArg) {
    GuestAddr bytes = o.args.ptr();
    NSUInteger length = o.args.u32();
    bool freeWhenDone = hasFreeArg ? o.args.u32() != 0 : true;
    void *host = bytes ? o.c.mem.ptr<void>(bytes) : nullptr;
    if (!freeWhenDone) return [allocated initWithBytesNoCopy:host length:length freeWhenDone:NO];
    GuestHeap *heap = &o.c.heap;
    return [allocated initWithBytesNoCopy:host length:length deallocator:^(void *, NSUInteger) {
        if (bytes) heap->free(bytes);
    }];
}
}  // namespace

B32_OVERRIDE("dataWithBytesNoCopy:length:") {
    returnObject(o, [dataNoCopy(o, [static_cast<Class>(o.receiver) alloc], false) autorelease]);
}
B32_OVERRIDE("dataWithBytesNoCopy:length:freeWhenDone:") {
    returnObject(o, [dataNoCopy(o, [static_cast<Class>(o.receiver) alloc], true) autorelease]);
}
B32_OVERRIDE("initWithBytesNoCopy:length:") { returnObject(o, dataNoCopy(o, static_cast<NSData *>(o.receiver), false)); }
B32_OVERRIDE("initWithBytesNoCopy:length:freeWhenDone:") {
    returnObject(o, dataNoCopy(o, static_cast<NSData *>(o.receiver), true));
}

// - (instancetype)initWithBytesNoCopy:(void *)bytes length:(NSUInteger)len
//       encoding:(NSStringEncoding)encoding freeWhenDone:(BOOL)freeBuffer
B32_OVERRIDE("initWithBytesNoCopy:length:encoding:freeWhenDone:") {
    GuestAddr bytes = o.args.ptr();
    NSUInteger length = o.args.u32();
    NSStringEncoding encoding = o.args.u32();
    bool freeWhenDone = o.args.u32() != 0;
    void *host = bytes ? o.c.mem.ptr<void>(bytes) : nullptr;
    auto *str = static_cast<NSString *>(o.receiver);
    if (!freeWhenDone) {
        returnObject(o, [str initWithBytesNoCopy:host length:length encoding:encoding freeWhenDone:NO]);
        return;
    }
    GuestHeap *heap = &o.c.heap;
    returnObject(o, [str initWithBytesNoCopy:host length:length encoding:encoding deallocator:^(void *, NSUInteger) {
        if (bytes) heap->free(bytes);
    }]);
}

// --- Core Data: iCloud stores open as local ones ---------------------------------------------------
// The ubiquitous-store options (iOS 5–9 iCloud Core Data) are gone from
// today's Core Data, which refuses a store that asks for them. Without iCloud
// the store was local anyway, so it opens without them.

namespace {
bool isStoreCoordinator(id receiver) { return [receiver isKindOfClass:NSClassFromString(@"NSPersistentStoreCoordinator")]; }
}  // namespace

// - (NSPersistentStore *)addPersistentStoreWithType:(NSString *)type configuration:(NSString *)configuration
//       URL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
B32_OVERRIDE_WHEN(isStoreCoordinator, "addPersistentStoreWithType:configuration:URL:options:error:") {
    NSString *type = o.bridge.toHost(o.args.ptr());
    NSString *configuration = o.bridge.toHost(o.args.ptr());
    NSURL *url = o.bridge.toHost(o.args.ptr());
    NSDictionary *options = o.bridge.toHost(o.args.ptr());
    GuestAddr errorOut = o.args.ptr();
    NSMutableDictionary *local = [[options mutableCopy] autorelease];
    for (NSString *key : {@"NSPersistentStoreUbiquitousContentNameKey", @"NSPersistentStoreUbiquitousContentURLKey",
                          @"NSPersistentStoreUbiquitousPeerTokenOption", @"NSPersistentStoreUbiquitousContainerIdentifierKey",
                          @"NSPersistentStoreRebuildFromUbiquitousContentOption",
                          @"NSPersistentStoreRemoveUbiquitousMetadataOption"})
        [local removeObjectForKey:key];
    NSError *error = nil;
    id store = reinterpret_cast<id (*)(id, SEL, NSString *, NSString *, NSURL *, NSDictionary *, NSError **)>(objc_msgSend)(
        o.receiver, o.sel, type, configuration, url, local, &error);
    if (!store && errorOut) o.c.mem.write<uint32_t>(errorOut, o.bridge.toGuest(error));
    returnObject(o, store);
}
