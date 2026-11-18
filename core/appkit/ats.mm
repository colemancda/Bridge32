// ATS, the Font Manager's numbers for fonts, and ATSUI: how Carbon programs found fonts and drew text with
// them. All of it is here on CoreText. The host still exports ATS's lookups, but they hang over a name they
// don't know, the fonts a program activates from memory never show up in them, and ATSUI's styles take none
// of their fonts. So fonts get numbers of their own here, with ATSFontRef and FMFont the same number, and
// ATSFontFamilyRef and FMFontFamily too. A style is a font, a size and QuickDraw's style bits; a layout draws
// its text with CoreText into the current QuickDraw port's pixels, where the port's pen is, in its color.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/appkit/Fonts.h"
#include "core/appkit/QuickDraw.h"
#include "core/objc/Bridge.h"
#include "core/thunks/Thunks.h"

#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

using namespace b32;

namespace {

constexpr int32_t kNoErr = 0, kParamErr = -50, kInvalidFamilyStatus = -981, kInvalidLayoutStatus = -8790,
                  kInvalidStyleStatus = -8791, kInvalidFontStatus = -8796;
constexpr uint32_t kFromTextBeginning = 0xFFFFFFFF, kToTextEnd = 0xFFFFFFFF, kUsePenLocation = 0xFFFFFFFF;

// --- the fonts --------------------------------------------------------------------------------------------

struct Font {
    std::string postScript, family, full;
    CTFontDescriptorRef descriptor;  // held
    bool bold, italic;
    uint32_t familyID;
};
// Font numbers start above anything a program might take for one of QuickDraw's own families, and family
// numbers stay within the short an FMFontFamily is.
constexpr uint32_t kFirstFont = 0x4000, kFirstFamily = 0x400;

std::recursive_mutex fontsLock;
std::vector<Font> fonts;
std::unordered_map<std::string, uint32_t> fontByPostScript;
std::vector<std::string> families;
std::unordered_map<std::string, uint32_t> familyByName;
std::unordered_map<uint32_t, std::vector<uint32_t>> familyFonts;

std::string lowercase(NSString *s) { return s.lowercaseString.UTF8String ?: ""; }
std::string utf8(NSString *s) { return s.UTF8String ?: ""; }

const Font *fontOf(uint32_t id) {
    return id >= kFirstFont && id - kFirstFont < fonts.size() ? &fonts[id - kFirstFont] : nullptr;
}
bool isFamily(uint32_t id) { return id >= kFirstFamily && id - kFirstFamily < families.size(); }

uint32_t familyFor(NSString *name) {
    std::string key = lowercase(name);
    if (auto it = familyByName.find(key); it != familyByName.end()) return it->second;
    uint32_t id = kFirstFamily + uint32_t(families.size());
    families.push_back(utf8(name));
    familyByName[key] = id;
    return id;
}

// A face's number, given it the first time it is seen.
uint32_t addFont(CTFontDescriptorRef descriptor) {
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, 12, nullptr);
    if (!font) return 0;
    NSString *postScript = [(NSString *)CTFontCopyPostScriptName(font) autorelease];
    NSString *family = [(NSString *)CTFontCopyFamilyName(font) autorelease];
    NSString *full = [(NSString *)CTFontCopyFullName(font) autorelease];
    CTFontSymbolicTraits traits = CTFontGetSymbolicTraits(font);
    CFRelease(font);
    std::string key = lowercase(postScript ?: @"");
    if (key.empty()) return 0;
    if (auto it = fontByPostScript.find(key); it != fontByPostScript.end()) return it->second;
    uint32_t id = kFirstFont + uint32_t(fonts.size());
    uint32_t familyID = familyFor(family ?: postScript);
    CFRetain(descriptor);
    fonts.push_back({utf8(postScript), utf8(family ?: postScript), utf8(full ?: postScript), descriptor,
                     (traits & kCTFontBoldTrait) != 0, (traits & kCTFontItalicTrait) != 0, familyID});
    fontByPostScript[key] = id;
    familyFonts[familyID].push_back(id);
    return id;
}

// The system's faces whose name (PostScript, full or family) is this one; CoreText would otherwise answer
// with whatever it thinks closest, which a program asking for a font by name doesn't want.
void addSystemFaces(NSString *name, bool family) {
    NSDictionary *attributes = @{(family ? (id)kCTFontFamilyNameAttribute : (id)kCTFontNameAttribute) : name};
    CTFontDescriptorRef wanted = CTFontDescriptorCreateWithAttributes((CFDictionaryRef)attributes);
    NSSet *mandatory = [NSSet setWithObject:(family ? (id)kCTFontFamilyNameAttribute : (id)kCTFontNameAttribute)];
    NSArray *matches = [(NSArray *)CTFontDescriptorCreateMatchingFontDescriptors(wanted, (CFSetRef)mandatory) autorelease];
    CFRelease(wanted);
    std::string key = lowercase(name);
    for (id match in matches) {
        CTFontRef font = CTFontCreateWithFontDescriptor((CTFontDescriptorRef)match, 12, nullptr);
        bool same = family ? lowercase([(NSString *)CTFontCopyFamilyName(font) autorelease]) == key
                           : lowercase([(NSString *)CTFontCopyPostScriptName(font) autorelease]) == key ||
                                 lowercase([(NSString *)CTFontCopyFullName(font) autorelease]) == key;
        CFRelease(font);
        if (same) addFont((CTFontDescriptorRef)match);
    }
}

// ATSFontFindFromName's answer: a face by its full or PostScript name, or a family's regular face. 0 when
// there is none.
uint32_t findFont(NSString *name) {
    std::string key = lowercase(name);
    auto known = [&]() -> uint32_t {
        for (size_t i = 0; i < fonts.size(); i++)
            if (lowercase(@(fonts[i].full.c_str())) == key || lowercase(@(fonts[i].postScript.c_str())) == key) return kFirstFont + uint32_t(i);
        if (auto it = familyByName.find(key); it != familyByName.end()) {
            const std::vector<uint32_t> &faces = familyFonts[it->second];
            for (uint32_t id : faces)
                if (!fontOf(id)->bold && !fontOf(id)->italic) return id;
            if (!faces.empty()) return faces.front();
        }
        return 0;
    };
    if (uint32_t id = known()) return id;
    addSystemFaces(name, false);
    if (uint32_t id = known()) return id;
    addSystemFaces(name, true);
    return known();
}

uint32_t findFamily(NSString *name) {
    std::string key = lowercase(name);
    auto known = [&]() -> uint32_t {
        auto it = familyByName.find(key);
        return it != familyByName.end() && !familyFonts[it->second].empty() ? it->second : 0;
    };
    if (uint32_t id = known()) return id;
    addSystemFaces(name, true);
    return known();
}

// The face of a family closest to QuickDraw style bits (bold 1, italic 2), and the bits it has itself.
uint32_t familyFace(uint32_t family, int16_t style, int16_t *intrinsic) {
    const std::vector<uint32_t> &faces = familyFonts[family];
    bool bold = style & 1, italic = style & 2;
    uint32_t best = 0;
    int bestScore = -1;
    for (uint32_t id : faces) {
        const Font *f = fontOf(id);
        int score = (f->bold == bold ? 2 : 0) + (f->italic == italic ? 1 : 0);
        if (score > bestScore) best = id, bestScore = score;
    }
    if (intrinsic && best) *intrinsic = int16_t((fontOf(best)->bold ? 1 : 0) | (fontOf(best)->italic ? 2 : 0));
    return best;
}

// A face at a size. Bold or italic the face doesn't have itself is what QuickDraw did with it: italic leans
// the glyphs, and bold is drawn heavier (see attributesFor).
CTFontRef copyFace(uint32_t id, double size, bool italic) {
    const Font *f = fontOf(id);
    if (!f) return CTFontCreateUIFontForLanguage(kCTFontUIFontApplication, size, nullptr);
    CGAffineTransform lean = CGAffineTransformMake(1, 0, 0.2, 1, 0, 0);
    return CTFontCreateWithFontDescriptor(f->descriptor, size, italic && !f->italic ? &lean : nullptr);
}

// --- ATSUI's styles and layouts -----------------------------------------------------------------------------

struct TextStyle {
    uint32_t font = 0;
    double size = 12;
    bool bold = false, italic = false, underline = false;
    bool colored = false;
    b32::appkit::QDColor color;
};
struct Run {
    uint32_t offset, length, style;
};
struct Layout {
    GuestAddr text = 0;
    uint32_t offset = 0, length = 0;
    std::vector<Run> runs;
    GuestAddr records = 0;  // the glyph records ATSUDirectGetLayoutDataArrayPtrFromTextLayout hands out
    uint32_t recordCapacity = 0;
};
std::mutex atsuiLock;
std::unordered_map<uint32_t, TextStyle> styles;
std::unordered_map<uint32_t, Layout> layouts;
uint32_t nextStyle = 0x5A000001, nextLayout = 0x5B000001;  // opaque to the guest

// The face a style draws with: the bold or italic face of its family when it asks for one and there is one.
CTFontRef copyStyleFont(const TextStyle &style) {
    std::lock_guard fontsGuard(fontsLock);
    uint32_t id = style.font;
    if (const Font *f = fontOf(id); f && (style.bold || style.italic))
        if (uint32_t face = familyFace(f->familyID, int16_t((style.bold ? 1 : 0) | (style.italic ? 2 : 0)), nullptr)) id = face;
    return copyFace(id, style.size, style.italic);
}
bool styleFaceIsBold(const TextStyle &style) {
    std::lock_guard fontsGuard(fontsLock);
    const Font *f = fontOf(style.font);
    if (!f) return false;
    uint32_t face = familyFace(f->familyID, int16_t((style.bold ? 1 : 0) | (style.italic ? 2 : 0)), nullptr);
    return face && fontOf(face)->bold;
}

NSDictionary *attributesFor(const TextStyle &style) {
    CTFontRef font = copyStyleFont(style);
    NSMutableDictionary *attributes = [NSMutableDictionary dictionaryWithObject:(id)font forKey:(id)kCTFontAttributeName];
    CFRelease(font);
    if (style.colored) {
        CGColorRef color = CGColorCreateSRGB(style.color.red / 65535.0, style.color.green / 65535.0, style.color.blue / 65535.0, 1);
        attributes[(id)kCTForegroundColorAttributeName] = (id)color;
        CGColorRelease(color);
    } else {
        attributes[(id)kCTForegroundColorFromContextAttributeName] = @YES;
    }
    if (style.bold && !styleFaceIsBold(style)) attributes[(id)kCTStrokeWidthAttributeName] = @(-3.0);
    if (style.underline) attributes[(id)kCTUnderlineStyleAttributeName] = @(kCTUnderlineStyleSingle);
    return attributes;
}

// A layout's text from `offset` for `length` characters (ATSUI's "from the beginning" and "to the end"
// included), as CoreText lays it out with the runs' styles.
CTLineRef copyLine(Call &c, const Layout &layout, uint32_t offset, uint32_t length, uint32_t *start = nullptr) {
    uint32_t first = offset == kFromTextBeginning ? layout.offset : offset;
    uint32_t end = layout.offset + layout.length;
    if (first < layout.offset || first > end) first = layout.offset;
    uint32_t count = length == kToTextEnd ? end - first : std::min(length, end - first);
    if (start) *start = first;
    std::vector<uint16_t> chars = layout.text && count ? c.mem.readArray<uint16_t>(layout.text + first * 2, count) : std::vector<uint16_t>();
    NSString *string = [[[NSString alloc] initWithCharacters:chars.data() length:chars.size()] autorelease];
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:string] autorelease];
    for (const Run &run : layout.runs) {
        uint32_t from = std::max(run.offset, first), to = std::min(run.offset + run.length, first + count);
        auto style = styles.find(run.style);
        if (from >= to || style == styles.end()) continue;
        [text setAttributes:attributesFor(style->second) range:NSMakeRange(from - first, to - from)];
    }
    if (layout.runs.empty() && count) {
        TextStyle plain;
        [text setAttributes:attributesFor(plain) range:NSMakeRange(0, count)];
    }
    return CTLineCreateWithAttributedString((CFAttributedStringRef)text);
}

double fixed(uint32_t value) { return int32_t(value) / 65536.0; }

}  // namespace

// --- QuickDraw's names for fonts (Fonts.h) ----------------------------------------------------------------

namespace b32::appkit {

CTFontRef copyQuickDrawFont(int16_t family, int16_t size, int16_t face) {
    double points = size > 0 ? size : 12;
    if (family == 0) return CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, points, nullptr);
    std::lock_guard guard(fontsLock);
    if (family == 1 || !isFamily(uint32_t(family))) return CTFontCreateUIFontForLanguage(kCTFontUIFontApplication, points, nullptr);
    uint32_t id = familyFace(uint32_t(family), face, nullptr);
    return copyFace(id, points, (face & 2) != 0);
}

std::string quickDrawFamilyName(int16_t family) {
    if (family == 0 || family == 1) {
        CTFontRef font = CTFontCreateUIFontForLanguage(family == 0 ? kCTFontUIFontSystem : kCTFontUIFontApplication, 12, nullptr);
        std::string name = utf8([(NSString *)CTFontCopyFamilyName(font) autorelease]);
        CFRelease(font);
        return name;
    }
    std::lock_guard guard(fontsLock);
    return isFamily(uint32_t(family)) ? families[uint32_t(family) - kFirstFamily] : "";
}

}  // namespace b32::appkit

// --- ATS: finding fonts and reading them -------------------------------------------------------------------

// ATSFontRef ATSFontFindFromName(CFStringRef name, ATSOptionFlags), ATSFontFindFromPostScriptName
B32_THUNK(_ATSFontFindFromName) {
    NSString *name = (NSString *)c.rt.bridge().toHost(c.args.ptr());
    c.args.u32();
    if (![name isKindOfClass:[NSString class]]) {
        c.ret(0);
        return;
    }
    std::lock_guard guard(fontsLock);
    c.ret(findFont(name));
}
B32_THUNK(_ATSFontFindFromPostScriptName) {
    NSString *name = (NSString *)c.rt.bridge().toHost(c.args.ptr());
    c.args.u32();
    if (![name isKindOfClass:[NSString class]]) {
        c.ret(0);
        return;
    }
    std::lock_guard guard(fontsLock);
    c.ret(findFont(name));
}
// ATSFontFamilyRef ATSFontFamilyFindFromName(CFStringRef name, ATSOptionFlags)
B32_THUNK(_ATSFontFamilyFindFromName) {
    NSString *name = (NSString *)c.rt.bridge().toHost(c.args.ptr());
    c.args.u32();
    if (![name isKindOfClass:[NSString class]]) {
        c.ret(0);
        return;
    }
    std::lock_guard guard(fontsLock);
    c.ret(findFamily(name));
}
// The Font Manager's numbers are ATS's: FMFontFamily FMGetFontFamilyFromATSFontFamilyRef(ATSFontFamilyRef)
// and back, FMFont FMGetFontFromATSFontRef(ATSFontRef) and back. An unknown family is kInvalidFontFamily (-1),
// an unknown font kInvalidFont (0).
B32_THUNK(_FMGetFontFamilyFromATSFontFamilyRef) {
    uint32_t family = c.args.u32();
    std::lock_guard guard(fontsLock);
    c.ret(isFamily(family) ? family : uint32_t(-1));
}
B32_THUNK(_FMGetATSFontFamilyRefFromFontFamily) {
    int16_t family = int16_t(c.args.u32());
    std::lock_guard guard(fontsLock);
    c.ret(isFamily(uint32_t(family)) ? uint32_t(family) : 0);
}
B32_THUNK(_FMGetFontFromATSFontRef) {
    uint32_t font = c.args.u32();
    std::lock_guard guard(fontsLock);
    c.ret(fontOf(font) ? font : 0);
}
B32_THUNK(_FMGetATSFontRefFromFont) {
    uint32_t font = c.args.u32();
    std::lock_guard guard(fontsLock);
    c.ret(fontOf(font) ? font : 0);
}
// OSStatus FMGetFontFromFontFamilyInstance(FMFontFamily, FMFontStyle, FMFont *font, FMFontStyle *intrinsic):
// the family's face closest to the style, and the style bits that face has itself (the rest are left for
// the caller to make up, as QuickDraw did).
B32_THUNK(_FMGetFontFromFontFamilyInstance) {
    int16_t family = int16_t(c.args.u32()), style = int16_t(c.args.u32());
    GuestAddr fontOut = c.args.ptr(), intrinsicOut = c.args.ptr();
    std::lock_guard guard(fontsLock);
    int16_t intrinsic = 0;
    uint32_t font = isFamily(uint32_t(family)) ? familyFace(uint32_t(family), style, &intrinsic) : 0;
    if (!font) {
        c.ret(uint32_t(kInvalidFamilyStatus));
        return;
    }
    if (fontOut) c.mem.write<uint32_t>(fontOut, font);
    if (intrinsicOut) c.mem.write<int16_t>(intrinsicOut, intrinsic);
    c.ret(kNoErr);
}
// OSStatus FMGetFontFamilyInstanceFromFont(FMFont, FMFontFamily *family, FMFontStyle *style)
B32_THUNK(_FMGetFontFamilyInstanceFromFont) {
    uint32_t font = c.args.u32();
    GuestAddr familyOut = c.args.ptr(), styleOut = c.args.ptr();
    std::lock_guard guard(fontsLock);
    const Font *f = fontOf(font);
    if (!f) {
        c.ret(uint32_t(kParamErr));
        return;
    }
    if (familyOut) c.mem.write<int16_t>(familyOut, int16_t(f->familyID));
    if (styleOut) c.mem.write<int16_t>(styleOut, int16_t((f->bold ? 1 : 0) | (f->italic ? 2 : 0)));
    c.ret(kNoErr);
}

// OSStatus ATSFontGetTable(ATSFontRef, FourCharCode tag, ByteOffset offset, ByteCount size, void *buffer,
//                          ByteCount *actual): with no buffer, the table's size.
B32_THUNK(_ATSFontGetTable) {
    uint32_t font = c.args.u32(), tag = c.args.u32(), offset = c.args.u32(), size = c.args.u32();
    GuestAddr buffer = c.args.ptr(), actualOut = c.args.ptr();
    CFDataRef table = nullptr;
    {
        std::lock_guard guard(fontsLock);
        if (!fontOf(font)) {
            c.ret(uint32_t(kParamErr));
            return;
        }
        CTFontRef face = copyFace(font, 12, false);
        table = CTFontCopyTable(face, tag, kCTFontTableOptionNoOptions);
        CFRelease(face);
    }
    if (!table) {
        if (actualOut) c.mem.write<uint32_t>(actualOut, 0);
        c.ret(uint32_t(kParamErr));
        return;
    }
    uint32_t length = uint32_t(CFDataGetLength(table)), copied = length;
    if (buffer && size) {
        copied = offset < length ? std::min(size, length - offset) : 0;
        if (copied) c.mem.copyIn(buffer, CFDataGetBytePtr(table) + offset, copied);
    }
    CFRelease(table);
    if (actualOut) c.mem.write<uint32_t>(actualOut, copied);
    c.ret(kNoErr);
}

// OSStatus ATSFontGetHorizontalMetrics(ATSFontRef, ATSOptionFlags, ATSFontMetrics *): in ems, a 32-bit
// program's record being a version and fourteen floats (ascent, descent below zero, leading, the average
// and widest advances, the least side bearings, stem width and height, cap and x heights, the italic angle,
// and the underline's position and thickness).
B32_THUNK(_ATSFontGetHorizontalMetrics) {
    uint32_t font = c.args.u32();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    CTFontRef face;
    {
        std::lock_guard guard(fontsLock);
        if (!fontOf(font)) {
            c.ret(uint32_t(kParamErr));
            return;
        }
        face = copyFace(font, 1, false);
    }
    // The advances of the letters, for the average and widest.
    UniChar letters[52];
    for (int i = 0; i < 26; i++) letters[i] = UniChar('A' + i), letters[26 + i] = UniChar('a' + i);
    CGGlyph glyphs[52];
    CGSize advances[52];
    CTFontGetGlyphsForCharacters(face, letters, glyphs, 52);
    CTFontGetAdvancesForGlyphs(face, kCTFontOrientationHorizontal, glyphs, advances, 52);
    double total = 0, widest = 0;
    for (const CGSize &a : advances) {
        total += a.width;
        widest = std::max(widest, double(a.width));
    }
    CGRect box = CTFontGetBoundingBox(face);
    const float values[14] = {float(CTFontGetAscent(face)), float(-CTFontGetDescent(face)), float(CTFontGetLeading(face)),
                              float(total / 52), float(std::max(widest, double(box.size.width))), float(box.origin.x), 0, 0, 0,
                              float(CTFontGetCapHeight(face)), float(CTFontGetXHeight(face)), float(CTFontGetSlantAngle(face)),
                              float(CTFontGetUnderlinePosition(face)), float(CTFontGetUnderlineThickness(face))};
    CFRelease(face);
    if (out) {
        c.mem.write<uint32_t>(out, 0);
        c.mem.writeArray<float>(out + 4, values, 14);
    }
    c.ret(kNoErr);
}

// --- fonts a program brings: activated from memory ---------------------------------------------------------

namespace {
// A container's faces, by the numbers they were given.
std::unordered_map<uint32_t, std::vector<uint32_t>> memoryContainers;
uint32_t nextMemoryContainer = 0x61000001;  // the file containers (carbon_files.mm) are 0x60000001 on
}  // namespace
// OSStatus ATSFontActivateFromMemory(LogicalAddress data, ByteCount length, ATSFontContext, ATSFontFormat,
//                                    void *reserved, ATSOptionFlags, ATSFontContainerRef *container):
// the faces are this process's, findable by name before the system's.
B32_THUNK(_ATSFontActivateFromMemory) {
    GuestAddr data = c.args.ptr();
    uint32_t length = c.args.u32();
    c.args.u32();
    c.args.u32();
    c.args.ptr();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    if (!data || !length) {
        c.ret(uint32_t(kParamErr));
        return;
    }
    NSData *bytes = [NSData dataWithBytes:c.mem.ptr<uint8_t>(data) length:length];
    NSArray *descriptors = [(NSArray *)CTFontManagerCreateFontDescriptorsFromData((CFDataRef)bytes) autorelease];
    std::vector<uint32_t> faces;
    {
        std::lock_guard guard(fontsLock);
        for (id descriptor in descriptors)
            if (uint32_t id = addFont((CTFontDescriptorRef)descriptor)) faces.push_back(id);
    }
    if (faces.empty()) {
        c.ret(uint32_t(kParamErr));
        return;
    }
    uint32_t container;
    {
        std::lock_guard guard(fontsLock);
        container = nextMemoryContainer++;
        memoryContainers[container] = faces;
    }
    if (out) c.mem.write<uint32_t>(out, container);
    c.ret(kNoErr);
}
// OSStatus ATSFontFindFromContainer(ATSFontContainerRef, ATSOptionFlags, ItemCount count, ATSFontRef *fonts,
//                                   ItemCount *found): with no array, how many there are.
B32_THUNK(_ATSFontFindFromContainer) {
    uint32_t container = c.args.u32();
    c.args.u32();
    uint32_t count = c.args.u32();
    GuestAddr array = c.args.ptr(), foundOut = c.args.ptr();
    std::lock_guard guard(fontsLock);
    auto it = memoryContainers.find(container);
    if (it == memoryContainers.end()) {
        if (foundOut) c.mem.write<uint32_t>(foundOut, 0);
        c.ret(uint32_t(kParamErr));
        return;
    }
    uint32_t found = uint32_t(it->second.size());
    if (array && count) {
        found = std::min(found, count);
        for (uint32_t i = 0; i < found; i++) c.mem.write<uint32_t>(array + i * 4, it->second[i]);
    }
    if (foundOut) c.mem.write<uint32_t>(foundOut, found);
    c.ret(kNoErr);
}

// --- ATSUI: styles --------------------------------------------------------------------------------------------

// OSStatus ATSUCreateStyle(ATSUStyle *), ATSUDisposeStyle(ATSUStyle)
B32_THUNK(_ATSUCreateStyle) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(atsuiLock);
    uint32_t style = nextStyle++;
    styles[style] = TextStyle();
    if (out) c.mem.write<uint32_t>(out, style);
    c.ret(kNoErr);
}
B32_THUNK(_ATSUDisposeStyle) {
    uint32_t style = c.args.u32();
    std::lock_guard guard(atsuiLock);
    c.ret(styles.erase(style) ? kNoErr : uint32_t(kInvalidStyleStatus));
}
// OSStatus ATSUSetAttributes(ATSUStyle, ItemCount, const ATSUAttributeTag *tags, const ByteCount *sizes,
//                            const ATSUAttributeValuePtr *values): the font (261), size (262, Fixed),
// QuickDraw's bold, italic and underline (256 to 258, Booleans) and color (263, an RGBColor) are kept;
// the rest are accepted and have no effect.
B32_THUNK(_ATSUSetAttributes) {
    uint32_t handle = c.args.u32(), count = c.args.u32();
    GuestAddr tags = c.args.ptr(), sizes = c.args.ptr(), values = c.args.ptr();
    std::lock_guard guard(atsuiLock);
    auto it = styles.find(handle);
    if (it == styles.end()) {
        c.ret(uint32_t(kInvalidStyleStatus));
        return;
    }
    TextStyle &style = it->second;
    int32_t status = kNoErr;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t tag = c.mem.read<uint32_t>(tags + i * 4);
        GuestAddr value = c.mem.read<uint32_t>(values + i * 4);
        (void)sizes;
        if (!value) continue;
        switch (tag) {
        case 261: {
            uint32_t font = c.mem.read<uint32_t>(value);
            std::lock_guard fontsGuard(fontsLock);
            if (fontOf(font)) style.font = font;
            else status = kInvalidFontStatus;
            break;
        }
        case 262: style.size = std::max(fixed(c.mem.read<uint32_t>(value)), 1.0); break;
        case 256: style.bold = c.mem.read<uint8_t>(value) != 0; break;
        case 257: style.italic = c.mem.read<uint8_t>(value) != 0; break;
        case 258: style.underline = c.mem.read<uint8_t>(value) != 0; break;
        case 263:
            style.colored = true;
            style.color = {c.mem.read<uint16_t>(value), c.mem.read<uint16_t>(value + 2), c.mem.read<uint16_t>(value + 4)};
            break;
        default: break;
        }
    }
    c.ret(uint32_t(status));
}

// --- ATSUI: layouts -------------------------------------------------------------------------------------------

// OSStatus ATSUCreateTextLayout(ATSUTextLayout *), ATSUDisposeTextLayout(ATSUTextLayout)
B32_THUNK(_ATSUCreateTextLayout) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(atsuiLock);
    uint32_t layout = nextLayout++;
    layouts[layout] = Layout();
    if (out) c.mem.write<uint32_t>(out, layout);
    c.ret(kNoErr);
}
B32_THUNK(_ATSUDisposeTextLayout) {
    uint32_t handle = c.args.u32();
    std::lock_guard guard(atsuiLock);
    auto it = layouts.find(handle);
    if (it == layouts.end()) {
        c.ret(uint32_t(kInvalidLayoutStatus));
        return;
    }
    if (it->second.records) c.heap.free(it->second.records);
    layouts.erase(it);
    c.ret(kNoErr);
}
// OSStatus ATSUSetTextPointerLocation(ATSUTextLayout, ConstUniCharArrayPtr text, UniCharArrayOffset offset,
//                                     UniCharCount length, UniCharCount total): the text stays the caller's,
// read each time it is laid out.
B32_THUNK(_ATSUSetTextPointerLocation) {
    uint32_t handle = c.args.u32();
    GuestAddr text = c.args.ptr();
    uint32_t offset = c.args.u32(), length = c.args.u32(), total = c.args.u32();
    std::lock_guard guard(atsuiLock);
    auto it = layouts.find(handle);
    if (it == layouts.end()) {
        c.ret(uint32_t(kInvalidLayoutStatus));
        return;
    }
    Layout &layout = it->second;
    layout.text = text;
    layout.offset = offset == kFromTextBeginning ? 0 : std::min(offset, total);
    layout.length = length == kToTextEnd ? total - layout.offset : std::min(length, total - layout.offset);
    layout.runs.clear();
    c.ret(kNoErr);
}
// OSStatus ATSUSetRunStyle(ATSUTextLayout, ATSUStyle, UniCharArrayOffset, UniCharCount): a later run over the
// same characters takes them.
B32_THUNK(_ATSUSetRunStyle) {
    uint32_t handle = c.args.u32(), style = c.args.u32(), offset = c.args.u32(), length = c.args.u32();
    std::lock_guard guard(atsuiLock);
    auto it = layouts.find(handle);
    if (it == layouts.end()) {
        c.ret(uint32_t(kInvalidLayoutStatus));
        return;
    }
    if (!styles.count(style)) {
        c.ret(uint32_t(kInvalidStyleStatus));
        return;
    }
    Layout &layout = it->second;
    uint32_t first = offset == kFromTextBeginning ? layout.offset : offset;
    uint32_t count = length == kToTextEnd ? layout.offset + layout.length - std::min(first, layout.offset + layout.length) : length;
    std::erase_if(layout.runs, [&](const Run &r) { return r.offset >= first && r.offset + r.length <= first + count; });
    layout.runs.push_back({first, count, style});
    c.ret(kNoErr);
}

// OSStatus ATSUMeasureTextImage(ATSUTextLayout, UniCharArrayOffset, UniCharCount, ATSUTextMeasurement x,
//                               ATSUTextMeasurement y, Rect *): the ink's bounds drawn at (x, y), in QuickDraw's
// coordinates (down from the top), rounded out to whole pixels. Nothing to ink is an empty rect.
B32_THUNK(_ATSUMeasureTextImage) {
    uint32_t handle = c.args.u32(), offset = c.args.u32(), length = c.args.u32();
    double x = fixed(c.args.u32()), y = fixed(c.args.u32());
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(atsuiLock);
    auto it = layouts.find(handle);
    if (it == layouts.end()) {
        c.ret(uint32_t(kInvalidLayoutStatus));
        return;
    }
    CTLineRef line = copyLine(c, it->second, offset, length);
    CGRect ink = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    CFRelease(line);
    int16_t rect[4] = {0, 0, 0, 0};
    if (!CGRectIsEmpty(ink) && !CGRectIsNull(ink)) {
        rect[0] = int16_t(std::floor(y - CGRectGetMaxY(ink)));
        rect[1] = int16_t(std::floor(x + CGRectGetMinX(ink)));
        rect[2] = int16_t(std::ceil(y - CGRectGetMinY(ink)));
        rect[3] = int16_t(std::ceil(x + CGRectGetMaxX(ink)));
    }
    if (out) c.mem.writeArray<int16_t>(out, rect, 4);
    c.ret(kNoErr);
}

// OSStatus ATSUDirectGetLayoutDataArrayPtrFromTextLayout(ATSUTextLayout, UniCharArrayOffset line,
//     ATSUDirectDataSelector, void **data, ItemCount *count): the glyph records (selector 100), one an
// ATSLayoutRecord of 16 bytes (glyph 0, flags 4, the character's byte offset in the line 8, the glyph's
// position as a Fixed 12), and a terminator after the last. The array is the layout's until it is laid out
// again.
B32_THUNK(_ATSUDirectGetLayoutDataArrayPtrFromTextLayout) {
    uint32_t handle = c.args.u32(), lineOffset = c.args.u32(), selector = c.args.u32();
    GuestAddr dataOut = c.args.ptr(), countOut = c.args.ptr();
    constexpr uint32_t kLayoutRecords = 100, kRecordSize = 16, kTerminator = 0x00080000, kWhiteSpace = 0x00040000;
    std::lock_guard guard(atsuiLock);
    auto it = layouts.find(handle);
    if (it == layouts.end()) {
        c.ret(uint32_t(kInvalidLayoutStatus));
        return;
    }
    if (selector != kLayoutRecords) {
        if (dataOut) c.mem.write<uint32_t>(dataOut, 0);
        if (countOut) c.mem.write<uint32_t>(countOut, 0);
        c.ret(uint32_t(kParamErr));
        return;
    }
    Layout &layout = it->second;
    uint32_t start = 0;
    CTLineRef line = copyLine(c, layout, lineOffset, kToTextEnd, &start);
    struct Record {
        uint16_t glyph;
        uint32_t flags, offset;
        int32_t position;
    };
    std::vector<Record> records;
    std::vector<uint16_t> chars = layout.text ? c.mem.readArray<uint16_t>(layout.text + start * 2, layout.offset + layout.length - start) : std::vector<uint16_t>();
    for (id runObject in (NSArray *)CTLineGetGlyphRuns(line)) {
        CTRunRef run = (CTRunRef)runObject;
        CFIndex count = CTRunGetGlyphCount(run);
        size_t n = size_t(count);
        std::vector<CGGlyph> glyphs(n);
        std::vector<CGPoint> positions(n);
        std::vector<CFIndex> indices(n);
        CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs.data());
        CTRunGetPositions(run, CFRangeMake(0, 0), positions.data());
        CTRunGetStringIndices(run, CFRangeMake(0, 0), indices.data());
        for (CFIndex i = 0; i < count; i++) {
            size_t index = size_t(indices[size_t(i)]);
            bool space = index < chars.size() && (chars[index] == ' ' || chars[index] == '\t' || chars[index] == 0xA0);
            records.push_back({glyphs[size_t(i)], space ? kWhiteSpace : 0, uint32_t(index * 2), int32_t(std::lround(positions[size_t(i)].x * 65536))});
        }
    }
    double width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
    CFRelease(line);
    records.push_back({0xFFFF, kTerminator, uint32_t(chars.size() * 2), int32_t(std::lround(width * 65536))});
    uint32_t bytes = uint32_t(records.size()) * kRecordSize;
    if (bytes > layout.recordCapacity) {
        if (layout.records) c.heap.free(layout.records);
        layout.records = c.heap.calloc(1, bytes);
        layout.recordCapacity = bytes;
    }
    for (size_t i = 0; i < records.size(); i++) {
        GuestAddr r = layout.records + uint32_t(i) * kRecordSize;
        c.mem.write<uint16_t>(r, records[i].glyph);
        c.mem.write<uint16_t>(r + 2, 0);
        c.mem.write<uint32_t>(r + 4, records[i].flags);
        c.mem.write<uint32_t>(r + 8, records[i].offset);
        c.mem.write<int32_t>(r + 12, records[i].position);
    }
    if (dataOut) c.mem.write<uint32_t>(dataOut, layout.records);
    if (countOut) c.mem.write<uint32_t>(countOut, uint32_t(records.size()));
    c.ret(kNoErr);
}
// OSStatus ATSUDirectReleaseLayoutDataArrayPtr(ATSULineRef, ATSUDirectDataSelector, void **): the array stays
// with its layout.
B32_THUNK(_ATSUDirectReleaseLayoutDataArrayPtr) {
    c.args.u32();
    c.args.u32();
    if (GuestAddr data = c.args.ptr()) c.mem.write<uint32_t>(data, 0);
    c.ret(kNoErr);
}

// OSStatus ATSUGlyphGetScreenMetrics(ATSUStyle, ItemCount, const GlyphID *glyphs, ByteCount stride,
//     Boolean forcingAntiAlias, Boolean antiAliasSwitch, ATSGlyphScreenMetrics *): one record of 40 bytes a
// glyph: the advance in whole pixels (x, y), the ink's top left from the glyph's origin with up positive,
// its height and width in pixels, and the bearings either side.
B32_THUNK(_ATSUGlyphGetScreenMetrics) {
    uint32_t handle = c.args.u32(), count = c.args.u32();
    GuestAddr glyphs = c.args.ptr();
    uint32_t stride = c.args.u32();
    c.args.u32();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    CTFontRef font;
    {
        std::lock_guard guard(atsuiLock);
        auto it = styles.find(handle);
        if (it == styles.end()) {
            c.ret(uint32_t(kInvalidStyleStatus));
            return;
        }
        font = copyStyleFont(it->second);
    }
    if (!stride) stride = 2;
    for (uint32_t i = 0; i < count && out; i++) {
        CGGlyph glyph = c.mem.read<uint16_t>(glyphs + i * stride);
        CGSize advance;
        CGRect ink;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &advance, 1);
        CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationHorizontal, &glyph, &ink, 1);
        double left = std::floor(CGRectGetMinX(ink)), top = std::ceil(CGRectGetMaxY(ink));
        double right = std::ceil(CGRectGetMaxX(ink)), bottom = std::floor(CGRectGetMinY(ink));
        if (CGRectIsEmpty(ink)) left = top = right = bottom = 0;
        double step = std::round(advance.width);
        const float points[4] = {float(step), 0, float(left), float(top)};
        const float bearings[4] = {float(left), 0, float(step - right), 0};
        GuestAddr m = out + i * 40;
        c.mem.writeArray<float>(m, points, 4);
        c.mem.write<uint32_t>(m + 16, uint32_t(top - bottom));
        c.mem.write<uint32_t>(m + 20, uint32_t(right - left));
        c.mem.writeArray<float>(m + 24, bearings, 4);
    }
    CFRelease(font);
    c.ret(kNoErr);
}

// OSStatus ATSUDrawText(ATSUTextLayout, UniCharArrayOffset, UniCharCount, ATSUTextMeasurement x,
//                       ATSUTextMeasurement y): into the current QuickDraw port's pixels, at the pen
// (kATSUUseGrafPortPenLoc) or at (x, y) in the port's coordinates, in the port's foreground color unless the
// style has its own. A 1-bit port gets ink where the text is, unsmoothed, as QuickDraw drew it there.
B32_THUNK(_ATSUDrawText) {
    uint32_t handle = c.args.u32(), offset = c.args.u32(), length = c.args.u32(), xArg = c.args.u32(), yArg = c.args.u32();
    GuestAddr port = b32::appkit::currentQuickDrawPort();
    b32::appkit::PortPixels px;
    if (!b32::appkit::portPixels(c.rt, port, px) || (px.depth != 1 && px.depth != 16 && px.depth != 32)) {
        static std::once_flag warned;
        std::call_once(warned, [] { log("ATSUDrawText: the current port has no pixels here to draw in; text is drawn only into GWorlds"); });
        c.ret(kNoErr);
        return;
    }
    b32::appkit::PortState state = b32::appkit::portState(port);
    double x = xArg == kUsePenLocation ? state.penH : fixed(xArg);
    double y = yArg == kUsePenLocation ? state.penV : fixed(yArg);
    CTLineRef line;
    {
        std::lock_guard guard(atsuiLock);
        auto it = layouts.find(handle);
        if (it == layouts.end()) {
            c.ret(uint32_t(kInvalidLayoutStatus));
            return;
        }
        line = copyLine(c, it->second, offset, length);
    }
    size_t width = size_t(px.right - px.left), height = size_t(px.bottom - px.top);
    CGFloat ink[3] = {state.fore.red / 65535.0, state.fore.green / 65535.0, state.fore.blue / 65535.0};
    auto draw = [&](CGContextRef context, bool smooth) {
        CGContextSetShouldAntialias(context, smooth);
        CGContextSetShouldSmoothFonts(context, false);
        CGContextSetRGBFillColor(context, ink[0], ink[1], ink[2], 1);
        CGContextSetTextMatrix(context, CGAffineTransformIdentity);
        // Rows run down from the top in QuickDraw and the bitmap, up from the bottom in CoreGraphics.
        CGContextSetTextPosition(context, x - px.left, CGFloat(px.bottom) - y);
        CTLineDraw(line, context);
    };
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    if (px.depth == 1) {
        // Drawn black on white beside the port, then set as ink (a dark color) or cleared (a light one).
        std::vector<uint8_t> gray(width * height, 0xff);
        CGColorSpaceRef grayspace = CGColorSpaceCreateDeviceGray();
        CGContextRef context = CGBitmapContextCreate(gray.data(), width, height, 8, width, grayspace, uint32_t(kCGImageAlphaNone));
        CGColorSpaceRelease(grayspace);
        if (context) {
            ink[0] = ink[1] = ink[2] = 0;
            draw(context, false);
            CGContextRelease(context);
            bool dark = state.fore.red * 0.299 + state.fore.green * 0.587 + state.fore.blue * 0.114 < 0x8000;
            uint8_t *pixels = c.mem.ptr<uint8_t>(px.base);
            for (size_t row = 0; row < height; row++)
                for (size_t column = 0; column < width; column++) {
                    if (gray[row * width + column] >= 0x80) continue;
                    uint8_t &byte = pixels[row * px.rowBytes + column / 8];
                    uint8_t bit = uint8_t(0x80 >> (column % 8));
                    byte = dark ? byte | bit : byte & ~bit;
                }
        }
    } else {
        // xRGB, big-endian whatever the processor: QuickDraw's own.
        uint32_t info = px.depth == 32 ? uint32_t(kCGImageAlphaNoneSkipFirst) | uint32_t(kCGBitmapByteOrder32Big)
                                       : uint32_t(kCGImageAlphaNoneSkipFirst) | uint32_t(kCGBitmapByteOrder16Big);
        CGContextRef context = CGBitmapContextCreate(c.mem.ptr<uint8_t>(px.base), width, height, px.depth == 32 ? 8 : 5,
                                                     px.rowBytes, rgb, info);
        if (context) {
            draw(context, true);
            CGContextRelease(context);
        }
    }
    CGColorSpaceRelease(rgb);
    CFRelease(line);
    c.ret(kNoErr);
}
