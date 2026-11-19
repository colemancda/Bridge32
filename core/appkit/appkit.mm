// AppKit's C functions for i386 Mac apps, and the NSApp global. The classes
// need nothing here: the bridge reaches them as it does any host class, and
// guest subclasses are visible to nibs through their shadow classes.
//
// NSRect and friends are CGFloats (float on i386) passed by value in argument
// words; NSPoint and NSSize come back in EAX:EDX and NSRect through a hidden
// pointer, which StructResult sorts out.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/objc/Dispatch.h"
#include "core/thunks/Format.h"

#import <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <crt_externs.h>

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }

NSRect rectArg(Call &c) {
    float x = c.args.structFloat(), y = c.args.structFloat(), w = c.args.structFloat(), h = c.args.structFloat();
    return NSMakeRect(x, y, w, h);
}
NSPoint pointArg(Call &c) {
    float x = c.args.structFloat();
    return NSMakePoint(x, c.args.structFloat());
}
NSSize sizeArg(Call &c) {
    float w = c.args.structFloat();
    return NSMakeSize(w, c.args.structFloat());
}
void writeRect(Call &c, GuestAddr out, NSRect r) {
    c.mem.write<float>(out, float(r.origin.x));
    c.mem.write<float>(out + 4, float(r.origin.y));
    c.mem.write<float>(out + 8, float(r.size.width));
    c.mem.write<float>(out + 12, float(r.size.height));
}
void writePoint(Call &c, GuestAddr out, NSPoint p) {
    c.mem.write<float>(out, float(p.x));
    c.mem.write<float>(out + 4, float(p.y));
}

// The guest's NSApp variable follows the host's.
void updateNSApp(Bridge &b) {
    if (GuestAddr variable = b.runtime().dataSymbol("_NSApp")) b.runtime().mem().write<uint32_t>(variable, b.toGuest(NSApp));
}

bool isApplicationClass(id receiver) { return object_isClass(receiver) && [(Class)receiver isSubclassOfClass:[NSApplication class]]; }
}  // namespace

B32_DATA(_NSApp, 4) {}

B32_OVERRIDE_WHEN(isApplicationClass, "sharedApplication") {
    id application = [(Class)o.receiver sharedApplication];
    updateNSApp(o.bridge);
    o.c.ret(o.bridge.toGuest(application));
}

// B32_DUMP_WINDOW=1: every 5 seconds the app's frontmost visible window is drawn into
// $TMPDIR/b32-window.png, so a Mac app can be checked without a screen (or a window the system won't
// capture), as UIKit apps can.
namespace {
void startWindowDumps() {
    if (!getenv("B32_DUMP_WINDOW")) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"b32-window.png"];
    NSTimer *timer = [NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *) {
        NSWindow *window = nil;
        for (NSWindow *w in NSApp.orderedWindows)
            if (w.isVisible) {
                window = w;
                break;
            }
        NSView *frame = window.contentView.superview ?: window.contentView;
        if (!frame) return;
        NSBitmapImageRep *rep = [frame bitmapImageRepForCachingDisplayInRect:frame.bounds];
        @try {
            [frame cacheDisplayInRect:frame.bounds toBitmapImageRep:rep];
        } @catch (NSException *e) {
            log("window dump: drawing threw %s", e.reason.UTF8String);
        }
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
    }];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}
}  // namespace

// int NSApplicationMain(int argc, const char *argv[]): the host's, on the
// host's arguments; the Info.plist it reads is the guest's.
B32_THUNK(_NSApplicationMain) {
    startWindowDumps();
    NSString *principal = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPrincipalClass"];
    Class cls = principal ? NSClassFromString(principal) : Nil;
    [cls ?: [NSApplication class] sharedApplication];
    updateNSApp(bridge(c));
    c.ret(uint32_t(NSApplicationMain(*_NSGetArgc(), const_cast<const char **>(*_NSGetArgv()))));
}

B32_THUNK(_NSApplicationLoad) {
    BOOL loaded = NSApplicationLoad();
    updateNSApp(bridge(c));
    c.ret(loaded);
}

B32_THUNK(_NSBeep) { NSBeep(); }

// NSImage *_NSGetThemePartImages(int part, int state, int flags): AppKit's private artwork for a part of
// the Aqua theme, which this AppKit no longer has. A plain light strip stands in, so the guest has an
// image of some size to draw with (Xcode's status bars).
B32_THUNK(__NSGetThemePartImages) {
    c.args.i32();
    c.args.i32();
    c.args.i32();
    static NSImage *image = [[NSImage imageWithSize:NSMakeSize(1, 22) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [[NSColor colorWithCalibratedWhite:0.88 alpha:1] setFill];
        NSRectFill(rect);
        return YES;
    }] retain];
    c.ret(bridge(c).toGuest(image));
}

// -[NSImage lockFocus] throws for an image it can't draw into (one of size zero), and a guest that
// carries on then sends -unlockFocus, which pops a graphics context that was never pushed and stops
// the app. An image the guest couldn't lock isn't unlocked.
namespace {
char lockedFocusKey;
bool isImage(id receiver) { return [receiver isKindOfClass:[NSImage class]]; }
}  // namespace
B32_OVERRIDE_WHEN(isImage, "lockFocus") {
    NSImage *image = o.receiver;
    @try {
        [image lockFocus];
    } @catch (NSException *e) {
        log("-[NSImage lockFocus] threw %s: %s; the guest draws nowhere", e.name.UTF8String, e.reason.UTF8String);
        return;
    }
    NSUInteger depth = [objc_getAssociatedObject(image, &lockedFocusKey) unsignedIntegerValue];
    objc_setAssociatedObject(image, &lockedFocusKey, @(depth + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
B32_OVERRIDE_WHEN(isImage, "unlockFocus") {
    NSImage *image = o.receiver;
    NSUInteger depth = [objc_getAssociatedObject(image, &lockedFocusKey) unsignedIntegerValue];
    if (!depth) return;
    objc_setAssociatedObject(image, &lockedFocusKey, depth > 1 ? @(depth - 1) : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [image unlockFocus];
}

// -[NSGraphicsContext graphicsPort] is declared void *; it's the context's CGContext, which the guest's
// Quartz calls take as the object it is.
namespace {
bool isGraphicsContext(id receiver) { return [receiver isKindOfClass:[NSGraphicsContext class]]; }
}  // namespace
B32_OVERRIDE_WHEN(isGraphicsContext, "graphicsPort") {
    o.c.ret(o.bridge.toGuest((id)static_cast<NSGraphicsContext *>(o.receiver).CGContext));
}

// NSArray *_NSUniqueMenuItemNamesForFullPaths(NSArray *paths): AppKit's private names for a menu of
// files (Xcode 3's Window menu), gone from today's AppKit: each file's name, with its folder's after
// it where two files share a name.
B32_THUNK(__NSUniqueMenuItemNamesForFullPaths) {
    NSArray *paths = bridge(c).toHost(c.args.ptr());
    NSCountedSet *names = [NSCountedSet set];
    for (NSString *path in paths) [names addObject:path.lastPathComponent];
    NSMutableArray *unique = [NSMutableArray arrayWithCapacity:paths.count];
    for (NSString *path in paths) {
        NSString *name = path.lastPathComponent;
        if ([names countForObject:name] > 1)
            name = [NSString stringWithFormat:@"%@ \u2014 %@", name, path.stringByDeletingLastPathComponent.lastPathComponent];
        [unique addObject:name];
    }
    c.ret(bridge(c).toGuest(unique));
}

// void NSCountWindows(NSInteger *count) and void NSWindowList(NSInteger size, NSInteger list[]):
// the app's windows, front to back, by number.
B32_THUNK(_NSCountWindows) {
    if (GuestAddr out = c.args.ptr()) c.mem.write<int32_t>(out, int32_t([NSWindow windowNumbersWithOptions:0].count));
}
B32_THUNK(_NSWindowList) {
    int32_t size = c.args.i32();
    GuestAddr list = c.args.ptr();
    NSArray<NSNumber *> *numbers = [NSWindow windowNumbersWithOptions:0];
    for (int32_t i = 0; list && i < size && i < int32_t(numbers.count); i++)
        c.mem.write<int32_t>(list + uint32_t(i) * 4, int32_t(numbers[NSUInteger(i)].integerValue));
}

// --- drawing --------------------------------------------------------------------------------

B32_THUNK(_NSRectFill) { NSRectFill(rectArg(c)); }
B32_THUNK(_NSRectFillUsingOperation) {
    NSRect r = rectArg(c);
    NSRectFillUsingOperation(r, NSCompositingOperation(c.args.u32()));
}
B32_THUNK(_NSFrameRect) { NSFrameRect(rectArg(c)); }
B32_THUNK(_NSFrameRectWithWidth) {
    NSRect r = rectArg(c);
    NSFrameRectWithWidth(r, c.args.f32());
}
B32_THUNK(_NSEraseRect) { NSEraseRect(rectArg(c)); }
B32_THUNK(_NSRectClip) { NSRectClip(rectArg(c)); }

// --- geometry -------------------------------------------------------------------------------

B32_THUNK(_NSInsetRect) {
    StructResult out(c, 16);
    NSRect r = rectArg(c);
    float dx = c.args.f32();
    writeRect(c, out, NSInsetRect(r, dx, c.args.f32()));
}
B32_THUNK(_NSOffsetRect) {
    StructResult out(c, 16);
    NSRect r = rectArg(c);
    float dx = c.args.f32();
    writeRect(c, out, NSOffsetRect(r, dx, c.args.f32()));
}
B32_THUNK(_NSIntegralRect) {
    StructResult out(c, 16);
    writeRect(c, out, NSIntegralRect(rectArg(c)));
}
B32_THUNK(_NSUnionRect) {
    StructResult out(c, 16);
    NSRect a = rectArg(c);
    writeRect(c, out, NSUnionRect(a, rectArg(c)));
}
B32_THUNK(_NSIntersectionRect) {
    StructResult out(c, 16);
    NSRect a = rectArg(c);
    writeRect(c, out, NSIntersectionRect(a, rectArg(c)));
}
// void NSDivideRect(NSRect, NSRect *slice, NSRect *rem, CGFloat amount, NSRectEdge edge)
B32_THUNK(_NSDivideRect) {
    NSRect r = rectArg(c);
    GuestAddr slice = c.args.ptr(), remainder = c.args.ptr();
    float amount = c.args.f32();
    NSRect s, rem;
    NSDivideRect(r, &s, &rem, amount, NSRectEdge(c.args.u32()));
    writeRect(c, slice, s);
    writeRect(c, remainder, rem);
}
B32_THUNK(_NSPointInRect) {
    NSPoint p = pointArg(c);
    c.ret(NSPointInRect(p, rectArg(c)));
}
B32_THUNK(_NSMouseInRect) {
    NSPoint p = pointArg(c);
    NSRect r = rectArg(c);
    c.ret(NSMouseInRect(p, r, c.args.u32() & 0xff));
}
B32_THUNK(_NSContainsRect) {
    NSRect a = rectArg(c);
    c.ret(NSContainsRect(a, rectArg(c)));
}
B32_THUNK(_NSIntersectsRect) {
    NSRect a = rectArg(c);
    c.ret(NSIntersectsRect(a, rectArg(c)));
}
B32_THUNK(_NSEqualRects) {
    NSRect a = rectArg(c);
    c.ret(NSEqualRects(a, rectArg(c)));
}
B32_THUNK(_NSEqualPoints) {
    NSPoint a = pointArg(c);
    c.ret(NSEqualPoints(a, pointArg(c)));
}
B32_THUNK(_NSEqualSizes) {
    NSSize a = sizeArg(c);
    c.ret(NSEqualSizes(a, sizeArg(c)));
}
B32_THUNK(_NSIsEmptyRect) { c.ret(NSIsEmptyRect(rectArg(c))); }

B32_THUNK(_NSStringFromRect) { c.ret(bridge(c).toGuest(NSStringFromRect(rectArg(c)))); }
B32_THUNK(_NSStringFromPoint) { c.ret(bridge(c).toGuest(NSStringFromPoint(pointArg(c)))); }
B32_THUNK(_NSStringFromSize) { c.ret(bridge(c).toGuest(NSStringFromSize(sizeArg(c)))); }
B32_THUNK(_NSRectFromString) {
    StructResult out(c, 16);
    writeRect(c, out, NSRectFromString(bridge(c).toHost(c.args.ptr())));
}
B32_THUNK(_NSPointFromString) {
    StructResult out(c, 8);
    writePoint(c, out, NSPointFromString(bridge(c).toHost(c.args.ptr())));
}
B32_THUNK(_NSSizeFromString) {
    StructResult out(c, 8);
    NSSize s = NSSizeFromString(bridge(c).toHost(c.args.ptr()));
    writePoint(c, out, NSMakePoint(s.width, s.height));
}

// --- alert panels: the message is a format with its arguments after the buttons -------------

namespace {
NSString *formatted(Call &c, GuestAddr format) {
    if (!format) return nil;
    NSString *host = bridge(c).toHost(format);
    std::string text = formatGuest(c, host.UTF8String, c.args, describeObject);
    return [NSString stringWithUTF8String:text.c_str()];
}

// title, message format, default button, alternate button, other button, arguments...
struct AlertText {
    NSString *title, *message, *defaultButton, *alternate, *other;
};
AlertText alertText(Call &c) {
    AlertText t;
    t.title = bridge(c).toHost(c.args.ptr());
    GuestAddr format = c.args.ptr();
    t.defaultButton = bridge(c).toHost(c.args.ptr());
    t.alternate = bridge(c).toHost(c.args.ptr());
    t.other = bridge(c).toHost(c.args.ptr());
    t.message = formatted(c, format);
    return t;
}
}  // namespace

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
B32_THUNK(_NSRunAlertPanel) {
    AlertText t = alertText(c);
    c.ret(uint32_t(NSRunAlertPanel(t.title, @"%@", t.defaultButton, t.alternate, t.other, t.message)));
}
B32_THUNK(_NSRunCriticalAlertPanel) {
    AlertText t = alertText(c);
    c.ret(uint32_t(NSRunCriticalAlertPanel(t.title, @"%@", t.defaultButton, t.alternate, t.other, t.message)));
}
B32_THUNK(_NSRunInformationalAlertPanel) {
    AlertText t = alertText(c);
    c.ret(uint32_t(NSRunInformationalAlertPanel(t.title, @"%@", t.defaultButton, t.alternate, t.other, t.message)));
}
B32_THUNK(_NSGetAlertPanel) {
    AlertText t = alertText(c);
    c.ret(bridge(c).toGuest(NSGetAlertPanel(t.title, @"%@", t.defaultButton, t.alternate, t.other, t.message)));
}
B32_THUNK(_NSReleaseAlertPanel) { NSReleaseAlertPanel(bridge(c).toHost(c.args.ptr())); }
#pragma clang diagnostic pop
