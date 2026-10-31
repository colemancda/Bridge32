#pragma once

#include <dispatch/dispatch.h>

#include <CoreGraphics/CGBase.h>

@class UIWindow;

namespace b32::uikit {

// Host-side setup before the guest runs: the iPhone-sized window.
void configureHost();

// How far the guest's windows are turned on the Mac (radians): a landscape
// game built before iOS 8 draws into a portrait window that is turned.
CGFloat windowRotation();

// From UIApplicationMain until the guest's scene connects, main-queue work it
// queues waits, and runs once its windows are attached and laid out. iOS lays
// out the launch windows (loading their view controllers) before anything
// queued in didFinishLaunching runs; Catalyst connects the scene later, and
// apps depend on that order (TruckSmart's first-run setup reads a value its
// first view controller's viewDidLoad writes). Returns whether it held the work.
bool holdLaunchWork(dispatch_queue_t queue, dispatch_block_t work);

// The guest's key window (or its frontmost visible one), or nil.
UIWindow *guestKeyWindow();

// Game controller mappings (Controller.mm): swipes from the right stick or
// D-pad when the app asks for them.
void startController();

}  // namespace b32::uikit
