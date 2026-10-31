#pragma once

@class UIWindow;

namespace b32::uikit {

// Host-side setup before the guest runs: the iPhone-sized window.
void configureHost();

// The guest's key window (or its frontmost visible one), or nil.
UIWindow *guestKeyWindow();

// Game controller mappings (Controller.mm): swipes from the right stick or
// D-pad when the app asks for them.
void startController();

}  // namespace b32::uikit
