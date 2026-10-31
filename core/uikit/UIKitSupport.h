#pragma once

#include <CoreGraphics/CGBase.h>

@class UIWindow;

namespace b32::uikit {

// Host-side setup before the guest runs: the iPhone-sized window.
void configureHost();

// How far the guest's windows are turned on the Mac (radians): a landscape
// game built before iOS 8 draws into a portrait window that is turned.
CGFloat windowRotation();

// The guest's key window (or its frontmost visible one), or nil.
UIWindow *guestKeyWindow();

// Game controller mappings (Controller.mm): swipes from the right stick or
// D-pad when the app asks for them.
void startController();

}  // namespace b32::uikit
