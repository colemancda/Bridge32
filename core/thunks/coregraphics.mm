// CoreGraphics and CoreFoundation basics. CF objects cross the bridge like
// ObjC objects (they are toll-free ObjC objects on the host); CGFloat is a
// float in the guest.
//
// Hand-written for now; most of these will come from the signature database.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#import <Accelerate/Accelerate.h>
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
    StructResult out(c, 16);
    CGRect r = rect(c);
    CGFloat dx = cgf(c);
    retRect(c, out, CGRectInset(r, dx, cgf(c)));
}
B32_THUNK(_CGRectOffset) {
    StructResult out(c, 16);
    CGRect r = rect(c);
    CGFloat dx = cgf(c);
    retRect(c, out, CGRectOffset(r, dx, cgf(c)));
}
B32_THUNK(_CGRectIntersection) {
    StructResult out(c, 16);
    CGRect a = rect(c);
    retRect(c, out, CGRectIntersection(a, rect(c)));
}
B32_THUNK(_CGRectUnion) {
    StructResult out(c, 16);
    CGRect a = rect(c);
    retRect(c, out, CGRectUnion(a, rect(c)));
}
B32_THUNK(_CGRectStandardize) {
    StructResult out(c, 16);
    retRect(c, out, CGRectStandardize(rect(c)));
}
B32_THUNK(_CGRectIntegral) {
    StructResult out(c, 16);
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
// void CGContextAddArc(CGContextRef, CGFloat x, CGFloat y, CGFloat radius, CGFloat startAngle,
//                      CGFloat endAngle, int clockwise)
B32_THUNK(_CGContextAddArc) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x = cgf(c), y = cgf(c), radius = cgf(c), start = cgf(c), end = cgf(c);
    CGContextAddArc(ctx, x, y, radius, start, end, c.args.i32());
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
    StructResult out(c, 24);
    writeTransform(c, out, CGAffineTransformMakeRotation(cgf(c)));
}
B32_THUNK(_CGAffineTransformMakeScale) {
    StructResult out(c, 24);
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformMakeScale(x, cgf(c)));
}
B32_THUNK(_CGAffineTransformMakeTranslation) {
    StructResult out(c, 24);
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformMakeTranslation(x, cgf(c)));
}
B32_THUNK(_CGAffineTransformRotate) {
    StructResult out(c, 24);
    CGAffineTransform t = transform(c);
    writeTransform(c, out, CGAffineTransformRotate(t, cgf(c)));
}
B32_THUNK(_CGAffineTransformScale) {
    StructResult out(c, 24);
    CGAffineTransform t = transform(c);
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformScale(t, x, cgf(c)));
}
B32_THUNK(_CGAffineTransformTranslate) {
    StructResult out(c, 24);
    CGAffineTransform t = transform(c);
    CGFloat x = cgf(c);
    writeTransform(c, out, CGAffineTransformTranslate(t, x, cgf(c)));
}
B32_THUNK(_CGAffineTransformConcat) {
    StructResult out(c, 24);
    CGAffineTransform a = transform(c);
    writeTransform(c, out, CGAffineTransformConcat(a, transform(c)));
}
B32_THUNK(_CGAffineTransformInvert) {
    StructResult out(c, 24);
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
    {"CGContextSetAllowsFontSubpixelPositioning", "v:ou"}, {"CGContextSetShouldSubpixelQuantizeFonts", "v:ou"},
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
    {"CGFontGetGlyphWithGlyphName", "u:oo"}, {"CGFontCopyFullName", "o:o"},
    {"CGColorSpaceGetBaseColorSpace", "o:o"}, {"CGContextSetShouldSubpixelPositionFonts", "v:ou"},
    {"CGImageSourceCreateWithDataProvider", "o:oo"}, {"CGImageSourceCreateImageAtIndex", "o:ozo"},
    {"CFAttributedStringCreate", "o:ooo"}, {"CFAttributedStringCreateWithSubstring", "o:oozz"},
    {"CFPropertyListCreateDeepCopy", "o:ooz"}, {"CFWriteStreamCopyProperty", "o:oo"},
    {"CFStringTokenizerCreate", "o:oozzzo"}, {"CFStringTokenizerAdvanceToNextToken", "z:o"},
    {"CFStringTokenizerCopyBestStringLanguage", "o:ozz"}, {"CFReadStreamCreateWithFile", "o:oo"},
    {"CFWriteStreamCreateWithFile", "o:oo"}, {"CFDataAppendBytes", "v:opz"},
    {"CFCharacterSetCreateMutable", "o:o"}, {"CFCharacterSetAddCharactersInRange", "v:ozz"},
    {"CFCharacterSetInvert", "v:o"}, {"CFRunLoopCopyAllModes", "o:o"}, {"CFSetAddValue", "v:oo"},
    {"CFSetContainsValue", "B:oo"}, {"CGContextReplacePathWithStrokedPath", "v:o"},
    {"CGImageCreateWithMask", "o:oo"}, {"CFGetRetainCount", "i:o"},
    {"CGPDFDocumentCreateWithProvider", "o:o"}, {"CGPDFDocumentGetPage", "o:oz"},
    {"CGPDFDocumentRelease", "v:o"}, {"CGPDFDocumentRetain", "o:o"}, {"CGContextDrawPDFPage", "v:oo"},
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

// CGColorRef CGColorCreateCopyWithAlpha(CGColorRef, CGFloat alpha)
B32_THUNK(_CGColorCreateCopyWithAlpha) {
    auto color = ref<CGColorRef>(c);
    c.ret(c.rt.bridge().toGuest((id)CGColorCreateCopyWithAlpha(color, cgf(c))));
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
// CGPoint CGContextGetTextPosition(CGContextRef), returned through r0
B32_THUNK(_CGContextGetTextPosition) {
    StructResult out(c, 8);
    CGPoint at = CGContextGetTextPosition(ref<CGContextRef>(c));
    c.mem.write<float>(out, float(at.x));
    c.mem.write<float>(out + 4, float(at.y));
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
B32_THUNK(_CGPathAddEllipseInRect) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGPathAddEllipseInRect(path, has ? &t : nullptr, rect(c));
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
    StructResult out(c, 16);
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
B32_THUNK(_CGAffineTransformEqualToTransform) {
    CGAffineTransform a = transform(c);
    c.ret(CGAffineTransformEqualToTransform(a, transform(c)));
}

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
// 16-bit glyphs in, 32-bit advances out, in the guest's byte order.
B32_THUNK(_CGFontGetGlyphAdvances) {
    auto font = ref<CGFontRef>(c);
    GuestAddr glyphs = c.args.ptr();
    size_t count = c.args.u32();
    GuestAddr advances = c.args.ptr();
    std::vector<CGGlyph> hostGlyphs = c.mem.readArray<CGGlyph>(glyphs, count);
    std::vector<int> hostAdvances(count);
    bool ok = CGFontGetGlyphAdvances(font, hostGlyphs.data(), count, hostAdvances.data());
    c.mem.writeArray<int32_t>(advances, hostAdvances.data(), count);
    c.ret(ok);
}

// bool CGFontGetGlyphBBoxes(CGFontRef, const CGGlyph glyphs[], size_t count, CGRect bboxes[]):
// the guest's CGRects are four floats.
B32_THUNK(_CGFontGetGlyphBBoxes) {
    auto font = ref<CGFontRef>(c);
    GuestAddr glyphs = c.args.ptr();
    size_t count = c.args.u32();
    GuestAddr bboxes = c.args.ptr();
    std::vector<CGRect> rects(count);
    std::vector<CGGlyph> hostGlyphs = c.mem.readArray<CGGlyph>(glyphs, count);
    bool ok = CGFontGetGlyphBBoxes(font, hostGlyphs.data(), count, rects.data());
    for (size_t i = 0; ok && i < count; i++) {
        const CGRect &r = rects[i];
        const float v[4] = {float(r.origin.x), float(r.origin.y), float(r.size.width), float(r.size.height)};
        c.mem.writeArray<float>(bboxes + GuestAddr(i * sizeof v), v, 4);
    }
    c.ret(ok);
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
namespace {
// Draws the glyphs from (x, y) and returns where the pen ends up.
CGFloat showGlyphsAt(CGContextRef ctx, CGFloat x, CGFloat y, const CGGlyph *glyphs, size_t count) {
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
    return pen;
}
}  // namespace

B32_THUNK(_CGContextShowGlyphsAtPoint) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat x = cgf(c), y = cgf(c);
    GuestAddr glyphs = c.args.ptr();
    size_t count = c.args.u32();
    std::vector<CGGlyph> hostGlyphs = c.mem.readArray<CGGlyph>(glyphs, count);
    showGlyphsAt(ctx, x, y, hostGlyphs.data(), count);
}
// void CGContextShowGlyphs(CGContextRef, const CGGlyph glyphs[], size_t count): from the text
// position, which moves past them.
B32_THUNK(_CGContextShowGlyphs) {
    auto ctx = ref<CGContextRef>(c);
    GuestAddr glyphs = c.args.ptr();
    size_t count = c.args.u32();
    std::vector<CGGlyph> hostGlyphs = c.mem.readArray<CGGlyph>(glyphs, count);
    CGPoint at = CGContextGetTextPosition(ctx);
    CGContextSetTextPosition(ctx, showGlyphsAt(ctx, at.x, at.y, hostGlyphs.data(), count), at.y);
}

// --- transparency layers, masks, shadings, transformed paths ---------------------------------------

B32_THUNK(_CGContextBeginTransparencyLayer) {
    auto ctx = ref<CGContextRef>(c);
    CGContextBeginTransparencyLayer(ctx, ref<CFDictionaryRef>(c));
}
// void CGContextBeginTransparencyLayerWithRect(CGContextRef, CGRect, CFDictionaryRef auxiliaryInfo)
B32_THUNK(_CGContextBeginTransparencyLayerWithRect) {
    auto ctx = ref<CGContextRef>(c);
    CGRect r = rect(c);
    CGContextBeginTransparencyLayerWithRect(ctx, r, ref<CFDictionaryRef>(c));
}
B32_THUNK(_CGContextEndTransparencyLayer) { CGContextEndTransparencyLayer(ref<CGContextRef>(c)); }
// void CGContextClipToMask(CGContextRef, CGRect, CGImageRef mask)
B32_THUNK(_CGContextClipToMask) {
    auto ctx = ref<CGContextRef>(c);
    CGRect r = rect(c);
    CGContextClipToMask(ctx, r, ref<CGImageRef>(c));
}
B32_THUNK(_CGContextDrawShading) {
    auto ctx = ref<CGContextRef>(c);
    CGContextDrawShading(ctx, ref<CGShadingRef>(c));
}
B32_THUNK(_CGShadingRelease) { CGShadingRelease(ref<CGShadingRef>(c)); }
// CGPathRef CGPathCreateCopyByTransformingPath(CGPathRef, const CGAffineTransform *)
B32_THUNK(_CGPathCreateCopyByTransformingPath) {
    auto path = ref<CGPathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    c.ret(c.rt.bridge().toGuest((id)CGPathCreateCopyByTransformingPath(path, has ? &t : nullptr)));
}

// --- vImage (Accelerate) ---------------------------------------------------------------------

namespace {
// vImage_Buffer { void *data; vImagePixelCount height, width; size_t rowBytes }:
// four words in the guest.
vImage_Buffer imageBuffer(Call &c, GuestAddr p) {
    if (!p) return {};
    GuestAddr data = c.mem.read<uint32_t>(p);
    return {data ? c.mem.ptr<void>(data) : nullptr, c.mem.read<uint32_t>(p + 4), c.mem.read<uint32_t>(p + 8),
            c.mem.read<uint32_t>(p + 12)};
}
}  // namespace

// vImage_Error vImageBoxConvolve_ARGB8888(const vImage_Buffer *src, const vImage_Buffer *dest,
//     void *tempBuffer, vImagePixelCount srcOffsetToROI_X, vImagePixelCount srcOffsetToROI_Y,
//     uint32_t kernel_height, uint32_t kernel_width, const Pixel_8888 backgroundColor, vImage_Flags)
// With kvImageGetTempBufferSize the result is a size rather than an error.
B32_THUNK(_vImageBoxConvolve_ARGB8888) {
    vImage_Buffer src = imageBuffer(c, c.args.ptr()), dest = imageBuffer(c, c.args.ptr());
    GuestAddr temp = c.args.ptr();
    vImagePixelCount x = c.args.u32(), y = c.args.u32();
    uint32_t kernelHeight = c.args.u32(), kernelWidth = c.args.u32();
    GuestAddr background = c.args.ptr();
    vImage_Flags flags = c.args.u32();
    vImage_Error result = vImageBoxConvolve_ARGB8888(&src, &dest, temp ? c.mem.ptr<void>(temp) : nullptr, x, y,
                                                     kernelHeight, kernelWidth,
                                                     background ? c.mem.ptr<uint8_t>(background) : nullptr, flags);
    c.ret(uint32_t(int32_t(result)));
}

// --- more colors, rects, paths and images ----------------------------------------------------

B32_THUNK(_CGColorGetAlpha) { c.retF32(float(CGColorGetAlpha(ref<CGColorRef>(c)))); }
B32_THUNK(_CGRectIsInfinite) { c.ret(CGRectIsInfinite(rect(c))); }

// CGPathRef CGPathCreateWithRect(CGRect, const CGAffineTransform *)
B32_THUNK(_CGPathCreateWithRect) {
    CGRect r = rect(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    c.ret(c.rt.bridge().toGuest((id)CGPathCreateWithRect(r, has ? &t : nullptr)));
}
// void CGPathAddRoundedRect(CGMutablePathRef, const CGAffineTransform *, CGRect,
//     CGFloat cornerWidth, CGFloat cornerHeight)
B32_THUNK(_CGPathAddRoundedRect) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGRect r = rect(c);
    CGFloat w = cgf(c);
    CGPathAddRoundedRect(path, has ? &t : nullptr, r, w, cgf(c));
}
// void CGPathAddArcToPoint(CGMutablePathRef, const CGAffineTransform *, CGFloat x1, CGFloat y1,
//     CGFloat x2, CGFloat y2, CGFloat radius)
B32_THUNK(_CGPathAddArcToPoint) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat x1 = cgf(c), y1 = cgf(c), x2 = cgf(c), y2 = cgf(c);
    CGPathAddArcToPoint(path, has ? &t : nullptr, x1, y1, x2, y2, cgf(c));
}

// CGContextRef CGBitmapContextCreateWithData(void *data, size_t width, size_t height,
//     size_t bitsPerComponent, size_t bytesPerRow, CGColorSpaceRef, uint32_t bitmapInfo,
//     CGBitmapContextReleaseDataCallback, void *releaseInfo): like CGBitmapContextCreate.
// The release callback is guest code, run when the context goes.
namespace {
struct ReleaseData {
    GuestAddr callback, info;
};
void releaseBitmapData(void *p, void *data) {
    auto *r = static_cast<ReleaseData *>(p);
    Runtime &rt = objc::Bridge::shared()->runtime();
    if (r->callback) Runtime::threadCpu().call(r->callback, {r->info, rt.mem().guestAddrOf(data)});
    delete r;
}
}  // namespace
B32_THUNK(_CGBitmapContextCreateWithData) {
    GuestAddr data = c.args.ptr();
    size_t width = c.args.u32(), height = c.args.u32(), bpc = c.args.u32(), bytesPerRow = c.args.u32();
    auto space = ref<CGColorSpaceRef>(c);
    uint32_t info = c.args.u32();
    GuestAddr callback = c.args.ptr(), releaseInfo = c.args.ptr();
    if (!bytesPerRow) {
        size_t components = space ? CGColorSpaceGetNumberOfComponents(space) + ((info & kCGBitmapAlphaInfoMask) ? 1 : 0) : 1;
        bytesPerRow = (width * components * bpc / 8 + 15) & ~size_t(15);
    }
    // Without a buffer of its own the context would draw into host memory the guest can't see.
    bool ours = !data;
    if (ours) data = c.heap.calloc(1, uint32_t(bytesPerRow * height));
    CGContextRef ctx = CGBitmapContextCreateWithData(c.mem.ptr<void>(data), width, height, bpc, bytesPerRow, space, info,
                                                     callback && !ours ? releaseBitmapData : nullptr,
                                                     callback && !ours ? new ReleaseData{callback, releaseInfo} : nullptr);
    c.ret(c.rt.bridge().toGuest((id)ctx));
}

// CGImageRef CGImageCreate(size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel,
//     size_t bytesPerRow, CGColorSpaceRef, CGBitmapInfo, CGDataProviderRef, const CGFloat *decode,
//     bool shouldInterpolate, CGColorRenderingIntent)
B32_THUNK(_CGImageCreate) {
    size_t width = c.args.u32(), height = c.args.u32(), bpc = c.args.u32(), bpp = c.args.u32(), bpr = c.args.u32();
    auto space = ref<CGColorSpaceRef>(c);
    CGBitmapInfo info = c.args.u32();
    auto provider = ref<CGDataProviderRef>(c);
    GuestAddr decodeIn = c.args.ptr();
    bool interpolate = c.args.u32() & 0xff;
    auto intent = CGColorRenderingIntent(c.args.i32());
    std::vector<CGFloat> decode;
    if (decodeIn) {
        size_t n = 2 * (space ? CGColorSpaceGetNumberOfComponents(space) : 1);
        for (size_t i = 0; i < n; i++) decode.push_back(c.mem.read<float>(decodeIn + uint32_t(i) * 4));
    }
    c.ret(c.rt.bridge().toGuest((id)CGImageCreate(width, height, bpc, bpp, bpr, space, info, provider,
                                                  decodeIn ? decode.data() : nullptr, interpolate, intent)));
}

// CGImageRef CGImageMaskCreate(size_t width, size_t height, size_t bitsPerComponent, size_t bitsPerPixel,
//     size_t bytesPerRow, CGDataProviderRef, const CGFloat *decode, bool shouldInterpolate)
B32_THUNK(_CGImageMaskCreate) {
    size_t width = c.args.u32(), height = c.args.u32(), bpc = c.args.u32(), bpp = c.args.u32(), bpr = c.args.u32();
    auto provider = ref<CGDataProviderRef>(c);
    GuestAddr decodeIn = c.args.ptr();
    bool interpolate = c.args.u32() & 0xff;
    CGFloat decode[2] = {};
    if (decodeIn) decode[0] = c.mem.read<float>(decodeIn), decode[1] = c.mem.read<float>(decodeIn + 4);
    c.ret(c.rt.bridge().toGuest((id)CGImageMaskCreate(width, height, bpc, bpp, bpr, provider,
                                                      decodeIn ? decode : nullptr, interpolate)));
}

// CGAffineTransform CATransform3DGetAffineTransform(CATransform3D): sixteen floats in, six out through r0.
B32_THUNK(_CATransform3DGetAffineTransform) {
    StructResult out(c, 24);
    float m[16];
    for (float &v : m) v = c.args.f32();
    // m11 m12 . . / m21 m22 . . / . . . . / m41 m42 . .
    writeTransform(c, out, CGAffineTransformMake(m[0], m[1], m[4], m[5], m[12], m[13]));
}

// --- Core Foundation odds and ends ---------------------------------------------------------------

// void *CFAllocatorAllocate(CFAllocatorRef, CFIndex size, CFOptionFlags): guest heap memory
// (CFAllocatorDeallocate frees it the same way).
B32_THUNK(_CFAllocatorAllocate) {
    c.args.u32();
    c.ret(c.heap.alloc(std::max<uint32_t>(c.args.u32(), 1)));
}
B32_THUNK(_CFAllocatorDeallocate) {
    c.args.u32();
    if (GuestAddr p = c.args.ptr()) c.heap.free(p);
}
// CFTypeRef CFMakeCollectable(CFTypeRef): no garbage collection, so the object itself.
B32_THUNK(_CFMakeCollectable) { c.ret(c.args.ptr()); }
// CFMutableSetRef CFSetCreateMutable(CFAllocatorRef, CFIndex capacity, const CFSetCallBacks *):
// the guest's callbacks are its copy of kCFTypeSetCallBacks (or NULL for raw pointers, unsupported).
B32_THUNK(_CFSetCreateMutable) {
    c.args.u32();
    CFIndex capacity = c.args.i32();
    if (!c.args.ptr()) log("CFSetCreateMutable without callbacks: using CFType callbacks anyway");
    c.ret(c.rt.bridge().toGuest((id)CFSetCreateMutable(nullptr, capacity, &kCFTypeSetCallBacks)));
}
// void CFStreamCreatePairWithSocketToHost(CFAllocatorRef, CFStringRef host, UInt32 port,
//     CFReadStreamRef *, CFWriteStreamRef *)
B32_THUNK(_CFStreamCreatePairWithSocketToHost) {
    c.args.u32();
    auto host = ref<CFStringRef>(c);
    UInt32 port = c.args.u32();
    GuestAddr readOut = c.args.ptr(), writeOut = c.args.ptr();
    CFReadStreamRef read = nullptr;
    CFWriteStreamRef write = nullptr;
    CFStreamCreatePairWithSocketToHost(nullptr, host, port, readOut ? &read : nullptr, writeOut ? &write : nullptr);
    if (readOut) c.mem.write<uint32_t>(readOut, read ? c.rt.bridge().toGuest((id)read) : 0);
    if (writeOut) c.mem.write<uint32_t>(writeOut, write ? c.rt.bridge().toGuest((id)write) : 0);
}

// --- more context and path geometry --------------------------------------------------------

namespace {
void writeRectTo(Call &c, GuestAddr out, CGRect r) {
    const float f[4] = {float(r.origin.x), float(r.origin.y), float(r.size.width), float(r.size.height)};
    c.mem.copyIn(out, f, sizeof f);
}
}  // namespace

// CGAffineTransform CGContextGetCTM(CGContextRef) and the bounding boxes: through r0.
B32_THUNK(_CGContextGetCTM) {
    StructResult out(c, 24);
    writeTransform(c, out, CGContextGetCTM(ref<CGContextRef>(c)));
}
B32_THUNK(_CGContextGetClipBoundingBox) {
    StructResult out(c, 16);
    writeRectTo(c, out, CGContextGetClipBoundingBox(ref<CGContextRef>(c)));
}
B32_THUNK(_CGContextGetPathBoundingBox) {
    StructResult out(c, 16);
    writeRectTo(c, out, CGContextGetPathBoundingBox(ref<CGContextRef>(c)));
}
// CGRect CGPathGetBoundingBox(CGPathRef), CGPathGetPathBoundingBox(CGPathRef) and
// CGPDFPageGetBoxRect(CGPDFPageRef, CGPDFBox): through r0.
B32_THUNK(_CGPathGetBoundingBox) {
    StructResult out(c, 16);
    writeRectTo(c, out, CGPathGetBoundingBox(ref<CGPathRef>(c)));
}
B32_THUNK(_CGPathGetPathBoundingBox) {
    StructResult out(c, 16);
    writeRectTo(c, out, CGPathGetPathBoundingBox(ref<CGPathRef>(c)));
}
B32_THUNK(_CGPDFPageGetBoxRect) {
    StructResult out(c, 16);
    auto page = ref<CGPDFPageRef>(c);
    writeRectTo(c, out, CGPDFPageGetBoxRect(page, CGPDFBox(c.args.i32())));
}
B32_THUNK(_CGContextSetMiterLimit) {
    auto ctx = ref<CGContextRef>(c);
    CGContextSetMiterLimit(ctx, cgf(c));
}
// void CGContextSetLineDash(CGContextRef, CGFloat phase, const CGFloat lengths[], size_t count)
B32_THUNK(_CGContextSetLineDash) {
    auto ctx = ref<CGContextRef>(c);
    CGFloat phase = cgf(c);
    GuestAddr lengths = c.args.ptr();
    size_t count = c.args.u32();
    std::vector<CGFloat> values(count);
    for (size_t i = 0; i < count; i++) values[i] = c.mem.read<float>(lengths + uint32_t(i) * 4);
    CGContextSetLineDash(ctx, phase, lengths ? values.data() : nullptr, count);
}
// void CGPathAddArc(CGMutablePathRef, const CGAffineTransform *, CGFloat x, CGFloat y, CGFloat radius,
//     CGFloat startAngle, CGFloat endAngle, bool clockwise)
B32_THUNK(_CGPathAddArc) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat x = cgf(c), y = cgf(c), radius = cgf(c), start = cgf(c), end = cgf(c);
    CGPathAddArc(path, has ? &t : nullptr, x, y, radius, start, end, c.args.u32() & 0xff);
}
// void CGPathAddCurveToPoint(CGMutablePathRef, const CGAffineTransform *, cp1x, cp1y, cp2x, cp2y, x, y)
B32_THUNK(_CGPathAddCurveToPoint) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat a = cgf(c), b = cgf(c), d = cgf(c), e = cgf(c), x = cgf(c);
    CGPathAddCurveToPoint(path, has ? &t : nullptr, a, b, d, e, x, cgf(c));
}
// void CGPathAddQuadCurveToPoint(CGMutablePathRef, const CGAffineTransform *, cpx, cpy, x, y)
B32_THUNK(_CGPathAddQuadCurveToPoint) {
    auto path = ref<CGMutablePathRef>(c);
    CGAffineTransform t;
    bool has = optionalTransform(c, c.args.ptr(), t);
    CGFloat a = cgf(c), b = cgf(c), x = cgf(c);
    CGPathAddQuadCurveToPoint(path, has ? &t : nullptr, a, b, x, cgf(c));
}
// CGPoint CGPathGetCurrentPoint(CGPathRef): through r0.
B32_THUNK(_CGPathGetCurrentPoint) {
    StructResult out(c, 8);
    CGPoint at = CGPathGetCurrentPoint(ref<CGPathRef>(c));
    c.mem.write<float>(out, float(at.x));
    c.mem.write<float>(out + 4, float(at.y));
}

// --- more Core Foundation strings and property lists -------------------------------------------

// CFStringRef CFStringCreateWithCharactersNoCopy(CFAllocatorRef, const UniChar *, CFIndex, CFAllocatorRef):
// copied, since the guest's deallocator can't be honored.
B32_THUNK(_CFStringCreateWithCharactersNoCopy) {
    c.args.u32();
    GuestAddr chars = c.args.ptr();
    CFIndex length = c.args.i32();
    std::vector<UniChar> hostChars = c.mem.readArray<UniChar>(chars, size_t(std::max<CFIndex>(length, 0)));
    c.ret(c.rt.bridge().toGuest((id)CFStringCreateWithCharacters(nullptr, hostChars.data(), length)));
}
// Boolean CFStringFindCharacterFromSet(CFStringRef, CFCharacterSetRef, CFRange, CFStringCompareFlags, CFRange *)
B32_THUNK(_CFStringFindCharacterFromSet) {
    auto string = ref<CFStringRef>(c);
    auto set = ref<CFCharacterSetRef>(c);
    CFIndex location = c.args.i32(), length = c.args.i32();
    CFStringCompareFlags flags = c.args.u32();
    GuestAddr out = c.args.ptr();
    CFRange found;
    Boolean ok = CFStringFindCharacterFromSet(string, set, CFRangeMake(location, length), flags, &found);
    if (ok && out) {
        c.mem.write<int32_t>(out, int32_t(found.location));
        c.mem.write<int32_t>(out + 4, int32_t(found.length));
    }
    c.ret(ok);
}
// CFRange CFStringGetRangeOfComposedCharactersAtIndex(CFStringRef, CFIndex): through r0.
B32_THUNK(_CFStringGetRangeOfComposedCharactersAtIndex) {
    StructResult out(c, 8);
    auto string = ref<CFStringRef>(c);
    CFRange r = CFStringGetRangeOfComposedCharactersAtIndex(string, c.args.i32());
    c.mem.write<int32_t>(out, int32_t(r.location));
    c.mem.write<int32_t>(out + 4, int32_t(r.length));
}
// CFPropertyListRef CFPropertyListCreateWithData(CFAllocatorRef, CFDataRef, CFOptionFlags,
//     CFPropertyListFormat *, CFErrorRef *): the format is a 32-bit CFIndex in the guest.
B32_THUNK(_CFPropertyListCreateWithData) {
    c.args.u32();
    auto data = ref<CFDataRef>(c);
    CFOptionFlags options = c.args.u32();
    GuestAddr formatOut = c.args.ptr(), errorOut = c.args.ptr();
    CFPropertyListFormat format = kCFPropertyListBinaryFormat_v1_0;
    CFErrorRef error = nullptr;
    CFPropertyListRef plist = CFPropertyListCreateWithData(nullptr, data, options, &format, errorOut ? &error : nullptr);
    if (formatOut) c.mem.write<int32_t>(formatOut, int32_t(format));
    if (errorOut) c.mem.write<uint32_t>(errorOut, error ? c.rt.bridge().toGuest((id)error) : 0);
    c.ret(plist ? c.rt.bridge().toGuest((id)plist) : 0);
}
