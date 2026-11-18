// What the pieces of the Carbon layer share. Carbon's UI has no 64-bit host, so
// core/appkit/carbon_ui.mm rebuilds the part old games use on AppKit.
#pragma once

#include "core/mem/GuestMemory.h"

#include <CoreGraphics/CoreGraphics.h>

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
// A zero size asks for the display's current mode, which a windowed picture takes from the last mode the guest
// asked the display for (or 1024 x 768); the size used comes back in width and height.
NSView *carbonFullScreenView(int &width, int &height);
// Remembers the resolution a guest asked for, as CGDisplayBestModeForParameters is given it.
void setRequestedDisplaySize(int width, int height);
// A point on the screen a game believes it fills, as the point of the real screen that shows it: where the
// cursor goes when the game moves it. The point itself when no game has a full-screen picture.
CGPoint gameScreenPoint(CGPoint point);
// Runs the Cocoa event queue, tracking key and mouse state, until something
// arrives or `seconds` pass.
void pumpCarbonEvents(double seconds);

}  // namespace b32::appkit

}  // namespace b32
