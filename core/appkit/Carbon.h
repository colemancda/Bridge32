// What the pieces of the Carbon layer share. Carbon's UI has no 64-bit host, so
// core/appkit/carbon_ui.mm rebuilds the part old games use on AppKit.
#pragma once

#include "core/mem/GuestMemory.h"

@class NSView;
@class NSWindow;

namespace b32 {

class Runtime;

namespace appkit {

// Where the guest's SetPort and SetGWorld leave the current port, and the
// screen's PixMapHandle to stand in for a window port's own
// (core/appkit/quickdraw.mm).
extern GuestAddr currentPort;
GuestAddr screenPixMap(Runtime &rt);
// Makes the guest a running Mac application the first time Carbon UI is used.
void ensureCarbonApplication();
// The content view behind a guest window or its port, or nil.
NSView *carbonViewForPort(GuestAddr port);
// A window filling the main display, for aglSetFullScreen.
// The view a game's "full screen" picture goes in: a borderless window over the whole screen, or with
// B32_WINDOWED=1 (or B32Windowed in the app's Info.plist) an ordinary window of the size the game asked for.
NSView *carbonFullScreenView(int width, int height);
// Runs the Cocoa event queue, tracking key and mouse state, until something
// arrives or `seconds` pass.
void pumpCarbonEvents(double seconds);

}  // namespace b32::appkit

}  // namespace b32
