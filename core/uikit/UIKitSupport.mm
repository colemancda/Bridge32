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
#include "core/thunks/MainQueue.h"
#include "core/objc/Dispatch.h"

#import <UIKit/UIKit.h>
#include <algorithm>
#include <crt_externs.h>
#include <cstring>
#include <objc/runtime.h>

using namespace b32;
using namespace b32::objc;

namespace {

constexpr CGFloat kStatusBarHeight = 20;

UIWindowScene *guestScene = nil;

// How far the device is turned from portrait: B32Orientation in Info.plist
// (set by make-app.sh) or the guest's own UIInterfaceOrientation.
CGFloat deviceRotation() {
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

// From iOS 8 the screen's bounds follow the interface orientation, and apps
// built with that SDK draw upright into a landscape window. Older ones see a
// portrait screen and draw turned, expecting the device turned.
bool boundsFollowOrientation() {
    static bool follow = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"B32GuestSDKVersion"] doubleValue] >= 8;
    return follow;
}

// How far the guest's window is turned on the Mac.
CGFloat guestRotation() { return boundsFollowOrientation() ? 0 : deviceRotation(); }

// The screen the guest sees: portrait, or landscape for a landscape game
// built for iOS 8 and later.
bool screenSwapped() { return boundsFollowOrientation() && deviceRotation() != 0; }
CGFloat screenWidth() { return screenSwapped() ? device::current().screenHeight : device::current().screenWidth; }
CGFloat screenHeight() { return screenSwapped() ? device::current().screenWidth : device::current().screenHeight; }

CGSize sceneSize() {
    return guestRotation() != 0 ? CGSizeMake(screenHeight(), screenWidth()) : CGSizeMake(screenWidth(), screenHeight());
}

NSHashTable<UIWindow *> *guestWindows = nil;
UIView *backdrop = nil;

// Fits every guest window into the Mac window: turned to the device
// orientation, scaled to fill the space below the title bar (Catalyst windows
// run under it, and CoD's pause button lives in that corner) and letterboxed.
// Guest windows keep their iPhone-sized bounds, so the guest sees no change.
void layoutGuestWindows() {
    if (!backdrop) return;
    CGRect area = UIEdgeInsetsInsetRect(backdrop.bounds, backdrop.safeAreaInsets);
    if (CGRectIsEmpty(area)) return;
    CGSize size = sceneSize();
    CGFloat scale = std::min(area.size.width / size.width, area.size.height / size.height);
    CGAffineTransform transform = CGAffineTransformScale(CGAffineTransformMakeRotation(guestRotation()), scale, scale);
    for (UIWindow *window in guestWindows) {
        window.transform = transform;
        window.center = CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area));
    }
}

void orient(UIWindow *window) {
    [guestWindows addObject:window];
    layoutGuestWindows();
}

// Main-queue work the guest queues during launch, held until its scene
// connects (see holdLaunchWork).
bool launching = false;
NSMutableArray *heldLaunchWork = nil;

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

// Fills the Mac window behind the guest; resizing it, full screen included,
// or a change to the title bar refits the guest.
@interface B32Backdrop : UIView
@end

@implementation B32Backdrop

- (void)layoutSubviews {
    [super layoutSubviews];
    layoutGuestWindows();
}

// The title bar's height is known once the window is up: make room for it,
// so the smallest window still shows the guest at full size.
- (void)safeAreaInsetsDidChange {
    [super safeAreaInsetsDidChange];
    UIEdgeInsets insets = self.safeAreaInsets;
    UIWindowScene *scene = self.window.windowScene;
    CGSize size = sceneSize();
    CGSize minimum = CGSizeMake(size.width + insets.left + insets.right, size.height + insets.top + insets.bottom);
    CGSize current = scene.sizeRestrictions.minimumSize;
    if (minimum.width > current.width || minimum.height > current.height) {
        scene.sizeRestrictions.minimumSize = minimum;
        CGRect frame = scene.effectiveGeometry.systemFrame;
        frame.size.width = std::max(frame.size.width, minimum.width);
        frame.size.height = std::max(frame.size.height, minimum.height);
        [scene requestGeometryUpdateWithPreferences:[[[UIWindowSceneGeometryPreferencesMac alloc] initWithSystemFrame:frame] autorelease]
                                       errorHandler:nil];
    }
    layoutGuestWindows();
}

@end

// UIMainStoryboardFile: UIKit doesn't load it for scene-based apps (like
// NSMainNibFile, see B32NibAppDelegate). Done when the scene connects, as
// UIKit would: the initial view controller in a window that becomes the
// app delegate's and key.
static void loadMainStoryboard() {
// The value of an Info.plist key for the guest's device (`key~iphone` or
// `key~ipad`), else the plain key. Read from the plist itself: NSBundle
// applies the Mac's own (iPad) suffix to the plain key.
static NSString *deviceInfoValue(NSString *key) {
    static NSDictionary *info = [[NSDictionary alloc]
        initWithContentsOfURL:[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *suffix = std::strncmp(device::current().machine, "iPad", 4) == 0 ? @"~ipad" : @"~iphone";
    return info[[key stringByAppendingString:suffix]] ?: info[key];
}

    NSString *name = deviceInfoValue(@"UIMainStoryboardFile");
    if (!name) return;
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:name bundle:NSBundle.mainBundle];
    UIViewController *root = [storyboard instantiateInitialViewController];
    if (!root) {
        log("main storyboard %s has no initial view controller", name.UTF8String);
        return;
    }
    // Through the -initWithFrame: swizzle: into the scene, turned to the guest's orientation.
    UIWindow *window = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, screenWidth(), screenHeight())];
    window.rootViewController = root;
    id<UIApplicationDelegate> delegate = UIApplication.sharedApplication.delegate;
    if ([delegate respondsToSelector:@selector(setWindow:)]) delegate.window = window;
    [window makeKeyAndVisible];
    log("loaded main storyboard %s: %s", name.UTF8String, object_getClassName(root));
}

// Named in the shell's UIApplicationSceneManifest.
@interface B32SceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation B32SceneDelegate

// Resizing the Mac window, full screen included.
- (void)windowScene:(UIWindowScene *)windowScene didUpdateCoordinateSpace:(id<UICoordinateSpace>)previous
    interfaceOrientation:(UIInterfaceOrientation)orientation traitCollection:(UITraitCollection *)traits {
    // UIKit doesn't resize the windows along with the scene; the backdrop
    // follows it and refits the guest.
    backdrop.window.frame = windowScene.coordinateSpace.bounds;
    layoutGuestWindows();
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    guestScene = windowScene;
    windowScene.sizeRestrictions.minimumSize = sceneSize();
    windowScene.sizeRestrictions.maximumSize = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
    UIWindow *backdropWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
    backdropWindow.windowLevel = UIWindowLevelNormal - 1;
    backdropWindow.backgroundColor = UIColor.blackColor;
    backdrop = [[B32Backdrop alloc] initWithFrame:backdropWindow.bounds];
    backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [backdropWindow addSubview:backdrop];
    backdropWindow.hidden = NO;
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
    bool hadWindows = pendingWindows.count > 0;
    // Lay the windows out now, loading their view controllers' views, as
    // iOS does at the end of launch.
    for (UIWindow *window in pendingWindows) [window layoutIfNeeded];
    [pendingWindows removeAllObjects];
    [pendingKeyWindows removeAllObjects];
    if (!hadWindows) loadMainStoryboard();

    // Then the work the guest queued while launching, in order, after this
    // run loop pass has drawn the windows.
    launching = false;
    for (dispatch_block_t work in heldLaunchWork) dispatch_async(dispatch_get_main_queue(), work);
    if (heldLaunchWork.count) log("ran %lu block(s) queued during launch", (unsigned long)heldLaunchWork.count);
    [heldLaunchWork removeAllObjects];
}

@end

// Apps from before iOS 13 name their main nib in Info.plist and leave the
// delegate to it, but UIKit doesn't load NSMainNibFile for scene-based apps.
// This stands in as the delegate just long enough to load the nib, whose
// File's Owner (the UIApplication) gets the guest's delegate from it.
@interface B32NibAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation B32NibAppDelegate

// The nib for the guest's device (NSMainNibFile~ipad / ~iphone), else the
// plain one. Read from the plist itself: NSBundle applies the Mac's own
// (iPad) suffix to the plain key.
+ (NSString *)mainNibName {
    static NSDictionary *info = [[NSDictionary alloc]
        initWithContentsOfURL:[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/Info.plist"]];
    NSString *key = std::strncmp(device::current().machine, "iPad", 4) == 0 ? @"NSMainNibFile~ipad" : @"NSMainNibFile~iphone";
    return info[key] ?: info[@"NSMainNibFile"];
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

CGFloat b32::uikit::windowRotation() { return guestRotation(); }

bool b32::uikit::holdLaunchWork(dispatch_queue_t queue, dispatch_block_t work) {
    if (!launching || queue != dispatch_get_main_queue()) return false;
    if (!heldLaunchWork) heldLaunchWork = [[NSMutableArray alloc] init];
    [heldLaunchWork addObject:[[work copy] autorelease]];
    return true;
}

UIWindow *b32::uikit::guestKeyWindow() {
    UIWindow *front = nil;
    for (UIWindow *window in guestWindows) {
        if (window.isKeyWindow) return window;
        if (!window.hidden) front = window;
    }
    return front;
}

void b32::uikit::configureHost() {
    NSArray *families = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"B32GuestDeviceFamily"];
    if ([families isKindOfClass:[NSArray class]] && ![families containsObject:@1] && [families containsObject:@2])
        device::useIPad();
    log("guest device %s, screen %.0fx%.0f", device::current().machine, screenWidth(), screenHeight());
    startController();
    mainQueueHold = [](void *queue, void *block) {
        return uikit::holdLaunchWork((dispatch_queue_t)queue, (dispatch_block_t)block);
    };

    pendingWindows = [[NSMutableArray alloc] init];
    guestWindows = [[NSHashTable weakObjectsHashTable] retain];
    pendingKeyWindows = [[NSMutableSet alloc] init];
    Method init = class_getInstanceMethod([UIWindow class], @selector(initWithFrame:));
    originalInitWithFrame = method_setImplementation(init, reinterpret_cast<IMP>(windowInitWithFrame));
    Method coder = class_getInstanceMethod([UIWindow class], @selector(initWithCoder:));
    originalInitWithCoder = method_setImplementation(coder, reinterpret_cast<IMP>(windowInitWithCoder));
    Method key = class_getInstanceMethod([UIWindow class], @selector(makeKeyAndVisible));
    originalMakeKeyAndVisible = method_setImplementation(key, reinterpret_cast<IMP>(windowMakeKeyAndVisible));

    // Private classes old nibs name that UIKit has since dropped, each
    // standing in as a plain subclass of what it was.
    static const char *const kRetiredClasses[][2] = {
        {"UIRoundedRectButton", "UIButton"},  // UIButtonTypeRoundedRect before iOS 7
    };
    for (auto &retired : kRetiredClasses) {
        if (objc_getClass(retired[0])) continue;
        Class cls = objc_allocateClassPair(objc_getClass(retired[1]), retired[0], 0);
        objc_registerClassPair(cls);
    }
}

// int UIApplicationMain(int argc, char *argv[], NSString *principalClassName, NSString *delegateClassName)
B32_THUNK(_UIApplicationMain) {
    launching = true;
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
B32_OVERRIDE_WHEN(isScreen, "nativeBounds") { writeGuestRect(o.c.mem, o.retPtr, 0, 0, screenWidth(), screenHeight()); }
B32_OVERRIDE_WHEN(isScreen, "nativeScale") { o.c.retF32(1.0f); }

// The idiom follows the guest's device: Catalyst's own is iPad, which would
// send iPhone games down their iPad paths.
namespace {
bool isDevice(id receiver) { return [receiver isKindOfClass:[UIDevice class]]; }
bool isTraits(id receiver) { return [receiver isKindOfClass:[UITraitCollection class]]; }
uint32_t guestIdiom() {
    return std::strncmp(device::current().machine, "iPad", 4) == 0 ? uint32_t(UIUserInterfaceIdiomPad)
                                                                    : uint32_t(UIUserInterfaceIdiomPhone);
}
}  // namespace
B32_OVERRIDE_WHEN(isDevice, "userInterfaceIdiom") { o.c.ret(guestIdiom()); }
B32_OVERRIDE_WHEN(isTraits, "userInterfaceIdiom") { o.c.ret(guestIdiom()); }

// --- the main bundle's files are in Contents/Resources ----------------------------------
// iOS bundles are flat, so guest code builds paths from bundlePath.

// A view controller presented before the scene connects (a launch dialog
// shown from main) has no window to appear in yet, and UIKit would drop it:
// it's presented once the scene has attached the guest's windows, with the
// guest's completion block called after.
namespace {
bool presentsBeforeScene(id receiver) { return !guestScene && [receiver isKindOfClass:[UIViewController class]]; }
}  // namespace
B32_OVERRIDE_WHEN(presentsBeforeScene, "presentViewController:animated:completion:") {
    UIViewController *presenter = o.receiver;
    UIViewController *presented = o.bridge.toHost(o.args.ptr());
    BOOL animated = o.args.u32() != 0;
    GuestAddr completion = o.args.ptr();
    [presenter retain];
    [presented retain];
    if (!heldLaunchWork) heldLaunchWork = [[NSMutableArray alloc] init];
    [heldLaunchWork addObject:[[^{
        [presenter presentViewController:presented animated:animated completion:^{
            // block_layout { isa, flags, reserved, invoke, ... }
            if (completion) Runtime::threadCpu().call(Runtime::threadCpu().mem().read<uint32_t>(completion + 12), {completion});
        }];
        [presenter release];
        [presented release];
    } copy] autorelease]];
    log("holding the presentation of %s until the scene connects", object_getClassName(presented));
}

B32_OVERRIDE_WHEN(isMainBundle, "bundlePath") { o.c.ret(o.bridge.toGuest([o.receiver resourcePath])); }
