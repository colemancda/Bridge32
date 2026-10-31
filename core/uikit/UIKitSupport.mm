// UIKit glue: app startup, and making the Mac look like an iPhone to the
// guest (a 320x480-point screen in a window of that size).
//
// Current UIKit requires the scene lifecycle, which 32-bit apps predate: they
// create a UIWindow with -initWithFrame: in applicationDidFinishLaunching:,
// before any scene exists. The shell's B32SceneDelegate takes the scene, and
// windows created before it connects are parked and attached to it then.

#include "UIKitSupport.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Dispatch.h"

#import <UIKit/UIKit.h>
#include <crt_externs.h>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

namespace {

constexpr CGFloat kScreenWidth = 320, kScreenHeight = 480, kStatusBarHeight = 20;

UIWindowScene *guestScene = nil;
NSMutableArray<UIWindow *> *pendingWindows = nil;   // created before the scene connected
NSMutableSet<UIWindow *> *pendingKeyWindows = nil;  // ...and asked to become key

IMP originalInitWithFrame = nullptr;
IMP originalMakeKeyAndVisible = nullptr;

id windowInitWithFrame(UIWindow *self, SEL _cmd, CGRect frame) {
    if (guestScene) {
        self = [self initWithWindowScene:guestScene];
        self.frame = frame;
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
    CGSize size = CGSizeMake(kScreenWidth, kScreenHeight);
    windowScene.sizeRestrictions.minimumSize = size;
    windowScene.sizeRestrictions.maximumSize = size;
    NSBundle *bundle = [NSBundle mainBundle];
    windowScene.title = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]
                            ?: [bundle objectForInfoDictionaryKey:@"CFBundleName"];

    for (UIWindow *window in pendingWindows) {
        window.windowScene = windowScene;
        if ([pendingKeyWindows containsObject:window])
            reinterpret_cast<void (*)(id, SEL)>(originalMakeKeyAndVisible)(window, @selector(makeKeyAndVisible));
    }
    log("scene connected; attached %lu window(s) created before it", (unsigned long)pendingWindows.count);
    [pendingWindows removeAllObjects];
    [pendingKeyWindows removeAllObjects];
}

@end

void b32::uikit::configureHost() {
    pendingWindows = [[NSMutableArray alloc] init];
    pendingKeyWindows = [[NSMutableSet alloc] init];
    Method init = class_getInstanceMethod([UIWindow class], @selector(initWithFrame:));
    originalInitWithFrame = method_setImplementation(init, reinterpret_cast<IMP>(windowInitWithFrame));
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
    c.ret(uint32_t(UIApplicationMain(*_NSGetArgc(), *_NSGetArgv(), hostName(principal), hostName(delegate))));
}

B32_THUNK(_UIGraphicsGetCurrentContext) { c.ret(c.rt.bridge().toGuest((id)UIGraphicsGetCurrentContext())); }

// --- the guest's screen is an iPhone's ------------------------------------------------

B32_OVERRIDE_WHEN(isScreen, "bounds") {
    writeGuestRect(o.c.mem, o.retPtr, 0, 0, kScreenWidth, kScreenHeight);
}
B32_OVERRIDE_WHEN(isScreen, "applicationFrame") {
    writeGuestRect(o.c.mem, o.retPtr, 0, kStatusBarHeight, kScreenWidth, kScreenHeight - kStatusBarHeight);
}
B32_OVERRIDE_WHEN(isScreen, "scale") { o.c.retF32(1.0f); }

// --- the main bundle's files are in Contents/Resources ----------------------------------
// iOS bundles are flat, so guest code builds paths from bundlePath.

B32_OVERRIDE_WHEN(isMainBundle, "bundlePath") { o.c.ret(o.bridge.toGuest([o.receiver resourcePath])); }
