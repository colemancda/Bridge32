// CoreFoundation for the guest. CF objects are toll-free ObjC objects on the
// host, so they cross the bridge like any other object; CFIndex is 32-bit in
// the guest ('z'), and CFRange and the number types need hand conversion.

#include "CTable.h"
#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>

using namespace b32;

namespace {

void *coreFoundation() { return RTLD_DEFAULT; }

constexpr CFunction kCoreFoundation[] = {
    {"CFAbsoluteTimeGetCurrent", "d:"},
    {"CFArrayGetCount", "z:o"}, {"CFArrayGetValueAtIndex", "o:oz"},
    {"CFDataGetLength", "z:o"}, {"CFDataCreate", "o:opz"},
    {"CFDictionaryGetValue", "o:oo"}, {"CFDictionaryGetCount", "z:o"},
    {"CFDictionarySetValue", "v:ooo"}, {"CFDictionaryRemoveValue", "v:oo"},
    {"CFPreferencesAppSynchronize", "B:o"}, {"CFPreferencesCopyAppValue", "o:oo"},
    {"CFPreferencesSetAppValue", "v:ooo"},
    {"CFRunLoopGetCurrent", "o:"}, {"CFRunLoopGetMain", "o:"},
    {"CFStringAppendCharacters", "v:opz"}, {"CFStringAppendCString", "v:opu"},
    {"CFStringCreateWithCString", "o:opu"}, {"CFStringGetCString", "B:opzu"},
    {"CFStringGetLength", "z:o"}, {"CFStringCreateMutable", "o:oz"}, {"CFStringCreateCopy", "o:oo"},
    {"CFStringCompare", "z:ooz"}, {"CFStringGetIntValue", "i:o"}, {"CFStringGetDoubleValue", "d:o"},
    {"CFUUIDCreate", "o:o"}, {"CFUUIDCreateString", "o:oo"},
    {"CFGetTypeID", "z:o"}, {"CFStringGetTypeID", "z:"}, {"CFNumberGetTypeID", "z:"},
    {"CFArrayGetTypeID", "z:"}, {"CFDictionaryGetTypeID", "z:"}, {"CFDataGetTypeID", "z:"},
    {"CFBooleanGetValue", "B:o"}, {"CFEqual", "B:oo"}, {"CFHash", "z:o"},
    {"CFURLCreateWithFileSystemPath", "o:ooiu"}, {"CFBundleGetMainBundle", "o:"},
    {"CFBundleCopyResourceURL", "o:oooo"}, {"CFBundleGetValueForInfoDictionaryKey", "o:oo"},
    {"CFLocaleCopyCurrent", "o:"}, {"CFLocaleGetIdentifier", "o:o"},
};

B32_C_FUNCTIONS(kCoreFoundation, coreFoundation);

objc::Bridge &bridge(Call &c) { return c.rt.bridge(); }

// CFRange is { CFIndex location, length }: two words in the guest.
CFRange range(Call &c) {
    CFIndex location = c.args.i32();
    return CFRangeMake(location, c.args.i32());
}

}  // namespace

// CFArrayRef CFArrayCreate(CFAllocatorRef, const void **values, CFIndex count, const CFArrayCallBacks *)
// The values are guest objects (the callbacks are kCFTypeArrayCallBacks in practice).
B32_THUNK(_CFArrayCreate) {
    c.args.ptr();
    GuestAddr values = c.args.ptr();
    int32_t count = c.args.i32();
    std::vector<id> objects(size_t(std::max(count, 0)));
    for (int32_t i = 0; i < count; i++) objects[i] = bridge(c).toHost(c.mem.read<uint32_t>(values + i * 4));
    CFArrayRef array = CFArrayCreate(nullptr, (const void **)objects.data(), count, &kCFTypeArrayCallBacks);
    c.ret(bridge(c).toGuest((id)array));
}

// void CFArrayGetValues(CFArrayRef, CFRange, const void **values)
B32_THUNK(_CFArrayGetValues) {
    CFArrayRef array = (CFArrayRef)bridge(c).toHost(c.args.ptr());
    CFRange r = range(c);
    GuestAddr out = c.args.ptr();
    std::vector<const void *> values(size_t(r.length));
    CFArrayGetValues(array, r, values.data());
    for (CFIndex i = 0; i < r.length; i++) c.mem.write<uint32_t>(out + uint32_t(i) * 4, bridge(c).toGuest((id)values[i]));
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
