// What the pieces of the Carbon layer share. Carbon's UI has no 64-bit host, so
// core/appkit/carbon_ui.mm rebuilds the part old games use on AppKit.
#pragma once

#include "core/mem/GuestMemory.h"

@class NSView;
@class NSWindow;

namespace b32::appkit {

// Makes the guest a running Mac application the first time Carbon UI is used.
void ensureCarbonApplication();
// The content view behind a guest window or its port, or nil.
NSView *carbonViewForPort(GuestAddr port);
// A window filling the main display, for aglSetFullScreen.
NSView *carbonFullScreenView();
// Runs the Cocoa event queue, tracking key and mouse state, until something
// arrives or `seconds` pass.
void pumpCarbonEvents(double seconds);

}  // namespace b32::appkit
