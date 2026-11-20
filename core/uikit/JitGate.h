#pragma once

@class UIWindowScene;

// On an iOS device the guest can't run until a debugger (StikDebug, AltJIT,
// TrollStore) has enabled JIT for the process, which it does while the app is
// running. So the shell starts UIKit first with a screen that waits for that,
// then runs the guest inside that same UIApplicationMain: the guest's own
// UIApplicationMain then finishes the launch in the app that is already
// running (see _UIApplicationMain in UIKitSupport.mm).
//
// Elsewhere JIT is always available and the guest starts as before. For
// testing without a device, B32_JIT_GATE=<seconds> forces the gate and opens
// it after that many seconds.
namespace b32::uikit {

// Whether dynarmic can have executable memory now.
bool jitAvailable();

// Runs UIApplicationMain with the gate in front of `start`, which runs the
// guest on the main thread once JIT is on. Never returns.
[[noreturn]] void runUnderJitGate(int argc, char **argv, void (^start)(void));

// Whether the shell's UIApplicationMain is already running because of the
// gate, so the guest's can't start another.
bool jitGateStartedUIKit();

// Called when the scene connects: shows the gate in it, if there is one.
void presentJitGate(UIWindowScene *scene);

}  // namespace b32::uikit
