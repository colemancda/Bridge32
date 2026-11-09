// Game controllers (MFi, Xbox, PlayStation...) for Mac games from before
// GameController.framework: the controller becomes the keyboard and mouse those
// games read, as events posted to the app itself. The system cursor isn't
// moved, and nothing reaches other apps. B32_NO_CONTROLLER=1 turns it off.
//
//   Left stick, D-pad    arrow keys
//   Right trigger        up arrow (accelerate)
//   Left trigger         down arrow (brake)
//   Right stick          mouse pointer
//   A                    left mouse button (select, nitro)
//   Right shoulder       space (nitro)
//   B, Menu              escape (back, pause)
//   X, Y, Left shoulder  1, 2, 3 (camera views)

#include "core/Log.h"

#import <AppKit/AppKit.h>
#import <GameController/GameController.h>
#include <Carbon/Carbon.h>

#include <cmath>
#include <vector>

namespace {

// How far a stick or trigger has to go to count as a key press, and to let go
// again; the gap stops a held stick at the edge from chattering.
constexpr float kPressAt = 0.4f, kReleaseAt = 0.25f;
constexpr float kStickDeadZone = 0.15f;
constexpr CGFloat kPointerSpeed = 22;  // points per tick at full deflection
constexpr NSTimeInterval kTick = 1.0 / 60;

struct KeyState {
    unsigned short keyCode;
    unichar character;
    bool down = false;
};

// Indexes into `keys`.
enum Key { Up, Down, Left, Right, Space, Escape, One, Two, Three, KeyCount };
KeyState keys[KeyCount] = {
    {kVK_UpArrow, NSUpArrowFunctionKey},       {kVK_DownArrow, NSDownArrowFunctionKey},
    {kVK_LeftArrow, NSLeftArrowFunctionKey},   {kVK_RightArrow, NSRightArrowFunctionKey},
    {kVK_Space, ' '},                          {kVK_Escape, 0x1B},
    {kVK_ANSI_1, '1'},                         {kVK_ANSI_2, '2'},
    {kVK_ANSI_3, '3'},
};

bool mouseDown = false;
bool pointerActive = false;
NSPoint pointer;
NSWindow *lastWindow = nil;  // not retained: only used while the app has its windows

NSWindow *targetWindow() { return NSApp.keyWindow ?: NSApp.mainWindow; }

void setKey(Key which, bool down, NSWindow *window) {
    KeyState &key = keys[which];
    if (key.down == down) return;
    key.down = down;
    NSString *text = [NSString stringWithCharacters:&key.character length:1];
    NSEvent *event = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:window.windowNumber
                                       context:nil
                                    characters:text
                   charactersIgnoringModifiers:text
                                     isARepeat:NO
                                       keyCode:key.keyCode];
    [NSApp postEvent:event atStart:NO];
}

void postMouse(NSEventType type, NSWindow *window) {
    NSEvent *event = [NSEvent mouseEventWithType:type
                                        location:pointer
                                   modifierFlags:0
                                       timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:window.windowNumber
                                         context:nil
                                     eventNumber:0
                                      clickCount:1
                                        pressure:mouseDown ? 1 : 0];
    [NSApp postEvent:event atStart:NO];
}

// With a hysteresis: `held` is whether the input currently counts as pressed.
bool pressed(float value, bool held) { return value >= (held ? kReleaseAt : kPressAt); }

void movePointer(GCExtendedGamepad *pad, NSWindow *window) {
    CGFloat x = pad.rightThumbstick.xAxis.value, y = pad.rightThumbstick.yAxis.value;
    if (std::hypot(x, y) < kStickDeadZone) {
        pointerActive = false;
        return;
    }
    if (!pointerActive) {
        // Picks up from wherever the real mouse left it.
        pointerActive = true;
        pointer = window.mouseLocationOutsideOfEventStream;
    }
    NSRect bounds = window.contentView.bounds;
    pointer.x = std::min(std::max<CGFloat>(pointer.x + x * kPointerSpeed, 0), NSMaxX(bounds) - 1);
    pointer.y = std::min(std::max<CGFloat>(pointer.y + y * kPointerSpeed, 0), NSMaxY(bounds) - 1);
    postMouse(mouseDown ? NSEventTypeLeftMouseDragged : NSEventTypeMouseMoved, window);
}

void poll() {
    GCController *controller = GCController.current ?: GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    NSWindow *window = targetWindow();
    if (window) lastWindow = window;
    if (!pad || !window) {
        // Don't leave anything held down in the game if the controller or
        // the focus goes away.
        if (lastWindow) {
            for (int i = 0; i < KeyCount; i++) setKey(Key(i), false, lastWindow);
            if (mouseDown) {
                mouseDown = false;
                postMouse(NSEventTypeLeftMouseUp, lastWindow);
            }
        }
        return;
    }

    float stickX = pad.leftThumbstick.xAxis.value, stickY = pad.leftThumbstick.yAxis.value;
    float padX = pad.dpad.xAxis.value, padY = pad.dpad.yAxis.value;
    float left = std::max(-stickX, -padX), right = std::max(stickX, padX);
    float up = std::max({stickY, padY, pad.rightTrigger.value});
    float down = std::max({-stickY, -padY, pad.leftTrigger.value});
    setKey(Left, pressed(left, keys[Left].down), window);
    setKey(Right, pressed(right, keys[Right].down), window);
    setKey(Up, pressed(up, keys[Up].down), window);
    setKey(Down, pressed(down, keys[Down].down), window);

    setKey(Space, pad.rightShoulder.isPressed, window);
    setKey(Escape, pad.buttonB.isPressed || pad.buttonMenu.isPressed, window);
    setKey(One, pad.buttonX.isPressed, window);
    setKey(Two, pad.buttonY.isPressed, window);
    setKey(Three, pad.leftShoulder.isPressed, window);

    movePointer(pad, window);

    bool a = pad.buttonA.isPressed;
    if (a != mouseDown) {
        if (!pointerActive) pointer = window.mouseLocationOutsideOfEventStream;
        mouseDown = a;
        postMouse(a ? NSEventTypeLeftMouseDown : NSEventTypeLeftMouseUp, window);
    }
}
}  // namespace

namespace b32::appkit {

void startControllerMapping() {
    if (getenv("B32_NO_CONTROLLER")) return;
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
                                                    GCController *controller = note.object;
                                                    log("controller connected: %s", controller.vendorName.UTF8String ?: "unnamed");
                                                }];
    NSTimer *timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *) { poll(); }];
    // Common modes, so it keeps working while a menu or a modal loop is up.
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

}  // namespace b32::appkit
