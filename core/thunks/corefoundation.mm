// CoreFoundation for the guest. CF objects are toll-free ObjC objects on the
// host, so they cross the bridge like any other object; CFIndex is 32-bit in
// the guest ('z'), and CFRange and the number types need hand conversion.

#include "CTable.h"
#include "Format.h"
#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Blocks.h"
#include "core/objc/Bridge.h"

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <objc/runtime.h>

#include <cstring>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <ffi/ffi.h>

using namespace b32;

namespace {

void *coreFoundation() { return RTLD_DEFAULT; }

constexpr CFunction kCoreFoundation[] = {
    {"CFAbsoluteTimeGetCurrent", "d:"},
    {"CFArrayGetCount", "z:o"}, 
    {"CFDataGetLength", "z:o"}, {"CFDataCreate", "o:opz"}, {"CFDataCreateMutable", "o:oz"},
    {"CFDataSetLength", "v:oz"},
    {"CFDictionaryGetCount", "z:o"},
    
    {"CFPreferencesAppSynchronize", "B:o"}, {"CFPreferencesCopyAppValue", "o:oo"},
    {"CFPreferencesCopyKeyList", "o:ooo"}, {"CFPreferencesSetValue", "v:ooooo"}, {"CFPreferencesSynchronize", "B:ooo"},
    {"CFPreferencesSetAppValue", "v:ooo"},
    {"CFRunLoopGetCurrent", "o:"}, {"CFRunLoopGetMain", "o:"}, {"CFRunLoopPerformBlock", "v:ooo"},
    {"CFRunLoopWakeUp", "v:o"}, {"CFRunLoopRun", "v:"},
    {"CFRunLoopAddTimer", "v:ooo"}, {"CFRunLoopTimerInvalidate", "v:o"},
    {"CFStringAppendCharacters", "v:opz"}, {"CFStringAppendCString", "v:opu"},
    {"CFStringCreateWithCString", "o:opu"}, {"CFStringGetCString", "B:opzu"},
    {"CFStringGetLength", "z:o"}, {"CFStringCreateMutable", "o:oz"}, {"CFStringCreateCopy", "o:oo"},
    {"CFStringCompare", "z:ooz"}, {"CFStringGetIntValue", "i:o"}, {"CFStringGetDoubleValue", "d:o"},
    {"CFUUIDCreate", "o:o"}, {"CFUUIDCreateString", "o:oo"},
    {"CFGetTypeID", "z:o"}, {"CFStringGetTypeID", "z:"}, {"CFNumberGetTypeID", "z:"},
    {"CFArrayGetTypeID", "z:"}, {"CFDictionaryGetTypeID", "z:"}, {"CFDataGetTypeID", "z:"}, {"CFBooleanGetTypeID", "z:"}, {"CFErrorGetTypeID", "z:"},
    {"CFSetGetTypeID", "z:"}, {"CFDateGetTypeID", "z:"}, {"CFNullGetTypeID", "z:"}, {"CFURLGetTypeID", "z:"},
    {"CFBooleanGetValue", "B:o"}, {"CFNumberIsFloatType", "B:o"}, {"CFEqual", "B:oo"}, {"CFHash", "z:o"},
    {"CFURLCreateWithFileSystemPath", "o:ooiu"}, {"CFBundleGetMainBundle", "o:"},
    {"CFBundleCopyResourceURL", "o:oooo"}, {"CFBundleCopyResourcesDirectoryURL", "o:o"},
    {"CFLocaleCopyCurrent", "o:"}, {"CFLocaleGetIdentifier", "o:o"}, {"CFLocaleGetSystem", "o:"},
    // Strings, locales, time zones, calendars and formatters (Adobe AIR).
    {"CFStringNormalize", "v:oz"}, {"CFStringCreateWithBytes", "o:opzuu"}, {"CFStringCreateWithCharacters", "o:opz"},
    {"CFStringGetCharacterAtIndex", "u:oz"}, {"CFStringGetSystemEncoding", "u:"},
    {"CFStringCompareWithOptionsAndLocale", "z:oozzzo"}, {"CFStringConvertEncodingToWindowsCodepage", "u:u"},
    {"CFStringConvertWindowsCodepageToEncoding", "u:u"}, {"CFAllocatorGetDefault", "o:"}, {"CFDataCreateCopy", "o:oo"},
    {"CFLocaleCreate", "o:oo"}, {"CFLocaleCreateCopy", "o:oo"}, {"CFLocaleCopyAvailableLocaleIdentifiers", "o:"},
    {"CFTimeZoneCopyDefault", "o:"}, {"CFTimeZoneCopySystem", "o:"}, {"CFTimeZoneCreateWithTimeIntervalFromGMT", "o:od"},
    {"CFTimeZoneGetSecondsFromGMT", "d:od"}, {"CFTimeZoneIsDaylightSavingTime", "B:od"},
    {"CFCalendarCreateWithIdentifier", "o:oo"}, {"CFCalendarGetFirstWeekday", "z:o"}, {"CFCalendarSetTimeZone", "v:oo"},
    {"CFDateFormatterCreate", "o:oozz"}, {"CFDateFormatterSetFormat", "v:oo"}, {"CFDateFormatterGetFormat", "o:o"},
    {"CFDateFormatterCopyProperty", "o:oo"}, {"CFDateFormatterSetProperty", "v:ooo"},
    {"CFDateFormatterCreateStringWithAbsoluteTime", "o:ood"},
    {"CFNumberFormatterCreate", "o:ooz"}, {"CFNumberFormatterCopyProperty", "o:oo"},
    {"CFNumberFormatterSetProperty", "v:ooo"}, {"CFNumberFormatterCreateStringWithValue", "o:oozp"},
    {"CFBundleGetBundleWithIdentifier", "o:o"}, {"CFURLCreateWithString", "o:ooo"}, {"CFURLCopyNetLocation", "o:o"},
    // CFNetwork: proxies, HTTP messages and streams.
    {"CFNetworkCopySystemProxySettings", "o:"}, {"CFHTTPMessageCreateRequest", "o:oooo"},
    {"CFHTTPMessageSetHeaderFieldValue", "v:ooo"}, {"CFHTTPMessageSetBody", "v:oo"},
    {"CFHTTPMessageCopyAllHeaderFields", "o:o"}, {"CFHTTPMessageGetResponseStatusCode", "z:o"},
    {"CFHTTPMessageGetTypeID", "z:"}, {"CFReadStreamCreateForHTTPRequest", "o:oo"},
    {"CFReadStreamCreateForStreamedHTTPRequest", "o:ooo"}, {"CFReadStreamCreateWithBytesNoCopy", "o:opzo"},
    {"CFReadStreamOpen", "B:o"}, {"CFReadStreamClose", "v:o"}, {"CFReadStreamGetStatus", "z:o"},
    {"CFReadStreamHasBytesAvailable", "B:o"}, {"CFReadStreamRead", "z:opz"}, {"CFReadStreamCopyProperty", "o:oo"},
    {"CFReadStreamSetProperty", "B:ooo"}, {"CFReadStreamCopyError", "o:o"}, {"CFReadStreamScheduleWithRunLoop", "v:ooo"},
    {"CFWriteStreamOpen", "B:o"}, {"CFWriteStreamClose", "v:o"}, {"CFWriteStreamWrite", "z:opz"},
    {"CFWriteStreamCanAcceptBytes", "B:o"}, {"CFWriteStreamSetProperty", "B:ooo"}, {"CFWriteStreamCopyError", "o:o"},
    {"CFRunLoopAddSource", "v:ooo"}, {"CFRunLoopRemoveSource", "v:ooo"}, {"CFRunLoopAddObserver", "v:ooo"},
    {"CFRunLoopRemoveObserver", "v:ooo"}, {"CFRunLoopObserverInvalidate", "v:o"},
    {"CFRunLoopSourceSignal", "v:o"}, {"CFRunLoopSourceInvalidate", "v:o"}, {"CFRunLoopSourceIsValid", "B:o"},
    {"CFDictionaryCreateMutableCopy", "o:ozo"}, {"CFLocaleGetValue", "o:oo"}, {"CFURLCopyQueryString", "o:oo"},
    {"CFRunLoopIsWaiting", "B:o"}, {"CFRunLoopRemoveTimer", "v:ooo"},
    // CFError, more CFString, CFHTTPMessage and stream calls (PopCap games).
    {"CFStringCreateExternalRepresentation", "o:oouu"}, {"CFStringCreateFromExternalRepresentation", "o:oou"},
    {"CFStringCreateWithCStringNoCopy", "o:opuo"}, {"CFURLCopyScheme", "o:o"},
    {"CFErrorCopyDescription", "o:o"}, {"CFErrorCopyUserInfo", "o:o"}, {"CFErrorGetCode", "z:o"},
    {"CFErrorGetDomain", "o:o"}, {"CFHTTPMessageCopyHeaderFieldValue", "o:oo"},
    {"CFHTTPMessageCopyRequestURL", "o:o"}, {"CFHTTPMessageCopyResponseStatusLine", "o:o"},
    {"CFHTTPMessageCopySerializedMessage", "o:o"}, {"CFReadStreamUnscheduleFromRunLoop", "v:ooo"},
    {"CFRunLoopTimerSetNextFireDate", "v:od"},
    {"CFStringGetFastestEncoding", "u:o"}, {"CFStringGetSmallestEncoding", "u:o"},
    {"CFStringGetMaximumSizeForEncoding", "z:zu"}, {"CFStringGetCStringPtr", "s:ou"},
    {"CFStringConvertEncodingToNSStringEncoding", "z:u"}, {"CFStringConvertNSStringEncodingToEncoding", "u:z"},
    {"CFStringConvertEncodingToIANACharSetName", "o:u"}, {"CFStringConvertIANACharSetNameToEncoding", "u:o"},
    {"CFStringCreateMutableCopy", "o:ozo"}, {"CFStringCreateWithSubstring", "o:oozz"},
    {"CFStringHasPrefix", "B:oo"}, {"CFStringHasSuffix", "B:oo"}, {"CFStringLowercase", "v:oo"},
    {"CFStringUppercase", "v:oo"}, {"CFStringCreateArrayBySeparatingStrings", "o:ooo"},
    {"CFStringFind", "z:oou"}, {"CFStringAppend", "v:oo"},
    {"CFCopyDescription", "o:o"}, {"CFDateCompare", "z:oop"},
    {"CFArrayAppendArray", "v:oozz"}, {"CFArrayRemoveValueAtIndex", "v:oz"},
    
    {"CFArrayRemoveAllValues", "v:o"}, 
    {"CFBundleGetInfoDictionary", "o:o"},
    {"CFNotificationCenterGetLocalCenter", "o:"}, {"CFNotificationCenterGetDarwinNotifyCenter", "o:"},
    {"CFRunLoopContainsTimer", "B:ooo"},
    {"CFURLCreateStringByAddingPercentEscapes", "o:oooou"},
    {"CFURLCreateStringByReplacingPercentEscapes", "o:ooo"},
    {"CFURLCreateStringByReplacingPercentEscapesUsingEncoding", "o:ooou"},
    {"CFURLCreateFromFileSystemRepresentation", "o:opzu"}, {"CFURLGetFileSystemRepresentation", "B:oupz"},
    {"CFURLCopyFileSystemPath", "o:oi"}, {"CFURLCopyPathExtension", "o:o"}, {"CFURLGetString", "o:o"},
    {"CFAttributedStringSetAttribute", "v:ozzoo"}, {"CFAttributedStringRemoveAttribute", "v:ozzo"},
};

B32_C_FUNCTIONS(kCoreFoundation, coreFoundation);

objc::Bridge &bridge(Call &c) { return c.rt.bridge(); }

// CFRange is { CFIndex location, length }: two words in the guest.
CFRange range(Call &c) {
    CFIndex location = c.args.i32();
    return CFRangeMake(location, c.args.i32());
}

}  // namespace

// --- collections -----------------------------------------------------------------------------------
// A CF collection made with the kCFType callbacks holds objects; one made
// with NULL callbacks holds plain pointer-sized values (the guest's malloc'd
// buffers, small integers), which pass through unconverted. The latter are
// marked with an associated object. A dictionary with callbacks of the
// guest's own (C string keys, say) holds plain values too, compared, hashed,
// retained and released by calling those guest functions.

namespace {
char rawKey;
constexpr int kRawValues = 1, kRawKeys = 2;

void markRaw(id collection, int flags) {
    if (flags) objc_setAssociatedObject(collection, &rawKey, @(flags), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
int rawFlags(id collection) { return [objc_getAssociatedObject(collection, &rawKey) intValue]; }

const void *hostValue(Call &c, bool raw, GuestAddr value) {
    return raw ? reinterpret_cast<const void *>(uintptr_t(value)) : (const void *)bridge(c).toHost(value);
}
GuestAddr guestValue(Call &c, bool raw, const void *value) {
    return raw ? GuestAddr(uintptr_t(value)) : bridge(c).toGuest((id)value);
}
}  // namespace

// CFArrayRef CFArrayCreate(CFAllocatorRef, const void **values, CFIndex count, const CFArrayCallBacks *)
B32_THUNK(_CFArrayCreate) {
    c.args.ptr();
    GuestAddr values = c.args.ptr();
    int32_t count = c.args.i32();
    bool raw = c.args.ptr() == 0;
    std::vector<const void *> items(size_t(std::max(count, 0)));
    for (int32_t i = 0; i < count; i++) items[size_t(i)] = hostValue(c, raw, c.mem.read<uint32_t>(values + uint32_t(i) * 4));
    CFArrayRef array = CFArrayCreate(nullptr, items.data(), count, raw ? nullptr : &kCFTypeArrayCallBacks);
    markRaw((id)array, raw ? kRawValues : 0);
    c.ret(bridge(c).toGuest((id)array));
}

// CFMutableArrayRef CFArrayCreateMutable(CFAllocatorRef, CFIndex capacity, const CFArrayCallBacks *)
B32_THUNK(_CFArrayCreateMutable) {
    c.args.ptr();
    CFIndex capacity = c.args.i32();
    bool raw = c.args.ptr() == 0;
    CFMutableArrayRef array = CFArrayCreateMutable(nullptr, capacity, raw ? nullptr : &kCFTypeArrayCallBacks);
    markRaw((id)array, raw ? kRawValues : 0);
    c.ret(bridge(c).toGuest((id)array));
}

namespace {

// A host callback that calls a guest callback function, as a libffi closure.
struct GuestCallback {
    enum Kind { Retain, Release, Equal, Hash } kind;
    GuestAddr fn;
    ffi_cif cif;
    ffi_type *args[2];
};

void callGuestCallback(ffi_cif *, void *ret, void **args, void *data) {
    auto *cb = static_cast<GuestCallback *>(data);
    auto arg = [&](int i) { return uint32_t(*static_cast<uintptr_t *>(args[i])); };
    Cpu &cpu = Runtime::threadCpu();
    switch (cb->kind) {
    case GuestCallback::Retain:  // const void *(CFAllocatorRef, const void *)
        *static_cast<void **>(ret) = reinterpret_cast<void *>(uintptr_t(uint32_t(cpu.call(cb->fn, {0, arg(1)}))));
        break;
    case GuestCallback::Release:  // void (CFAllocatorRef, const void *)
        cpu.call(cb->fn, {0, arg(1)});
        break;
    case GuestCallback::Equal:  // Boolean (const void *, const void *)
        *static_cast<ffi_arg *>(ret) = uint8_t(cpu.call(cb->fn, {arg(0), arg(1)}));
        break;
    case GuestCallback::Hash:  // CFHashCode (const void *)
        *static_cast<uint64_t *>(ret) = uint32_t(cpu.call(cb->fn, {arg(0)}));
        break;
    }
}

// The host function for the guest callback at `fn`, or null for none.
void *hostCallback(GuestAddr fn, GuestCallback::Kind kind) {
    if (!fn) return nullptr;
    auto *cb = new GuestCallback{kind, fn, {}, {&ffi_type_pointer, &ffi_type_pointer}};
    unsigned argc = kind == GuestCallback::Hash ? 1 : 2;
    ffi_type *ret = kind == GuestCallback::Retain ? &ffi_type_pointer : kind == GuestCallback::Release ? &ffi_type_void
                  : kind == GuestCallback::Equal  ? &ffi_type_uint8   : &ffi_type_uint64;
    void *code = nullptr;
    auto *closure = static_cast<ffi_closure *>(ffi_closure_alloc(sizeof(ffi_closure), &code));
    if (!closure || ffi_prep_cif(&cb->cif, FFI_DEFAULT_ABI, argc, ret, cb->args) != FFI_OK ||
        ffi_prep_closure_loc(closure, &cb->cif, callGuestCallback, cb, code) != FFI_OK)
        fatal("can't make a host callback for guest function 0x%08x", fn);
    return code;
}

// How a guest collection's callbacks are honoured.
enum class Callbacks { Objects, Plain, Guest };
Callbacks callbacksKind(Call &c, GuestAddr callbacks, const char *standard, const char *standard2 = nullptr) {
    if (!callbacks) return Callbacks::Plain;
    if (callbacks == c.rt.dataSymbol(standard) || (standard2 && callbacks == c.rt.dataSymbol(standard2)))
        return Callbacks::Objects;
    return Callbacks::Guest;
}

// Host versions of guest key and value callbacks
//   { version, retain, release, copyDescription, equal, hash },
// made once per guest callbacks structure.
const CFDictionaryKeyCallBacks *hostKeyCallbacks(Call &c, GuestAddr guest) {
    static std::mutex lock;
    static std::unordered_map<GuestAddr, CFDictionaryKeyCallBacks *> made;
    std::lock_guard guard(lock);
    if (auto it = made.find(guest); it != made.end()) return it->second;
    auto *cb = new CFDictionaryKeyCallBacks{};
    cb->retain = reinterpret_cast<CFDictionaryRetainCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 4), GuestCallback::Retain));
    cb->release = reinterpret_cast<CFDictionaryReleaseCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 8), GuestCallback::Release));
    cb->equal = reinterpret_cast<CFDictionaryEqualCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 16), GuestCallback::Equal));
    cb->hash = reinterpret_cast<CFDictionaryHashCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 20), GuestCallback::Hash));
    made[guest] = cb;
    return cb;
}
const CFDictionaryValueCallBacks *hostValueCallbacks(Call &c, GuestAddr guest) {
    static std::mutex lock;
    static std::unordered_map<GuestAddr, CFDictionaryValueCallBacks *> made;
    std::lock_guard guard(lock);
    if (auto it = made.find(guest); it != made.end()) return it->second;
    auto *cb = new CFDictionaryValueCallBacks{};
    cb->retain = reinterpret_cast<CFDictionaryRetainCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 4), GuestCallback::Retain));
    cb->release = reinterpret_cast<CFDictionaryReleaseCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 8), GuestCallback::Release));
    cb->equal = reinterpret_cast<CFDictionaryEqualCallBack>(hostCallback(c.mem.read<uint32_t>(guest + 16), GuestCallback::Equal));
    made[guest] = cb;
    return cb;
}

}  // namespace

// CFMutableDictionaryRef CFDictionaryCreateMutable(CFAllocatorRef, CFIndex capacity,
//     const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *)
B32_THUNK(_CFDictionaryCreateMutable) {
    c.args.ptr();
    CFIndex capacity = c.args.i32();
    GuestAddr keyCallbacks = c.args.ptr(), valueCallbacks = c.args.ptr();
    Callbacks keys = callbacksKind(c, keyCallbacks, "_kCFTypeDictionaryKeyCallBacks", "_kCFCopyStringDictionaryKeyCallBacks");
    Callbacks values = callbacksKind(c, valueCallbacks, "_kCFTypeDictionaryValueCallBacks");
    const CFDictionaryKeyCallBacks *hostKeys = keys == Callbacks::Objects ? &kCFTypeDictionaryKeyCallBacks
                                             : keys == Callbacks::Guest   ? hostKeyCallbacks(c, keyCallbacks)
                                                                          : nullptr;
    const CFDictionaryValueCallBacks *hostValues = values == Callbacks::Objects ? &kCFTypeDictionaryValueCallBacks
                                                 : values == Callbacks::Guest   ? hostValueCallbacks(c, valueCallbacks)
                                                                                : nullptr;
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(nullptr, capacity, hostKeys, hostValues);
    markRaw((id)dict, (keys != Callbacks::Objects ? kRawKeys : 0) | (values != Callbacks::Objects ? kRawValues : 0));
    c.ret(bridge(c).toGuest((id)dict));
}

// CFDictionaryRef CFDictionaryCreate(CFAllocatorRef, const void **keys, const void **values, CFIndex count,
//     const CFDictionaryKeyCallBacks *, const CFDictionaryValueCallBacks *)
B32_THUNK(_CFDictionaryCreate) {
    c.args.ptr();
    GuestAddr keyList = c.args.ptr(), valueList = c.args.ptr();
    int32_t count = c.args.i32();
    GuestAddr keyCallbacks = c.args.ptr(), valueCallbacks = c.args.ptr();
    Callbacks keys = callbacksKind(c, keyCallbacks, "_kCFTypeDictionaryKeyCallBacks", "_kCFCopyStringDictionaryKeyCallBacks");
    Callbacks values = callbacksKind(c, valueCallbacks, "_kCFTypeDictionaryValueCallBacks");
    const CFDictionaryKeyCallBacks *hostKeys = keys == Callbacks::Objects ? &kCFTypeDictionaryKeyCallBacks
                                             : keys == Callbacks::Guest   ? hostKeyCallbacks(c, keyCallbacks)
                                                                          : nullptr;
    const CFDictionaryValueCallBacks *hostValues = values == Callbacks::Objects ? &kCFTypeDictionaryValueCallBacks
                                                 : values == Callbacks::Guest   ? hostValueCallbacks(c, valueCallbacks)
                                                                                : nullptr;
    bool rawKeys = keys != Callbacks::Objects, rawValues = values != Callbacks::Objects;
    std::vector<const void *> k(size_t(std::max(count, 0))), v(k.size());
    for (int32_t i = 0; i < count; i++) {
        k[size_t(i)] = hostValue(c, rawKeys, c.mem.read<uint32_t>(keyList + uint32_t(i) * 4));
        v[size_t(i)] = hostValue(c, rawValues, c.mem.read<uint32_t>(valueList + uint32_t(i) * 4));
    }
    CFDictionaryRef dict = CFDictionaryCreate(nullptr, k.data(), v.data(), count, hostKeys, hostValues);
    markRaw((id)dict, (rawKeys ? kRawKeys : 0) | (rawValues ? kRawValues : 0));
    c.ret(bridge(c).toGuest((id)dict));
}

B32_THUNK(_CFArrayGetValueAtIndex) {
    id array = bridge(c).toHost(c.args.ptr());
    c.ret(guestValue(c, rawFlags(array) & kRawValues, CFArrayGetValueAtIndex((CFArrayRef)array, c.args.i32())));
}
B32_THUNK(_CFArrayAppendValue) {
    id array = bridge(c).toHost(c.args.ptr());
    CFArrayAppendValue((CFMutableArrayRef)array, hostValue(c, rawFlags(array) & kRawValues, c.args.ptr()));
}
B32_THUNK(_CFArraySetValueAtIndex) {
    id array = bridge(c).toHost(c.args.ptr());
    CFIndex index = c.args.i32();
    CFArraySetValueAtIndex((CFMutableArrayRef)array, index, hostValue(c, rawFlags(array) & kRawValues, c.args.ptr()));
}
B32_THUNK(_CFArrayInsertValueAtIndex) {
    id array = bridge(c).toHost(c.args.ptr());
    CFIndex index = c.args.i32();
    CFArrayInsertValueAtIndex((CFMutableArrayRef)array, index, hostValue(c, rawFlags(array) & kRawValues, c.args.ptr()));
}
// CFIndex CFArrayGetFirstIndexOfValue(CFArrayRef, CFRange, const void *value)
B32_THUNK(_CFArrayGetFirstIndexOfValue) {
    id array = bridge(c).toHost(c.args.ptr());
    CFRange r = range(c);
    c.ret(uint32_t(CFArrayGetFirstIndexOfValue((CFArrayRef)array, r, hostValue(c, rawFlags(array) & kRawValues, c.args.ptr()))));
}

// void CFArrayGetValues(CFArrayRef, CFRange, const void **values)
B32_THUNK(_CFArrayGetValues) {
    id array = bridge(c).toHost(c.args.ptr());
    CFRange r = range(c);
    GuestAddr out = c.args.ptr();
    bool raw = rawFlags(array) & kRawValues;
    std::vector<const void *> values(size_t(r.length));
    CFArrayGetValues((CFArrayRef)array, r, values.data());
    for (CFIndex i = 0; i < r.length; i++) c.mem.write<uint32_t>(out + uint32_t(i) * 4, guestValue(c, raw, values[size_t(i)]));
}

// void CFDictionaryGetKeysAndValues(CFDictionaryRef, const void **keys, const void **values):
// either array may be NULL.
B32_THUNK(_CFDictionaryGetKeysAndValues) {
    id dict = bridge(c).toHost(c.args.ptr());
    GuestAddr outKeys = c.args.ptr(), outValues = c.args.ptr();
    int flags = rawFlags(dict);
    size_t count = size_t(CFDictionaryGetCount((CFDictionaryRef)dict));
    std::vector<const void *> keys(count), values(count);
    CFDictionaryGetKeysAndValues((CFDictionaryRef)dict, keys.data(), values.data());
    for (size_t i = 0; i < count; i++) {
        if (outKeys) c.mem.write<uint32_t>(outKeys + uint32_t(i) * 4, guestValue(c, flags & kRawKeys, keys[i]));
        if (outValues) c.mem.write<uint32_t>(outValues + uint32_t(i) * 4, guestValue(c, flags & kRawValues, values[i]));
    }
}

B32_THUNK(_CFDictionaryGetValue) {
    id dict = bridge(c).toHost(c.args.ptr());
    int flags = rawFlags(dict);
    const void *key = hostValue(c, flags & kRawKeys, c.args.ptr());
    c.ret(guestValue(c, flags & kRawValues, CFDictionaryGetValue((CFDictionaryRef)dict, key)));
}
B32_THUNK(_CFDictionarySetValue) {
    id dict = bridge(c).toHost(c.args.ptr());
    int flags = rawFlags(dict);
    const void *key = hostValue(c, flags & kRawKeys, c.args.ptr());
    CFDictionarySetValue((CFMutableDictionaryRef)dict, key, hostValue(c, flags & kRawValues, c.args.ptr()));
}
B32_THUNK(_CFDictionaryAddValue) {
    id dict = bridge(c).toHost(c.args.ptr());
    int flags = rawFlags(dict);
    const void *key = hostValue(c, flags & kRawKeys, c.args.ptr());
    CFDictionaryAddValue((CFMutableDictionaryRef)dict, key, hostValue(c, flags & kRawValues, c.args.ptr()));
}
B32_THUNK(_CFDictionaryRemoveValue) {
    id dict = bridge(c).toHost(c.args.ptr());
    CFDictionaryRemoveValue((CFMutableDictionaryRef)dict, hostValue(c, rawFlags(dict) & kRawKeys, c.args.ptr()));
}
// Boolean CFDictionaryGetValueIfPresent(CFDictionaryRef, const void *key, const void **value)
B32_THUNK(_CFDictionaryGetValueIfPresent) {
    id dict = bridge(c).toHost(c.args.ptr());
    int flags = rawFlags(dict);
    const void *key = hostValue(c, flags & kRawKeys, c.args.ptr());
    GuestAddr out = c.args.ptr();
    const void *value = nullptr;
    Boolean found = CFDictionaryGetValueIfPresent((CFDictionaryRef)dict, key, &value);
    if (found && out) c.mem.write<uint32_t>(out, guestValue(c, flags & kRawValues, value));
    c.ret(found);
}

B32_THUNK(_CFDictionaryContainsKey) {
    id dict = bridge(c).toHost(c.args.ptr());
    c.ret(CFDictionaryContainsKey((CFDictionaryRef)dict, hostValue(c, rawFlags(dict) & kRawKeys, c.args.ptr())));
}

// CFDataRef CFDataCreateWithBytesNoCopy(CFAllocatorRef, const UInt8 *, CFIndex, CFAllocatorRef deallocator)
// The bytes stay in guest memory, which never moves.
B32_THUNK(_CFDataCreateWithBytesNoCopy) {
    c.args.ptr();
    GuestAddr bytes = c.args.ptr();
    int32_t length = c.args.i32();
    c.args.ptr();  // the guest frees its own buffer; the host never deallocates guest memory
    CFDataRef data = CFDataCreateWithBytesNoCopy(nullptr, c.mem.ptr<UInt8>(bytes), length, kCFAllocatorNull);
    c.ret(bridge(c).toGuest((id)data));
}

// const UInt8 *CFDataGetBytePtr(CFDataRef): host storage is copied into guest
// memory owned by the data object (unless it already is guest memory).
B32_THUNK(_CFDataGetBytePtr) {
    NSData *data = (NSData *)bridge(c).toHost(c.args.ptr());
    const uint8_t *bytes = static_cast<const uint8_t *>(data.bytes);
    if (!bytes) {
        c.ret(0);
        return;
    }
    GuestMemory &mem = c.mem;
    if (bytes >= mem.base() && bytes < mem.base() + GuestMemory::kSize) {
        c.ret(mem.guestAddrOf(bytes));
        return;
    }
    c.ret(bridge(c).guestBytes(bytes, uint32_t(data.length), data));
}

// UInt8 *CFDataGetMutableBytePtr(CFMutableDataRef): the same guest buffer as -mutableBytes.
B32_THUNK(_CFDataGetMutableBytePtr) { c.ret(bridge(c).mutableBytes(bridge(c).toHost(c.args.ptr()))); }

// CFStringRef CFStringCreateWithBytesNoCopy(CFAllocatorRef, const UInt8 *bytes, CFIndex numBytes,
//     CFStringEncoding, Boolean isExternalRepresentation, CFAllocatorRef contentsDeallocator):
// a copy, since the host mustn't free guest memory with the deallocator.
B32_THUNK(_CFStringCreateWithBytesNoCopy) {
    c.args.ptr();
    GuestAddr bytes = c.args.ptr();
    CFIndex length = c.args.i32();
    CFStringEncoding encoding = c.args.u32();
    Boolean external = Boolean(c.args.u32());
    CFStringRef string = CFStringCreateWithBytes(nullptr, c.mem.ptr<UInt8>(bytes), length, encoding, external);
    c.ret(bridge(c).toGuest((id)string));
}

// void CFDataGetBytes(CFDataRef, CFRange, UInt8 *buffer)
B32_THUNK(_CFDataGetBytes) {
    CFDataRef data = (CFDataRef)bridge(c).toHost(c.args.ptr());
    CFRange r = range(c);
    CFDataGetBytes(data, r, c.mem.ptr<UInt8>(c.args.ptr()));
}

// Boolean CFNumberGetValue(CFNumberRef, CFNumberType, void *valuePtr)
// The long, CFIndex and NSInteger types are 32-bit in the guest, CGFloat a float.
B32_THUNK(_CFNumberGetValue) {
    CFNumberRef number = (CFNumberRef)bridge(c).toHost(c.args.ptr());
    CFNumberType type = CFNumberType(c.args.u32());
    GuestAddr out = c.args.ptr();
    switch (type) {
    case kCFNumberLongType: case kCFNumberCFIndexType: case kCFNumberNSIntegerType: {
        int32_t v = 0;
        Boolean ok = CFNumberGetValue(number, kCFNumberSInt32Type, &v);
        c.mem.write<int32_t>(out, v);
        c.ret(ok);
        break;
    }
    case kCFNumberCGFloatType: {
        float v = 0;
        Boolean ok = CFNumberGetValue(number, kCFNumberFloat32Type, &v);
        c.mem.write<float>(out, v);
        c.ret(ok);
        break;
    }
    default:  // every other type has the same size in both ABIs
        c.ret(CFNumberGetValue(number, type, c.mem.ptr<void>(out)));
        break;
    }
}

// CFNumberType CFNumberGetType(CFNumberRef): types whose size differs in the
// guest (long, CFIndex, NSInteger, CGFloat are 64-bit here) are reported by
// their explicit 64-bit names, which mean the same in both.
B32_THUNK(_CFNumberGetType) {
    CFNumberType type = CFNumberGetType((CFNumberRef)bridge(c).toHost(c.args.ptr()));
    switch (type) {
    case kCFNumberLongType: case kCFNumberCFIndexType: case kCFNumberNSIntegerType: type = kCFNumberSInt64Type; break;
    case kCFNumberCGFloatType: type = kCFNumberFloat64Type; break;
    default: break;
    }
    c.ret(uint32_t(type));
}
// CFIndex CFNumberGetByteSize(CFNumberRef): after that translation, the sizes agree.
B32_THUNK(_CFNumberGetByteSize) { c.ret(uint32_t(CFNumberGetByteSize((CFNumberRef)bridge(c).toHost(c.args.ptr())))); }

// CFNumberRef CFNumberCreate(CFAllocatorRef, CFNumberType, const void *valuePtr)
B32_THUNK(_CFNumberCreate) {
    c.args.ptr();
    CFNumberType type = CFNumberType(c.args.u32());
    GuestAddr value = c.args.ptr();
    CFNumberRef number;
    switch (type) {
    case kCFNumberLongType: case kCFNumberCFIndexType: case kCFNumberNSIntegerType:
        number = CFNumberCreate(nullptr, kCFNumberSInt32Type, c.mem.ptr<void>(value));
        break;
    case kCFNumberCGFloatType: number = CFNumberCreate(nullptr, kCFNumberFloat32Type, c.mem.ptr<void>(value)); break;
    default: number = CFNumberCreate(nullptr, type, c.mem.ptr<void>(value)); break;
    }
    c.ret(bridge(c).toGuest((id)number));
}

// --- CFNetServices (Bonjour): local multiplayer isn't bridged; creation fails --------------

B32_THUNK(_CFNetServiceBrowserCreate) { c.ret(0); }
B32_THUNK(_CFNetServiceCreate) { c.ret(0); }

// An SInt32, not an object.
B32_DATA(_kCFStreamErrorDomainNetServices, 4) { rt.mem().write<int32_t>(addr, kCFStreamErrorDomainNetServices); }

// --- constants ------------------------------------------------------------------------------

B32_OBJC_CONSTANT(kCFAllocatorDefault)
B32_OBJC_CONSTANT(kCFAllocatorNull)
B32_OBJC_CONSTANT(kCFAllocatorSystemDefault)
B32_OBJC_CONSTANT(kCFBooleanTrue)
B32_OBJC_CONSTANT(kCFBooleanFalse)
B32_OBJC_CONSTANT(kCFRunLoopCommonModes)
B32_OBJC_CONSTANT(kCFRunLoopDefaultMode)
B32_OBJC_CONSTANT(kCFPreferencesCurrentApplication)
B32_OBJC_CONSTANT(kCFPreferencesCurrentUser)
B32_OBJC_CONSTANT(kCFPreferencesAnyHost)
B32_OBJC_CONSTANT(NSFileSystemFreeSize)
B32_OBJC_CONSTANT(NSFileModificationDate)
B32_OBJC_CONSTANT(NSGregorianCalendar)
B32_OBJC_CONSTANT(NSLocalizedDescriptionKey)
B32_OBJC_CONSTANT(NSUnderlyingErrorKey)
B32_OBJC_CONSTANT(NSLocaleCountryCode)

// --- run loop timers ---------------------------------------------------------------------

namespace {
struct GuestTimer {
    GuestAddr callout;
    GuestAddr info;
    GuestAddr timer;  // the guest's reference to the timer
};

void timerFired(CFRunLoopTimerRef, void *data) {
    auto *t = static_cast<GuestTimer *>(data);
    Runtime::threadCpu().call(t->callout, {t->timer, t->info});
}
}  // namespace

// CFRunLoopTimerRef CFRunLoopTimerCreate(CFAllocatorRef, CFAbsoluteTime fireDate,
//     CFTimeInterval interval, CFOptionFlags, CFIndex order, CFRunLoopTimerCallBack,
//     CFRunLoopTimerContext *)
// The guest context is { version, info, retain, release, copyDescription }; only
// info is kept (games pass plain pointers).
B32_THUNK(_CFRunLoopTimerCreate) {
    c.args.ptr();
    CFAbsoluteTime fireDate = c.args.f64();
    CFTimeInterval interval = c.args.f64();
    CFOptionFlags flags = c.args.u32();
    CFIndex order = c.args.i32();
    auto *t = new GuestTimer{c.args.ptr(), 0, 0};
    if (GuestAddr context = c.args.ptr()) t->info = c.mem.read<uint32_t>(context + 4);
    CFRunLoopTimerContext context = {0, t, nullptr, nullptr, nullptr};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(nullptr, fireDate, interval, flags, order, timerFired, &context);
    t->timer = bridge(c).toGuest((id)timer);
    c.ret(t->timer);
}

// --- the rest of CFString and CFArray -----------------------------------------------------------------

// The characters live in host memory; "no direct pointer" is always allowed.
B32_THUNK(_CFStringGetCharactersPtr) { c.ret(0); }
B32_THUNK(_CFBundleGetDataPointerForName) { c.ret(0); }

// CFStringRef CFStringCreateWithFormat(CFAllocatorRef, CFDictionaryRef options, CFStringRef format, ...)
B32_THUNK(_CFStringCreateWithFormat) {
    c.args.ptr();
    c.args.ptr();
    NSString *format = (NSString *)bridge(c).toHost(c.args.ptr());
    std::string s = formatGuest(c, format.UTF8String, c.args, objc::describeObject);
    c.ret(bridge(c).toGuest([[NSString alloc] initWithUTF8String:s.c_str()]));
}

// void CFStringGetCharacters(CFStringRef, CFRange, UniChar *buffer): the guest's CFRange is two words.
B32_THUNK(_CFStringGetCharacters) {
    auto string = (CFStringRef)bridge(c).toHost(c.args.ptr());
    CFIndex location = c.args.i32(), length = c.args.i32();
    GuestAddr out = c.args.ptr();
    std::vector<UniChar> characters(size_t(std::max<CFIndex>(length, 0)));
    CFStringGetCharacters(string, CFRangeMake(location, length), characters.data());
    c.mem.writeArray<UniChar>(out, characters.data(), characters.size());
}

// Boolean CFStringFindWithOptions(CFStringRef, CFStringRef toFind, CFRange rangeToSearch,
//                                 CFStringCompareFlags, CFRange *result)
B32_THUNK(_CFStringFindWithOptions) {
    auto string = (CFStringRef)bridge(c).toHost(c.args.ptr());
    auto toFind = (CFStringRef)bridge(c).toHost(c.args.ptr());
    CFIndex location = c.args.i32(), length = c.args.i32();
    CFStringCompareFlags flags = c.args.u32();
    GuestAddr resultOut = c.args.ptr();
    CFRange found;
    Boolean ok = CFStringFindWithOptions(string, toFind, CFRangeMake(location, length), flags, &found);
    if (ok && resultOut) {
        c.mem.write<int32_t>(resultOut, int32_t(found.location));
        c.mem.write<int32_t>(resultOut + 4, int32_t(found.length));
    }
    c.ret(ok);
}

// CFStringRef CFStringCreateWithFormatAndArguments(CFAllocatorRef, CFDictionaryRef options, CFStringRef format, va_list)
B32_THUNK(_CFStringCreateWithFormatAndArguments) {
    c.args.ptr();
    c.args.ptr();
    NSString *format = (NSString *)bridge(c).toHost(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, format.UTF8String, va, objc::describeObject);
    c.ret(bridge(c).toGuest([[NSString alloc] initWithUTF8String:s.c_str()]));
}

// void CFStringAppendFormat(CFMutableStringRef, CFDictionaryRef options, CFStringRef format, ...)
B32_THUNK(_CFStringAppendFormat) {
    auto *string = (NSMutableString *)bridge(c).toHost(c.args.ptr());
    c.args.ptr();
    NSString *format = (NSString *)bridge(c).toHost(c.args.ptr());
    std::string s = formatGuest(c, format.UTF8String, c.args, objc::describeObject);
    [string appendString:[NSString stringWithUTF8String:s.c_str()]];
}

// Boolean CFStringTransform(CFMutableStringRef, CFRange *range, CFStringRef transform, Boolean reverse):
// the guest's CFRange is two 32-bit words.
B32_THUNK(_CFStringTransform) {
    auto string = (CFMutableStringRef)bridge(c).toHost(c.args.ptr());
    GuestAddr rangeAddr = c.args.ptr();
    auto transform = (CFStringRef)bridge(c).toHost(c.args.ptr());
    Boolean reverse = c.args.u32() != 0;
    CFRange range;
    if (rangeAddr) range = CFRangeMake(c.mem.read<int32_t>(rangeAddr), c.mem.read<int32_t>(rangeAddr + 4));
    Boolean ok = CFStringTransform(string, rangeAddr ? &range : nullptr, transform, reverse);
    if (rangeAddr) {
        c.mem.write<int32_t>(rangeAddr, int32_t(range.location));
        c.mem.write<int32_t>(rangeAddr + 4, int32_t(range.length));
    }
    c.ret(ok);
}

// void CFArrayApplyFunction(CFArrayRef, CFRange, void (*applier)(const void *value, void *context), void *context)
B32_THUNK(_CFArrayApplyFunction) {
    auto array = (CFArrayRef)bridge(c).toHost(c.args.ptr());
    CFIndex location = c.args.i32(), length = c.args.i32();
    GuestAddr applier = c.args.ptr(), context = c.args.ptr();
    for (CFIndex i = location; i < location + length; i++)
        c.cpu.call(applier, {guestValue(c, rawFlags((id)array) & kRawValues, CFArrayGetValueAtIndex(array, i)), context});
}

// CFUUIDBytes is 16 bytes: four words in, through r0 out.
B32_THUNK(_CFUUIDCreateFromUUIDBytes) {
    c.args.ptr();
    CFUUIDBytes bytes;
    for (int i = 0; i < 4; i++) {
        uint32_t w = c.args.u32();
        std::memcpy(reinterpret_cast<uint8_t *>(&bytes) + i * 4, &w, 4);
    }
    c.ret(bridge(c).toGuest((id)CFUUIDCreateFromUUIDBytes(nullptr, bytes)));
}
B32_THUNK(_CFUUIDGetUUIDBytes) {
    StructResult out(c, 16);
    CFUUIDBytes bytes = CFUUIDGetUUIDBytes((CFUUIDRef)bridge(c).toHost(c.args.ptr()));
    c.mem.copyIn(out, &bytes, sizeof bytes);
}

// Darwin and local notifications aren't delivered to guest callbacks yet.
B32_THUNK(_CFNotificationCenterAddObserver) {}
B32_THUNK(_CFNotificationCenterRemoveObserver) {}
B32_THUNK(_CFNotificationCenterRemoveEveryObserver) {}

// CFIndex CFStringGetBytes(CFStringRef, CFRange, CFStringEncoding, UInt8 lossByte,
//     Boolean isExternalRepresentation, UInt8 *buffer, CFIndex maxBufLen, CFIndex *usedBufLen)
B32_THUNK(_CFStringGetBytes) {
    CFStringRef string = (CFStringRef)bridge(c).toHost(c.args.ptr());
    CFRange r = range(c);
    CFStringEncoding encoding = c.args.u32();
    UInt8 lossByte = UInt8(c.args.u32());
    Boolean external = c.args.u32() != 0;
    GuestAddr buffer = c.args.ptr();
    CFIndex maxLength = c.args.i32();
    GuestAddr used = c.args.ptr();
    CFIndex usedLength = 0;
    CFIndex converted = CFStringGetBytes(string, r, encoding, lossByte, external,
                                         buffer ? c.mem.ptr<UInt8>(buffer) : nullptr, maxLength, &usedLength);
    if (used) c.mem.write<int32_t>(used, int32_t(usedLength));
    c.ret(uint32_t(converted));
}

// CFIndex CFDictionaryGetCountOfKey(CFDictionaryRef, const void *key)
B32_THUNK(_CFDictionaryGetCountOfKey) {
    id dict = bridge(c).toHost(c.args.ptr());
    c.ret(uint32_t(CFDictionaryGetCountOfKey((CFDictionaryRef)dict, hostValue(c, rawFlags(dict) & kRawKeys, c.args.ptr()))));
}

// void CFDictionaryApplyFunction(CFDictionaryRef, CFDictionaryApplierFunction, void *context):
// calls the guest's function(key, value, context) for each entry.
B32_THUNK(_CFDictionaryApplyFunction) {
    id dict = bridge(c).toHost(c.args.ptr());
    GuestAddr fn = c.args.ptr(), context = c.args.ptr();
    int flags = rawFlags(dict);
    CFIndex count = CFDictionaryGetCount((CFDictionaryRef)dict);
    std::vector<const void *> keys(static_cast<size_t>(count)), values(static_cast<size_t>(count));
    CFDictionaryGetKeysAndValues((CFDictionaryRef)dict, keys.data(), values.data());
    for (CFIndex i = 0; i < count; i++)
        c.cpu.call(fn, {guestValue(c, flags & kRawKeys, keys[size_t(i)]), guestValue(c, flags & kRawValues, values[size_t(i)]),
                        context});
}

// --- allocators -----------------------------------------------------------------------------
//
// CF objects live on the host, which never allocates through guest code, so
// a guest allocator (AIDA64 wraps the default one to count memory) is never
// installed: creating one gives back the default allocator, and the context
// of any allocator is empty.

// void CFAllocatorGetContext(CFAllocatorRef, CFAllocatorContext *): the guest
// context is { version, info, retain, release, copyDescription, allocate,
// reallocate, deallocate, preferredSize }.
B32_THUNK(_CFAllocatorGetContext) {
    c.args.ptr();
    GuestAddr context = c.args.ptr();
    for (uint32_t i = 1; i < 9; i++) c.mem.write<uint32_t>(context + i * 4, 0);
}

// CFAllocatorRef CFAllocatorCreate(CFAllocatorRef, CFAllocatorContext *)
B32_THUNK(_CFAllocatorCreate) {
    CFAllocatorRef allocator = CFAllocatorGetDefault();
    CFRetain(allocator);
    c.ret(bridge(c).toGuest((id)allocator));
}

// void CFAllocatorSetDefault(CFAllocatorRef)
B32_THUNK(_CFAllocatorSetDefault) {}

// --- run loop observers ---------------------------------------------------------------------

namespace {
struct GuestObserver {
    GuestAddr callout;
    GuestAddr info;
    GuestAddr observer;  // the guest's reference to the observer
};

void observerFired(CFRunLoopObserverRef, CFRunLoopActivity activity, void *data) {
    auto *o = static_cast<GuestObserver *>(data);
    Runtime::threadCpu().call(o->callout, {o->observer, uint32_t(activity), o->info});
}
}  // namespace

// CFRunLoopObserverRef CFRunLoopObserverCreate(CFAllocatorRef, CFOptionFlags activities,
//     Boolean repeats, CFIndex order, CFRunLoopObserverCallBack, CFRunLoopObserverContext *)
// The guest context is { version, info, retain, release, copyDescription }; only info is kept.
B32_THUNK(_CFRunLoopObserverCreate) {
    c.args.ptr();
    CFOptionFlags activities = c.args.u32();
    Boolean repeats = c.args.u32() != 0;
    CFIndex order = c.args.i32();
    auto *o = new GuestObserver{c.args.ptr(), 0, 0};
    if (GuestAddr context = c.args.ptr()) o->info = c.mem.read<uint32_t>(context + 4);
    CFRunLoopObserverContext context = {0, o, nullptr, nullptr, nullptr};
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(nullptr, activities, repeats, order, observerFired, &context);
    o->observer = bridge(c).toGuest((id)observer);
    c.ret(o->observer);
}

namespace {
// The guest block (a heap copy, kept for the observer's life) in `callout`.
void observerBlockFired(CFRunLoopObserverRef, CFRunLoopActivity activity, void *data) {
    auto *o = static_cast<GuestObserver *>(data);
    Cpu &cpu = Runtime::threadCpu();
    cpu.call(cpu.mem().read<uint32_t>(o->callout + 12), {o->callout, o->observer, uint32_t(activity)});  // its invoke
}
}  // namespace

// CFRunLoopObserverRef CFRunLoopObserverCreateWithHandler(CFAllocatorRef, CFOptionFlags activities,
//     Boolean repeats, CFIndex order, void (^)(CFRunLoopObserverRef, CFRunLoopActivity))
B32_THUNK(_CFRunLoopObserverCreateWithHandler) {
    c.args.ptr();
    CFOptionFlags activities = c.args.u32();
    Boolean repeats = c.args.u32() != 0;
    CFIndex order = c.args.i32();
    auto *o = new GuestObserver{objc::blocks::copy(bridge(c), c.args.ptr()), 0, 0};
    CFRunLoopObserverContext context = {0, o, nullptr, nullptr, nullptr};
    CFRunLoopObserverRef observer = CFRunLoopObserverCreate(nullptr, activities, repeats, order, observerBlockFired, &context);
    o->observer = bridge(c).toGuest((id)observer);
    c.ret(o->observer);
}

// --- read stream clients ------------------------------------------------------------------

namespace {
struct GuestStreamClient {
    GuestAddr callback;
    GuestAddr info;
    GuestAddr stream;  // the guest's reference to the stream
};

void streamEvent(CFReadStreamRef, CFStreamEventType type, void *data) {
    auto *client = static_cast<GuestStreamClient *>(data);
    Runtime::threadCpu().call(client->callback, {client->stream, uint32_t(type), client->info});
}
}  // namespace

// Boolean CFReadStreamSetClient(CFReadStreamRef, CFOptionFlags events, CFReadStreamClientCallBack,
//     CFStreamClientContext *)
// The guest context is { version, info, retain, release, copyDescription }; only info is kept.
B32_THUNK(_CFReadStreamSetClient) {
    GuestAddr guestStream = c.args.ptr();
    CFReadStreamRef stream = (CFReadStreamRef)bridge(c).toHost(guestStream);
    CFOptionFlags events = c.args.u32();
    GuestAddr callback = c.args.ptr(), context = c.args.ptr();
    if (!callback) {
        c.ret(CFReadStreamSetClient(stream, kCFStreamEventNone, nullptr, nullptr));
        return;
    }
    auto *client = new GuestStreamClient{callback, context ? c.mem.read<uint32_t>(context + 4) : 0, guestStream};
    CFStreamClientContext hostContext = {0, client, nullptr, nullptr, nullptr};
    c.ret(CFReadStreamSetClient(stream, events, streamEvent, &hostContext));
}

// --- run loop sources ----------------------------------------------------------------------

namespace {
// A version 0 source's guest callbacks: schedule(info, runLoop, mode),
// cancel(info, runLoop, mode) and perform(info).
struct GuestSource {
    GuestAddr info, schedule, cancel, perform;
};

void sourceScheduled(void *data, CFRunLoopRef runLoop, CFRunLoopMode mode) {
    auto *s = static_cast<GuestSource *>(data);
    objc::Bridge &b = *objc::Bridge::shared();
    if (s->schedule) Runtime::threadCpu().call(s->schedule, {s->info, b.toGuest((id)runLoop), b.toGuest((id)mode)});
}
void sourceCancelled(void *data, CFRunLoopRef runLoop, CFRunLoopMode mode) {
    auto *s = static_cast<GuestSource *>(data);
    objc::Bridge &b = *objc::Bridge::shared();
    if (s->cancel) Runtime::threadCpu().call(s->cancel, {s->info, b.toGuest((id)runLoop), b.toGuest((id)mode)});
}
void sourcePerformed(void *data) {
    auto *s = static_cast<GuestSource *>(data);
    if (s->perform) Runtime::threadCpu().call(s->perform, {s->info});
}
}  // namespace

// CFRunLoopSourceRef CFRunLoopSourceCreate(CFAllocatorRef, CFIndex order, CFRunLoopSourceContext *)
// The guest context is { version, info, retain, release, copyDescription, equal,
// hash, schedule, cancel, perform }; only version 0 sources (signalled ones)
// are supported, and info is kept as given.
B32_THUNK(_CFRunLoopSourceCreate) {
    c.args.ptr();
    CFIndex order = c.args.i32();
    GuestAddr context = c.args.ptr();
    if (!context || c.mem.read<uint32_t>(context) != 0) fatal("only version 0 run loop sources are supported");
    auto *s = new GuestSource{c.mem.read<uint32_t>(context + 4), c.mem.read<uint32_t>(context + 28),
                              c.mem.read<uint32_t>(context + 32), c.mem.read<uint32_t>(context + 36)};
    CFRunLoopSourceContext host = {};
    host.info = s;
    host.schedule = sourceScheduled;
    host.cancel = sourceCancelled;
    host.perform = sourcePerformed;
    c.ret(bridge(c).toGuest((id)CFRunLoopSourceCreate(nullptr, order, &host)));
}

// CFTypeRef CFAutorelease(CFTypeRef): an autorelease of the host object.
B32_THUNK(_CFAutorelease) {
    GuestAddr object = c.args.ptr();
    if (object) CFAutorelease((CFTypeRef)bridge(c).toHost(object));
    c.ret(object);
}

// Boolean CFURLCreateDataAndPropertiesFromResource(CFAllocatorRef, CFURLRef, CFDataRef *data,
//     CFDictionaryRef *properties, CFArrayRef desiredProperties, SInt32 *errorCode)
// Long deprecated, but games still read files with it. Only the data is
// fetched; properties come back NULL.
B32_THUNK(_CFURLCreateDataAndPropertiesFromResource) {
    c.args.ptr();
    CFURLRef url = (CFURLRef)bridge(c).toHost(c.args.ptr());
    GuestAddr dataOut = c.args.ptr(), propertiesOut = c.args.ptr();
    c.args.ptr();
    GuestAddr errorOut = c.args.ptr();
    NSData *data = url ? [NSData dataWithContentsOfURL:(__bridge NSURL *)url] : nil;
    if (dataOut) c.mem.write<uint32_t>(dataOut, data ? bridge(c).toGuest((id)CFBridgingRetain(data)) : 0);
    if (propertiesOut) c.mem.write<uint32_t>(propertiesOut, 0);
    if (errorOut) c.mem.write<int32_t>(errorOut, data ? 0 : kCFURLResourceNotFoundError);
    c.ret(data ? 1 : 0);
}

// CFPropertyListRef CFPropertyListCreateFromXMLData(CFAllocatorRef, CFDataRef,
//     CFOptionFlags mutabilityOption, CFStringRef *errorString)
B32_THUNK(_CFPropertyListCreateFromXMLData) {
    c.args.ptr();
    CFDataRef data = (CFDataRef)bridge(c).toHost(c.args.ptr());
    CFOptionFlags options = c.args.u32();
    GuestAddr errorOut = c.args.ptr();
    CFErrorRef error = nullptr;
    CFPropertyListRef list = data ? CFPropertyListCreateWithData(nullptr, data, options, nullptr, &error) : nullptr;
    if (errorOut) {
        CFStringRef message = error ? CFErrorCopyDescription(error) : nullptr;
        c.mem.write<uint32_t>(errorOut, message ? bridge(c).toGuest((id)message) : 0);
    }
    if (error) CFRelease(error);
    c.ret(list ? bridge(c).toGuest((id)list) : 0);
}
