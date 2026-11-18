// What the QuickDraw layer (quickdraw.mm) knows about a port, for the pieces that draw into one: the text
// engine (ats.mm) draws a string where the port's pen is, in its colors, into its pixels.
#pragma once

#include "core/mem/GuestMemory.h"

#include <cstdint>

namespace b32 {
class Runtime;
}

namespace b32::appkit {

// An RGBColor: 16 bits a component.
struct QDColor {
    uint16_t red = 0, green = 0, blue = 0;
};

// A port's pixels in the guest's memory: where its rows start, how far apart they are, the bits a pixel has
// (1, 16 or 32) and the rect of the port's own coordinates they cover (top, left, bottom, right).
struct PortPixels {
    GuestAddr base = 0;
    uint32_t rowBytes = 0;
    int depth = 0;
    int16_t top = 0, left = 0, bottom = 0, right = 0;
};

// The port QuickDraw draws in now (SetPort, SetGWorld).
GuestAddr currentQuickDrawPort();
// A port's pixels, when it has some of its own: a GWorld, or a port made over one. A window's port has none
// here (the host draws windows).
bool portPixels(Runtime &rt, GuestAddr port, PortPixels &out);

// What a port draws with: the pen's place (in the port's coordinates), the colors, and the text settings
// (a font family, a style's bits, a size in points; 0 is the system font at its size).
struct PortState {
    int16_t penH = 0, penV = 0;
    QDColor fore{0, 0, 0}, back{0xffff, 0xffff, 0xffff};
    int16_t textFont = 0, textFace = 0, textSize = 0;
};
PortState portState(GuestAddr port);

}  // namespace b32::appkit
