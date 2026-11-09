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
#include <crt_externs.h>

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }

NSRect rectArg(Call &c) {
    float x = c.args.f32(), y = c.args.f32(), w = c.args.f32(), h = c.args.f32();
    return NSMakeRect(x, y, w, h);
}
NSPoint pointArg(Call &c) {
    float x = c.args.f32();
    return NSMakePoint(x, c.args.f32());
}
NSSize sizeArg(Call &c) {
    float w = c.args.f32();
    return NSMakeSize(w, c.args.f32());
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

// int NSApplicationMain(int argc, const char *argv[]): the host's, on the
// host's arguments; the Info.plist it reads is the guest's.
B32_THUNK(_NSApplicationMain) {
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
