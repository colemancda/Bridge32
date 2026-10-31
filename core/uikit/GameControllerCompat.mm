// MFi controllers for games written against iOS 7's GameController API.
//
//  - -[GCController gamepad], the iOS 7 "standard" profile, is long
//    deprecated, and today's controllers (DualSense, Xbox...) come with only
//    the extended profile. It has every element the standard one does
//    (buttonA-Y, dpad, shoulders) under the same names, so games get it
//    instead when the host has no standard profile.
//  - controllerPausedHandler, iOS 7-12's pause button, is deprecated too
//    and not reliably called any more; the controller's Menu button calls
//    it as well.

#include "core/Log.h"
#include "core/objc/Bridge.h"
#include "core/objc/Dispatch.h"

#import <GameController/GameController.h>
#include <objc/message.h>

using namespace b32;

namespace {

bool isController(id receiver) { return [receiver isKindOfClass:[GCController class]]; }

id hostGamepad(GCController *controller) {
    return reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(controller, @selector(gamepad));
}

}  // namespace

// - (GCGamepad *)gamepad
B32_OVERRIDE_WHEN(isController, "gamepad") {
    auto *controller = (GCController *)o.receiver;
    id profile = hostGamepad(controller) ?: controller.extendedGamepad;
    static bool logged = false;
    if (!logged && profile && profile == controller.extendedGamepad) {
        logged = true;
        log("controller: %s has no standard gamepad profile; the guest gets its extended one", controller.vendorName.UTF8String ?: "?");
    }
    o.c.ret(o.bridge.toGuest(profile));
}

// - (void)setControllerPausedHandler:(void (^)(GCController *))handler
B32_OVERRIDE_WHEN(isController, "setControllerPausedHandler:") {
    auto *controller = (GCController *)o.receiver;
    id handler = o.bridge.toHost(o.args.ptr());
    reinterpret_cast<void (*)(id, SEL, id)>(objc_msgSend)(controller, o.sel, handler);

    GCControllerButtonInput *menu = controller.extendedGamepad.buttonMenu ?: controller.microGamepad.buttonMenu;
    if (!menu) return;
    if (!handler) {
        menu.pressedChangedHandler = nil;
        return;
    }
    void (^paused)(GCController *) = [[handler copy] autorelease];
    menu.pressedChangedHandler = ^(GCControllerButtonInput *, float, BOOL pressed) {
        if (pressed) paused(controller);
    };
    log("controller: %s's Menu button calls the guest's pause handler", controller.vendorName.UTF8String ?: "?");
}
