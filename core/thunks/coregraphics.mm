// CoreGraphics and CoreFoundation basics. CF objects cross the bridge like
// ObjC objects (they are toll-free ObjC objects on the host); CGFloat is a
// float in the guest.
//
// Hand-written for now; most of these will come from the signature database.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <dlfcn.h>

#include <cstring>
#include <mutex>
#include <unordered_map>
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

// --- table-driven CoreGraphics (no CGFloat or struct arguments) ---------------------------------

namespace {
void *process() { return RTLD_DEFAULT; }

constexpr CFunction kCoreGraphics[] = {
    {"CGImageGetAlphaInfo", "u:o"}, {"CGImageGetBitmapInfo", "u:o"}, {"CGImageGetBitsPerComponent", "z:o"},
    {"CGImageGetBitsPerPixel", "z:o"}, {"CGImageGetBytesPerRow", "z:o"}, {"CGImageGetColorSpace", "o:o"},
    {"CGImageCreateCopy", "o:o"}, {"CGImageRelease", "v:o"}, {"CGImageRetain", "o:o"},
    {"CGImageCreateWithPNGDataProvider", "o:opuu"}, {"CGImageCreateWithJPEGDataProvider", "o:opuu"},
    {"CGDataProviderCreateWithCFData", "o:o"}, {"CGDataProviderRelease", "v:o"},
    {"CGDataProviderCopyData", "o:o"}, {"CGImageGetDataProvider", "o:o"},
    {"CGColorSpaceCreateDeviceGray", "o:"}, {"CGColorSpaceGetModel", "i:o"},
    {"CGColorSpaceGetNumberOfComponents", "z:o"}, {"CGColorSpaceRetain", "o:o"},
    {"CGColorRelease", "v:o"}, {"CGColorRetain", "o:o"}, {"CGColorGetColorSpace", "o:o"},
    {"CGColorGetNumberOfComponents", "z:o"},
    {"CGContextClip", "v:o"}, {"CGContextEOClip", "v:o"}, {"CGContextSetBlendMode", "v:oi"},
    {"CGContextSetFillColorWithColor", "v:oo"}, {"CGContextSetStrokeColorWithColor", "v:oo"},
    {"CGContextSetInterpolationQuality", "v:oi"}, {"CGContextSetLineJoin", "v:oi"}, {"CGContextSetLineCap", "v:oi"},
    {"CGContextSetTextDrawingMode", "v:oi"}, {"CGContextAddPath", "v:oo"}, {"CGContextSetShouldAntialias", "v:ou"},
    {"CGContextSetAllowsAntialiasing", "v:ou"}, {"CGContextDrawPath", "v:oi"}, {"CGContextEOFillPath", "v:o"},
    {"CGContextRelease", "v:o"}, {"CGContextRetain", "o:o"}, {"CGContextFlush", "v:o"},
    {"CGBitmapContextCreateImage", "o:o"}, {"CGBitmapContextGetWidth", "z:o"},
    {"CGBitmapContextGetHeight", "z:o"}, {"CGBitmapContextGetBytesPerRow", "z:o"},
    {"CGPathCreateMutable", "o:"}, {"CGPathRelease", "v:o"}, {"CGPathRetain", "o:o"}, {"CGPathCloseSubpath", "v:o"},
    {"CGPathCreateCopy", "o:o"}, {"CGPathIsEmpty", "B:o"},
    {"CGGradientRelease", "v:o"}, {"CGGradientCreateWithColors", "o:oop"},
    {"CGDataProviderCreateWithFilename", "o:p"}, {"CGFontCreateWithDataProvider", "o:o"},
    {"CGFontRelease", "v:o"}, {"CGFontRetain", "o:o"}, {"CGFontGetUnitsPerEm", "i:o"},
    {"CGFontGetAscent", "i:o"}, {"CGFontGetDescent", "i:o"}, {"CGFontGetLeading", "i:o"},
    {"CGFontGetCapHeight", "i:o"}, {"CGFontGetXHeight", "i:o"}, {"CGFontGetNumberOfGlyphs", "z:o"},
    {"CGFontCopyTableForTag", "o:ou"}, {"CGFontCreateWithFontName", "o:o"},
    {"CGFontGetGlyphWithGlyphName", "u:oo"},
};
}  // namespace

B32_C_FUNCTIONS(kCoreGraphics, process);

// --- bitmap contexts: always backed by guest memory ------------------------------------------------

// CGContextRef CGBitmapContextCreate(void *data, size_t width, size_t height, size_t bitsPerComponent,
//                                    size_t bytesPerRow, CGColorSpaceRef, uint32_t bitmapInfo)
// With no data, the buffer is allocated in the guest (and leaked), so the
// guest can read the pixels through CGBitmapContextGetData.
B32_THUNK(_CGBitmapContextCreate) {
    GuestAddr data = c.args.ptr();
    size_t width = c.args.u32(), height = c.args.u32(), bpc = c.args.u32(), bytesPerRow = c.args.u32();
    auto space = ref<CGColorSpaceRef>(c);
    uint32_t info = c.args.u32();
    if (!bytesPerRow) {
        size_t components = space ? CGColorSpaceGetNumberOfComponents(space) + ((info & kCGBitmapAlphaInfoMask) ? 1 : 0) : 1;
        bytesPerRow = (width * components * bpc / 8 + 15) & ~size_t(15);
    }
    if (!data) data = c.heap.calloc(1, uint32_t(bytesPerRow * height));
    CGContextRef ctx = CGBitmapContextCreate(c.mem.ptr<void>(data), width, height, bpc, bytesPerRow, space, info);
    c.ret(c.rt.bridge().toGuest((id)ctx));
}

B32_THUNK(_CGBitmapContextGetData) {
    auto *data = static_cast<uint8_t *>(CGBitmapContextGetData(ref<CGContextRef>(c)));
    uint8_t *base = c.mem.base();
    bool inGuest = data && data >= base && data < base + (uint64_t(1) << 32);
    if (data && !inGuest) log("CGBitmapContextGetData: the context's buffer isn't guest memory");
    c.ret(inGuest ? GuestAddr(data - base) : 0);
}

// --- colors -----------------------------------------------------------------------------------------

// CGColorRef CGColorCreate(CGColorSpaceRef, const CGFloat *components): one per
// space component plus alpha.
B32_THUNK(_CGColorCreate) {
    auto space = ref<CGColorSpaceRef>(c);
    GuestAddr p = c.args.ptr();
    size_t count = CGColorSpaceGetNumberOfComponents(space) + 1;
    c.ret(c.rt.bridge().toGuest((id)CGColorCreate(space, components(c, p, count).data())));
}

// const CGFloat *CGColorGetComponents(CGColorRef): a guest float copy kept with the color.
B32_THUNK(_CGColorGetComponents) {
    auto color = ref<CGColorRef>(c);
    size_t count = CGColorGetNumberOfComponents(color);
    const CGFloat *values = CGColorGetComponents(color);
    std::vector<float> floats(values, values + count);
    c.ret(c.rt.bridge().guestBytes(floats.data(), uint32_t(count * sizeof(float)), (id)color));
}

B32_THUNK(_CGContextSetGrayFillColor) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat gray = cgf(c);
    CGContextSetGrayFillColor(ctx, gray, cgf(c));
}
B32_THUNK(_CGContextSetGrayStrokeColor) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat gray = cgf(c);
    CGContextSetGrayStrokeColor(ctx, gray, cgf(c));
}
B32_THUNK(_CGContextSetAlpha) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetAlpha(ctx, cgf(c));
}
// void CGContextSetShadowWithColor(CGContextRef, CGSize offset, CGFloat blur, CGColorRef)
B32_THUNK(_CGContextSetShadowWithColor) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat w = cgf(c), h = cgf(c), blur = cgf(c);
    CGContextSetShadowWithColor(ctx, CGSizeMake(w, h), blur, ref<CGColorRef>(c));
}

// --- more drawing ---------------------------------------------------------------------------------

B32_THUNK(_CGContextAddEllipseInRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextAddEllipseInRect(ctx, rect(c));
}
B32_THUNK(_CGContextStrokeEllipseInRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextStrokeEllipseInRect(ctx, rect(c));
}
B32_THUNK(_CGContextClearRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextClearRect(ctx, rect(c));
}
B32_THUNK(_CGContextClipToRect) {
    auto ctx = ref<CGContextRef>(c);
    CGContextClipToRect(ctx, rect(c));
}
B32_THUNK(_CGContextConcatCTM) {
    auto ctx = ref<CGContextRef>(c);
    CGContextConcatCTM(ctx, transform(c));
}
B32_THUNK(_CGContextRotateCTM) {
    auto ctx = ref<CGContextRef>(c);
    CGContextRotateCTM(ctx, cgf(c));
}
B32_THUNK(_CGContextSetTextMatrix) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetTextMatrix(ctx, transform(c));
}
B32_THUNK(_CGContextSetTextPosition) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x = cgf(c);
    CGContextSetTextPosition(ctx, x, cgf(c));
}

// void CGContextDrawLinearGradient(CGContextRef, CGGradientRef, CGPoint start, CGPoint end, CGGradientDrawingOptions)
B32_THUNK(_CGContextDrawLinearGradient) {
    auto ctx = ref<CGContextRef>(c);
    auto gradient = ref<CGGradientRef>(c);
    CGPoint start = point(c), end = point(c);
    CGContextDrawLinearGradient(ctx, gradient, start, end, c.args.u32());
}
// void CGContextDrawRadialGradient(CGContextRef, CGGradientRef, CGPoint startCenter, CGFloat startRadius,
//                                  CGPoint endCenter, CGFloat endRadius, CGGradientDrawingOptions)
B32_THUNK(_CGContextDrawRadialGradient) {
    auto ctx = ref<CGContextRef>(c);
    auto gradient = ref<CGGradientRef>(c);
    CGPoint start = point(c);
    CGFloat startRadius = cgf(c);
    CGPoint end = point(c);
    CGFloat endRadius = cgf(c);
    CGContextDrawRadialGradient(ctx, gradient, start, startRadius, end, endRadius, c.args.u32());
}

// CGGradientRef CGGradientCreateWithColorComponents(CGColorSpaceRef, const CGFloat components[],
//                                                   const CGFloat locations[], size_t count)
B32_THUNK(_CGGradientCreateWithColorComponents) {
    auto space = ref<CGColorSpaceRef>(c);
    GuestAddr comps = c.args.ptr(), locs = c.args.ptr();
    size_t count = c.args.u32();
    size_t perColor = CGColorSpaceGetNumberOfComponents(space) + 1;
    std::vector<CGFloat> colors = components(c, comps, perColor * count);
    std::vector<CGFloat> locations;
    if (locs) locations = components(c, locs, count);
    c.ret(c.rt.bridge().toGuest(
        (id)CGGradientCreateWithColorComponents(space, colors.data(), locs ? locations.data() : nullptr, count)));
}

// --- paths ------------------------------------------------------------------------------------------

namespace {
// An optional const CGAffineTransform * argument.
bool optionalTransform(Call &c, GuestAddr p, CGAffineTransform &t) {
    if (!p) return false;
    float v[6];
    std::memcpy(v, c.mem.ptr<void>(p), sizeof v);
    t = CGAffineTransformMake(v[0], v[1], v[2], v[3], v[4], v[5]);
    return true;
}
}  // namespace

B32_THUNK(_CGPathAddRect) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGPathAddRect(path, has ? &t : nullptr, rect(c));
}
// void CGPathAddLines(CGMutablePathRef, const CGAffineTransform *, const CGPoint points[], size_t count)
B32_THUNK(_CGPathAddLines) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    GuestAddr points = c.args.ptr();
    uint32_t count = c.args.u32();
    std::vector<CGPoint> host(count);
    for (uint32_t i = 0; i < count; i++)
        host[i] = CGPointMake(c.mem.read<float>(points + i * 8), c.mem.read<float>(points + i * 8 + 4));
    CGPathAddLines(path, has ? &t : nullptr, host.data(), count);
}
B32_THUNK(_CGPathMoveToPoint) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat x = cgf(c);
    CGPathMoveToPoint(path, has ? &t : nullptr, x, cgf(c));
}
B32_THUNK(_CGPathAddLineToPoint) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat x = cgf(c);
    CGPathAddLineToPoint(path, has ? &t : nullptr, x, cgf(c));
}
// bool CGPathContainsPoint(CGPathRef, const CGAffineTransform *, CGPoint, bool eoFill)
B32_THUNK(_CGPathContainsPoint) {
    auto path = ref<CGPathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGPoint p = point(c);
    c.ret(CGPathContainsPoint(path, has ? &t : nullptr, p, c.args.u32() != 0));
}
// CGPathRef CGPathCreateCopyByStrokingPath(CGPathRef, const CGAffineTransform *, CGFloat lineWidth,
//                                          CGLineCap, CGLineJoin, CGFloat miterLimit)
B32_THUNK(_CGPathCreateCopyByStrokingPath) {
    auto path = ref<CGPathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat width = cgf(c);
    auto cap = CGLineCap(c.args.i32());
    auto join = CGLineJoin(c.args.i32());
    c.ret(c.rt.bridge().toGuest((id)CGPathCreateCopyByStrokingPath(path, has ? &t : nullptr, width, cap, join, cgf(c))));
}

// --- geometry ----------------------------------------------------------------------------------------

// CGRect CGImageCreateWithImageInRect(CGImageRef, CGRect)
B32_THUNK(_CGImageCreateWithImageInRect) {
    auto image = ref<CGImageRef>(c);
    c.ret(c.rt.bridge().toGuest((id)CGImageCreateWithImageInRect(image, rect(c))));
}

// CGRect CGRectApplyAffineTransform(CGRect, CGAffineTransform): through r0.
B32_THUNK(_CGRectApplyAffineTransform) {
    GuestAddr out = c.args.ptr();
    CGRect r = rect(c);
    CGRect result = CGRectApplyAffineTransform(r, transform(c));
    const float v[4] = {float(result.origin.x), float(result.origin.y), float(result.size.width), float(result.size.height)};
    c.mem.copyIn(out, v, sizeof v);
}

// void CGRectDivide(CGRect, CGRect *slice, CGRect *remainder, CGFloat amount, CGRectEdge)
B32_THUNK(_CGRectDivide) {
    CGRect r = rect(c);
    GuestAddr slice = c.args.ptr(), remainder = c.args.ptr();
    CGFloat amount = cgf(c);
    CGRect s, rest;
    CGRectDivide(r, &s, &rest, amount, CGRectEdge(c.args.u32()));
    const float sv[4] = {float(s.origin.x), float(s.origin.y), float(s.size.width), float(s.size.height)};
    const float rv[4] = {float(rest.origin.x), float(rest.origin.y), float(rest.size.width), float(rest.size.height)};
    if (slice) c.mem.copyIn(slice, sv, sizeof sv);
    if (remainder) c.mem.copyIn(remainder, rv, sizeof rv);
}

B32_THUNK(_CGAffineTransformIsIdentity) { c.ret(CGAffineTransformIsIdentity(transform(c))); }

// --- fonts and data providers -----------------------------------------------------------------

// CGDataProviderRef CGDataProviderCreateWithData(void *info, const void *data, size_t size,
//     CGDataProviderReleaseDataCallback): the bytes stay in guest memory, which
// never moves; the guest's release callback isn't called (the data leaks).
B32_THUNK(_CGDataProviderCreateWithData) {
    c.args.ptr();
    GuestAddr data = c.args.ptr();
    size_t size = c.args.u32();
    c.ret(c.rt.bridge().toGuest((id)CGDataProviderCreateWithData(nullptr, c.mem.ptr<void>(data), size, nullptr)));
}

// bool CGFontGetGlyphAdvances(CGFontRef, const CGGlyph glyphs[], size_t count, int advances[]):
// both arrays have the same layout in the guest.
B32_THUNK(_CGFontGetGlyphAdvances) {
    auto font = ref<CGFontRef>(c);
    GuestAddr glyphs = c.args.ptr();
    size_t count = c.args.u32();
    GuestAddr advances = c.args.ptr();
    c.ret(CGFontGetGlyphAdvances(font, c.mem.ptr<CGGlyph>(glyphs), count, c.mem.ptr<int>(advances)));
}

// CGContextShowGlyphsAtPoint is gone from the macOS SDK; it's drawn with
// CGContextShowGlyphsAtPositions, laying glyphs out by their advances in the
// font and size the guest set on the context (which CG doesn't hand back).
namespace {
struct TextState {
    CGFontRef font = nullptr;
    CGFloat size = 0;
};
std::mutex textLock;
std::unordered_map<CGContextRef, TextState> textStates;
}  // namespace

B32_THUNK(_CGContextSetFont) {
    auto ctx = ref<CGContextRef>(c);
    auto font = ref<CGFontRef>(c);
    CGContextSetFont(ctx, font);
    std::lock_guard guard(textLock);
    TextState &state = textStates[ctx];
    if (font) CGFontRetain(font);
    if (state.font) CGFontRelease(state.font);
    state.font = font;
}

B32_THUNK(_CGContextSetFontSize) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat size = cgf(c);
    CGContextSetFontSize(ctx, size);
    std::lock_guard guard(textLock);
    textStates[ctx].size = size;
}

// void CGContextShowGlyphsAtPoint(CGContextRef, CGFloat x, CGFloat y, const CGGlyph glyphs[], size_t count)
B32_THUNK(_CGContextShowGlyphsAtPoint) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x = cgf(c), y = cgf(c);
    const CGGlyph *glyphs = c.mem.ptr<CGGlyph>(c.args.ptr());
    size_t count = c.args.u32();
    TextState state;
    {
        std::lock_guard guard(textLock);
        state = textStates[ctx];
    }
    std::vector<int> advances(count);
    if (state.font) CGFontGetGlyphAdvances(state.font, glyphs, count, advances.data());
    CGFloat scale = state.font ? state.size / CGFontGetUnitsPerEm(state.font) : 0;
    std::vector<CGPoint> positions(count);
    CGFloat pen = x;
    for (size_t i = 0; i < count; i++) {
        positions[i] = CGPointMake(pen, y);
        pen += advances[i] * scale;
    }
    CGContextShowGlyphsAtPositions(ctx, glyphs, positions.data(), count);
}
