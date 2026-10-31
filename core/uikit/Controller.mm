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

// --- swipe --------------------------------------------------------------------------------

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

// A quick drag from the middle of the guest's screen, in the guest's own
// coordinates (its window may be turned on the Mac).
- (void)swipe:(int)direction {
    UIWindow *window = uikit::guestKeyWindow();
    if (!window) return;
    CGPoint center = CGPointMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds));
    // The touches go to the first responder from the view there up whose
    // touch handling is the game's own: guest methods are bridge trampolines,
    // which live in no loaded image. (UIKit's own handlers would pass them on
    // through UIKit's private event machinery.)
    UIResponder *view = nil;
    for (UIResponder *r = [window hitTest:center withEvent:nil]; r && !view; r = r.nextResponder) {
        Dl_info info{};
        IMP imp = class_getMethodImplementation(object_getClass(r), @selector(touchesBegan:withEvent:));
        if (!dladdr((void *)imp, &info)) view = r;
    }
    if (!view) return;

    CGPoint screen = direction == 1 ? CGPointMake(1, 0) : direction == 2 ? CGPointMake(0, -1)
                   : direction == 3 ? CGPointMake(-1, 0) : CGPointMake(0, 1);
    CGPoint step = CGPointApplyAffineTransform(screen, CGAffineTransformMakeRotation(-guestRotation()));

    B32Touch *touch = [[[B32Touch alloc] init] autorelease];
    touch.window = window;
    touch.view = view;
    touch.tapCount = 1;
    B32TouchEvent *event = [[[B32TouchEvent alloc] init] autorelease];
    event.allTouches = [NSSet setWithObject:touch];
    NSSet *touches = event.allTouches;

    auto send = [=](UITouchPhase phase, CGFloat distance) {
        touch.previousLocation = phase == UITouchPhaseBegan ? center : touch.location;
        touch.location = CGPointMake(center.x + step.x * distance, center.y + step.y * distance);
        touch.phase = phase;
        touch.timestamp = event.timestamp = NSProcessInfo.processInfo.systemUptime;
        switch (phase) {
        case UITouchPhaseBegan: [view touchesBegan:touches withEvent:(UIEvent *)event]; break;
        case UITouchPhaseMoved: [view touchesMoved:touches withEvent:(UIEvent *)event]; break;
        default: [view touchesEnded:touches withEvent:(UIEvent *)event]; break;
        }
    };
    [touch retain];
    [event retain];
    send(UITouchPhaseBegan, 0);
    for (int i = 1; i <= 4; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(i) * 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            send(i < 4 ? UITouchPhaseMoved : UITouchPhaseEnded, CGFloat(i) * 20);
            if (i == 4) {
                [touch release];
                [event release];
            }
        });
    }
}

@end

void b32::uikit::startController() {
    if (!enabled(@"swipe")) return;
    log("controller: the right stick and D-pad swipe");
    static B32SwipePad *pad = [[B32SwipePad alloc] init];
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:pad selector:@selector(poll) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
