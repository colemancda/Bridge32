// Core Text on the host's. Fonts, lines, runs, frames and framesetters are CF
// objects, which cross the bridge like any object (Create/Copy results are +1,
// Get results +0). What needs converting is the 32-bit side's CGFloat (float),
// CFRange { long, long } (two words), point and rect arrays, structs returned
// through r0, paragraph style settings and run delegate callbacks.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/Thunks.h"

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include <cstring>
#include <vector>

using namespace b32;

namespace {
template <typename T> T ref(Call &c) { return (T)c.rt.bridge().toHost(c.args.ptr()); }
GuestAddr guest(Call &c, CFTypeRef object) { return object ? c.rt.bridge().toGuest((id)object) : 0; }
CGFloat cgf(Call &c) { return CGFloat(c.args.f32()); }
CFRange range(Call &c) {
    CFIndex location = c.args.i32();
    return CFRangeMake(location, c.args.i32());
}
void writeRange(Call &c, GuestAddr out, CFRange r) {
    c.mem.write<int32_t>(out, int32_t(r.location));
    c.mem.write<int32_t>(out + 4, int32_t(r.length));
}
void writePoints(Call &c, GuestAddr out, const CGPoint *points, size_t count) {
    for (size_t i = 0; i < count; i++) {
        c.mem.write<float>(out + uint32_t(i) * 8, float(points[i].x));
        c.mem.write<float>(out + uint32_t(i) * 8 + 4, float(points[i].y));
    }
}
void writeFloat(Call &c, GuestAddr out, CGFloat value) {
    if (out) c.mem.write<float>(out, float(value));
}
// An optional const CGAffineTransform *: six floats in the guest.
bool transformAt(Call &c, GuestAddr p, CGAffineTransform &t) {
    if (!p) return false;
    const float *f = c.mem.ptr<float>(p);
    t = CGAffineTransformMake(f[0], f[1], f[2], f[3], f[4], f[5]);
    return true;
}
}  // namespace

// --- fonts ---------------------------------------------------------------------------------

// CTFontRef CTFontCreateWithName(CFStringRef, CGFloat size, const CGAffineTransform *)
B32_THUNK(_CTFontCreateWithName) {
    auto name = ref<CFStringRef>(c);
    CGFloat size = cgf(c);
    CGAffineTransform t;
    bool has = transformAt(c, c.args.ptr(), t);
    c.ret(guest(c, CTFontCreateWithName(name, size, has ? &t : nullptr)));
}
// CTFontRef CTFontCreateCopyWithAttributes(CTFontRef, CGFloat size, const CGAffineTransform *,
//     CTFontDescriptorRef)
B32_THUNK(_CTFontCreateCopyWithAttributes) {
    auto font = ref<CTFontRef>(c);
    CGFloat size = cgf(c);
    CGAffineTransform t;
    bool has = transformAt(c, c.args.ptr(), t);
    auto descriptor = ref<CTFontDescriptorRef>(c);
    c.ret(guest(c, CTFontCreateCopyWithAttributes(font, size, has ? &t : nullptr, descriptor)));
}
B32_THUNK(_CTFontCopyFullName) { c.ret(guest(c, CTFontCopyFullName(ref<CTFontRef>(c)))); }
B32_THUNK(_CTFontGetSize) { c.retF32(float(CTFontGetSize(ref<CTFontRef>(c)))); }
B32_THUNK(_CTFontGetAscent) { c.retF32(float(CTFontGetAscent(ref<CTFontRef>(c)))); }
B32_THUNK(_CTFontGetDescent) { c.retF32(float(CTFontGetDescent(ref<CTFontRef>(c)))); }

// CGRect CTFontGetBoundingRectsForGlyphs(CTFontRef, CTFontOrientation, const CGGlyph *,
//     CGRect *boundingRects, CFIndex count): the overall rect through r0.
B32_THUNK(_CTFontGetBoundingRectsForGlyphs) {
    GuestAddr out = c.args.ptr();
    auto font = ref<CTFontRef>(c);
    auto orientation = CTFontOrientation(c.args.u32());
    GuestAddr glyphs = c.args.ptr(), rects = c.args.ptr();
    CFIndex count = c.args.i32();
    std::vector<CGRect> host(rects ? size_t(count) : 0);
    CGRect all = CTFontGetBoundingRectsForGlyphs(font, orientation, c.mem.ptr<CGGlyph>(glyphs),
                                                 rects ? host.data() : nullptr, count);
    auto writeRect = [&](GuestAddr p, CGRect r) {
        const float f[4] = {float(r.origin.x), float(r.origin.y), float(r.size.width), float(r.size.height)};
        c.mem.copyIn(p, f, sizeof f);
    };
    for (size_t i = 0; i < host.size(); i++) writeRect(rects + uint32_t(i) * 16, host[i]);
    writeRect(out, all);
}

// void CTFontDrawGlyphs(CTFontRef, const CGGlyph *, const CGPoint *, size_t count, CGContextRef)
B32_THUNK(_CTFontDrawGlyphs) {
    auto font = ref<CTFontRef>(c);
    GuestAddr glyphs = c.args.ptr(), positions = c.args.ptr();
    size_t count = c.args.u32();
    auto context = ref<CGContextRef>(c);
    std::vector<CGPoint> points(count);
    const float *f = c.mem.ptr<float>(positions);
    for (size_t i = 0; i < count; i++) points[i] = CGPointMake(f[i * 2], f[i * 2 + 1]);
    CTFontDrawGlyphs(font, c.mem.ptr<CGGlyph>(glyphs), points.data(), count, context);
}

// bool CTFontManagerRegisterFontsForURL(CFURLRef, CTFontManagerScope, CFErrorRef *)
B32_THUNK(_CTFontManagerRegisterFontsForURL) {
    auto url = ref<CFURLRef>(c);
    auto scope = CTFontManagerScope(c.args.u32());
    GuestAddr errorOut = c.args.ptr();
    CFErrorRef error = nullptr;
    bool ok = CTFontManagerRegisterFontsForURL(url, scope, errorOut ? &error : nullptr);
    // Registering a font the process already has is fine.
    if (!ok && error && CFErrorGetCode(error) == kCTFontManagerErrorAlreadyRegistered) {
        CFRelease(error);
        error = nullptr;
        ok = true;
    }
    if (errorOut) c.mem.write<uint32_t>(errorOut, guest(c, error));
    c.ret(ok);
}

// --- paragraph styles ----------------------------------------------------------------------

// CTParagraphStyleRef CTParagraphStyleCreate(const CTParagraphStyleSetting *, size_t count):
// settings are { spec, size_t valueSize, const void *value } (three words), and
// each value is converted by its specifier's type.
B32_THUNK(_CTParagraphStyleCreate) {
    GuestAddr settings = c.args.ptr();
    size_t count = c.args.u32();
    std::vector<CTParagraphStyleSetting> host(count);
    std::vector<CGFloat> floats(count);
    std::vector<id> objects(count);
    std::vector<CTLineBoundsOptions> options(count);
    for (size_t i = 0; i < count; i++) {
        GuestAddr s = settings + uint32_t(i) * 12;
        auto spec = CTParagraphStyleSpecifier(c.mem.read<uint32_t>(s));
        uint32_t size = c.mem.read<uint32_t>(s + 4);
        GuestAddr value = c.mem.read<uint32_t>(s + 8);
        host[i].spec = spec;
        switch (spec) {
        case kCTParagraphStyleSpecifierAlignment:
        case kCTParagraphStyleSpecifierLineBreakMode:
        case kCTParagraphStyleSpecifierBaseWritingDirection:
            host[i].valueSize = size;  // one byte, the same on both sides
            host[i].value = c.mem.ptr<void>(value);
            break;
        case kCTParagraphStyleSpecifierTabStops:
            objects[i] = c.rt.bridge().toHost(c.mem.read<uint32_t>(value));
            host[i].valueSize = sizeof(CFArrayRef);
            host[i].value = &objects[i];
            break;
        case kCTParagraphStyleSpecifierLineBoundsOptions:
            options[i] = c.mem.read<uint32_t>(value);
            host[i].valueSize = sizeof(CTLineBoundsOptions);
            host[i].value = &options[i];
            break;
        default:  // the rest are CGFloats
            floats[i] = c.mem.read<float>(value);
            host[i].valueSize = sizeof(CGFloat);
            host[i].value = &floats[i];
            break;
        }
    }
    c.ret(guest(c, CTParagraphStyleCreate(host.data(), count)));
}

// --- run delegates: the guest's callbacks behind host ones -------------------------------------

namespace {
// CTRunDelegateCallbacks { CFIndex version; dealloc; getAscent; getDescent; getWidth }:
// five words, the last four guest functions taking the refCon.
struct GuestRunDelegate {
    GuestAddr dealloc, ascent, descent, width, refCon;
};
CGFloat callFloat(GuestAddr fn, GuestAddr refCon) {
    if (!fn) return 0;
    uint32_t bits = uint32_t(Runtime::threadCpu().call(fn, {refCon}));
    float f;
    std::memcpy(&f, &bits, 4);
    return f;
}
void runDelegateDealloc(void *p) {
    auto *d = static_cast<GuestRunDelegate *>(p);
    if (d->dealloc) Runtime::threadCpu().call(d->dealloc, {d->refCon});
    delete d;
}
CGFloat runDelegateAscent(void *p) { return callFloat(static_cast<GuestRunDelegate *>(p)->ascent, static_cast<GuestRunDelegate *>(p)->refCon); }
CGFloat runDelegateDescent(void *p) { return callFloat(static_cast<GuestRunDelegate *>(p)->descent, static_cast<GuestRunDelegate *>(p)->refCon); }
CGFloat runDelegateWidth(void *p) { return callFloat(static_cast<GuestRunDelegate *>(p)->width, static_cast<GuestRunDelegate *>(p)->refCon); }
}  // namespace

// CTRunDelegateRef CTRunDelegateCreate(const CTRunDelegateCallbacks *, void *refCon)
B32_THUNK(_CTRunDelegateCreate) {
    GuestAddr callbacks = c.args.ptr(), refCon = c.args.ptr();
    auto *d = new GuestRunDelegate{c.mem.read<uint32_t>(callbacks + 4), c.mem.read<uint32_t>(callbacks + 8),
                                   c.mem.read<uint32_t>(callbacks + 12), c.mem.read<uint32_t>(callbacks + 16), refCon};
    CTRunDelegateCallbacks host = {kCTRunDelegateVersion1, runDelegateDealloc, runDelegateAscent, runDelegateDescent,
                                   runDelegateWidth};
    CTRunDelegateRef delegate = CTRunDelegateCreate(&host, d);
    if (!delegate) delete d;
    c.ret(guest(c, delegate));
}
B32_THUNK(_CTRunDelegateGetRefCon) {
    auto *d = static_cast<GuestRunDelegate *>(CTRunDelegateGetRefCon(ref<CTRunDelegateRef>(c)));
    c.ret(d ? d->refCon : 0);
}

// --- framesetters and frames -----------------------------------------------------------------

B32_THUNK(_CTFramesetterCreateWithAttributedString) {
    c.ret(guest(c, CTFramesetterCreateWithAttributedString(ref<CFAttributedStringRef>(c))));
}
// CTFrameRef CTFramesetterCreateFrame(CTFramesetterRef, CFRange, CGPathRef, CFDictionaryRef)
B32_THUNK(_CTFramesetterCreateFrame) {
    auto framesetter = ref<CTFramesetterRef>(c);
    CFRange r = range(c);
    auto path = ref<CGPathRef>(c);
    c.ret(guest(c, CTFramesetterCreateFrame(framesetter, r, path, ref<CFDictionaryRef>(c))));
}
// CGSize CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterRef, CFRange,
//     CFDictionaryRef, CGSize constraints, CFRange *fitRange): the size through r0.
B32_THUNK(_CTFramesetterSuggestFrameSizeWithConstraints) {
    GuestAddr out = c.args.ptr();
    auto framesetter = ref<CTFramesetterRef>(c);
    CFRange r = range(c);
    auto attributes = ref<CFDictionaryRef>(c);
    CGFloat w = cgf(c), h = cgf(c);
    GuestAddr fitOut = c.args.ptr();
    CFRange fit;
    CGSize size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, r, attributes, CGSizeMake(w, h), &fit);
    if (fitOut) writeRange(c, fitOut, fit);
    c.mem.write<float>(out, float(size.width));
    c.mem.write<float>(out + 4, float(size.height));
}
B32_THUNK(_CTFrameGetLines) { c.ret(guest(c, CTFrameGetLines(ref<CTFrameRef>(c)))); }
// void CTFrameGetLineOrigins(CTFrameRef, CFRange, CGPoint origins[])
B32_THUNK(_CTFrameGetLineOrigins) {
    auto frame = ref<CTFrameRef>(c);
    CFRange r = range(c);
    GuestAddr out = c.args.ptr();
    CFIndex total = CFArrayGetCount(CTFrameGetLines(frame));
    CFIndex count = r.length ? r.length : total - r.location;
    if (count <= 0) return;
    std::vector<CGPoint> origins(static_cast<size_t>(count));
    CTFrameGetLineOrigins(frame, CFRangeMake(r.location, count), origins.data());
    writePoints(c, out, origins.data(), origins.size());
}
B32_THUNK(_CTFrameDraw) {
    auto frame = ref<CTFrameRef>(c);
    CTFrameDraw(frame, ref<CGContextRef>(c));
}

// --- lines ---------------------------------------------------------------------------------

B32_THUNK(_CTLineCreateWithAttributedString) {
    c.ret(guest(c, CTLineCreateWithAttributedString(ref<CFAttributedStringRef>(c))));
}
// CTLineRef CTLineCreateTruncatedLine(CTLineRef, double width, CTLineTruncationType, CTLineRef token)
B32_THUNK(_CTLineCreateTruncatedLine) {
    auto line = ref<CTLineRef>(c);
    double width = c.args.f64();
    auto type = CTLineTruncationType(c.args.u32());
    c.ret(guest(c, CTLineCreateTruncatedLine(line, width, type, ref<CTLineRef>(c))));
}
B32_THUNK(_CTLineDraw) {
    auto line = ref<CTLineRef>(c);
    CTLineDraw(line, ref<CGContextRef>(c));
}
B32_THUNK(_CTLineGetGlyphCount) { c.ret(uint32_t(CTLineGetGlyphCount(ref<CTLineRef>(c)))); }
B32_THUNK(_CTLineGetGlyphRuns) { c.ret(guest(c, CTLineGetGlyphRuns(ref<CTLineRef>(c)))); }
// CFRange CTLineGetStringRange(CTLineRef): through r0.
B32_THUNK(_CTLineGetStringRange) {
    GuestAddr out = c.args.ptr();
    writeRange(c, out, CTLineGetStringRange(ref<CTLineRef>(c)));
}
// double CTLineGetTypographicBounds(CTLineRef, CGFloat *ascent, CGFloat *descent, CGFloat *leading)
B32_THUNK(_CTLineGetTypographicBounds) {
    auto line = ref<CTLineRef>(c);
    GuestAddr ascentOut = c.args.ptr(), descentOut = c.args.ptr(), leadingOut = c.args.ptr();
    CGFloat ascent, descent, leading;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    writeFloat(c, ascentOut, ascent);
    writeFloat(c, descentOut, descent);
    writeFloat(c, leadingOut, leading);
    c.retF64(width);
}
// CGFloat CTLineGetOffsetForStringIndex(CTLineRef, CFIndex, CGFloat *secondaryOffset)
B32_THUNK(_CTLineGetOffsetForStringIndex) {
    auto line = ref<CTLineRef>(c);
    CFIndex index = c.args.i32();
    GuestAddr secondaryOut = c.args.ptr();
    CGFloat secondary;
    CGFloat offset = CTLineGetOffsetForStringIndex(line, index, &secondary);
    writeFloat(c, secondaryOut, secondary);
    c.retF32(float(offset));
}
// CFIndex CTLineGetStringIndexForPosition(CTLineRef, CGPoint)
B32_THUNK(_CTLineGetStringIndexForPosition) {
    auto line = ref<CTLineRef>(c);
    CGFloat x = cgf(c), y = cgf(c);
    c.ret(uint32_t(CTLineGetStringIndexForPosition(line, CGPointMake(x, y))));
}

// --- runs ----------------------------------------------------------------------------------

B32_THUNK(_CTRunGetGlyphCount) { c.ret(uint32_t(CTRunGetGlyphCount(ref<CTRunRef>(c)))); }
B32_THUNK(_CTRunGetAttributes) { c.ret(guest(c, CTRunGetAttributes(ref<CTRunRef>(c)))); }
// The direct pointers are host memory; NULL tells callers to copy with
// CTRunGetGlyphs/CTRunGetPositions instead, as the API allows.
B32_THUNK(_CTRunGetGlyphsPtr) { c.ret(0); }
B32_THUNK(_CTRunGetPositionsPtr) { c.ret(0); }
// void CTRunGetGlyphs(CTRunRef, CFRange, CGGlyph buffer[]): 16-bit glyphs on both sides.
B32_THUNK(_CTRunGetGlyphs) {
    auto run = ref<CTRunRef>(c);
    CFRange r = range(c);
    GuestAddr out = c.args.ptr();
    CTRunGetGlyphs(run, r, c.mem.ptr<CGGlyph>(out));
}
// void CTRunGetPositions(CTRunRef, CFRange, CGPoint buffer[])
B32_THUNK(_CTRunGetPositions) {
    auto run = ref<CTRunRef>(c);
    CFRange r = range(c);
    GuestAddr out = c.args.ptr();
    CFIndex count = r.length ? r.length : CTRunGetGlyphCount(run) - r.location;
    if (count <= 0) return;
    std::vector<CGPoint> points(static_cast<size_t>(count));
    CTRunGetPositions(run, CFRangeMake(r.location, count), points.data());
    writePoints(c, out, points.data(), points.size());
}
B32_THUNK(_CTRunGetStringRange) {
    GuestAddr out = c.args.ptr();
    writeRange(c, out, CTRunGetStringRange(ref<CTRunRef>(c)));
}
// double CTRunGetTypographicBounds(CTRunRef, CFRange, CGFloat *ascent, CGFloat *descent, CGFloat *leading)
B32_THUNK(_CTRunGetTypographicBounds) {
    auto run = ref<CTRunRef>(c);
    CFRange r = range(c);
    GuestAddr ascentOut = c.args.ptr(), descentOut = c.args.ptr(), leadingOut = c.args.ptr();
    CGFloat ascent, descent, leading;
    double width = CTRunGetTypographicBounds(run, r, &ascent, &descent, &leading);
    writeFloat(c, ascentOut, ascent);
    writeFloat(c, descentOut, descent);
    writeFloat(c, leadingOut, leading);
    c.retF64(width);
}

// bool CTFontGetGlyphsForCharacters(CTFontRef, const UniChar[], CGGlyph[], CFIndex): 16-bit on both sides.
B32_THUNK(_CTFontGetGlyphsForCharacters) {
    auto font = ref<CTFontRef>(c);
    GuestAddr chars = c.args.ptr(), glyphs = c.args.ptr();
    CFIndex count = c.args.i32();
    c.ret(CTFontGetGlyphsForCharacters(font, c.mem.ptr<UniChar>(chars), c.mem.ptr<CGGlyph>(glyphs), count));
}
B32_THUNK(_CTFontManagerUnregisterFontsForURL) {
    auto url = ref<CFURLRef>(c);
    auto scope = CTFontManagerScope(c.args.u32());
    GuestAddr errorOut = c.args.ptr();
    if (errorOut) c.mem.write<uint32_t>(errorOut, 0);
    c.ret(CTFontManagerUnregisterFontsForURL(url, scope, nullptr));
}
// void CTRunDraw(CTRunRef, CGContextRef, CFRange)
B32_THUNK(_CTRunDraw) {
    auto run = ref<CTRunRef>(c);
    auto context = ref<CGContextRef>(c);
    CTRunDraw(run, context, range(c));
}
B32_THUNK(_CTTypesetterCreateWithAttributedString) {
    c.ret(guest(c, CTTypesetterCreateWithAttributedString(ref<CFAttributedStringRef>(c))));
}
// CFIndex CTTypesetterSuggestLineBreak(CTTypesetterRef, CFIndex start, double width)
B32_THUNK(_CTTypesetterSuggestLineBreak) {
    auto typesetter = ref<CTTypesetterRef>(c);
    CFIndex start = c.args.i32();
    c.ret(uint32_t(CTTypesetterSuggestLineBreak(typesetter, start, c.args.f64())));
}
