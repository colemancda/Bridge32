// CoreGraphics and CoreFoundation basics. CF objects cross the bridge like
// ObjC objects (they are toll-free ObjC objects on the host); CGFloat is a
// float in the guest.
//
// Hand-written for now; most of these will come from the signature database.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

using namespace b32;

namespace {
template <typename T> T ref(Call &c) { return (T)c.rt.bridge().toHost(c.args.ptr()); }
CGFloat cgf(Call &c) { return CGFloat(c.args.f32()); }
CGRect rect(Call &c) {
    CGFloat x = cgf(c), y = cgf(c), w = cgf(c), h = cgf(c);
    return CGRectMake(x, y, w, h);
}
CGPoint point(Call &c) {
    CGFloat x = cgf(c);
    return CGPointMake(x, cgf(c));
}
}  // namespace

// --- CoreFoundation memory management -------------------------------------------------

B32_THUNK(_CFRetain) {
    GuestAddr obj = c.args.ptr();
    CFRetain((CFTypeRef)c.rt.bridge().toHost(obj));
    c.ret(obj);
}
B32_THUNK(_CFRelease) { CFRelease((CFTypeRef)c.rt.bridge().toHost(c.args.ptr())); }

// --- CGContext ----------------------------------------------------------------------

B32_THUNK(_CGContextSetRGBFillColor) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat r = cgf(c), g = cgf(c), b = cgf(c);
    CGContextSetRGBFillColor(ctx, r, g, b, cgf(c));
}
B32_THUNK(_CGContextSetRGBStrokeColor) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat r = cgf(c), g = cgf(c), b = cgf(c);
    CGContextSetRGBStrokeColor(ctx, r, g, b, cgf(c));
}
B32_THUNK(_CGContextFillRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextFillRect(ctx, rect(c));
}
B32_THUNK(_CGContextFillEllipseInRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextFillEllipseInRect(ctx, rect(c));
}
B32_THUNK(_CGContextStrokeRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextStrokeRect(ctx, rect(c));
}
B32_THUNK(_CGContextSetLineWidth) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetLineWidth(ctx, cgf(c));
}
B32_THUNK(_CGContextMoveToPoint) {
    auto ctx = ref<CGContextRef>(c);
    CGPoint p = point(c);
    CGContextMoveToPoint(ctx, p.x, p.y);
}
B32_THUNK(_CGContextAddLineToPoint) {
    auto ctx = ref<CGContextRef>(c);
    CGPoint p = point(c);
    CGContextAddLineToPoint(ctx, p.x, p.y);
}
B32_THUNK(_CGContextStrokePath) { CGContextStrokePath(ref<CGContextRef>(c)); }

// --- CGGeometry -----------------------------------------------------------------------
// Functions returning a CGRect take the result pointer in r0 (it's larger
// than 4 bytes in the guest ABI).

namespace {
void retRect(Call &c, GuestAddr out, CGRect r) {
    c.mem.write<float>(out, float(r.origin.x));
    c.mem.write<float>(out + 4, float(r.origin.y));
    c.mem.write<float>(out + 8, float(r.size.width));
    c.mem.write<float>(out + 12, float(r.size.height));
}
}  // namespace

B32_THUNK(_CGRectInset) {
    GuestAddr out = c.args.ptr();
    CGRect r = rect(c);
    CGFloat dx = cgf(c);
    retRect(c, out, CGRectInset(r, dx, cgf(c)));
}
B32_THUNK(_CGRectOffset) {
    GuestAddr out = c.args.ptr();
    CGRect r = rect(c);
    CGFloat dx = cgf(c);
    retRect(c, out, CGRectOffset(r, dx, cgf(c)));
}
B32_THUNK(_CGRectIntersection) {
    GuestAddr out = c.args.ptr();
    CGRect a = rect(c);
    retRect(c, out, CGRectIntersection(a, rect(c)));
}
B32_THUNK(_CGRectUnion) {
    GuestAddr out = c.args.ptr();
    CGRect a = rect(c);
    retRect(c, out, CGRectUnion(a, rect(c)));
}
B32_THUNK(_CGRectStandardize) {
    GuestAddr out = c.args.ptr();
    retRect(c, out, CGRectStandardize(rect(c)));
}
B32_THUNK(_CGRectIntegral) {
    GuestAddr out = c.args.ptr();
    retRect(c, out, CGRectIntegral(rect(c)));
}
B32_THUNK(_CGRectContainsPoint) {
    CGRect r = rect(c);
    c.ret(CGRectContainsPoint(r, point(c)));
}
B32_THUNK(_CGRectContainsRect) {
    CGRect a = rect(c);
    c.ret(CGRectContainsRect(a, rect(c)));
}
B32_THUNK(_CGRectIntersectsRect) {
    CGRect a = rect(c);
    c.ret(CGRectIntersectsRect(a, rect(c)));
}
B32_THUNK(_CGRectEqualToRect) {
    CGRect a = rect(c);
    c.ret(CGRectEqualToRect(a, rect(c)));
}
B32_THUNK(_CGRectIsEmpty) { c.ret(CGRectIsEmpty(rect(c))); }
B32_THUNK(_CGRectIsNull) { c.ret(CGRectIsNull(rect(c))); }
B32_THUNK(_CGPointEqualToPoint) {
    CGPoint a = point(c);
    c.ret(CGPointEqualToPoint(a, point(c)));
}

#define B32_RECT_GETTER(fn)                                  \
    B32_THUNK(_##fn) { c.retF32(float(fn(rect(c)))); }
B32_RECT_GETTER(CGRectGetMinX)
B32_RECT_GETTER(CGRectGetMidX)
B32_RECT_GETTER(CGRectGetMaxX)
B32_RECT_GETTER(CGRectGetMinY)
B32_RECT_GETTER(CGRectGetMidY)
B32_RECT_GETTER(CGRectGetMaxY)
B32_RECT_GETTER(CGRectGetWidth)
B32_RECT_GETTER(CGRectGetHeight)

B32_DATA(_CGRectZero, 16) {}
B32_DATA(_CGPointZero, 8) {}
B32_DATA(_CGSizeZero, 8) {}
