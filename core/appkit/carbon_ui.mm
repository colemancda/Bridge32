// Carbon's windows, controls, menus and events, rebuilt on AppKit for i386
// games: HIToolbox's UI has no 64-bit version to forward to. Interface Builder's
// Carbon nibs (objects.xib, XML) become NSWindows and NSControls. A WindowRef,
// ControlRef and so on is a small guest block whose address keys a host record.
// Everything here runs on the main thread, as Carbon UI had to.

#include "Carbon.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"

#import <AppKit/AppKit.h>

#include <cstring>
#include <map>
#include <string>
#include <unordered_map>
#include <vector>

using namespace b32;
using namespace b32::objc;

namespace {

Bridge &bridge(Call &c) { return c.rt.bridge(); }
id object(Call &c) { return bridge(c).toHost(c.args.ptr()); }
GuestAddr newHandle(Call &c) { return c.heap.calloc(1, 16); }

constexpr int32_t kNoErr = 0, kEventNotHandled = -9874, kEventLoopTimedOut = -9875, kEventParamNotFound = -9870,
                  kControlNotFound = -30584, kBadNib = -10;

constexpr uint32_t fourCC(const char (&s)[5]) {
    return uint32_t(uint8_t(s[0])) << 24 | uint32_t(uint8_t(s[1])) << 16 | uint32_t(uint8_t(s[2])) << 8 | uint8_t(s[3]);
}
uint32_t fourCC(NSString *s) {
    uint32_t v = 0;
    const char *text = s.UTF8String ?: "";
    for (int i = 0; i < 4; i++) v = v << 8 | (text[i] ? uint8_t(text[i]) : ' ');
    return v;
}
constexpr uint32_t kClassCommand = fourCC("cmds"), kClassWindow = fourCC("wind"), kClassKeyboard = fourCC("keyb"),
                   kClassMouse = fourCC("mous"), kClassControl = fourCC("cntl"), kClassApplication = fourCC("appl");
constexpr uint32_t kDirectObject = fourCC("----"), kKeyCodeParam = fourCC("kcod"), kModifiersParam = fourCC("kmod"),
                   kMacCharParam = fourCC("kchr"), kMouseLocationParam = fourCC("mloc"), kMouseButtonParam = fourCC("mbtn");
constexpr uint32_t kCommandProcess = 1, kWindowClose = 72;
constexpr uint32_t kKeyDown = 1, kKeyRepeat = 2, kKeyUp = 3, kModifiersChanged = 4;
constexpr uint32_t kMouseDown = 1, kMouseUp = 2, kMouseMoved = 5, kMouseDragged = 6;

enum class Kind { Button, CheckBox, StaticText, EditText, Popup, Box, Separator, Bar, Arrows, Pane, Image };

struct Handler {
    GuestAddr function, user, ref;
    std::vector<std::pair<uint32_t, uint32_t>> types;
};
struct Target {
    std::vector<Handler *> handlers;
    GuestAddr parent = 0;  // where an event goes when this target doesn't take it
};
struct CMenu {
    NSMenu *menu;
    GuestAddr handle;
    std::vector<uint32_t> commands;
};
struct CWindow;
struct CControl {
    GuestAddr handle, target;
    id view;
    Kind kind;
    CWindow *window;
    uint32_t signature, command;
    int32_t identifier, minimum, maximum, value;
    GuestAddr action, refcon;
    CMenu *menu;
};
struct CWindow {
    GuestAddr handle, target;
    NSWindow *window;
    NSView *content;
    std::vector<CControl *> controls;
    GuestAddr refcon;
};
struct CEvent {
    uint32_t cls, kind;
    double when;
    std::map<uint32_t, std::vector<uint8_t>> params;
};

std::unordered_map<GuestAddr, Target *> targets;
std::unordered_map<GuestAddr, CWindow *> windows;
std::unordered_map<GuestAddr, CControl *> controls;
std::unordered_map<GuestAddr, CMenu *> menus;
std::unordered_map<GuestAddr, CEvent *> events;
std::unordered_map<GuestAddr, NSXMLDocument *> nibs;
std::unordered_map<GuestAddr, NSTimer *> timers;
std::unordered_map<void *, CControl *> controlByView;
GuestAddr applicationTarget = 0, dispatcherTarget = 0, currentPort = 0;

GuestAddr makeTarget(Call &c, GuestAddr parent) {
    GuestAddr handle = newHandle(c);
    auto *target = new Target;
    target->parent = parent;
    targets[handle] = target;
    return handle;
}
GuestAddr appTarget(Call &c) {
    if (!applicationTarget) applicationTarget = makeTarget(c, 0);
    return applicationTarget;
}

// The Cocoa keycode state that GetKeys reports, and the pointer.
uint8_t keyState[16];
void noteKey(unsigned short code, bool down) {
    if (code >= 128) return;
    if (down) keyState[code >> 3] |= 1 << (code & 7);
    else keyState[code >> 3] &= ~(1 << (code & 7));
}

GuestAddr makeEvent(Runtime &rt, uint32_t cls, uint32_t kind) {
    GuestAddr handle = rt.heap().calloc(1, 16);
    auto *event = new CEvent;
    event->cls = cls;
    event->kind = kind;
    event->when = NSProcessInfo.processInfo.systemUptime;
    events[handle] = event;
    return handle;
}
void setParam(GuestAddr handle, uint32_t name, const void *bytes, size_t size) {
    auto &slot = events[handle]->params[name];
    slot.assign(static_cast<const uint8_t *>(bytes), static_cast<const uint8_t *>(bytes) + size);
}
void freeEvent(Runtime &rt, GuestAddr handle) {
    delete events[handle];
    events.erase(handle);
    rt.heap().free(handle);
}

// Runs the guest's handlers for an event at `target`, then up its chain.
int32_t dispatchTo(GuestAddr handle, GuestAddr target) {
    CEvent *event = events[handle];
    Cpu &cpu = Runtime::threadCpu();
    for (GuestAddr t = target; t;) {
        auto found = targets.find(t);
        if (found == targets.end()) break;
        std::vector<Handler *> handlers = found->second->handlers;
        for (Handler *h : handlers)
            for (auto [cls, kind] : h->types)
                if (cls == event->cls && kind == event->kind) {
                    int32_t result = int32_t(cpu.call(h->function, {0, handle, h->user}));
                    if (result != kEventNotHandled) return result;
                    break;
                }
        t = found->second->parent;
    }
    return kEventNotHandled;
}

void sendCommand(Runtime &rt, uint32_t command, GuestAddr target, GuestAddr menu = 0, uint16_t item = 0) {
    GuestAddr event = makeEvent(rt, kClassCommand, kCommandProcess);
    // HICommand: attributes, commandID, menu ref, menu item index.
    uint8_t hc[16] = {};
    std::memcpy(hc + 4, &command, 4);
    std::memcpy(hc + 8, &menu, 4);
    std::memcpy(hc + 12, &item, 2);
    setParam(event, kDirectObject, hc, sizeof hc);
    dispatchTo(event, target);
    freeEvent(rt, event);
}

CControl *controlOf(GuestAddr handle) {
    auto it = controls.find(handle);
    return it == controls.end() ? nullptr : it->second;
}
CWindow *windowOf(GuestAddr handle) {
    auto it = windows.find(handle);
    return it == windows.end() ? nullptr : it->second;
}
Runtime &runtime() { return Bridge::shared()->runtime(); }

}  // namespace

// AppKit sends a control's action and a window's close here.
@interface B32CarbonResponder : NSObject <NSWindowDelegate>
@end
@implementation B32CarbonResponder
- (void)fire:(id)sender {
    auto it = controlByView.find(sender);
    if (it == controlByView.end()) return;
    CControl *control = it->second;
    if (control->action) Runtime::threadCpu().call(control->action, {control->handle, 0});
    if (control->command) sendCommand(runtime(), control->command, control->target);
}
- (void)menuFired:(NSMenuItem *)item {
    sendCommand(runtime(), uint32_t(item.tag), applicationTarget);
}
- (BOOL)windowShouldClose:(NSWindow *)sender {
    for (auto &[handle, window] : windows)
        if (window->window == sender) {
            GuestAddr event = makeEvent(runtime(), kClassWindow, kWindowClose);
            setParam(event, kDirectObject, &handle, 4);
            int32_t result = dispatchTo(event, window->target);
            freeEvent(runtime(), event);
            return result == kEventNotHandled;
        }
    return YES;
}
@end

@interface B32CarbonContent : NSView
@end
@implementation B32CarbonContent
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)event {}  // tracked at the queue; no beep
- (void)keyUp:(NSEvent *)event {}
@end

namespace {
B32CarbonResponder *responder() {
    static B32CarbonResponder *shared = [[B32CarbonResponder alloc] init];
    return shared;
}

// --- nibs ------------------------------------------------------------------------------

NSString *childText(NSXMLElement *e, NSString *name) {
    for (NSXMLElement *c in e.children)
        if ([c isKindOfClass:[NSXMLElement class]] && [[c attributeForName:@"name"].stringValue isEqualToString:name]) return c.stringValue;
    return nil;
}
NSXMLElement *child(NSXMLElement *e, NSString *name) {
    for (NSXMLElement *c in e.children)
        if ([c isKindOfClass:[NSXMLElement class]] && [[c attributeForName:@"name"].stringValue isEqualToString:name]) return c;
    return nil;
}
NSXMLElement *objectWithId(NSXMLDocument *doc, NSString *identifier) {
    NSArray *found = [doc nodesForXPath:[NSString stringWithFormat:@"//object[@id='%@']", identifier] error:nil];
    return found.firstObject;
}
// A reference element leads to the object it names.
NSXMLElement *resolve(NSXMLDocument *doc, NSXMLElement *e) {
    if ([e.name isEqualToString:@"reference"]) return objectWithId(doc, [e attributeForName:@"idRef"].stringValue);
    return e;
}
NSXMLElement *namedObject(NSXMLDocument *doc, NSString *name) {
    NSArray *table = [doc nodesForXPath:@"//dictionary[@name='nameTable']/*" error:nil];
    for (NSUInteger i = 0; i + 1 < table.count; i += 2)
        if ([[table[i] stringValue] isEqualToString:name]) return resolve(doc, table[i + 1]);
    return nil;
}
// "top left bottom right".
NSRect rectOf(NSString *text) {
    NSArray<NSString *> *p = [text componentsSeparatedByString:@" "];
    if (p.count < 4) return NSZeroRect;
    CGFloat t = p[0].doubleValue, l = p[1].doubleValue, b = p[2].doubleValue, r = p[3].doubleValue;
    return NSMakeRect(l, t, r - l, b - t);
}

CMenu *buildMenu(Call &c, NSXMLDocument *doc, NSXMLElement *e) {
    auto *menu = new CMenu;
    menu->handle = newHandle(c);
    menu->menu = [[NSMenu alloc] initWithTitle:childText(e, @"title") ?: @""];
    menu->menu.autoenablesItems = NO;
    menus[menu->handle] = menu;
    for (NSXMLElement *raw in child(e, @"items").children) {
        NSXMLElement *itemElement = resolve(doc, raw);
        if ([[childText(itemElement, @"separator") uppercaseString] isEqualToString:@"TRUE"]) {
            [menu->menu addItem:NSMenuItem.separatorItem];
            continue;
        }
        NSString *title = childText(itemElement, @"title") ?: @"";
        NSString *key = [childText(itemElement, @"keyEquivalent") lowercaseString] ?: @"";
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(menuFired:) keyEquivalent:key];
        item.target = responder();
        NSString *command = childText(itemElement, @"command");
        if (command) item.tag = NSInteger(fourCC(command));
        item.enabled = ![[childText(itemElement, @"disabled") uppercaseString] isEqualToString:@"TRUE"];
        if ([[childText(itemElement, @"checked") uppercaseString] isEqualToString:@"TRUE"]) item.state = NSControlStateValueOn;
        if (NSXMLElement *sub = child(itemElement, @"submenu")) {
            CMenu *submenu = buildMenu(c, doc, resolve(doc, sub));
            item.submenu = submenu->menu;
            item.action = nil;
        }
        [menu->menu addItem:item];
    }
    return menu;
}

void addControl(Call &c, NSXMLDocument *doc, NSXMLElement *e, CWindow *window, NSPoint origin, bool compositing);

void addSubviews(Call &c, NSXMLDocument *doc, NSXMLElement *parent, CWindow *window, NSPoint origin, bool compositing) {
    NSXMLElement *subviews = child(parent, @"subviews");
    if (!subviews) return;
    for (NSXMLElement *raw in subviews.children)
        if ([raw isKindOfClass:[NSXMLElement class]]) addControl(c, doc, resolve(doc, raw), window, origin, compositing);
}

NSTextField *makeLabel(NSString *text, NSRect frame, BOOL small) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text ?: @""];
    label.frame = frame;
    if (small) label.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    return label;
}

void addControl(Call &c, NSXMLDocument *doc, NSXMLElement *e, CWindow *window, NSPoint origin, bool compositing) {
    NSString *cls = [e attributeForName:@"class"].stringValue;
    NSRect bounds = rectOf(childText(e, @"bounds"));
    NSRect frame = bounds;
    if (compositing) frame = NSOffsetRect(bounds, origin.x, origin.y);
    NSString *title = childText(e, @"title");

    auto *control = new CControl{};
    control->handle = newHandle(c);
    control->target = makeTarget(c, window->target);
    control->window = window;
    control->signature = childText(e, @"controlSignature") ? fourCC(childText(e, @"controlSignature")) : 0;
    control->identifier = [childText(e, @"controlID") intValue];
    control->command = childText(e, @"command") ? fourCC(childText(e, @"command")) : 0;
    control->value = [childText(e, @"initialValue") intValue];
    control->minimum = [childText(e, @"minimumValue") intValue];
    control->maximum = childText(e, @"maximumValue") ? [childText(e, @"maximumValue") intValue] : 1;
    bool isSmall = [[childText(e, @"small") uppercaseString] isEqualToString:@"TRUE"];

    NSView *view = nil;
    if ([cls isEqualToString:@"IBCarbonButton"]) {
        control->kind = Kind::Button;
        NSButton *button = [NSButton buttonWithTitle:title ?: @"" target:responder() action:@selector(fire:)];
        button.frame = NSInsetRect(frame, -6, -5);
        if ([childText(e, @"buttonType") intValue] == 1) button.keyEquivalent = @"\r";
        view = button;
    } else if ([cls isEqualToString:@"IBCarbonCheckBox"]) {
        control->kind = Kind::CheckBox;
        NSButton *box = [NSButton checkboxWithTitle:title ?: @"" target:responder() action:@selector(fire:)];
        box.frame = frame;
        box.state = control->value ? NSControlStateValueOn : NSControlStateValueOff;
        view = box;
    } else if ([cls isEqualToString:@"IBCarbonStaticText"]) {
        control->kind = Kind::StaticText;
        view = makeLabel(title, frame, isSmall);
    } else if ([cls isEqualToString:@"IBCarbonEditText"]) {
        control->kind = Kind::EditText;
        NSTextField *field = [NSTextField textFieldWithString:title ?: @""];
        field.frame = frame;
        view = field;
    } else if ([cls isEqualToString:@"IBCarbonPopupButton"]) {
        control->kind = Kind::Popup;
        // The Carbon control includes its title on the left.
        NSRect popupFrame = frame;
        if (title.length) {
            CGFloat width = [title sizeWithAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:NSFont.systemFontSize]}].width + 8;
            NSTextField *label = makeLabel(title, NSMakeRect(frame.origin.x, frame.origin.y + 2, width, frame.size.height), NO);
            [window->content addSubview:label];
            popupFrame.origin.x += width;
            popupFrame.size.width -= width;
        }
        NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:popupFrame pullsDown:NO];
        popup.autoenablesItems = NO;
        popup.target = responder();
        popup.action = @selector(fire:);
        if (NSXMLElement *menuElement = child(e, @"menu")) {
            CMenu *menu = buildMenu(c, doc, resolve(doc, menuElement));
            control->menu = menu;
            for (NSMenuItem *item in menu->menu.itemArray) item.target = nil;
            popup.menu = menu->menu;
            popup.target = responder();
            popup.action = @selector(fire:);
            for (NSMenuItem *item in menu->menu.itemArray) { item.action = @selector(fire:); item.target = popup; item.action = nil; }
        }
        view = popup;
    } else if ([cls isEqualToString:@"IBCarbonGroupBox"]) {
        control->kind = Kind::Box;
        NSBox *box = [[NSBox alloc] initWithFrame:frame];
        box.title = title ?: @"";
        box.titlePosition = title.length ? NSAtTop : NSNoTitle;
        view = box;
    } else if ([cls isEqualToString:@"IBCarbonSeparator"]) {
        control->kind = Kind::Separator;
        NSBox *line = [[NSBox alloc] initWithFrame:frame];
        line.boxType = NSBoxSeparator;
        view = line;
    } else if ([cls isEqualToString:@"IBCarbonRelevanceBar"]) {
        control->kind = Kind::Bar;
        NSProgressIndicator *bar = [[NSProgressIndicator alloc] initWithFrame:frame];
        bar.indeterminate = NO;
        bar.minValue = control->minimum;
        bar.maxValue = control->maximum;
        bar.doubleValue = control->value;
        view = bar;
    } else if ([cls isEqualToString:@"IBCarbonLittleArrows"]) {
        control->kind = Kind::Arrows;
        NSStepper *stepper = [[NSStepper alloc] initWithFrame:frame];
        stepper.minValue = control->minimum;
        stepper.maxValue = control->maximum;
        stepper.intValue = control->value;
        stepper.target = responder();
        stepper.action = @selector(fire:);
        view = stepper;
    } else {
        control->kind = [cls isEqualToString:@"IBCarbonIcon"] ? Kind::Image : Kind::Pane;
        view = [[NSView alloc] initWithFrame:frame];
    }
    control->view = view;
    [window->content addSubview:view];
    controlByView[view] = control;
    controls[control->handle] = control;
    window->controls.push_back(control);
    addSubviews(c, doc, e, window, compositing ? frame.origin : origin, compositing);
}

NSWindowStyleMask styleFor(NSXMLElement *e) {
    NSWindowStyleMask style = NSWindowStyleMaskTitled;
    auto no = [&](NSString *key) { return [[childText(e, key) uppercaseString] isEqualToString:@"FALSE"]; };
    if (!no(@"hasCloseBox")) style |= NSWindowStyleMaskClosable;
    if (!no(@"hasCollapseBox")) style |= NSWindowStyleMaskMiniaturizable;
    if (!no(@"isResizable")) style |= NSWindowStyleMaskResizable;
    return style;
}

CWindow *registerWindow(Call &c, NSWindow *ns) {
    auto *window = new CWindow{};
    window->handle = newHandle(c);
    window->target = makeTarget(c, appTarget(c));
    window->window = ns;
    B32CarbonContent *content = [[B32CarbonContent alloc] initWithFrame:ns.contentView.bounds];
    ns.contentView = content;
    window->content = content;
    ns.delegate = responder();
    ns.releasedWhenClosed = NO;
    windows[window->handle] = window;
    return window;
}

NSWindow *makeNSWindow(NSRect contentRect, NSWindowStyleMask style) {
    // Carbon's rectangles are global with the origin at the top left of the main display.
    CGFloat screen = NSScreen.screens.firstObject.frame.size.height;
    NSRect cocoa = NSMakeRect(contentRect.origin.x, screen - NSMaxY(contentRect), contentRect.size.width, contentRect.size.height);
    return [[NSWindow alloc] initWithContentRect:cocoa styleMask:style backing:NSBackingStoreBuffered defer:NO];
}

CWindow *portWindow(GuestAddr port) { return windowOf(port); }  // a window's port is the window

void writeRect(Call &c, GuestAddr out, NSRect r) {
    const int16_t fields[4] = {int16_t(r.origin.y), int16_t(r.origin.x), int16_t(NSMaxY(r)), int16_t(NSMaxX(r))};
    c.mem.copyIn(out, fields, sizeof fields);
}
NSRect readRect(Call &c, GuestAddr in) {
    int16_t t = c.mem.read<int16_t>(in), l = c.mem.read<int16_t>(in + 2), b = c.mem.read<int16_t>(in + 4), r = c.mem.read<int16_t>(in + 6);
    return NSMakeRect(l, t, r - l, b - t);
}
NSRect globalBounds(CWindow *w) {
    NSRect content = [w->window contentRectForFrameRect:w->window.frame];
    CGFloat screen = NSScreen.screens.firstObject.frame.size.height;
    return NSMakeRect(content.origin.x, screen - NSMaxY(content), content.size.width, content.size.height);
}

// --- pumping -----------------------------------------------------------------------------

struct PumpedEvent {
    bool valid = false;
    int16_t what = 0;
    uint32_t message = 0;
    uint16_t modifiers = 0;
    NSPoint where = NSZeroPoint;
};

uint16_t carbonModifiers(NSEventModifierFlags flags) {
    uint16_t m = 0;
    if (flags & NSEventModifierFlagCommand) m |= 0x0100;
    if (flags & NSEventModifierFlagShift) m |= 0x0200;
    if (flags & NSEventModifierFlagCapsLock) m |= 0x0400;
    if (flags & NSEventModifierFlagOption) m |= 0x0800;
    if (flags & NSEventModifierFlagControl) m |= 0x1000;
    return m;
}

NSPoint globalMouse() {
    NSPoint p = NSEvent.mouseLocation;
    return NSMakePoint(p.x, NSScreen.screens.firstObject.frame.size.height - p.y);
}

PumpedEvent pumpOne(double seconds) {
    b32::appkit::ensureCarbonApplication();
    PumpedEvent out;
    @autoreleasepool {
        NSDate *until = seconds > 0 ? [NSDate dateWithTimeIntervalSinceNow:seconds] : NSDate.distantPast;
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until inMode:NSDefaultRunLoopMode dequeue:YES];
        if (!event) return out;
        out.where = globalMouse();
        out.modifiers = carbonModifiers(event.modifierFlags);
        switch (event.type) {
        case NSEventTypeKeyDown:
        case NSEventTypeKeyUp: {
            bool down = event.type == NSEventTypeKeyDown;
            noteKey(event.keyCode, down);
            NSString *chars = event.charactersIgnoringModifiers;
            uint8_t character = chars.length ? uint8_t([chars characterAtIndex:0]) : 0;
            out.valid = true;
            out.what = down ? (event.isARepeat ? 5 : 3) : 4;
            out.message = uint32_t(character) | uint32_t(event.keyCode) << 8;
            break;
        }
        case NSEventTypeFlagsChanged: {
            static const struct { unsigned short key; NSEventModifierFlags flag; } kModifiers[] = {
                {55, NSEventModifierFlagCommand}, {56, NSEventModifierFlagShift}, {57, NSEventModifierFlagCapsLock},
                {58, NSEventModifierFlagOption}, {59, NSEventModifierFlagControl}};
            for (auto m : kModifiers) noteKey(m.key, event.modifierFlags & m.flag);
            break;
        }
        case NSEventTypeLeftMouseDown:
            out.valid = true;
            out.what = 1;
            break;
        case NSEventTypeLeftMouseUp:
            out.valid = true;
            out.what = 2;
            break;
        default: break;
        }
        [NSApp sendEvent:event];
        [NSApp updateWindows];
    }
    return out;
}
}  // namespace

namespace b32::appkit {

void ensureCarbonApplication() {
    static bool done = false;
    if (done) return;
    done = true;
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyRegular;
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
}
NSView *carbonViewForPort(GuestAddr port) {
    CWindow *w = portWindow(port);
    return w ? w->content : nil;
}
NSView *carbonFullScreenView() {
    static NSWindow *window = nil;
    if (!window) {
        ensureCarbonApplication();
        window = [[NSWindow alloc] initWithContentRect:NSScreen.mainScreen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.level = NSMainMenuWindowLevel + 1;
        window.contentView = [[B32CarbonContent alloc] initWithFrame:window.contentView.bounds];
        [window makeKeyAndOrderFront:nil];
    }
    return window.contentView;
}
void pumpCarbonEvents(double seconds) { pumpOne(seconds); }

}  // namespace b32::appkit

using b32::appkit::ensureCarbonApplication;

// --- nib references ------------------------------------------------------------------------

// OSStatus CreateNibReference(CFStringRef name, IBNibRef *out)
B32_THUNK(_CreateNibReference) {
    NSString *name = object(c);
    GuestAddr out = c.args.ptr();
    // Localized, so it's found under English.lproj; the nib is a folder.
    NSString *nib = [NSBundle.mainBundle pathForResource:name ofType:@"nib"];
    NSString *path = [nib stringByAppendingPathComponent:@"objects.xib"];
    NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
    // These files are Mac Roman, without saying so.
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding] : nil;
    // They also hold raw control characters (key equivalents), which XML forbids.
    static NSRegularExpression *control = [[NSRegularExpression regularExpressionWithPattern:@"[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]" options:0 error:nil] retain];
    if (text) text = [control stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    NSXMLDocument *doc = text ? [[NSXMLDocument alloc] initWithXMLString:text options:0 error:nil] : nil;
    if (!doc) {
        log("CreateNibReference(%s): no readable objects.xib", name.UTF8String);
        c.ret(uint32_t(kBadNib));
        return;
    }
    GuestAddr handle = newHandle(c);
    nibs[handle] = doc;
    c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}
B32_THUNK(_DisposeNibReference) {
    GuestAddr handle = c.args.ptr();
    [nibs[handle] release];
    nibs.erase(handle);
    c.heap.free(handle);
}
// OSStatus SetMenuBarFromNib(IBNibRef, CFStringRef name)
B32_THUNK(_SetMenuBarFromNib) {
    ensureCarbonApplication();
    GuestAddr handle = c.args.ptr();
    NSString *name = object(c);
    NSXMLDocument *doc = nibs[handle];
    NSXMLElement *e = namedObject(doc, name);
    if (!e) {
        c.ret(uint32_t(kBadNib));
        return;
    }
    appTarget(c);
    NSApp.mainMenu = buildMenu(c, doc, e)->menu;
    c.ret(0);
}
// OSStatus CreateWindowFromNib(IBNibRef, CFStringRef name, WindowRef *out)
B32_THUNK(_CreateWindowFromNib) {
    ensureCarbonApplication();
    GuestAddr handle = c.args.ptr();
    NSString *name = object(c);
    GuestAddr out = c.args.ptr();
    NSXMLDocument *doc = nibs[handle];
    NSXMLElement *e = namedObject(doc, name);
    if (!e) {
        log("CreateWindowFromNib: no window named %s", name.UTF8String);
        c.ret(uint32_t(kBadNib));
        return;
    }
    NSWindow *ns = makeNSWindow(rectOf(childText(e, @"windowRect")), styleFor(e));
    ns.title = childText(e, @"title") ?: @"";
    CWindow *window = registerWindow(c, ns);
    bool compositing = [[childText(e, @"compositing") uppercaseString] isEqualToString:@"TRUE"];
    if (NSXMLElement *root = child(e, @"rootControl")) addSubviews(c, doc, resolve(doc, root), window, NSZeroPoint, compositing);
    [ns center];
    c.mem.write<uint32_t>(out, window->handle);
    c.ret(0);
}

// --- windows ------------------------------------------------------------------------------

// WindowRef NewCWindow(storage, Rect *bounds, title, visible, procID, behind, goAway, refCon)
B32_THUNK(_NewCWindow) {
    ensureCarbonApplication();
    c.args.ptr();
    NSRect rect = readRect(c, c.args.ptr());
    GuestAddr titlePtr = c.args.ptr();
    bool visible = c.args.u32() & 0xff;
    c.args.u32();
    c.args.ptr();
    c.args.u32();
    GuestAddr refcon = c.args.u32();
    NSWindow *ns = makeNSWindow(rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable);
    if (titlePtr) {
        uint8_t length = c.mem.read<uint8_t>(titlePtr);
        ns.title = [[NSString alloc] initWithBytes:c.mem.ptr<char>(titlePtr + 1) length:length encoding:NSMacOSRomanStringEncoding];
    }
    CWindow *window = registerWindow(c, ns);
    window->refcon = refcon;
    if (visible) [ns makeKeyAndOrderFront:nil];
    c.ret(window->handle);
}
// OSStatus CreateNewWindow(class, attributes, const Rect *bounds, WindowRef *out)
B32_THUNK(_CreateNewWindow) {
    ensureCarbonApplication();
    c.args.u32();
    c.args.u32();
    NSRect rect = readRect(c, c.args.ptr());
    GuestAddr out = c.args.ptr();
    CWindow *window = registerWindow(c, makeNSWindow(rect, NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable));
    c.mem.write<uint32_t>(out, window->handle);
    c.ret(0);
}
B32_THUNK(_DisposeWindow) {
    GuestAddr handle = c.args.ptr();
    if (CWindow *w = windowOf(handle)) {
        [w->window orderOut:nil];
        w->window.delegate = nil;
        for (CControl *control : w->controls) {
            controlByView.erase(control->view);
            controls.erase(control->handle);
        }
        windows.erase(handle);
    }
}
B32_THUNK(_ShowWindow) {
    if (CWindow *w = windowOf(c.args.ptr())) [w->window makeKeyAndOrderFront:nil];
}
B32_THUNK(_HideWindow) {
    if (CWindow *w = windowOf(c.args.ptr())) [w->window orderOut:nil];
}
B32_THUNK(_SelectWindow) {
    if (CWindow *w = windowOf(c.args.ptr())) [w->window makeKeyAndOrderFront:nil];
}
B32_THUNK(_BringToFront) {
    if (CWindow *w = windowOf(c.args.ptr())) [w->window orderFront:nil];
}
B32_THUNK(_ActivateWindow) { c.ret(0); }
B32_THUNK(_IsWindowVisible) {
    CWindow *w = windowOf(c.args.ptr());
    c.ret(w && w->window.visible);
}
B32_THUNK(_GetWindowPort) { c.ret(c.args.ptr()); }
B32_THUNK(_GetWindowFromPort) { c.ret(c.args.ptr()); }
B32_THUNK(_SetWRefCon) {
    CWindow *w = windowOf(c.args.ptr());
    uint32_t value = c.args.u32();
    if (w) w->refcon = value;
}
B32_THUNK(_GetWRefCon) {
    CWindow *w = windowOf(c.args.ptr());
    c.ret(w ? w->refcon : 0);
}
B32_THUNK(_SetWindowTitleWithCFString) {
    CWindow *w = windowOf(c.args.ptr());
    NSString *title = object(c);
    if (w) w->window.title = title ?: @"";
    c.ret(0);
}
// OSStatus GetWindowBounds(window, region, Rect *out)
B32_THUNK(_GetWindowBounds) {
    CWindow *w = windowOf(c.args.ptr());
    c.args.u32();
    GuestAddr out = c.args.ptr();
    if (w) writeRect(c, out, globalBounds(w));
    c.ret(0);
}
B32_THUNK(_SetWindowBounds) {
    CWindow *w = windowOf(c.args.ptr());
    c.args.u32();
    NSRect rect = readRect(c, c.args.ptr());
    if (w) {
        CGFloat screen = NSScreen.screens.firstObject.frame.size.height;
        NSRect cocoa = NSMakeRect(rect.origin.x, screen - NSMaxY(rect), rect.size.width, rect.size.height);
        [w->window setFrame:[w->window frameRectForContentRect:cocoa] display:YES];
    }
    c.ret(0);
}
B32_THUNK(_RepositionWindow) {
    if (CWindow *w = windowOf(c.args.ptr())) [w->window center];
    c.ret(0);
}
B32_THUNK(_GetWindowEventTarget) {
    CWindow *w = windowOf(c.args.ptr());
    c.ret(w ? w->target : 0);
}
B32_THUNK(_GetControlEventTarget) {
    CControl *control = controlOf(c.args.ptr());
    c.ret(control ? control->target : 0);
}
B32_THUNK(_GetMenuEventTarget) { c.ret(appTarget(c)); }
B32_THUNK(_GetApplicationEventTarget) { c.ret(appTarget(c)); }
B32_THUNK(_GetUserFocusEventTarget) { c.ret(appTarget(c)); }
B32_THUNK(_GetEventDispatcherTarget) {
    if (!dispatcherTarget) dispatcherTarget = makeTarget(c, appTarget(c));
    c.ret(dispatcherTarget);
}
B32_THUNK(_ActiveNonFloatingWindow) {
    for (auto &[handle, window] : windows)
        if (window->window.isKeyWindow) {
            c.ret(handle);
            return;
        }
    c.ret(0);
}
// Window groups only order windows, which AppKit's levels cover for one game window.
B32_THUNK(_CreateWindowGroup) {
    c.args.u32();
    c.mem.write<uint32_t>(c.args.ptr(), newHandle(c));
    c.ret(0);
}
B32_THUNK(_SetWindowGroup) { c.ret(0); }
B32_THUNK(_SetWindowGroupLevel) { c.ret(0); }
B32_THUNK(_ReleaseWindowGroup) { c.ret(0); }
B32_THUNK(_IsWindowContainedInGroup) { c.ret(0); }

// --- controls -----------------------------------------------------------------------------

namespace {
void refreshValue(CControl *control) {
    switch (control->kind) {
    case Kind::CheckBox: control->value = ((NSButton *)control->view).state == NSControlStateValueOn; break;
    case Kind::Popup: control->value = int32_t(((NSPopUpButton *)control->view).indexOfSelectedItem) + 1; break;
    case Kind::Arrows: control->value = ((NSStepper *)control->view).intValue; break;
    default: break;
    }
}
void applyValue(CControl *control) {
    switch (control->kind) {
    case Kind::CheckBox: ((NSButton *)control->view).state = control->value ? NSControlStateValueOn : NSControlStateValueOff; break;
    case Kind::Popup:
        if (control->value >= 1 && control->value <= NSInteger(((NSPopUpButton *)control->view).numberOfItems))
            [(NSPopUpButton *)control->view selectItemAtIndex:control->value - 1];
        break;
    case Kind::Arrows: ((NSStepper *)control->view).intValue = control->value; break;
    case Kind::Bar: ((NSProgressIndicator *)control->view).doubleValue = control->value; break;
    default: break;
    }
}
void setValue(Call &c) {
    CControl *control = controlOf(c.args.ptr());
    int32_t value = c.args.i32();
    if (control) {
        control->value = value;
        applyValue(control);
    }
}
void getValue(Call &c) {
    CControl *control = controlOf(c.args.ptr());
    if (control) refreshValue(control);
    c.ret(control ? uint32_t(control->value) : 0);
}
void setMinimum(Call &c) {
    CControl *control = controlOf(c.args.ptr());
    int32_t value = c.args.i32();
    if (control) {
        control->minimum = value;
        if (control->kind == Kind::Arrows) ((NSStepper *)control->view).minValue = value;
        if (control->kind == Kind::Bar) ((NSProgressIndicator *)control->view).minValue = value;
    }
}
void setMaximum(Call &c) {
    CControl *control = controlOf(c.args.ptr());
    int32_t value = c.args.i32();
    if (control) {
        control->maximum = value;
        if (control->kind == Kind::Arrows) ((NSStepper *)control->view).maxValue = value;
        if (control->kind == Kind::Bar) ((NSProgressIndicator *)control->view).maxValue = value;
    }
}
}  // namespace

// OSStatus GetControlByID(WindowRef, const ControlID *, ControlRef *out)
B32_THUNK(_GetControlByID) {
    CWindow *w = windowOf(c.args.ptr());
    GuestAddr id = c.args.ptr(), out = c.args.ptr();
    uint32_t signature = c.mem.read<uint32_t>(id);
    int32_t identifier = c.mem.read<int32_t>(id + 4);
    if (w)
        for (CControl *control : w->controls)
            if (control->signature == signature && control->identifier == identifier) {
                c.mem.write<uint32_t>(out, control->handle);
                c.ret(0);
                return;
            }
    c.mem.write<uint32_t>(out, 0);
    c.ret(uint32_t(kControlNotFound));
}
B32_THUNK(_GetControlID) {
    CControl *control = controlOf(c.args.ptr());
    GuestAddr out = c.args.ptr();
    if (control) {
        c.mem.write<uint32_t>(out, control->signature);
        c.mem.write<int32_t>(out + 4, control->identifier);
    }
    c.ret(0);
}
B32_THUNK(_GetControlCommandID) {
    CControl *control = controlOf(c.args.ptr());
    GuestAddr out = c.args.ptr();
    if (control) c.mem.write<uint32_t>(out, control->command);
    c.ret(0);
}
B32_THUNK(_GetControlOwner) {
    CControl *control = controlOf(c.args.ptr());
    c.ret(control ? control->window->handle : 0);
}
B32_THUNK(_GetControlValue) { getValue(c); }
B32_THUNK(_GetControl32BitValue) { getValue(c); }
B32_THUNK(_SetControlValue) { setValue(c); }
B32_THUNK(_SetControl32BitValue) { setValue(c); }
B32_THUNK(_GetControlMinimum) {
    CControl *control = controlOf(c.args.ptr());
    c.ret(control ? uint32_t(control->minimum) : 0);
}
B32_THUNK(_GetControlMaximum) {
    CControl *control = controlOf(c.args.ptr());
    c.ret(control ? uint32_t(control->maximum) : 0);
}
B32_THUNK(_SetControlMinimum) { setMinimum(c); }
B32_THUNK(_SetControlMaximum) { setMaximum(c); }
B32_THUNK(_ActivateControl) {
    if (CControl *control = controlOf(c.args.ptr()))
        if ([control->view respondsToSelector:@selector(setEnabled:)]) [(NSControl *)control->view setEnabled:YES];
    c.ret(0);
}
B32_THUNK(_DeactivateControl) {
    if (CControl *control = controlOf(c.args.ptr()))
        if ([control->view respondsToSelector:@selector(setEnabled:)]) [(NSControl *)control->view setEnabled:NO];
    c.ret(0);
}
B32_THUNK(_IsControlActive) {
    CControl *control = controlOf(c.args.ptr());
    c.ret(!control || ![control->view respondsToSelector:@selector(isEnabled)] || [(NSControl *)control->view isEnabled]);
}
B32_THUNK(_ShowControl) {
    if (CControl *control = controlOf(c.args.ptr())) ((NSView *)control->view).hidden = NO;
}
B32_THUNK(_HideControl) {
    if (CControl *control = controlOf(c.args.ptr())) ((NSView *)control->view).hidden = YES;
}
B32_THUNK(_DisposeControl) {}
B32_THUNK(_Draw1Control) {}
B32_THUNK(_SetControlAction) {
    CControl *control = controlOf(c.args.ptr());
    GuestAddr action = c.args.ptr();
    if (control) control->action = action;
}
B32_THUNK(_GetControlBounds) {
    CControl *control = controlOf(c.args.ptr());
    GuestAddr out = c.args.ptr();
    if (control) writeRect(c, out, ((NSView *)control->view).frame);
    c.ret(out);
}
B32_THUNK(_GetControlPopupMenuHandle) {
    CControl *control = controlOf(c.args.ptr());
    c.ret(control && control->menu ? control->menu->handle : 0);
}
#define B32_IDENTITY_UPP(symbol) B32_THUNK(symbol) { c.ret(c.args.ptr()); }
B32_IDENTITY_UPP(_NewControlActionUPP)
B32_IDENTITY_UPP(_NewControlUserPaneDrawUPP)
B32_IDENTITY_UPP(_NewEventHandlerUPP)
B32_IDENTITY_UPP(_NewEventLoopTimerUPP)
B32_THUNK(_DisposeControlActionUPP) {}
B32_THUNK(_DisposeControlUserPaneDrawUPP) {}
B32_THUNK(_DisposeEventHandlerUPP) {}
B32_THUNK(_DisposeEventLoopTimerUPP) {}

// OSErr SetControlData(control, part, tag, size, const void *data)
B32_THUNK(_SetControlData) {
    CControl *control = controlOf(c.args.ptr());
    c.args.u32();
    uint32_t tag = c.args.u32();
    uint32_t size = c.args.u32();
    GuestAddr data = c.args.ptr();
    constexpr uint32_t kCFStringTag = fourCC("cfst"), kTextTag = fourCC("text"), kUserPaneDraw = fourCC("draw");
    if (control && [control->view isKindOfClass:[NSTextField class]]) {
        NSString *text = nil;
        if (tag == kCFStringTag) text = bridge(c).toHost(c.mem.read<uint32_t>(data));
        else if (tag == kTextTag) text = [[[NSString alloc] initWithBytes:c.mem.ptr<char>(data) length:size encoding:NSMacOSRomanStringEncoding] autorelease];
        if (text) ((NSTextField *)control->view).stringValue = text;
    }
    (void)kUserPaneDraw;  // a pane's drawing callback isn't called: the panes hold only decoration here
    c.ret(0);
}
// OSErr GetControlData(control, part, tag, size, void *out, Size *actual)
B32_THUNK(_GetControlData) {
    CControl *control = controlOf(c.args.ptr());
    c.args.u32();
    uint32_t tag = c.args.u32();
    uint32_t size = c.args.u32();
    GuestAddr out = c.args.ptr(), actual = c.args.ptr();
    constexpr uint32_t kCFStringTag = fourCC("cfst"), kTextTag = fourCC("text");
    NSString *text = control && [control->view isKindOfClass:[NSTextField class]] ? ((NSTextField *)control->view).stringValue : nil;
    if (text && tag == kCFStringTag) {
        c.mem.write<uint32_t>(out, bridge(c).toGuest([text copy]));
        if (actual) c.mem.write<uint32_t>(actual, 4);
    } else if (text && tag == kTextTag) {
        NSData *bytes = [text dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
        uint32_t n = std::min(uint32_t(bytes.length), size);
        if (out) c.mem.copyIn(out, bytes.bytes, n);
        if (actual) c.mem.write<uint32_t>(actual, uint32_t(bytes.length));
    } else if (actual) {
        c.mem.write<uint32_t>(actual, 0);
    }
    c.ret(0);
}
// OSStatus CreateScrollingTextBoxControl(window, bounds, contentID, autoScroll, delayBeforeScroll,
// delayBetween, ticksPerPixel, ControlRef *out)
B32_THUNK(_CreateScrollingTextBoxControl) {
    CWindow *w = windowOf(c.args.ptr());
    NSRect bounds = readRect(c, c.args.ptr());
    c.args.u32();
    c.args.u32();
    c.args.u32();
    c.args.u32();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    if (w) {
        auto *control = new CControl{};
        control->handle = newHandle(c);
        control->target = makeTarget(c, w->target);
        control->window = w;
        control->kind = Kind::Pane;
        control->view = [[NSView alloc] initWithFrame:bounds];
        [w->content addSubview:control->view];
        controlByView[control->view] = control;
        controls[control->handle] = control;
        w->controls.push_back(control);
        c.mem.write<uint32_t>(out, control->handle);
    }
    c.ret(0);
}
B32_THUNK(_ClearKeyboardFocus) { c.ret(0); }
B32_THUNK(_AdvanceKeyboardFocus) { c.ret(0); }
B32_THUNK(_SetKeyboardFocus) {
    CWindow *w = windowOf(c.args.ptr());
    CControl *control = controlOf(c.args.ptr());
    if (w && control) [w->window makeFirstResponder:control->view];
    c.ret(0);
}

// --- menus --------------------------------------------------------------------------------

namespace {
CMenu *menuOf(GuestAddr handle) {
    auto it = menus.find(handle);
    return it == menus.end() ? nullptr : it->second;
}
NSMenuItem *itemOf(CMenu *menu, int index) {  // 1-based
    return menu && index >= 1 && index <= menu->menu.numberOfItems ? [menu->menu itemAtIndex:index - 1] : nil;
}
}  // namespace

B32_THUNK(_CountMenuItems) {
    CMenu *menu = menuOf(c.args.ptr());
    c.ret(menu ? uint32_t(menu->menu.numberOfItems) : 0);
}
// OSStatus DeleteMenuItems(menu, first, count)
B32_THUNK(_DeleteMenuItems) {
    CMenu *menu = menuOf(c.args.ptr());
    int first = c.args.i32() & 0xffff;
    int count = c.args.i32();
    for (int i = 0; menu && i < count && first <= menu->menu.numberOfItems; i++) [menu->menu removeItemAtIndex:first - 1];
    c.ret(0);
}
// OSStatus AppendMenuItemTextWithCFString(menu, text, attributes, command, MenuItemIndex *out)
B32_THUNK(_AppendMenuItemTextWithCFString) {
    CMenu *menu = menuOf(c.args.ptr());
    NSString *text = object(c);
    c.args.u32();
    uint32_t command = c.args.u32();
    GuestAddr out = c.args.ptr();
    if (menu) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:text ?: @"" action:nil keyEquivalent:@""];
        item.tag = NSInteger(command);
        [menu->menu addItem:item];
        if (out) c.mem.write<uint16_t>(out, uint16_t(menu->menu.numberOfItems));
    }
    c.ret(0);
}
B32_THUNK(_CheckMenuItem) {
    NSMenuItem *item = itemOf(menuOf(c.args.ptr()), c.args.i32() & 0xffff);
    item.state = (c.args.u32() & 0xff) ? NSControlStateValueOn : NSControlStateValueOff;
}
B32_THUNK(_EnableMenuItem) { itemOf(menuOf(c.args.ptr()), c.args.i32() & 0xffff).enabled = YES; }
B32_THUNK(_DisableMenuItem) { itemOf(menuOf(c.args.ptr()), c.args.i32() & 0xffff).enabled = NO; }
B32_THUNK(_EnableMenuCommand) {}
B32_THUNK(_DisableMenuCommand) {}
B32_THUNK(_GetMenuHandle) { c.ret(0); }
B32_THUNK(_MenuSelect) { c.ret(0); }
B32_THUNK(_GetMenuItemCommandID) {
    NSMenuItem *item = itemOf(menuOf(c.args.ptr()), c.args.i32() & 0xffff);
    GuestAddr out = c.args.ptr();
    if (out) c.mem.write<uint32_t>(out, item ? uint32_t(item.tag) : 0);
    c.ret(0);
}

// --- events -------------------------------------------------------------------------------

// OSStatus InstallEventHandler(target, handler, count, const EventTypeSpec *types, user, EventHandlerRef *out)
B32_THUNK(_InstallEventHandler) {
    GuestAddr target = c.args.ptr(), function = c.args.ptr();
    uint32_t count = c.args.u32();
    GuestAddr list = c.args.ptr(), user = c.args.u32(), out = c.args.ptr();
    auto *handler = new Handler{function, user, newHandle(c), {}};
    for (uint32_t i = 0; i < count; i++) handler->types.push_back({c.mem.read<uint32_t>(list + i * 8), c.mem.read<uint32_t>(list + i * 8 + 4)});
    auto it = targets.find(target);
    if (it != targets.end()) it->second->handlers.push_back(handler);
    if (out) c.mem.write<uint32_t>(out, handler->ref);
    c.ret(0);
}
B32_THUNK(_RemoveEventHandler) {
    GuestAddr ref = c.args.ptr();
    for (auto &[address, target] : targets)
        std::erase_if(target->handlers, [ref](Handler *h) { return h->ref == ref; });
    c.ret(0);
}
namespace {
void changeTypes(Call &c, bool add) {
    GuestAddr ref = c.args.ptr();
    uint32_t count = c.args.u32();
    GuestAddr list = c.args.ptr();
    for (auto &[address, target] : targets)
        for (Handler *h : target->handlers) {
            if (h->ref != ref) continue;
            for (uint32_t i = 0; i < count; i++) {
                std::pair<uint32_t, uint32_t> type{c.mem.read<uint32_t>(list + i * 8), c.mem.read<uint32_t>(list + i * 8 + 4)};
                if (add) h->types.push_back(type);
                else std::erase(h->types, type);
            }
        }
    c.ret(0);
}
}  // namespace
B32_THUNK(_AddEventTypesToHandler) { changeTypes(c, true); }
B32_THUNK(_RemoveEventTypesFromHandler) { changeTypes(c, false); }

B32_THUNK(_GetEventClass) { c.ret(events.count(c.mem.read<uint32_t>(c.cpu.sp() + 4)) ? events[c.args.ptr()]->cls : 0); }
B32_THUNK(_GetEventKind) { c.ret(events.count(c.mem.read<uint32_t>(c.cpu.sp() + 4)) ? events[c.args.ptr()]->kind : 0); }
// OSStatus GetEventParameter(event, name, desired, actualType *, size, actualSize *, void *data)
B32_THUNK(_GetEventParameter) {
    GuestAddr handle = c.args.ptr();
    uint32_t name = c.args.u32();
    uint32_t desired = c.args.u32();
    GuestAddr actualType = c.args.ptr();
    uint32_t size = c.args.u32();
    GuestAddr actualSize = c.args.ptr(), data = c.args.ptr();
    auto it = events.find(handle);
    if (it == events.end() || !it->second->params.count(name)) {
        c.ret(uint32_t(kEventParamNotFound));
        return;
    }
    auto &bytes = it->second->params[name];
    if (actualType) c.mem.write<uint32_t>(actualType, desired);
    if (actualSize) c.mem.write<uint32_t>(actualSize, uint32_t(bytes.size()));
    if (data) c.mem.copyIn(data, bytes.data(), std::min(uint32_t(bytes.size()), size));
    c.ret(0);
}
B32_THUNK(_CreateEvent) {
    c.args.ptr();
    uint32_t cls = c.args.u32(), kind = c.args.u32();
    c.args.u64();  // when
    c.args.u32();
    GuestAddr out = c.args.ptr();
    c.mem.write<uint32_t>(out, makeEvent(c.rt, cls, kind));
    c.ret(0);
}
B32_THUNK(_SendEventToEventTarget) {
    GuestAddr event = c.args.ptr(), target = c.args.ptr();
    c.ret(uint32_t(events.count(event) ? dispatchTo(event, target) : kEventNotHandled));
}
B32_THUNK(_ReleaseEvent) {
    GuestAddr event = c.args.ptr();
    if (events.count(event)) freeEvent(c.rt, event);
}
B32_THUNK(_CallNextEventHandler) { c.ret(uint32_t(kEventNotHandled)); }
B32_THUNK(_GetCurrentEventLoop) { c.ret(1); }
B32_THUNK(_GetMainEventLoop) { c.ret(1); }
B32_THUNK(_RunCurrentEventLoop) {
    b32::appkit::pumpCarbonEvents(c.args.f64());
    c.ret(0);
}

// OSStatus ReceiveNextEvent(count, list, timeout (double), pull, EventRef *out)
B32_THUNK(_ReceiveNextEvent) {
    c.args.u32();
    c.args.ptr();
    double timeout = c.args.f64();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    PumpedEvent event = pumpOne(std::max(timeout, 0.0));
    if (!event.valid) {
        c.ret(uint32_t(kEventLoopTimedOut));
        return;
    }
    uint32_t cls = event.what <= 2 ? kClassMouse : kClassKeyboard;
    uint32_t kind = event.what == 1 ? kMouseDown : event.what == 2 ? kMouseUp : event.what == 3 ? kKeyDown : event.what == 4 ? kKeyUp : kKeyRepeat;
    GuestAddr handle = makeEvent(c.rt, cls, kind);
    if (cls == kClassKeyboard) {
        uint32_t code = (event.message >> 8) & 0xff;
        uint8_t character = event.message & 0xff;
        setParam(handle, kKeyCodeParam, &code, 4);
        setParam(handle, kMacCharParam, &character, 1);
    }
    uint32_t modifiers = event.modifiers;
    setParam(handle, kModifiersParam, &modifiers, 4);
    int16_t point[2] = {int16_t(event.where.y), int16_t(event.where.x)};
    setParam(handle, kMouseLocationParam, point, 4);
    uint16_t button = 1;
    setParam(handle, kMouseButtonParam, &button, 2);
    if (out) c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}

// Boolean WaitNextEvent(mask, EventRecord *, sleep ticks, RgnHandle)
// EventRecord: what (2), message (4), when (4), where {v, h} (4), modifiers (2).
B32_THUNK(_WaitNextEvent) {
    c.args.u32();
    GuestAddr record = c.args.ptr();
    uint32_t ticks = c.args.u32();
    PumpedEvent event = pumpOne(ticks / 60.0);
    NSPoint where = event.valid ? event.where : globalMouse();
    if (record) {
        c.mem.write<int16_t>(record, event.valid ? event.what : 0);
        c.mem.write<uint32_t>(record + 2, event.message);
        c.mem.write<uint32_t>(record + 6, uint32_t(NSProcessInfo.processInfo.systemUptime * 60));
        c.mem.write<int16_t>(record + 10, int16_t(where.y));
        c.mem.write<int16_t>(record + 12, int16_t(where.x));
        c.mem.write<uint16_t>(record + 14, event.modifiers);
    }
    c.ret(event.valid ? 1 : 0);
}
B32_THUNK(_FlushEvents) {}
B32_THUNK(_ConvertEventRefToEventRecord) {
    GuestAddr handle = c.args.ptr(), record = c.args.ptr();
    auto it = events.find(handle);
    if (it == events.end()) {
        c.ret(0);
        return;
    }
    CEvent *event = it->second;
    int16_t what = event->cls == kClassKeyboard ? (event->kind == kKeyDown ? 3 : event->kind == kKeyUp ? 4 : 5) : event->kind == kMouseDown ? 1 : 2;
    uint32_t code = 0;
    uint8_t character = 0;
    if (event->params.count(kKeyCodeParam)) std::memcpy(&code, event->params[kKeyCodeParam].data(), 4);
    if (event->params.count(kMacCharParam)) character = event->params[kMacCharParam][0];
    c.mem.write<int16_t>(record, what);
    c.mem.write<uint32_t>(record + 2, uint32_t(character) | code << 8);
    c.ret(1);
}

B32_THUNK(_RunApplicationEventLoop) {
    ensureCarbonApplication();
    [NSApp run];
}
B32_THUNK(_QuitApplicationEventLoop) {
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
B32_THUNK(_RunAppModalLoopForWindow) {
    if (CWindow *w = windowOf(c.args.ptr())) [NSApp runModalForWindow:w->window];
    c.ret(0);
}
B32_THUNK(_QuitAppModalLoopForWindow) {
    [NSApp stopModal];
    c.args.ptr();
    c.ret(0);
}

// OSStatus InstallEventLoopTimer(loop, delay, interval, upp, user, EventLoopTimerRef *out); doubles.
B32_THUNK(_InstallEventLoopTimer) {
    c.args.u32();
    double delay = c.args.f64(), interval = c.args.f64();
    GuestAddr function = c.args.ptr(), user = c.args.u32(), out = c.args.ptr();
    GuestAddr handle = newHandle(c);
    NSTimer *timer = [NSTimer timerWithTimeInterval:std::max(interval, 0.001) repeats:interval > 0 block:^(NSTimer *) {
        Runtime::threadCpu().call(function, {handle, user});
    }];
    timer.fireDate = [NSDate dateWithTimeIntervalSinceNow:delay];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    timers[handle] = timer;
    if (out) c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}
B32_THUNK(_RemoveEventLoopTimer) {
    GuestAddr handle = c.args.ptr();
    [timers[handle] invalidate];
    timers.erase(handle);
    c.ret(0);
}

// void GetKeys(KeyMap): 128 bits, a byte for every 8 key codes.
B32_THUNK(_GetKeys) { c.mem.copyIn(c.args.ptr(), keyState, sizeof keyState); }
// void GetMouse(Point *) (local to the current port), GetGlobalMouse.
B32_THUNK(_GetGlobalMouse) {
    GuestAddr out = c.args.ptr();
    NSPoint p = globalMouse();
    c.mem.write<int16_t>(out, int16_t(p.y));
    c.mem.write<int16_t>(out + 2, int16_t(p.x));
}
B32_THUNK(_GetMouse) {
    GuestAddr out = c.args.ptr();
    NSPoint p = globalMouse();
    if (CWindow *w = windowOf(currentPort)) {
        NSRect bounds = globalBounds(w);
        p.x -= bounds.origin.x;
        p.y -= bounds.origin.y;
    }
    c.mem.write<int16_t>(out, int16_t(p.y));
    c.mem.write<int16_t>(out + 2, int16_t(p.x));
}
B32_THUNK(_Button) { c.ret(NSEvent.pressedMouseButtons & 1); }
B32_THUNK(_FindWindow) {
    c.args.u32();
    c.mem.write<uint32_t>(c.args.ptr(), 0);
    c.ret(0);
}
B32_THUNK(_InitCursor) {}
B32_THUNK(_HideCursor) { [NSCursor hide]; }
B32_THUNK(_ShowCursor) { [NSCursor unhide]; }
B32_THUNK(_SetSystemUIMode) { c.ret(0); }
B32_THUNK(_GetSystemUIMode) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    if (a) c.mem.write<uint32_t>(a, 0);
    if (b) c.mem.write<uint32_t>(b, 0);
}
B32_THUNK(_SysBeep) { NSBeep(); }
B32_THUNK(_TickCount) { c.ret(uint32_t(NSProcessInfo.processInfo.systemUptime * 60)); }
B32_THUNK(_GetDblTime) { c.ret(30); }

// QuickDraw's current port, all games ask it to remember for them.
B32_THUNK(_SetPort) { currentPort = c.args.ptr(); }
B32_THUNK(_GetPort) { c.mem.write<uint32_t>(c.args.ptr(), currentPort); }
B32_THUNK(_SetPortDialogPort) { currentPort = c.args.ptr(); }
B32_THUNK(_GetPortBounds) {
    GuestAddr port = c.args.ptr(), out = c.args.ptr();
    NSRect bounds = NSZeroRect;
    if (CWindow *w = windowOf(port)) bounds = NSMakeRect(0, 0, w->content.bounds.size.width, w->content.bounds.size.height);
    writeRect(c, out, bounds);
    c.ret(out);
}
