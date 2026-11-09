// Foundation's (and a few neighbors') C functions and the constants that
// aren't objects, which the guest reads as plain values: version numbers,
// CGRectNull, kCMTime*, UIBackgroundTaskInvalid, CF callback structs.

#include "Bridge.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Format.h"

#import <CoreData/CoreData.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>
#include <simd/simd.h>
#import <QuartzCore/QuartzCore.h>
#include <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import <UIKit/UIKit.h>
#endif

#include <cstring>

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
#if TARGET_OS_MACCATALYST
B32_THUNK(_NSUserName) { c.ret(bridge(c).toGuest(@"mobile")); }  // the iOS user
B32_THUNK(_NSFullUserName) { c.ret(bridge(c).toGuest(@"Mobile User")); }
#else
B32_THUNK(_NSUserName) { c.ret(bridge(c).toGuest(NSUserName())); }
B32_THUNK(_NSFullUserName) { c.ret(bridge(c).toGuest(NSFullUserName())); }
#endif
B32_THUNK(_NSOpenStepRootDirectory) { c.ret(bridge(c).toGuest(NSOpenStepRootDirectory())); }

B32_THUNK(_NSLogv) {
    NSString *format = bridge(c).toHost(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    std::string s = formatGuest(c, [format UTF8String], va, describeObject);
    NSLog(@"%s", s.c_str());
}

#if TARGET_OS_MACCATALYST  // UIKit's string functions
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
    StructResult out(c, 16);
    writeRect(c, out, CGRectFromString(bridge(c).toHost(c.args.ptr())));
}
// CGSize CGSizeFromString(NSString *): 8 bytes, returned through r0.
B32_THUNK(_CGSizeFromString) {
    StructResult out(c, 8);
    CGSize size = CGSizeFromString(bridge(c).toHost(c.args.ptr()));
    c.mem.write<float>(out, float(size.width));
    c.mem.write<float>(out + 4, float(size.height));
}
// CGPoint CGPointFromString(NSString *): 8 bytes, returned through r0.
B32_THUNK(_CGPointFromString) {
    StructResult out(c, 8);
    CGPoint point = CGPointFromString(bridge(c).toHost(c.args.ptr()));
    c.mem.write<float>(out, float(point.x));
    c.mem.write<float>(out + 4, float(point.y));
}

#endif

// NSRange NSIntersectionRange(NSRange, NSRange): each NSRange is two words; the
// 8-byte result goes through r0.
B32_THUNK(_NSIntersectionRange) {
    StructResult out(c, 8);
    NSUInteger l1 = c.args.u32(), n1 = c.args.u32(), l2 = c.args.u32(), n2 = c.args.u32();
    NSRange r = NSIntersectionRange(NSMakeRange(l1, n1), NSMakeRange(l2, n2));
    c.mem.write<uint32_t>(out, uint32_t(r.location));
    c.mem.write<uint32_t>(out + 4, uint32_t(r.length));
}
B32_THUNK(_NSUnionRange) {
    StructResult out(c, 8);
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

#if TARGET_OS_MACCATALYST
B32_THUNK(_UIRectFill) { UIRectFill(guestRect(c)); }
B32_THUNK(_UIRectFillUsingBlendMode) {
    CGRect r = guestRect(c);
    UIRectFillUsingBlendMode(r, CGBlendMode(c.args.i32()));
}
B32_THUNK(_UIRectFrame) { UIRectFrame(guestRect(c)); }
B32_THUNK(_UIGraphicsPushContext) { UIGraphicsPushContext((CGContextRef)bridge(c).toHost(c.args.ptr())); }
B32_THUNK(_UIGraphicsPopContext) { UIGraphicsPopContext(); }
#endif

// --- value constants ------------------------------------------------------------------------------

// iOS 6.1's.
#if TARGET_OS_MACCATALYST
B32_DATA(_NSFoundationVersionNumber, 8) { rt.mem().write<double>(addr, 993.0); }
B32_DATA(_kCFCoreFoundationVersionNumber, 8) { rt.mem().write<double>(addr, 793.0); }
#else
// Mac OS X 10.14's, the newest a 32-bit app ever saw.
B32_DATA(_NSFoundationVersionNumber, 8) { rt.mem().write<double>(addr, 1575.0); }
B32_DATA(_kCFCoreFoundationVersionNumber, 8) { rt.mem().write<double>(addr, 1575.0); }
#endif
B32_DATA(_kCFAbsoluteTimeIntervalSince1970, 8) { rt.mem().write<double>(addr, kCFAbsoluteTimeIntervalSince1970); }

#if TARGET_OS_MACCATALYST
B32_DATA(_UIBackgroundTaskInvalid, 4) {}
#endif
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

#if TARGET_OS_MACCATALYST
// CGFloat constants: floats in the guest.
B32_DATA(_UIScrollViewDecelerationRateFast, 4) { rt.mem().write<float>(addr, float(UIScrollViewDecelerationRateFast)); }
B32_DATA(_UIScrollViewDecelerationRateNormal, 4) { rt.mem().write<float>(addr, float(UIScrollViewDecelerationRateNormal)); }
B32_DATA(_UIWindowLevelStatusBar, 4) { rt.mem().write<float>(addr, float(UIWindowLevelStatusBar)); }
B32_DATA(_UIWindowLevelAlert, 4) { rt.mem().write<float>(addr, float(UIWindowLevelAlert)); }
B32_DATA(_UIWindowLevelNormal, 4) { rt.mem().write<float>(addr, float(UIWindowLevelNormal)); }

#endif

// CATransform3D CATransform3DMakeTranslation(CGFloat tx, CGFloat ty, CGFloat tz):
// sixteen CGFloats, returned through r0.
B32_THUNK(_CATransform3DMakeTranslation) {
    StructResult out(c, 64);
    float tx = c.args.f32(), ty = c.args.f32(), tz = c.args.f32();
    CATransform3D t = CATransform3DMakeTranslation(tx, ty, tz);
    const CGFloat *v = &t.m11;
    for (int i = 0; i < 16; i++) c.mem.write<float>(out + uint32_t(i) * 4, float(v[i]));
}

// CoreData's merge policies: objects the host constant lookup doesn't take for ones.
B32_DATA(_NSErrorMergePolicy, 4) { rt.mem().write<uint32_t>(addr, rt.bridge().toGuest(NSErrorMergePolicy)); }
B32_DATA(_NSOverwriteMergePolicy, 4) { rt.mem().write<uint32_t>(addr, rt.bridge().toGuest(NSOverwriteMergePolicy)); }
B32_DATA(_NSRollbackMergePolicy, 4) { rt.mem().write<uint32_t>(addr, rt.bridge().toGuest(NSRollbackMergePolicy)); }
B32_DATA(_NSMergeByPropertyObjectTrumpMergePolicy, 4) {
    rt.mem().write<uint32_t>(addr, rt.bridge().toGuest(NSMergeByPropertyObjectTrumpMergePolicy));
}
B32_DATA(_NSMergeByPropertyStoreTrumpMergePolicy, 4) {
    rt.mem().write<uint32_t>(addr, rt.bridge().toGuest(NSMergeByPropertyStoreTrumpMergePolicy));
}

// GLKMatrix4Identity: sixteen floats in both ABIs.
B32_DATA(_GLKMatrix4Identity, 64) {
    for (uint32_t i = 0; i < 4; i++) rt.mem().write<float>(addr + i * 20, 1.0f);
}
B32_DATA(_GLKMatrix3Identity, 36) {
    for (uint32_t i = 0; i < 3; i++) rt.mem().write<float>(addr + i * 16, 1.0f);
}

// GLKMatrix4 GLKMatrix4Invert(GLKMatrix4, bool *isInvertible) and the 3x3 one:
// column-major floats by value in argument words, the result through r0. A
// matrix that can't be inverted gives the identity, as GLKit's does.
B32_THUNK(_GLKMatrix4Invert) {
    StructResult out(c, 64);
    simd_float4x4 m;
    float *f = reinterpret_cast<float *>(&m);
    for (int i = 0; i < 16; i++) f[i] = c.args.f32();
    GuestAddr invertibleOut = c.args.ptr();
    bool invertible = simd_determinant(m) != 0;
    simd_float4x4 result = invertible ? simd_inverse(m) : matrix_identity_float4x4;
    if (invertibleOut) c.mem.write<uint8_t>(invertibleOut, invertible);
    c.mem.copyIn(out, &result, 64);
}
B32_THUNK(_GLKMatrix3Invert) {
    StructResult out(c, 36);
    float in[9];
    for (float &v : in) v = c.args.f32();
    GuestAddr invertibleOut = c.args.ptr();
    simd_float3x3 m = simd_matrix(simd_make_float3(in[0], in[1], in[2]), simd_make_float3(in[3], in[4], in[5]),
                                  simd_make_float3(in[6], in[7], in[8]));
    bool invertible = simd_determinant(m) != 0;
    simd_float3x3 result = invertible ? simd_inverse(m) : matrix_identity_float3x3;
    if (invertibleOut) c.mem.write<uint8_t>(invertibleOut, invertible);
    for (int col = 0; col < 3; col++)
        for (int row = 0; row < 3; row++) c.mem.write<float>(out + uint32_t(col * 3 + row) * 4, result.columns[col][row]);
}

// CATransform3D CATransform3DMakeScale(CGFloat sx, CGFloat sy, CGFloat sz): through r0.
B32_THUNK(_CATransform3DMakeScale) {
    StructResult out(c, 64);
    float sx = c.args.f32(), sy = c.args.f32(), sz = c.args.f32();
    CATransform3D t = CATransform3DMakeScale(sx, sy, sz);
    const CGFloat *v = &t.m11;
    for (int i = 0; i < 16; i++) c.mem.write<float>(out + uint32_t(i) * 4, float(v[i]));
}

// CATransform3D by value: sixteen floats in the guest, in argument words (the
// first in whatever registers are left, the rest on the stack) and returned
// through r0.
namespace {
CATransform3D transformArg(Call &c) {
    CATransform3D t;
    CGFloat *v = &t.m11;
    for (int i = 0; i < 16; i++) v[i] = c.args.f32();
    return t;
}
void returnTransform(Call &c, GuestAddr out, const CATransform3D &t) {
    const CGFloat *v = &t.m11;
    for (int i = 0; i < 16; i++) c.mem.write<float>(out + uint32_t(i) * 4, float(v[i]));
}
}  // namespace

B32_DATA(_CATransform3DIdentity, 64) {
    for (uint32_t i = 0; i < 4; i++) rt.mem().write<float>(addr + i * 20, 1.0f);
}
// CATransform3D CATransform3DMakeRotation(CGFloat angle, CGFloat x, CGFloat y, CGFloat z)
B32_THUNK(_CATransform3DMakeRotation) {
    StructResult out(c, 64);
    float angle = c.args.f32(), x = c.args.f32(), y = c.args.f32();
    returnTransform(c, out, CATransform3DMakeRotation(angle, x, y, c.args.f32()));
}
// CATransform3D CATransform3DMakeAffineTransform(CGAffineTransform): six floats by value.
B32_THUNK(_CATransform3DMakeAffineTransform) {
    StructResult out(c, 64);
    CGAffineTransform m;
    m.a = c.args.f32(), m.b = c.args.f32(), m.c = c.args.f32(), m.d = c.args.f32();
    m.tx = c.args.f32(), m.ty = c.args.f32();
    returnTransform(c, out, CATransform3DMakeAffineTransform(m));
}
// CATransform3D CATransform3DScale/Translate(CATransform3D, CGFloat, CGFloat, CGFloat)
B32_THUNK(_CATransform3DScale) {
    StructResult out(c, 64);
    CATransform3D t = transformArg(c);
    float sx = c.args.f32(), sy = c.args.f32();
    returnTransform(c, out, CATransform3DScale(t, sx, sy, c.args.f32()));
}
B32_THUNK(_CATransform3DTranslate) {
    StructResult out(c, 64);
    CATransform3D t = transformArg(c);
    float tx = c.args.f32(), ty = c.args.f32();
    returnTransform(c, out, CATransform3DTranslate(t, tx, ty, c.args.f32()));
}
// CATransform3D CATransform3DRotate(CATransform3D, CGFloat angle, CGFloat x, CGFloat y, CGFloat z)
B32_THUNK(_CATransform3DRotate) {
    StructResult out(c, 64);
    CATransform3D t = transformArg(c);
    float angle = c.args.f32(), x = c.args.f32(), y = c.args.f32();
    returnTransform(c, out, CATransform3DRotate(t, angle, x, y, c.args.f32()));
}
B32_THUNK(_CATransform3DConcat) {
    StructResult out(c, 64);
    CATransform3D a = transformArg(c);
    returnTransform(c, out, CATransform3DConcat(a, transformArg(c)));
}
B32_THUNK(_CATransform3DInvert) {
    StructResult out(c, 64);
    returnTransform(c, out, CATransform3DInvert(transformArg(c)));
}
B32_THUNK(_CATransform3DIsIdentity) { c.ret(CATransform3DIsIdentity(transformArg(c))); }
B32_THUNK(_CATransform3DEqualToTransform) {
    CATransform3D a = transformArg(c);
    c.ret(CATransform3DEqualToTransform(a, transformArg(c)));
}

// CLLocationCoordinate2D { double latitude, longitude }: the same 16 bytes on
// both sides, by value in four words and returned through r0.
B32_THUNK(_CLLocationCoordinate2DMake) {
    StructResult out(c, 16);
    double latitude = c.args.f64();
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(latitude, c.args.f64());
    c.mem.copyIn(out, &coordinate, sizeof coordinate);
}
B32_THUNK(_CLLocationCoordinate2DIsValid) {
    double latitude = c.args.f64();
    c.ret(CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude, c.args.f64())));
}
// NSString *NSStringFromRange(NSRange): two words.
B32_THUNK(_NSStringFromRange) {
    NSUInteger location = c.args.u32();
    c.ret(bridge(c).toGuest(NSStringFromRange(NSMakeRange(location, c.args.u32()))));
}

// --- CMTime: { int64 value; int32 timescale; uint32 flags; int64 epoch }, 24 bytes, same
// layout in both ABIs; passed in six words and returned through r0 ---------------------------------

namespace {
CMTime cmtime(Call &c) {
    CMTime t;
    uint32_t words[6];
    for (auto &w : words) w = c.args.u32();
    std::memcpy(&t, words, sizeof t);
    return t;
}
void returnTime(Call &c, GuestAddr out, CMTime t) { c.mem.copyIn(out, &t, sizeof t); }
}  // namespace

B32_THUNK(_CMTimeMake) {
    StructResult out(c, 24);
    int64_t value = int64_t(c.args.u64());
    returnTime(c, out, CMTimeMake(value, c.args.i32()));
}
B32_THUNK(_CMTimeMakeWithSeconds) {
    StructResult out(c, 24);
    double seconds = c.args.f64();
    returnTime(c, out, CMTimeMakeWithSeconds(seconds, c.args.i32()));
}
B32_THUNK(_CMTimeGetSeconds) { c.retF64(CMTimeGetSeconds(cmtime(c))); }
B32_THUNK(_CMTimeAdd) {
    StructResult out(c, 24);
    CMTime a = cmtime(c);
    returnTime(c, out, CMTimeAdd(a, cmtime(c)));
}
B32_THUNK(_CMTimeSubtract) {
    StructResult out(c, 24);
    CMTime a = cmtime(c);
    returnTime(c, out, CMTimeSubtract(a, cmtime(c)));
}
B32_THUNK(_CMTimeMaximum) {
    StructResult out(c, 24);
    CMTime a = cmtime(c);
    returnTime(c, out, CMTimeMaximum(a, cmtime(c)));
}
B32_THUNK(_CMTimeMultiply) {
    StructResult out(c, 24);
    CMTime a = cmtime(c);
    returnTime(c, out, CMTimeMultiply(a, c.args.i32()));
}
B32_THUNK(_CMTimeCompare) {
    CMTime a = cmtime(c);
    c.ret(uint32_t(CMTimeCompare(a, cmtime(c))));
}
