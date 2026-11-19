// Foundation's old C collections (NSMapTable and NSHashTable as NSCreateMapTable, NSMapGet, NSHashInsert...
// use them) and its zone allocator, which Mac frameworks of the Tiger and Leopard era call everywhere.
//
// A table is a host object, so the guest can retain, release and describe it like the NSMapTable it was, and
// its entries are the guest's own words. The callbacks a table is made with are honoured: the standard ones
// (NSObjectMapKeyCallBacks...) hold stubs this file knows, which it runs on the host; any other is a guest
// function, called with the table as its first argument as Foundation does.
//
// Zones have long been ignored (every zone is the default one), so a zone is NULL and its memory the guest's
// heap.

#include "Bridge.h"
#include "Dispatch.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/cpu/Cpu.h"

#import <Foundation/Foundation.h>
#include <objc/runtime.h>

#include <cstring>
#include <mutex>
#include <unordered_map>
#include <vector>

using namespace b32;

namespace {

// The standard callbacks' functions, as stubs a guest can also call.
enum class Builtin { None, ObjectHash, ObjectEqual, ObjectRetain, ObjectRelease, PointerHash, PointerEqual, Free,
                     StructHash, StructEqual, Describe };
const std::pair<const char *, Builtin> kBuiltins[] = {
    {"_b32_NSObjectHash", Builtin::ObjectHash},     {"_b32_NSObjectIsEqual", Builtin::ObjectEqual},
    {"_b32_NSObjectRetain", Builtin::ObjectRetain}, {"_b32_NSObjectRelease", Builtin::ObjectRelease},
    {"_b32_NSPointerHash", Builtin::PointerHash},   {"_b32_NSPointerIsEqual", Builtin::PointerEqual},
    {"_b32_NSPointerFree", Builtin::Free},          {"_b32_NSStructHash", Builtin::StructHash},
    {"_b32_NSStructIsEqual", Builtin::StructEqual}, {"_b32_NSDescribe", Builtin::Describe},
};

GuestAddr stub(Runtime &rt, Builtin b) {
    for (auto &[name, which] : kBuiltins)
        if (which == b) return rt.thunks().stubFor(name);
    return 0;
}
Builtin builtinOf(Runtime &rt, GuestAddr fn) {
    if (!fn) return Builtin::None;
    static std::once_flag once;
    static std::unordered_map<GuestAddr, Builtin> byAddr;
    std::call_once(once, [&] {
        for (auto &[name, which] : kBuiltins) byAddr[rt.thunks().stubFor(name)] = which;
    });
    auto it = byAddr.find(fn);
    return it == byAddr.end() ? Builtin::None : it->second;
}

// A message sent the way the guest would send it, so guest classes' own methods run.
uint32_t send(Runtime &rt, uint32_t object, const char *selector, std::initializer_list<uint32_t> args = {}) {
    if (!object) return 0;
    static GuestAddr msgSend = rt.lookUp("_objc_msgSend", false);
    std::vector<uint32_t> words{object, rt.bridge().guestSel(selector)};
    words.insert(words.end(), args);
    return uint32_t(Runtime::threadCpu().call(msgSend, words));
}

// One callback function: a standard one run here, or the guest's own.
struct Callback {
    GuestAddr fn = 0;
    Builtin builtin = Builtin::None;
};

struct Table {
    Runtime &rt;
    GuestAddr self = 0;
    bool isMap = true;
    // Keys (a hash table's items): hash, isEqual, retain, release, describe; values: retain, release, describe.
    Callback hash, equal, keyRetain, keyRelease, valueRetain, valueRelease;
    GuestAddr keyCallbacks[6] = {}, valueCallbacks[3] = {};  // as made, for a copy

    uint32_t call(const Callback &cb, std::initializer_list<uint32_t> args) const {
        std::vector<uint32_t> words{self};
        words.insert(words.end(), args);
        return uint32_t(Runtime::threadCpu().call(cb.fn, words));
    }
    uint32_t hashOf(uint32_t key) const {
        switch (hash.builtin) {
        case Builtin::ObjectHash: return send(rt, key, "hash");
        case Builtin::StructHash: return key ? rt.mem().read<uint32_t>(key) : 0;
        case Builtin::None: if (hash.fn) return call(hash, {key}); return key;
        default: return key;
        }
    }
    bool same(uint32_t a, uint32_t b) const {
        if (a == b) return true;
        switch (equal.builtin) {
        case Builtin::ObjectEqual: return a && b && uint8_t(send(rt, a, "isEqual:", {b}));
        case Builtin::StructEqual: return a && b && rt.mem().read<uint32_t>(a) == rt.mem().read<uint32_t>(b);
        case Builtin::None: return equal.fn && uint8_t(call(equal, {a, b}));
        default: return false;
        }
    }
    void retain(const Callback &cb, uint32_t word) const {
        if (cb.builtin == Builtin::ObjectRetain) send(rt, word, "retain");
        else if (cb.builtin == Builtin::None && cb.fn) call(cb, {word});
    }
    void release(const Callback &cb, uint32_t word) const {
        if (cb.builtin == Builtin::ObjectRelease) send(rt, word, "release");
        else if (cb.builtin == Builtin::Free) { if (word) rt.heap().free(word); }
        else if (cb.builtin == Builtin::None && cb.fn) call(cb, {word});
    }

    struct Hasher {
        const Table *t;
        size_t operator()(uint32_t key) const { return t->hashOf(key); }
    };
    struct Equal {
        const Table *t;
        bool operator()(uint32_t a, uint32_t b) const { return t->same(a, b); }
    };
    std::unordered_map<uint32_t, uint32_t, Hasher, Equal> entries{16, Hasher{this}, Equal{this}};

    Table(Runtime &rt, bool isMap) : rt(rt), isMap(isMap) {}

    void setCallbacks(const GuestAddr keys[], const GuestAddr values[]) {
        std::copy(keys, keys + (isMap ? 6 : 5), keyCallbacks);
        if (values) std::copy(values, values + 3, valueCallbacks);
        auto make = [&](GuestAddr fn) { return Callback{fn, builtinOf(rt, fn)}; };
        hash = make(keys[0]), equal = make(keys[1]), keyRetain = make(keys[2]), keyRelease = make(keys[3]);
        if (values) valueRetain = make(values[0]), valueRelease = make(values[1]);
    }

    // Insert as NSMapInsert does: the new key and value are retained, any old pair released.
    void insert(uint32_t key, uint32_t value) {
        retain(keyRetain, key);
        if (isMap) retain(valueRetain, value);
        auto it = entries.find(key);
        if (it != entries.end()) {
            uint32_t oldKey = it->first, oldValue = it->second;
            entries.erase(it);
            entries.emplace(key, value);
            if (isMap) release(valueRelease, oldValue);
            release(keyRelease, oldKey);
        } else {
            entries.emplace(key, value);
        }
    }
    void remove(uint32_t key) {
        auto it = entries.find(key);
        if (it == entries.end()) return;
        uint32_t oldKey = it->first, oldValue = it->second;
        entries.erase(it);
        if (isMap) release(valueRelease, oldValue);
        release(keyRelease, oldKey);
    }
    void reset() {
        auto old = std::move(entries);
        entries = decltype(entries)(16, Hasher{this}, Equal{this});
        for (auto &[k, v] : old) {
            if (isMap) release(valueRelease, v);
            release(keyRelease, k);
        }
    }
};

}  // namespace

// The host object a guest table is.
@interface B32LegacyTable : NSObject {
@public
    Table *table;
}
@end
@implementation B32LegacyTable
- (void)dealloc {
    delete table;
    [super dealloc];
}
- (NSUInteger)count {
    return table->entries.size();
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<%s table %p, %zu entries>", table->isMap ? "map" : "hash", self,
                                      table->entries.size()];
}
@end

namespace {

Table &tableAt(Call &c, GuestAddr guest) {
    id object = c.rt.bridge().toHost(guest);
    if (![object isKindOfClass:[B32LegacyTable class]])
        fatal("%s: 0x%08x (%s) isn't a table made by NSCreateMapTable or NSCreateHashTable", c.name, guest,
              object ? object_getClassName(object) : "nil");
    return *static_cast<B32LegacyTable *>(object)->table;
}

// A table made with the classes' own API (+[NSHashTable hashTableWithOptions:], an NSMapTable
// initializer), which the C functions take too: they send it the messages they stand for, as
// the guest would, so the bridge's handling of such tables (sides of plain pointers) applies.
bool isClassTable(Call &c, GuestAddr guest) {
    id object = c.rt.bridge().toHost(guest);
    return [object isKindOfClass:[NSMapTable class]] || [object isKindOfClass:[NSHashTable class]];
}
// The items of a guest NSArray, as guest words.
std::vector<uint32_t> guestItems(Runtime &rt, uint32_t array) {
    std::vector<uint32_t> items(send(rt, array, "count"));
    for (uint32_t i = 0; i < items.size(); i++) items[i] = send(rt, array, "objectAtIndex:", {i});
    return items;
}
std::vector<std::pair<uint32_t, uint32_t>> classTableEntries(Runtime &rt, GuestAddr table, bool isMap) {
    std::vector<std::pair<uint32_t, uint32_t>> entries;
    if (isMap) {
        for (uint32_t key : guestItems(rt, send(rt, send(rt, table, "keyEnumerator"), "allObjects")))
            entries.emplace_back(key, send(rt, table, "objectForKey:", {key}));
    } else if (NSHashTable *host = rt.bridge().toHost(table); objc::isRawHashTable(host)) {
        for (id item in host) entries.emplace_back(uint32_t(uintptr_t(item)), uint32_t(uintptr_t(item)));
    } else {
        for (uint32_t item : guestItems(rt, send(rt, table, "allObjects"))) entries.emplace_back(item, item);
    }
    return entries;
}

GuestAddr newTable(Call &c, bool isMap, const GuestAddr keys[], const GuestAddr values[]) {
    B32LegacyTable *object = [[B32LegacyTable alloc] init];  // the guest's reference
    object->table = new Table(c.rt, isMap);
    GuestAddr guest = c.rt.bridge().toGuest(object);
    object->table->self = guest;
    object->table->setCallbacks(keys, values);
    return guest;
}

GuestAddr copyTable(Call &c, Table &from) {
    GuestAddr guest = newTable(c, from.isMap, from.keyCallbacks, from.isMap ? from.valueCallbacks : nullptr);
    Table &to = tableAt(c, guest);
    for (auto &[k, v] : from.entries) to.insert(k, v);
    return guest;
}

void freeTable(Call &c, GuestAddr guest) {
    if (!guest) return;
    if (isClassTable(c, guest)) return (void)send(c.rt, guest, "release");
    tableAt(c, guest).reset();
    [c.rt.bridge().toHost(guest) release];
}

// Enumerators are { unsigned _pi, _si; void *_bs } by value: here a snapshot's number and a place in it.
std::mutex snapshotsLock;
std::unordered_map<uint32_t, std::vector<std::pair<uint32_t, uint32_t>>> snapshots;
uint32_t nextSnapshot = 1;

void startEnumeration(Call &c, GuestAddr out, GuestAddr table, bool isMap) {
    std::vector<std::pair<uint32_t, uint32_t>> entries;
    if (isClassTable(c, table)) {
        entries = classTableEntries(c.rt, table, isMap);
    } else {
        Table &t = tableAt(c, table);
        entries.assign(t.entries.begin(), t.entries.end());
    }
    std::lock_guard guard(snapshotsLock);
    uint32_t id = nextSnapshot++;
    snapshots[id] = std::move(entries);
    c.mem.write<uint32_t>(out, 0);
    c.mem.write<uint32_t>(out + 4, id);
    c.mem.write<uint32_t>(out + 8, 0);
}
bool nextEntry(Call &c, GuestAddr e, uint32_t &key, uint32_t &value) {
    std::lock_guard guard(snapshotsLock);
    auto it = snapshots.find(c.mem.read<uint32_t>(e + 4));
    if (it == snapshots.end()) return false;
    uint32_t place = c.mem.read<uint32_t>(e);
    if (place >= it->second.size()) return false;
    std::tie(key, value) = it->second[place];
    c.mem.write<uint32_t>(e, place + 1);
    return true;
}
void endEnumeration(Call &c, GuestAddr e) {
    std::lock_guard guard(snapshotsLock);
    snapshots.erase(c.mem.read<uint32_t>(e + 4));
}

NSArray *hostObjects(Call &c, Table &t, bool values) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:t.entries.size()];
    for (auto &[k, v] : t.entries)
        if (id object = c.rt.bridge().toHost(values ? v : k)) [array addObject:object];
    return array;
}

void readCallbacks(Call &c, GuestAddr *out, int count) {
    for (int i = 0; i < count; i++) out[i] = c.args.ptr();
}

}  // namespace

// --- the standard callbacks' functions ---------------------------------------------------------

// Each takes the table first.
B32_THUNK(_b32_NSObjectHash) { c.args.ptr(); c.ret(send(c.rt, c.args.ptr(), "hash")); }
B32_THUNK(_b32_NSObjectIsEqual) {
    c.args.ptr();
    uint32_t a = c.args.ptr(), b = c.args.ptr();
    c.ret(a == b || (a && b && uint8_t(send(c.rt, a, "isEqual:", {b}))));
}
B32_THUNK(_b32_NSObjectRetain) { c.args.ptr(); send(c.rt, c.args.ptr(), "retain"); }
B32_THUNK(_b32_NSObjectRelease) { c.args.ptr(); send(c.rt, c.args.ptr(), "release"); }
B32_THUNK(_b32_NSPointerHash) { c.args.ptr(); c.ret(c.args.ptr()); }
B32_THUNK(_b32_NSPointerIsEqual) {
    c.args.ptr();
    uint32_t a = c.args.ptr();
    c.ret(a == c.args.ptr());
}
B32_THUNK(_b32_NSPointerFree) {
    c.args.ptr();
    if (GuestAddr p = c.args.ptr()) c.heap.free(p);
}
B32_THUNK(_b32_NSStructHash) {
    c.args.ptr();
    GuestAddr p = c.args.ptr();
    c.ret(p ? c.mem.read<uint32_t>(p) : 0);
}
B32_THUNK(_b32_NSStructIsEqual) {
    c.args.ptr();
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    c.ret(a == b || (a && b && c.mem.read<uint32_t>(a) == c.mem.read<uint32_t>(b)));
}
B32_THUNK(_b32_NSDescribe) {
    c.args.ptr();
    c.ret(c.rt.bridge().toGuest([NSString stringWithFormat:@"0x%x", c.args.ptr()]));
}

// --- the standard callbacks ------------------------------------------------------------------------

namespace {
void writeCallbacks(Runtime &rt, GuestAddr addr, std::initializer_list<Builtin> fns) {
    uint32_t offset = 0;
    for (Builtin b : fns) {
        rt.mem().write<uint32_t>(addr + offset, b == Builtin::None ? 0 : stub(rt, b));
        offset += 4;
    }
}
constexpr uint32_t kNotAPointer = 0xffffffff;  // NSNotAPointerMapKey
constexpr uint32_t kNotAnInteger = 0x80000000;  // NSNotAnIntegerMapKey, NSNotAnIntMapKey
using B = Builtin;

// NSMapTableKeyCallBacks: { hash, isEqual, retain, release, describe, notAKeyMarker }
void mapKeys(Runtime &rt, GuestAddr addr, Builtin hash, Builtin equal, Builtin retain, Builtin release,
             uint32_t marker) {
    writeCallbacks(rt, addr, {hash, equal, retain, release, B::Describe});
    rt.mem().write<uint32_t>(addr + 20, marker);
}
}  // namespace

B32_DATA(_NSIntegerMapKeyCallBacks, 24) { mapKeys(rt, addr, B::PointerHash, B::PointerEqual, B::None, B::None, kNotAnInteger); }
B32_DATA(_NSIntMapKeyCallBacks, 24) { mapKeys(rt, addr, B::PointerHash, B::PointerEqual, B::None, B::None, kNotAnInteger); }
B32_DATA(_NSNonOwnedPointerMapKeyCallBacks, 24) { mapKeys(rt, addr, B::PointerHash, B::PointerEqual, B::None, B::None, kNotAPointer); }
B32_DATA(_NSNonOwnedPointerOrNullMapKeyCallBacks, 24) { mapKeys(rt, addr, B::PointerHash, B::PointerEqual, B::None, B::None, kNotAPointer); }
B32_DATA(_NSOwnedPointerMapKeyCallBacks, 24) { mapKeys(rt, addr, B::PointerHash, B::PointerEqual, B::None, B::Free, kNotAPointer); }
B32_DATA(_NSObjectMapKeyCallBacks, 24) { mapKeys(rt, addr, B::ObjectHash, B::ObjectEqual, B::ObjectRetain, B::ObjectRelease, 0); }
B32_DATA(_NSNonRetainedObjectMapKeyCallBacks, 24) { mapKeys(rt, addr, B::ObjectHash, B::ObjectEqual, B::None, B::None, 0); }

// NSMapTableValueCallBacks: { retain, release, describe }
B32_DATA(_NSIntegerMapValueCallBacks, 12) { writeCallbacks(rt, addr, {B::None, B::None, B::Describe}); }
B32_DATA(_NSIntMapValueCallBacks, 12) { writeCallbacks(rt, addr, {B::None, B::None, B::Describe}); }
B32_DATA(_NSNonOwnedPointerMapValueCallBacks, 12) { writeCallbacks(rt, addr, {B::None, B::None, B::Describe}); }
B32_DATA(_NSOwnedPointerMapValueCallBacks, 12) { writeCallbacks(rt, addr, {B::None, B::Free, B::Describe}); }
B32_DATA(_NSObjectMapValueCallBacks, 12) { writeCallbacks(rt, addr, {B::ObjectRetain, B::ObjectRelease, B::Describe}); }
B32_DATA(_NSNonRetainedObjectMapValueCallBacks, 12) { writeCallbacks(rt, addr, {B::None, B::None, B::Describe}); }

// NSHashTableCallBacks: { hash, isEqual, retain, release, describe }
B32_DATA(_NSIntegerHashCallBacks, 20) { writeCallbacks(rt, addr, {B::PointerHash, B::PointerEqual, B::None, B::None, B::Describe}); }
B32_DATA(_NSIntHashCallBacks, 20) { writeCallbacks(rt, addr, {B::PointerHash, B::PointerEqual, B::None, B::None, B::Describe}); }
B32_DATA(_NSNonOwnedPointerHashCallBacks, 20) { writeCallbacks(rt, addr, {B::PointerHash, B::PointerEqual, B::None, B::None, B::Describe}); }
B32_DATA(_NSOwnedPointerHashCallBacks, 20) { writeCallbacks(rt, addr, {B::PointerHash, B::PointerEqual, B::None, B::Free, B::Describe}); }
B32_DATA(_NSPointerToStructHashCallBacks, 20) { writeCallbacks(rt, addr, {B::StructHash, B::StructEqual, B::None, B::Free, B::Describe}); }
B32_DATA(_NSObjectHashCallBacks, 20) { writeCallbacks(rt, addr, {B::ObjectHash, B::ObjectEqual, B::ObjectRetain, B::ObjectRelease, B::Describe}); }
B32_DATA(_NSNonRetainedObjectHashCallBacks, 20) { writeCallbacks(rt, addr, {B::ObjectHash, B::ObjectEqual, B::None, B::None, B::Describe}); }
B32_DATA(_NSOwnedObjectIdentityHashCallBacks, 20) { writeCallbacks(rt, addr, {B::PointerHash, B::PointerEqual, B::ObjectRetain, B::ObjectRelease, B::Describe}); }

// --- map tables ---------------------------------------------------------------------------------

// NSMapTable *NSCreateMapTable(NSMapTableKeyCallBacks, NSMapTableValueCallBacks, NSUInteger capacity):
// the callbacks come by value.
B32_THUNK(_NSCreateMapTable) {
    GuestAddr keys[6], values[3];
    readCallbacks(c, keys, 6);
    readCallbacks(c, values, 3);
    c.ret(newTable(c, true, keys, values));
}
B32_THUNK(_NSCreateMapTableWithZone) {
    GuestAddr keys[6], values[3];
    readCallbacks(c, keys, 6);
    readCallbacks(c, values, 3);
    c.ret(newTable(c, true, keys, values));
}
B32_THUNK(_NSCopyMapTableWithZone) { c.ret(copyTable(c, tableAt(c, c.args.ptr()))); }
B32_THUNK(_NSFreeMapTable) { freeTable(c, c.args.ptr()); }
B32_THUNK(_NSResetMapTable) {
    GuestAddr table = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "removeAllObjects");
    tableAt(c, table).reset();
}
B32_THUNK(_NSCountMapTable) {
    GuestAddr table = c.args.ptr();
    c.ret(isClassTable(c, table) ? send(c.rt, table, "count") : uint32_t(tableAt(c, table).entries.size()));
}
B32_THUNK(_NSCompareMapTables) {
    Table &a = tableAt(c, c.args.ptr()), &b = tableAt(c, c.args.ptr());
    bool same = a.entries.size() == b.entries.size();
    for (auto it = a.entries.begin(); same && it != a.entries.end(); ++it) {
        auto there = b.entries.find(it->first);
        same = there != b.entries.end() && there->second == it->second;
    }
    c.ret(same);
}

B32_THUNK(_NSMapGet) {
    GuestAddr table = c.args.ptr();
    uint32_t key = c.args.ptr();
    if (isClassTable(c, table)) return c.ret(send(c.rt, table, "objectForKey:", {key}));
    Table &t = tableAt(c, table);
    auto it = t.entries.find(key);
    c.ret(it == t.entries.end() ? 0 : it->second);
}
// BOOL NSMapMember(NSMapTable *, const void *key, void **originalKey, void **value)
B32_THUNK(_NSMapMember) {
    GuestAddr table = c.args.ptr();
    uint32_t key = c.args.ptr();
    GuestAddr keyOut = c.args.ptr(), valueOut = c.args.ptr();
    if (isClassTable(c, table)) {
        uint32_t value = send(c.rt, table, "objectForKey:", {key});
        if (!value) return c.ret(0);
        if (keyOut) c.mem.write<uint32_t>(keyOut, key);
        if (valueOut) c.mem.write<uint32_t>(valueOut, value);
        return c.ret(1);
    }
    Table &t = tableAt(c, table);
    auto it = t.entries.find(key);
    if (it == t.entries.end()) return c.ret(0);
    if (keyOut) c.mem.write<uint32_t>(keyOut, it->first);
    if (valueOut) c.mem.write<uint32_t>(valueOut, it->second);
    c.ret(1);
}
B32_THUNK(_NSMapInsert) {
    GuestAddr table = c.args.ptr();
    uint32_t key = c.args.ptr(), value = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "setObject:forKey:", {value, key});
    tableAt(c, table).insert(key, value);
}
B32_THUNK(_NSMapInsertKnownAbsent) {
    GuestAddr table = c.args.ptr();
    uint32_t key = c.args.ptr(), value = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "setObject:forKey:", {value, key});
    tableAt(c, table).insert(key, value);
}
// The key already there (and nothing inserted), or NULL once the pair is in.
B32_THUNK(_NSMapInsertIfAbsent) {
    GuestAddr table = c.args.ptr();
    uint32_t key = c.args.ptr(), value = c.args.ptr();
    if (isClassTable(c, table)) {
        if (send(c.rt, table, "objectForKey:", {key})) return c.ret(key);
        send(c.rt, table, "setObject:forKey:", {value, key});
        return c.ret(0);
    }
    Table &t = tableAt(c, table);
    if (auto it = t.entries.find(key); it != t.entries.end()) return c.ret(it->first);
    t.insert(key, value);
    c.ret(0);
}
B32_THUNK(_NSMapRemove) {
    GuestAddr table = c.args.ptr();
    uint32_t key = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "removeObjectForKey:", {key});
    tableAt(c, table).remove(key);
}
B32_THUNK(_NSAllMapTableKeys) {
    GuestAddr table = c.args.ptr();
    if (isClassTable(c, table)) return c.ret(send(c.rt, send(c.rt, table, "keyEnumerator"), "allObjects"));
    c.ret(c.rt.bridge().toGuest(hostObjects(c, tableAt(c, table), false)));
}
B32_THUNK(_NSAllMapTableValues) {
    GuestAddr table = c.args.ptr();
    if (isClassTable(c, table)) return c.ret(send(c.rt, send(c.rt, table, "objectEnumerator"), "allObjects"));
    c.ret(c.rt.bridge().toGuest(hostObjects(c, tableAt(c, table), true)));
}
B32_THUNK(_NSStringFromMapTable) {
    c.ret(c.rt.bridge().toGuest([c.rt.bridge().toHost(c.args.ptr()) description]));
}

// NSMapEnumerator NSEnumerateMapTable(NSMapTable *): a 12-byte struct, returned in memory.
B32_THUNK(_NSEnumerateMapTable) {
    StructResult out(c, 12);
    startEnumeration(c, out, c.args.ptr(), true);
}
// BOOL NSNextMapEnumeratorPair(NSMapEnumerator *, void **key, void **value)
B32_THUNK(_NSNextMapEnumeratorPair) {
    GuestAddr e = c.args.ptr(), keyOut = c.args.ptr(), valueOut = c.args.ptr();
    uint32_t key, value;
    if (!nextEntry(c, e, key, value)) return c.ret(0);
    if (keyOut) c.mem.write<uint32_t>(keyOut, key);
    if (valueOut) c.mem.write<uint32_t>(valueOut, value);
    c.ret(1);
}
B32_THUNK(_NSEndMapTableEnumeration) { endEnumeration(c, c.args.ptr()); }

// --- hash tables --------------------------------------------------------------------------------

// NSHashTable *NSCreateHashTable(NSHashTableCallBacks, NSUInteger capacity)
B32_THUNK(_NSCreateHashTable) {
    GuestAddr keys[5];
    readCallbacks(c, keys, 5);
    c.ret(newTable(c, false, keys, nullptr));
}
B32_THUNK(_NSCreateHashTableWithZone) {
    GuestAddr keys[5];
    readCallbacks(c, keys, 5);
    c.ret(newTable(c, false, keys, nullptr));
}
B32_THUNK(_NSCopyHashTableWithZone) { c.ret(copyTable(c, tableAt(c, c.args.ptr()))); }
B32_THUNK(_NSFreeHashTable) { freeTable(c, c.args.ptr()); }
B32_THUNK(_NSResetHashTable) {
    GuestAddr table = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "removeAllObjects");
    tableAt(c, table).reset();
}
B32_THUNK(_NSCountHashTable) {
    GuestAddr table = c.args.ptr();
    c.ret(isClassTable(c, table) ? send(c.rt, table, "count") : uint32_t(tableAt(c, table).entries.size()));
}
B32_THUNK(_NSCompareHashTables) {
    Table &a = tableAt(c, c.args.ptr()), &b = tableAt(c, c.args.ptr());
    bool same = a.entries.size() == b.entries.size();
    for (auto it = a.entries.begin(); same && it != a.entries.end(); ++it) same = b.entries.count(it->first);
    c.ret(same);
}
B32_THUNK(_NSHashGet) {
    GuestAddr table = c.args.ptr();
    uint32_t item = c.args.ptr();
    if (isClassTable(c, table)) return c.ret(send(c.rt, table, "member:", {item}));
    Table &t = tableAt(c, table);
    auto it = t.entries.find(item);
    c.ret(it == t.entries.end() ? 0 : it->first);
}
B32_THUNK(_NSHashInsert) {
    GuestAddr table = c.args.ptr();
    uint32_t item = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "addObject:", {item});
    tableAt(c, table).insert(item, item);
}
B32_THUNK(_NSHashInsertKnownAbsent) {
    GuestAddr table = c.args.ptr();
    uint32_t item = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "addObject:", {item});
    tableAt(c, table).insert(item, item);
}
// The item already there (and nothing inserted), or NULL once it's in.
B32_THUNK(_NSHashInsertIfAbsent) {
    GuestAddr table = c.args.ptr();
    uint32_t item = c.args.ptr();
    if (isClassTable(c, table)) {
        if (uint32_t there = send(c.rt, table, "member:", {item})) return c.ret(there);
        send(c.rt, table, "addObject:", {item});
        return c.ret(0);
    }
    Table &t = tableAt(c, table);
    if (auto it = t.entries.find(item); it != t.entries.end()) return c.ret(it->first);
    t.insert(item, item);
    c.ret(0);
}
B32_THUNK(_NSHashRemove) {
    GuestAddr table = c.args.ptr();
    uint32_t item = c.args.ptr();
    if (isClassTable(c, table)) return (void)send(c.rt, table, "removeObject:", {item});
    tableAt(c, table).remove(item);
}
B32_THUNK(_NSAllHashTableObjects) {
    GuestAddr table = c.args.ptr();
    if (isClassTable(c, table)) return c.ret(send(c.rt, table, "allObjects"));
    c.ret(c.rt.bridge().toGuest(hostObjects(c, tableAt(c, table), false)));
}
B32_THUNK(_NSStringFromHashTable) {
    c.ret(c.rt.bridge().toGuest([c.rt.bridge().toHost(c.args.ptr()) description]));
}
B32_THUNK(_NSEnumerateHashTable) {
    StructResult out(c, 12);
    startEnumeration(c, out, c.args.ptr(), false);
}
B32_THUNK(_NSNextHashEnumeratorItem) {
    uint32_t key, value;
    c.ret(nextEntry(c, c.args.ptr(), key, value) ? key : 0);
}
B32_THUNK(_NSEndHashTableEnumeration) { endEnumeration(c, c.args.ptr()); }

// --- zones ----------------------------------------------------------------------------------------

B32_THUNK(_NSDefaultMallocZone) { c.ret(0); }
B32_THUNK(_NSCreateZone) { c.ret(0); }
B32_THUNK(_NSRecycleZone) {}
B32_THUNK(_NSSetZoneName) {}
B32_THUNK(_NSZoneName) { c.ret(c.rt.bridge().toGuest(@"DefaultMallocZone")); }
B32_THUNK(_NSZoneFromPointer) { c.ret(0); }
B32_THUNK(_NSZoneMalloc) {
    c.args.ptr();
    c.ret(c.heap.alloc(c.args.u32()));
}
B32_THUNK(_NSZoneCalloc) {
    c.args.ptr();
    uint32_t count = c.args.u32();
    c.ret(c.heap.calloc(count, c.args.u32()));
}
B32_THUNK(_NSZoneRealloc) {
    c.args.ptr();
    GuestAddr p = c.args.ptr();
    c.ret(c.heap.realloc(p, c.args.u32()));
}
B32_THUNK(_NSZoneFree) {
    c.args.ptr();
    if (GuestAddr p = c.args.ptr()) c.heap.free(p);
}
B32_THUNK(_NSPageSize) { c.ret(4096); }
B32_THUNK(_NSLogPageSize) { c.ret(12); }
B32_THUNK(_NSRoundUpToMultipleOfPageSize) { c.ret((c.args.u32() + 4095) & ~4095u); }
B32_THUNK(_NSRoundDownToMultipleOfPageSize) { c.ret(c.args.u32() & ~4095u); }
B32_THUNK(_NSAllocateMemoryPages) {
    uint32_t size = (c.args.u32() + 4095) & ~4095u;
    GuestAddr p = c.heap.alloc(size, 4096);
    if (p) std::memset(c.mem.ptr<uint8_t>(p), 0, size);
    c.ret(p);
}
B32_THUNK(_NSDeallocateMemoryPages) {
    if (GuestAddr p = c.args.ptr()) c.heap.free(p);
}
