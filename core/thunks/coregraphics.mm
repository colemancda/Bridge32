// CoreGraphics and CoreFoundation basics. CF objects cross the bridge like
// ObjC objects (they are toll-free ObjC objects on the host); CGFloat is a
// float in the guest.
//
// Hand-written for now; most of these will come from the signature database.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <vector>

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

// --- more CGContext -------------------------------------------------------------------

#define B32_CONTEXT_OP(fn) \
    B32_THUNK(_##fn) { fn(ref<CGContextRef>(c)); }
B32_CONTEXT_OP(CGContextBeginPath)
B32_CONTEXT_OP(CGContextClosePath)
B32_CONTEXT_OP(CGContextFillPath)
B32_CONTEXT_OP(CGContextSaveGState)
B32_CONTEXT_OP(CGContextRestoreGState)

B32_THUNK(_CGContextScaleCTM) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x = cgf(c);
    CGContextScaleCTM(ctx, x, cgf(c));
}
B32_THUNK(_CGContextTranslateCTM) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x = cgf(c);
    CGContextTranslateCTM(ctx, x, cgf(c));
}
B32_THUNK(_CGContextAddRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextAddRect(ctx, rect(c));
}
B32_THUNK(_CGContextAddArcToPoint) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x1 = cgf(c), y1 = cgf(c), x2 = cgf(c), y2 = cgf(c);
    CGContextAddArcToPoint(ctx, x1, y1, x2, y2, cgf(c));
}
B32_THUNK(_CGContextDrawImage) {
    auto ctx = ref<CGContextRef>(c);
    CGRect r = rect(c);
    CGContextDrawImage(ctx, r, ref<CGImageRef>(c));
}
B32_THUNK(_CGContextSetStrokeColorSpace) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetStrokeColorSpace(ctx, ref<CGColorSpaceRef>(c));
}
B32_THUNK(_CGContextSetFillColorSpace) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetFillColorSpace(ctx, ref<CGColorSpaceRef>(c));
}

namespace {
// Color components for the context's current color space (plus alpha), as
// guest floats.
std::vector<CGFloat> components(Call &c, GuestAddr p, size_t count) {
    std::vector<CGFloat> values(count);
    for (size_t i = 0; i < count; i++) values[i] = c.mem.read<float>(p + uint32_t(i) * 4);
    return values;
}
}  // namespace

// void CGContextSetFillColor(CGContextRef, const CGFloat *components): RGB(A)
// in practice; four components covers it.
B32_THUNK(_CGContextSetFillColor) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetFillColor(ctx, components(c, c.args.ptr(), 4).data());
}
B32_THUNK(_CGContextSetStrokeColor) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetStrokeColor(ctx, components(c, c.args.ptr(), 4).data());
}

// void CGContextStrokeLineSegments(CGContextRef, const CGPoint *points, size_t count)
B32_THUNK(_CGContextStrokeLineSegments) {
    auto ctx = ref<CGContextRef>(c);
    GuestAddr points = c.args.ptr();
    uint32_t count = c.args.u32();
    std::vector<CGPoint> host(count);
    for (uint32_t i = 0; i < count; i++)
        host[i] = CGPointMake(c.mem.read<float>(points + i * 8), c.mem.read<float>(points + i * 8 + 4));
    CGContextStrokeLineSegments(ctx, host.data(), count);
}

B32_THUNK(_CGColorSpaceCreateDeviceRGB) { c.ret(c.rt.bridge().toGuest((id)CGColorSpaceCreateDeviceRGB())); }
B32_THUNK(_CGColorSpaceRelease) { CGColorSpaceRelease(ref<CGColorSpaceRef>(c)); }
B32_THUNK(_CGImageGetWidth) { c.ret(uint32_t(CGImageGetWidth(ref<CGImageRef>(c)))); }
B32_THUNK(_CGImageGetHeight) { c.ret(uint32_t(CGImageGetHeight(ref<CGImageRef>(c)))); }

// --- CGAffineTransform: six CGFloats, 24 bytes, returned through r0 ------------------------

namespace {
CGAffineTransform transform(Call &c) {
    CGFloat v[6];
    for (auto &x : v) x = cgf(c);
    return CGAffineTransformMake(v[0], v[1], v[2], v[3], v[4], v[5]);
}
void writeTransform(Call &c, GuestAddr out, CGAffineTransform t) {
    const CGFloat v[6] = {t.a, t.b, t.c, t.d, t.tx, t.ty};
    for (int i = 0; i < 6; i++) c.mem.write<float>(out + uint32_t(i) * 4, float(v[i]));
}
}  // namespace

B32_DATA(_CGAffineTransformIdentity, 24) {
    const float identity[6] = {1, 0, 0, 1, 0, 0};
    rt.mem().copyIn(addr, identity, sizeof identity);
}

B32_THUNK(_CGAffineTransformMakeRotation) {
    GuestAddr out = c.args.ptr();
    writeTransform(c, out, CGAffineTransformMakeRotation(cgf(c)));
}
B32_THUNK(_CGAffineTransformMakeScale) {
    GuestAddr out = c.args.ptr();
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformMakeScale(x, cgf(c)));
}
B32_THUNK(_CGAffineTransformMakeTranslation) {
    GuestAddr out = c.args.ptr();
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformMakeTranslation(x, cgf(c)));
}
B32_THUNK(_CGAffineTransformRotate) {
    GuestAddr out = c.args.ptr();
    CGAffineTransform t = transform(c);
    writeTransform(c, out, CGAffineTransformRotate(t, cgf(c)));
}
B32_THUNK(_CGAffineTransformScale) {
    GuestAddr out = c.args.ptr();
    CGAffineTransform t = transform(c);
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformScale(t, x, cgf(c)));
}
B32_THUNK(_CGAffineTransformTranslate) {
    GuestAddr out = c.args.ptr();
    CGAffineTransform t = transform(c);
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformTranslate(t, x, cgf(c)));
}
B32_THUNK(_CGAffineTransformConcat) {
    GuestAddr out = c.args.ptr();
    CGAffineTransform a = transform(c);
    writeTransform(c, out, CGAffineTransformConcat(a, transform(c)));
}
B32_THUNK(_CGAffineTransformInvert) {
    GuestAddr out = c.args.ptr();
    writeTransform(c, out, CGAffineTransformInvert(transform(c)));
}
