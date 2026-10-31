// Phone input for a Mac with a game controller (MFi, Xbox, PlayStation...),
// chosen per app with B32Controller in Info.plist (make-app.sh --controller)
// or $B32_CONTROLLER, a comma-separated list of:
//  - tilt:  the right stick (or D-pad) tilts a fake phone, as racing games
//           steer: left/right turns it like a wheel, up/down pitches it.
//  - swipe: the right stick (or D-pad) swipes from the middle of the screen
//           each time it picks a new direction, as maze games like PAC-MAN
//           read their controls.
//
// UIAccelerometer has no Mac hardware behind it, so the guest always gets
// this compat one; without tilt it reports a phone held still.

#include "UIKitSupport.h"

#include "core/Log.h"

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <vector>

using namespace b32;

namespace {

bool enabled(NSString *mode) {
    static NSArray<NSString *> *modes = [] {
        const char *env = getenv("B32_CONTROLLER");
        NSString *setting = env ? @(env) : [NSBundle.mainBundle objectForInfoDictionaryKey:@"B32Controller"];
        return [[setting ?: @"" componentsSeparatedByString:@","] retain];
    }();
    return [modes containsObject:mode];
}

// The right stick, or the D-pad when the stick is centered; up is +y.
CGPoint stick() {
    GCController *controller = GCController.current ?: GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    if (!pad) return CGPointZero;
    CGPoint value = CGPointMake(pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value);
    if (std::hypot(value.x, value.y) < 0.15) value = CGPointMake(pad.dpad.xAxis.value, pad.dpad.yAxis.value);
    if (std::hypot(value.x, value.y) < 0.15) value = CGPointZero;
    return value;
}

// How far the guest's screen is turned (as in UIKitSupport.mm).
CGFloat guestRotation() {
    NSString *orientation = [NSBundle.mainBundle objectForInfoDictionaryKey:@"B32Orientation"]
                                ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"UIInterfaceOrientation"];
    if ([orientation hasSuffix:@"LandscapeRight"]) return -M_PI_2;
    if ([orientation hasSuffix:@"LandscapeLeft"]) return M_PI_2;
    return 0;
}

}  // namespace

// --- tilt ---------------------------------------------------------------------------------

@interface B32Acceleration : NSObject
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic) double x, y, z;  // UIAccelerationValue
@end

@implementation B32Acceleration
@end

@interface B32Compat_UIAccelerometer : NSObject
@property (nonatomic) NSTimeInterval updateInterval;
@property (nonatomic, assign) id delegate;
@end

@implementation B32Compat_UIAccelerometer {
    NSTimer *_timer;
    double _roll, _pitch;  // smoothed, so the D-pad steers gradually
}

+ (instancetype)sharedAccelerometer {
    static B32Compat_UIAccelerometer *shared = [[B32Compat_UIAccelerometer alloc] init];
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _updateInterval = 1.0 / 30;
        if (enabled(@"tilt")) log("controller: the right stick and D-pad tilt the device");
    }
    return self;
}

- (void)setDelegate:(id)delegate {
    _delegate = delegate;
    [self restart];
}

- (void)setUpdateInterval:(NSTimeInterval)interval {
    _updateInterval = std::max(interval, 1.0 / 100);
    [self restart];
}

- (void)restart {
    [_timer invalidate];
    _timer = nil;
    if (!_delegate) return;
    _timer = [NSTimer timerWithTimeInterval:_updateInterval target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

// Gravity as the phone's accelerometer reads it (in g, device axes: +x to
// the right of the portrait screen, +y to its top, +z out of it), for a
// phone held facing the player, tipped back by `pitch` and turned like a
// steering wheel by `roll` (positive: clockwise).
- (void)tick {
    CGPoint input = enabled(@"tilt") ? stick() : CGPointZero;
    const double maxRoll = 45 * M_PI / 180, restPitch = 35 * M_PI / 180, pitchRange = 30 * M_PI / 180;
    double alpha = std::min(1.0, _updateInterval * 10);  // ~0.1 s to settle
    _roll += (input.x * maxRoll - _roll) * alpha;
    _pitch += (-input.y * pitchRange - _pitch) * alpha;
    double pitch = restPitch + _pitch;

    // In the player's view (u right, v up, w toward the player).
    double u = std::cos(pitch) * std::sin(_roll), v = -std::cos(pitch) * std::cos(_roll), w = -std::sin(pitch);
    // The portrait device axes in that view, by how the game holds it.
    double x = u, y = v;
    CGFloat rotation = guestRotation();
    if (rotation < 0) {  // landscape right: the phone's top points left
        x = v;
        y = -u;
    } else if (rotation > 0) {  // landscape left: its top points right
        x = -v;
        y = u;
    }
    B32Acceleration *acceleration = [[B32Acceleration alloc] init];
    acceleration.timestamp = NSProcessInfo.processInfo.systemUptime;
    acceleration.x = x;
    acceleration.y = y;
    acceleration.z = w;
    SEL didAccelerate = sel_registerName("accelerometer:didAccelerate:");
    if ([_delegate respondsToSelector:didAccelerate])
        reinterpret_cast<void (*)(id, SEL, id, id)>(objc_msgSend)(_delegate, didAccelerate, self, acceleration);
    [acceleration release];
}

@end

// --- synthetic touches ----------------------------------------------------------------------

// Just enough of UITouch and UIEvent for games' touch methods.
@interface B32Touch : NSObject
@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) UIResponder *view;  // the responder it's delivered to
@property (nonatomic) CGPoint location, previousLocation;  // in the window
@property (nonatomic) UITouchPhase phase;
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic) NSUInteger tapCount;
@end

@implementation B32Touch

- (void)dealloc {
    [_window release];
    [_view release];
    [super dealloc];
}

- (CGPoint)locationInView:(UIView *)view { return view ? [_window convertPoint:_location toView:view] : _location; }

- (CGPoint)previousLocationInView:(UIView *)view {
    return view ? [_window convertPoint:_previousLocation toView:view] : _previousLocation;
}

// UIKit's default touch handlers ask a touch whether to pass it up the
// responder chain; a synthetic swipe stays with the view it was sent to.
- (BOOL)_wantsForwardingFromResponder:(id)responder toNextResponder:(id)next withEvent:(id)event {
    return NO;
}

@end

@interface B32TouchEvent : NSObject
@property (nonatomic, retain) NSSet *allTouches;
@property (nonatomic) NSTimeInterval timestamp;
@end

@implementation B32TouchEvent

- (void)dealloc {
    [_allTouches release];
    [super dealloc];
}

- (UIEventType)type { return UIEventTypeTouches; }
- (NSSet *)touchesForView:(UIView *)view { return _allTouches; }
- (NSSet *)touchesForWindow:(UIWindow *)window { return _allTouches; }

@end

namespace {

// The guest's key window and, for a point on the game's screen as the
// player sees it (in its points, before the Mac scales it), the same point in
// that window's own coordinates: the window may be turned on the Mac.
CGPoint guestPoint(UIWindow *window, CGPoint screen) {
    CGSize bounds = window.bounds.size;
    CGSize shown = guestRotation() != 0 ? CGSizeMake(bounds.height, bounds.width) : bounds;
    CGPoint fromCenter = CGPointMake(screen.x - shown.width / 2, screen.y - shown.height / 2);
    CGPoint turned = CGPointApplyAffineTransform(fromCenter, CGAffineTransformMakeRotation(-guestRotation()));
    return CGPointMake(turned.x + bounds.width / 2, turned.y + bounds.height / 2);
}

// The first responder from the view at `point` up whose touch handling is
// the game's own: guest methods are bridge trampolines, which live in no
// loaded image. (UIKit's own handlers would pass the touches on through
// UIKit's private event machinery.)
UIResponder *touchHandler(UIWindow *window, CGPoint point) {
    for (UIResponder *r = [window hitTest:point withEvent:nil]; r; r = r.nextResponder) {
        Dl_info info{};
        IMP imp = class_getMethodImplementation(object_getClass(r), @selector(touchesBegan:withEvent:));
        if (!dladdr((void *)imp, &info)) return r;
    }
    return nil;
}

NSMutableSet *activeTouches() {
    static NSMutableSet *touches = [[NSMutableSet alloc] init];
    return touches;
}

}  // namespace

// One synthetic finger on the game's screen, in the player's view of it.
@interface B32Finger : NSObject
@property (nonatomic, readonly) BOOL down;
- (void)moveTo:(CGPoint)screen;  // touches down first if it isn't already
- (void)up;
@end

@implementation B32Finger {
    B32Touch *_touch;
}

- (BOOL)down { return _touch != nil; }

- (void)send:(UITouchPhase)phase {
    _touch.phase = phase;
    B32TouchEvent *event = [[B32TouchEvent alloc] init];
    event.allTouches = [[activeTouches() copy] autorelease];
    event.timestamp = _touch.timestamp = NSProcessInfo.processInfo.systemUptime;
    NSSet *touches = [NSSet setWithObject:_touch];
    UIResponder *handler = _touch.view;
    switch (phase) {
    case UITouchPhaseBegan: [handler touchesBegan:touches withEvent:(UIEvent *)event]; break;
    case UITouchPhaseMoved: [handler touchesMoved:touches withEvent:(UIEvent *)event]; break;
    default: [handler touchesEnded:touches withEvent:(UIEvent *)event]; break;
    }
    [event release];
}

- (void)moveTo:(CGPoint)screen {
    if (_touch) {
        CGPoint point = guestPoint(_touch.window, screen);
        if (CGPointEqualToPoint(point, _touch.location)) return;
        _touch.previousLocation = _touch.location;
        _touch.location = point;
        [self send:UITouchPhaseMoved];
        return;
    }
    UIWindow *window = uikit::guestKeyWindow();
    if (!window) return;
    CGPoint point = guestPoint(window, screen);
    UIResponder *handler = touchHandler(window, point);
    if (!handler) return;
    _touch = [[B32Touch alloc] init];
    _touch.window = window;
    _touch.view = handler;
    _touch.tapCount = 1;
    _touch.location = _touch.previousLocation = point;
    [activeTouches() addObject:_touch];
    [self send:UITouchPhaseBegan];
}

- (void)up {
    if (!_touch) return;
    [self send:UITouchPhaseEnded];
    [activeTouches() removeObject:_touch];
    [_touch release];
    _touch = nil;
}

- (void)dealloc {
    [self up];
    [super dealloc];
}

@end

// --- swipe ---------------------------------------------------------------------------------

@interface B32SwipePad : NSObject
@end

@implementation B32SwipePad {
    int _direction;  // 0 none, 1 right, 2 up, 3 left, 4 down
}

- (void)poll {
    CGPoint input = stick();
    int direction = 0;
    if (std::hypot(input.x, input.y) > 0.5)
        direction = std::fabs(input.x) > std::fabs(input.y) ? (input.x > 0 ? 1 : 3) : (input.y > 0 ? 2 : 4);
    if (direction && direction != _direction) [self swipe:direction];
    _direction = direction;
}

// A quick drag from the middle of the guest's screen.
- (void)swipe:(int)direction {
    UIWindow *window = uikit::guestKeyWindow();
    if (!window) return;
    CGSize bounds = window.bounds.size;
    CGPoint center = guestRotation() != 0 ? CGPointMake(bounds.height / 2, bounds.width / 2)
                                          : CGPointMake(bounds.width / 2, bounds.height / 2);
    CGPoint step = direction == 1 ? CGPointMake(1, 0) : direction == 2 ? CGPointMake(0, -1)
                 : direction == 3 ? CGPointMake(-1, 0) : CGPointMake(0, 1);
    B32Finger *finger = [[B32Finger alloc] init];
    [finger moveTo:center];
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(i) * 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [finger moveTo:CGPointMake(center.x + step.x * 20 * i, center.y + step.y * 20 * i)];
            if (i == 4) {
                [finger up];
                [finger release];
            }
        });
    }
}

@end

// --- buttons and sticks on on-screen controls ----------------------------------------------

// B32ControllerButtons (or $B32_CONTROLLER_BUTTONS) puts fingers on a game's
// on-screen controls, as space-separated bindings in the game's screen points:
//   a=383,215              a button holds a finger there while pressed
//   leftStick=stick:71,259,35   a stick drags a finger around a centre, up to
//                               the radius: a virtual joystick
//   rightStick=look:300,140,240 a stick drags a finger from there at up to
//                               that many points a second, lifting and
//                               starting over as it nears the edge: looking
//                               around by swiping
// Inputs: a b x y l1 r1 l2 r2 l3 r3 menu options up down left right, and
// leftStick rightStick dpad.

namespace {

struct Binding {
    enum Kind { Button, Stick, Look } kind;
    NSString *input;
    CGPoint point;
    CGFloat amount;     // stick radius, or look speed
    CGPoint dragged{};  // how far a look has dragged
    B32Finger *finger;
};

GCControllerElement *element(GCExtendedGamepad *pad, NSString *name) {
    static NSDictionary<NSString *, NSString *> *keys = [@{
        @"a" : @"buttonA", @"b" : @"buttonB", @"x" : @"buttonX", @"y" : @"buttonY",
        @"l1" : @"leftShoulder", @"r1" : @"rightShoulder", @"l2" : @"leftTrigger", @"r2" : @"rightTrigger",
        @"l3" : @"leftThumbstickButton", @"r3" : @"rightThumbstickButton",
        @"menu" : @"buttonMenu", @"options" : @"buttonOptions",
        @"leftStick" : @"leftThumbstick", @"rightStick" : @"rightThumbstick", @"dpad" : @"dpad",
    } retain];
    if ([name isEqualToString:@"up"]) return pad.dpad.up;
    if ([name isEqualToString:@"down"]) return pad.dpad.down;
    if ([name isEqualToString:@"left"]) return pad.dpad.left;
    if ([name isEqualToString:@"right"]) return pad.dpad.right;
    NSString *key = keys[name];
    return key ? [pad valueForKey:key] : nil;
}

std::vector<Binding> &bindings() {
    static std::vector<Binding> list = [] {
        std::vector<Binding> parsed;
        const char *env = getenv("B32_CONTROLLER_BUTTONS");
        NSString *spec = env ? @(env) : [NSBundle.mainBundle objectForInfoDictionaryKey:@"B32ControllerButtons"];
        for (NSString *entry in [spec ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
            NSArray<NSString *> *parts = [entry componentsSeparatedByString:@"="];
            if (parts.count != 2) continue;
            Binding b{Binding::Button, [parts[0] retain], {}, 0, {}, [[B32Finger alloc] init]};
            NSString *value = parts[1];
            if ([value hasPrefix:@"stick:"]) b.kind = Binding::Stick;
            if ([value hasPrefix:@"look:"]) b.kind = Binding::Look;
            if (b.kind != Binding::Button) value = [value substringFromIndex:[value rangeOfString:@":"].location + 1];
            NSArray<NSString *> *numbers = [value componentsSeparatedByString:@","];
            if (numbers.count < 2) continue;
            b.point = CGPointMake(numbers[0].doubleValue, numbers[1].doubleValue);
            b.amount = numbers.count > 2 ? numbers[2].doubleValue : 30;
            parsed.push_back(b);
        }
        return parsed;
    }();
    return list;
}

void pollBindings() {
    GCController *controller = GCController.current ?: GCController.controllers.firstObject;
    GCExtendedGamepad *pad = controller.extendedGamepad;
    const CGFloat dt = 1.0 / 60;
    for (Binding &b : bindings()) {
        GCControllerElement *input = pad ? element(pad, b.input) : nil;
        if (b.kind == Binding::Button) {
            BOOL pressed = [input isKindOfClass:[GCControllerButtonInput class]] && ((GCControllerButtonInput *)input).pressed;
            if (pressed) [b.finger moveTo:b.point];
            else [b.finger up];
            continue;
        }
        CGPoint v = CGPointZero;
        if ([input isKindOfClass:[GCControllerDirectionPad class]]) {
            auto *axes = (GCControllerDirectionPad *)input;
            v = CGPointMake(axes.xAxis.value, -axes.yAxis.value);  // screen y points down
        }
        if (std::hypot(v.x, v.y) < 0.15) {
            [b.finger up];
            b.dragged = CGPointZero;
            continue;
        }
        if (b.kind == Binding::Stick) {
            [b.finger moveTo:CGPointMake(b.point.x + v.x * b.amount, b.point.y + v.y * b.amount)];
            continue;
        }
        b.dragged = CGPointMake(b.dragged.x + v.x * b.amount * dt, b.dragged.y + v.y * b.amount * dt);
        if (std::hypot(b.dragged.x, b.dragged.y) > 80) {  // lift and start over
            [b.finger up];
            b.dragged = CGPointZero;
        }
        [b.finger moveTo:CGPointMake(b.point.x + b.dragged.x, b.point.y + b.dragged.y)];
    }
}

}  // namespace

@interface B32ControllerPoller : NSObject
@end

@implementation B32ControllerPoller {
    B32SwipePad *_swipe;
}

- (instancetype)init {
    if ((self = [super init]) && enabled(@"swipe")) _swipe = [[B32SwipePad alloc] init];
    return self;
}

- (void)poll {
    [_swipe poll];
    pollBindings();
}

@end

void b32::uikit::startController() {
    bool swipe = enabled(@"swipe");
    size_t count = bindings().size();
    if (!swipe && !count) return;
    if (swipe) log("controller: the right stick and D-pad swipe");
    if (count) log("controller: %zu buttons and sticks on on-screen controls", count);
    static B32ControllerPoller *poller = [[B32ControllerPoller alloc] init];
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:poller selector:@selector(poll) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
