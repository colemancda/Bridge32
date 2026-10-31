// Nested run loops on the main thread. iOS games and engines (SDL, launch
// dialogs) often run the main run loop themselves, waiting inside
// -[NSRunLoop runMode:beforeDate:] or CFRunLoopRunInMode for input. On iOS
// touches arrive through run loop sources, so that works. In a Mac Catalyst
// app, mouse and keyboard input sits in AppKit's event queue, which only
// NSApplication's own loop drains, so a guest's nested loop would wait
// forever with clicks piling up. Here, the main thread's nested loops also
// take events off that queue and dispatch them.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/objc/Dispatch.h"

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>

using namespace b32;

namespace {

// AppKit's shared application, which a Catalyst app has under UIKit; nil
// off the main thread.
id appKitApplication() {
    if (!pthread_main_np()) return nil;
    static id app = [] {
        Class cls = objc_getClass("NSApplication");
        return cls ? reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(cls, sel_registerName("sharedApplication")) : nil;
    }();
    return app;
}

// Waits until `until` for one event in `mode`, running the run loop (its
// timers and sources) meanwhile, and dispatches it; true if there was one.
bool dispatchNextEvent(id app, NSString *mode, NSDate *until) {
    SEL next = sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:");
    id event = reinterpret_cast<id (*)(id, SEL, unsigned long long, id, id, BOOL)>(objc_msgSend)(
        app, next, ~0ULL, until, mode, YES);
    if (!event) return false;
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(app, sel_registerName("sendEvent:"), event);
    return true;
}

bool isMainRunLoop(id receiver) {
    return pthread_main_np() && [receiver isKindOfClass:[NSRunLoop class]] && appKitApplication();
}

}  // namespace

// - (BOOL)runMode:(NSRunLoopMode)mode beforeDate:(NSDate *)limitDate: one
// pass, which here also dispatches the input event that ends it.
B32_OVERRIDE_WHEN(isMainRunLoop, "runMode:beforeDate:") {
    NSString *mode = o.bridge.toHost(o.args.ptr());
    NSDate *until = o.bridge.toHost(o.args.ptr());
    dispatchNextEvent(appKitApplication(), mode ?: NSDefaultRunLoopMode, until ?: [NSDate distantFuture]);
    o.c.ret(1);
}

// - (void)runUntilDate:(NSDate *)limitDate
B32_OVERRIDE_WHEN(isMainRunLoop, "runUntilDate:") {
    NSDate *until = o.bridge.toHost(o.args.ptr());
    id app = appKitApplication();
    while ([until timeIntervalSinceNow] > 0) dispatchNextEvent(app, NSDefaultRunLoopMode, until);
}

// SInt32 CFRunLoopRunInMode(CFStringRef mode, CFTimeInterval seconds, Boolean returnAfterSourceHandled)
// Audio callbacks may also be delivered through a guest thread's run loop,
// which has no events to dispatch.
B32_THUNK(_CFRunLoopRunInMode) {
    CFStringRef mode = (CFStringRef)c.rt.bridge().toHost(c.args.ptr());
    double seconds = c.args.f64();
    Boolean returnAfterSource = Boolean(c.args.u32());
    id app = appKitApplication();
    if (!app) {
        c.ret(uint32_t(CFRunLoopRunInMode(mode, seconds, returnAfterSource)));
        return;
    }
    // SDL polls with no wait: dispatch everything already queued, then give
    // the run loop its pass.
    if (seconds <= 0) {
        while (dispatchNextEvent(app, (NSString *)mode, [NSDate distantPast])) {}
        c.ret(uint32_t(CFRunLoopRunInMode(mode, 0, returnAfterSource)));
        return;
    }
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    bool handled = dispatchNextEvent(app, (NSString *)mode, until);
    c.ret(uint32_t(handled ? kCFRunLoopRunHandledSource : kCFRunLoopRunTimedOut));
}
