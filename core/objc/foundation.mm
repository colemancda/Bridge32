// Foundation's (and a few neighbors') C functions and the constants that
// aren't objects, which the guest reads as plain values: version numbers,
// CGRectNull, kCMTime*, UIBackgroundTaskInvalid, CF callback structs.

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Format.h"

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }
GuestAddr exceptionHandler = 0;

CGRect guestRect(Call &c) {
    float x = c.args.f32(), y = c.args.f32(), w = c.args.f32(), h = c.args.f32();
    return CGRectMake(x, y, w, h);
}
void writeRect(Call &c, GuestAddr out, CGRect r) {
    const float v[4] = {float(r.origin.x), float(r.origin.y), float(r.size.width), float(r.size.height)};
    c.mem.copyIn(out, v, sizeof v);
}
}  // namespace

// --- exceptions --------------------------------------------------------------------------------

// Guest exceptions don't unwind through the bridge yet, so the handler is only kept.
B32_THUNK(_NSSetUncaughtExceptionHandler) { exceptionHandler = c.args.ptr(); }
B32_THUNK(_NSGetUncaughtExceptionHandler) { c.ret(exceptionHandler); }

// --- strings and geometry ------------------------------------------------------------------------

B32_THUNK(_NSHomeDirectory) { c.ret(bridge(c).toGuest(NSHomeDirectory())); }
B32_THUNK(_NSTemporaryDirectory) { c.ret(bridge(c).toGuest(NSTemporaryDirectory())); }
B32_THUNK(_NSUserName) { c.ret(bridge(c).toGuest(@"mobile")); }  // the iOS user
B32_THUNK(_NSFullUserName) { c.ret(bridge(c).toGuest(@"Mobile User")); }
B32_THUNK(_NSOpenStepRootDirectory) { c.ret(bridge(c).toGuest(NSOpenStepRootDirectory())); }

B32_THUNK(_NSLogv) {
    NSString *format = bridge(c).toHost(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, [format UTF8String], va, describeObject);
    NSLog(@"%s", s.c_str());
}

B32_THUNK(_NSStringFromCGRect) { c.ret(bridge(c).toGuest(NSStringFromCGRect(guestRect(c)))); }
B32_THUNK(_NSStringFromCGSize) {
    float w = c.args.f32();
    c.ret(bridge(c).toGuest(NSStringFromCGSize(CGSizeMake(w, c.args.f32()))));
}
B32_THUNK(_NSStringFromCGPoint) {
    float x = c.args.f32();
    c.ret(bridge(c).toGuest(NSStringFromCGPoint(CGPointMake(x, c.args.f32()))));
}
// CGRect CGRectFromString(NSString *): 16 bytes, returned through r0.
B32_THUNK(_CGRectFromString) {
    GuestAddr out = c.args.ptr();
    writeRect(c, out, CGRectFromString(bridge(c).toHost(c.args.ptr())));
}
// CGSize CGSizeFromString(NSString *): 8 bytes, returned through r0.
B32_THUNK(_CGSizeFromString) {
    GuestAddr out = c.args.ptr();
    CGSize size = CGSizeFromString(bridge(c).toHost(c.args.ptr()));
    c.mem.write<float>(out, float(size.width));
    c.mem.write<float>(out + 4, float(size.height));
}

// NSRange NSIntersectionRange(NSRange, NSRange): each NSRange is two words; the
// 8-byte result goes through r0.
B32_THUNK(_NSIntersectionRange) {
    GuestAddr out = c.args.ptr();
    NSUInteger l1 = c.args.u32(), n1 = c.args.u32(), l2 = c.args.u32(), n2 = c.args.u32();
    NSRange r = NSIntersectionRange(NSMakeRange(l1, n1), NSMakeRange(l2, n2));
    c.mem.write<uint32_t>(out, uint32_t(r.location));
    c.mem.write<uint32_t>(out + 4, uint32_t(r.length));
}
B32_THUNK(_NSUnionRange) {
    GuestAddr out = c.args.ptr();
    NSUInteger l1 = c.args.u32(), n1 = c.args.u32(), l2 = c.args.u32(), n2 = c.args.u32();
    NSRange r = NSUnionRange(NSMakeRange(l1, n1), NSMakeRange(l2, n2));
    c.mem.write<uint32_t>(out, uint32_t(r.location));
    c.mem.write<uint32_t>(out + 4, uint32_t(r.length));
}

// NSDictionary *_NSDictionaryOfVariableBindings(NSString *commaSeparatedKeys, id first, ...):
// what NSDictionaryOfVariableBindings(a, b) expands to.
B32_THUNK(__NSDictionaryOfVariableBindings) {
    NSString *keys = bridge(c).toHost(c.args.ptr());
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in [keys componentsSeparatedByString:@","]) {
        NSString *name = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        id value = bridge(c).toHost(c.args.ptr());
        if (value) result[name] = value;
    }
    c.ret(bridge(c).toGuest(result));
}

// const char *NSGetSizeAndAlignment(const char *type, NSUInteger *size, NSUInteger *alignment),
// in guest terms.
B32_THUNK(_NSGetSizeAndAlignment) {
    GuestAddr type = c.args.ptr(), size = c.args.ptr(), alignment = c.args.ptr();
    const char *start = c.mem.cstr(type), *p = start;
    Type t = parseType(p);
    if (size) c.mem.write<uint32_t>(size, t.guestSize());
    if (alignment) c.mem.write<uint32_t>(alignment, t.guestAlign());
    c.ret(type + GuestAddr(p - start));
}

// Libraries "linked" at iOS 6.
B32_THUNK(_NSVersionOfRunTimeLibrary) { c.ret(uint32_t(-1)); }
B32_THUNK(_NSVersionOfLinkTimeLibrary) { c.ret(uint32_t(-1)); }

B32_THUNK(_CACurrentMediaTime) { c.retF64(CACurrentMediaTime()); }

B32_THUNK(_UIRectFill) { UIRectFill(guestRect(c)); }
B32_THUNK(_UIGraphicsPushContext) { UIGraphicsPushContext((CGContextRef)bridge(c).toHost(c.args.ptr())); }
B32_THUNK(_UIGraphicsPopContext) { UIGraphicsPopContext(); }

// --- value constants ------------------------------------------------------------------------------

// iOS 6.1's.
B32_DATA(_NSFoundationVersionNumber, 8) { rt.mem().write<double>(addr, 993.0); }
B32_DATA(_kCFCoreFoundationVersionNumber, 8) { rt.mem().write<double>(addr, 793.0); }
B32_DATA(_kCFAbsoluteTimeIntervalSince1970, 8) { rt.mem().write<double>(addr, kCFAbsoluteTimeIntervalSince1970); }

B32_DATA(_UIBackgroundTaskInvalid, 4) {}
B32_DATA(_CGRectNull, 16) {
    const float null[4] = {INFINITY, INFINITY, 0, 0};
    rt.mem().copyIn(addr, null, sizeof null);
}
B32_DATA(_CGRectInfinite, 16) {
    const float infinite[4] = {-FLT_MAX / 2, -FLT_MAX / 2, FLT_MAX, FLT_MAX};
    rt.mem().copyIn(addr, infinite, sizeof infinite);
}

// CMTime { int64 value; int32 timescale; uint32 flags; int64 epoch } is laid out
// the same in both ABIs.
#define B32_CMTIME(name) \
    B32_DATA(_##name, 24) { rt.mem().copyIn(addr, &name, sizeof(CMTime)); }
B32_CMTIME(kCMTimeZero)
B32_CMTIME(kCMTimeInvalid)
B32_CMTIME(kCMTimeIndefinite)
B32_CMTIME(kCMTimePositiveInfinity)
B32_CMTIME(kCMTimeNegativeInfinity)

// Callback structs the guest passes by address to CF creation functions,
// whose thunks use the host's own.
B32_DATA(_kCFTypeDictionaryKeyCallBacks, 24) {}
B32_DATA(_kCFTypeDictionaryValueCallBacks, 20) {}
B32_DATA(_kCFCopyStringDictionaryKeyCallBacks, 24) {}
