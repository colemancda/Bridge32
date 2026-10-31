// UIKit glue: app startup, and making the Mac look like an iPhone to the
// guest (a 320x480-point screen in a window of that size).
//
// Current UIKit requires the scene lifecycle, which 32-bit apps predate: they
// create a UIWindow (with -initWithFrame:, or from the main nib) before any
// scene exists. The shell's B32SceneDelegate takes the scene, and
// windows created before it connects are parked and attached to it then.

#include "UIKitSupport.h"

#include "core/Device.h"
#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Dispatch.h"

#import <UIKit/UIKit.h>
#include <crt_externs.h>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

namespace {

constexpr CGFloat kStatusBarHeight = 20;
CGFloat screenWidth() { return device::current().screenWidth; }
CGFloat screenHeight() { return device::current().screenHeight; }

UIWindowScene *guestScene = nil;

// How far the guest's portrait screen is turned on the Mac: games of the era
// draw landscape into a portrait framebuffer and expect the device turned.
// B32Orientation in Info.plist (set by make-app.sh) or the guest's own
// UIInterfaceOrientation chooses it.
CGFloat guestRotation() {
    static CGFloat rotation = [] {
        NSBundle *bundle = [NSBundle mainBundle];
        NSString *orientation = [bundle objectForInfoDictionaryKey:@"B32Orientation"]
                                    ?: [bundle objectForInfoDictionaryKey:@"UIInterfaceOrientation"];
        if ([orientation hasSuffix:@"LandscapeRight"]) return CGFloat(-M_PI_2);
        if ([orientation hasSuffix:@"LandscapeLeft"]) return CGFloat(M_PI_2);
        return CGFloat(0);
    }();
    return rotation;
}

CGSize sceneSize() {
    return guestRotation() != 0 ? CGSizeMake(screenHeight(), screenWidth()) : CGSizeMake(screenWidth(), screenHeight());
}

// Turns a guest window to match the device orientation, centered in the scene.
void orient(UIWindow *window) {
    if (guestRotation() == 0) return;
    window.transform = CGAffineTransformMakeRotation(guestRotation());
    CGSize size = sceneSize();
    window.center = CGPointMake(size.width / 2, size.height / 2);
}
NSMutableArray<UIWindow *> *pendingWindows = nil;   // created before the scene connected
NSMutableSet<UIWindow *> *pendingKeyWindows = nil;  // ...and asked to become key

IMP originalInitWithFrame = nullptr;
IMP originalInitWithCoder = nullptr;
IMP originalMakeKeyAndVisible = nullptr;

// Windows from the main nib arrive through -initWithCoder:.
id windowInitWithCoder(UIWindow *self, SEL _cmd, NSCoder *coder) {
    self = reinterpret_cast<id (*)(id, SEL, NSCoder *)>(originalInitWithCoder)(self, _cmd, coder);
    if (!self) return nil;
    if (guestScene) {
        self.windowScene = guestScene;
        orient(self);
    } else {
        [pendingWindows addObject:self];
    }
    return self;
}

id windowInitWithFrame(UIWindow *self, SEL _cmd, CGRect frame) {
    if (guestScene) {
        self = [self initWithWindowScene:guestScene];
        self.frame = frame;
        orient(self);
        return self;
    }
    self = reinterpret_cast<id (*)(id, SEL, CGRect)>(originalInitWithFrame)(self, _cmd, frame);
    if (self) [pendingWindows addObject:self];
    return self;
}

void windowMakeKeyAndVisible(UIWindow *self, SEL _cmd) {
    if (!self.windowScene && [pendingWindows containsObject:self]) {
        [pendingKeyWindows addObject:self];
        return;
    }
    reinterpret_cast<void (*)(id, SEL)>(originalMakeKeyAndVisible)(self, _cmd);
}

void writeGuestRect(GuestMemory &mem, GuestAddr out, CGFloat x, CGFloat y, CGFloat w, CGFloat h) {
    mem.write<float>(out, float(x));
    mem.write<float>(out + 4, float(y));
    mem.write<float>(out + 8, float(w));
    mem.write<float>(out + 12, float(h));
}

bool isScreen(id receiver) { return [receiver isKindOfClass:[UIScreen class]]; }
bool isMainBundle(id receiver) { return receiver == [NSBundle mainBundle]; }

}  // namespace

// Named in the shell's UIApplicationSceneManifest.
@interface B32SceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation B32SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    guestScene = windowScene;
    CGSize size = sceneSize();
    windowScene.sizeRestrictions.minimumSize = size;
    windowScene.sizeRestrictions.maximumSize = size;
    NSBundle *bundle = [NSBundle mainBundle];
    windowScene.title = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                            ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"];

    for (UIWindow *window in pendingWindows) {
        window.windowScene = windowScene;
        orient(window);
        if ([pendingKeyWindows containsObject:window])
            reinterpret_cast<void (*)(id, SEL)>(originalMakeKeyAndVisible)(window, @selector(makeKeyAndVisible));
    }
    log("scene connected; attached %lu window(s) created before it", (unsigned long)pendingWindows.count);
    [pendingWindows removeAllObjects];
    [pendingKeyWindows removeAllObjects];
}

@end

// Apps from before iOS 13 name their main nib in Info.plist and leave the
// delegate to it, but UIKit doesn't load NSMainNibFile for scene-based apps.
// This stands in as the delegate just long enough to load the nib, whose
// File's Owner (the UIApplication) gets the guest's delegate from it.
@interface B32NibAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation B32NibAppDelegate

+ (NSString *)mainNibName {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle objectForInfoDictionaryKey:@"NSMainNibFile~ipad"] ?: [bundle objectForInfoDictionaryKey:@"NSMainNibFile"];
}

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary *)options {
    // Setting the nib's delegate makes UIKit release this one; stay alive
    // until this method returns (and after, since UIKit may still message it).
    [self retain];
    NSString *nib = [B32NibAppDelegate mainNibName];
    // The nib's objects live for the whole run, as with UIKit's own main nib.
    NSArray *objects = [[[NSBundle mainBundle] loadNibNamed:nib owner:application options:nil] retain];
    log("loaded main nib %s: %lu top-level objects, delegate %s", nib.UTF8String, (unsigned long)objects.count,
        object_getClassName(application.delegate));
    if (application.delegate == self) log("the main nib didn't set the application's delegate");
    return YES;
}

@end

void b32::uikit::configureHost() {
    NSArray *families = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"B32GuestDeviceFamily"];
    if ([families isKindOfClass:[NSArray class]] && ![families containsObject:@1] && [families containsObject:@2])
        device::useIPad();
    log("guest device %s, screen %.0fx%.0f", device::current().machine, screenWidth(), screenHeight());

    pendingWindows = [[NSMutableArray alloc] init];
    pendingKeyWindows = [[NSMutableSet alloc] init];
    Method init = class_getInstanceMethod([UIWindow class], @selector(initWithFrame:));
    originalInitWithFrame = method_setImplementation(init, reinterpret_cast<IMP>(windowInitWithFrame));
    Method coder = class_getInstanceMethod([UIWindow class], @selector(initWithCoder:));
    originalInitWithCoder = method_setImplementation(coder, reinterpret_cast<IMP>(windowInitWithCoder));
    Method key = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    originalMakeKeyAndVisible = method_setImplementation(key, reinterpret_cast<IMP>(windowMakeKeyAndVisible));
}

// int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName)
B32_THUNK(_UIApplicationMain) {
    Bridge &bridge = c.rt.bridge();
    c.args.i32();  // the host passes the process's own argc/argv
    c.args.ptr();
    NSString *principal = bridge.toHost(c.args.ptr());
    NSString *delegate = bridge.toHost(c.args.ptr());
    // Guest classes may have been given a prefixed shadow name.
    auto hostName = [&](NSString *name) -> NSString * {
        if (!name) return nil;
        ClassInfo *info = bridge.classNamed(name.UTF8String);
        return info && info->host ? @(class_getName(info->host)) : name;
    };
    log("UIApplicationMain(principal %s, delegate %s)", principal.UTF8String ?: "nil", delegate.UTF8String ?: "nil");
    if (!delegate && [B32NibAppDelegate mainNibName]) delegate = @"B32NibAppDelegate";
    c.ret(uint32_t(UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), hostName(principal), hostName(delegate))));
}

B32_THUNK(_UIGraphicsGetCurrentContext) { c.ret(c.rt.bridge().toGuest((id)UIGraphicsGetCurrentContext())); }

// --- the guest's screen is an iPhone's ------------------------------------------------

B32_OVERRIDE_WHEN(isScreen, "bounds") {
    writeGuestRect(o.c.mem, o.retPtr, 0, 0, screenWidth(), screenHeight());
}
B32_OVERRIDE_WHEN(isScreen, "applicationFrame") {
    writeGuestRect(o.c.mem, o.retPtr, 0, kStatusBarHeight, screenWidth(), screenHeight() - kStatusBarHeight);
}
B32_OVERRIDE_WHEN(isScreen, "scale") { o.c.retF32(1.0f); }

// --- the main bundle's files are in Contents/Resources ----------------------------------
// iOS bundles are flat, so guest code builds paths from bundlePath.

B32_OVERRIDE_WHEN(isMainBundle, "bundlePath") { o.c.ret(o.bridge.toGuest([o.receiver resourcePath])); }
