// The screen shown on an iOS device until a debugger has enabled JIT; see JitGate.h.

#include "core/uikit/JitGate.h"

#include "core/Log.h"

#import <UIKit/UIKit.h>

#include <TargetConditionals.h>
#include <unistd.h>

#include <cstdlib>

using namespace b32;

// Not in the public SDK, but a stable wrapper in libSystem.
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

namespace {

constexpr unsigned int kCsOpsStatus = 0;
constexpr unsigned int kCsDebugged = 0x10000000;

bool gateStartedUIKit = false;
bool fakeJitOpen = false;  // B32_JIT_GATE: the stand-in for a debugger arriving
void (^guestStart)(void) = nil;
UIWindow *gateWindow = nil;
NSTimer *gateTimer = nil;

bool gateForced() { return getenv("B32_JIT_GATE") != nullptr; }

// Asks StikDebug to attach to this app and enable JIT.
NSURL *stikDebugURL() {
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleIdentifier) return nil;
    NSURLComponents *components = [[[NSURLComponents alloc] init] autorelease];
    components.scheme = @"stikdebug";
    components.host = @"enable-jit";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"bundle-id" value:bundleIdentifier],
        [NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"],
    ];
    return components.URL;
}

}  // namespace

@interface B32GateAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation B32GateAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    return YES;
}
@end

@interface B32JitGateController : UIViewController
@property(nonatomic, retain) UILabel *status;
@end

@implementation B32JitGateController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    UILabel *title = [[[UILabel alloc] init] autorelease];
    title.text = @"JIT isn’t enabled";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:24];

    UILabel *explanation = [[[UILabel alloc] init] autorelease];
    explanation.text = @"This app runs 32-bit code with a JIT, which iOS only allows while a debugger is "
                        "attached. Enable JIT for it in StikDebug, then come back.";
    explanation.textColor = UIColor.lightGrayColor;
    explanation.numberOfLines = 0;
    explanation.textAlignment = NSTextAlignmentCenter;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Enable JIT in StikDebug" forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [button addTarget:self action:@selector(openStikDebug) forControlEvents:UIControlEventTouchUpInside];

    self.status = [[[UILabel alloc] init] autorelease];
    self.status.text = @"Waiting for JIT…";
    self.status.textColor = UIColor.grayColor;
    self.status.font = [UIFont systemFontOfSize:14];

    UIStackView *stack = [[[UIStackView alloc] initWithArrangedSubviews:@[ title, explanation, button, self.status ]] autorelease];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
    ]];
}

- (void)openStikDebug {
    NSURL *url = stikDebugURL();
    if (!url) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL opened) {
        if (!opened) self.status.text = @"StikDebug isn’t installed, or can’t be opened.";
    }];
}

- (void)dealloc {
    [_status release];
    [super dealloc];
}

@end

bool b32::uikit::jitAvailable() {
    if (gateForced()) return fakeJitOpen;
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    unsigned int flags = 0;
    return csops(getpid(), kCsOpsStatus, &flags, sizeof(flags)) == 0 && (flags & kCsDebugged) != 0;
#else
    return true;
#endif
}

bool b32::uikit::jitGateStartedUIKit() { return gateStartedUIKit; }

void b32::uikit::runUnderJitGate(int argc, char **argv, void (^start)(void)) {
    guestStart = [start copy];
    gateStartedUIKit = true;
    exit(UIApplicationMain(argc, argv, nil, @"B32GateAppDelegate"));
}

void b32::uikit::presentJitGate(UIWindowScene *scene) {
    if (!gateStartedUIKit || gateWindow) return;
    gateWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gateWindow.windowLevel = UIWindowLevelNormal + 1;
    gateWindow.rootViewController = [[[B32JitGateController alloc] init] autorelease];
    gateWindow.hidden = NO;
    log("waiting for JIT");

    const char *delay = getenv("B32_JIT_GATE");
    NSTimeInterval fakeDelay = delay && atof(delay) > 0 ? atof(delay) : 3;
    NSDate *begin = [NSDate date];
    gateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        if (gateForced() && -begin.timeIntervalSinceNow >= fakeDelay) fakeJitOpen = true;
        if (!jitAvailable()) return;

        [timer invalidate];
        gateTimer = nil;
        gateWindow.hidden = YES;
        [gateWindow release];
        gateWindow = nil;
        log("JIT is on; starting the guest");
        // From this timer's callout, not a main-queue block: the guest never
        // returns, and a serial main queue would starve behind it.
        guestStart();
    }];
}
