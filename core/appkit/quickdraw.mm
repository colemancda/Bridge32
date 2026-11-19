// QuickDraw's graphics model: the screen's GDevice, offscreen GWorlds with
// pixel buffers of the guest's own memory, and the current port and device.
// Most drawing calls are no-ops — the games that come here draw their own
// pixels into the buffers (a texture, a cursor) or draw through OpenGL — but the
// structures they walk have to be there, in the guest's memory and byte order.
// What a game draws text with is real: a port's pen, colors and font, EraseRect,
// and the text itself (ATSUDrawText, in ats.mm), into a GWorld's pixels.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/appkit/Carbon.h"
#include "core/appkit/Fonts.h"
#include "core/appkit/QuickDraw.h"
#include "core/thunks/Thunks.h"

#import <AppKit/AppKit.h>
#include <CoreText/CoreText.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

using namespace b32;

namespace b32::appkit {

GuestAddr currentPort = 0;  // where SetPort and SetGWorld leave it

}  // namespace b32::appkit

namespace {

using b32::appkit::currentPort;

// Rect: top, left, bottom, right, in the guest's byte order.
void writeRect(Runtime &rt, GuestAddr rect, int16_t top, int16_t left, int16_t bottom, int16_t right) {
    rt.mem().write<int16_t>(rect, top);
    rt.mem().write<int16_t>(rect + 2, left);
    rt.mem().write<int16_t>(rect + 4, bottom);
    rt.mem().write<int16_t>(rect + 6, right);
}
void copyRect(Runtime &rt, GuestAddr to, GuestAddr from) {
    for (int i = 0; i < 8; i++) rt.mem().write<uint8_t>(to + i, rt.mem().read<uint8_t>(from + i));
}

// A PixMap in the guest's memory, behind a handle: baseAddr 0, rowBytes 4,
// bounds 6, pmVersion 14, hRes 22, vRes 26, pixelType 30, pixelSize 32,
// cmpCount 34, cmpSize 36, pixelFormat 38, pmTable 42 (see Quickdraw.h; 50 bytes).
GuestAddr newPixMapHandle(Runtime &rt, GuestAddr base, uint32_t rowBytes, GuestAddr bounds, int16_t depth) {
    GuestAddr handle = rt.heap().alloc(4);
    GuestAddr map = rt.heap().calloc(1, 50);
    rt.mem().write<uint32_t>(handle, map);
    rt.mem().write<uint32_t>(map, base);
    rt.mem().write<uint16_t>(map + 4, uint16_t(rowBytes | 0x8000));
    copyRect(rt, map + 6, bounds);
    rt.mem().write<int32_t>(map + 22, 72 << 16);  // hRes
    rt.mem().write<int32_t>(map + 26, 72 << 16);  // vRes
    rt.mem().write<int16_t>(map + 30, 16);        // RGBDirect
    rt.mem().write<int16_t>(map + 32, depth);
    rt.mem().write<int16_t>(map + 34, depth == 32 ? 4 : 3);
    rt.mem().write<int16_t>(map + 36, 8);
    return handle;
}

// --- the screen's one device ------------------------------------------------

// GDevice (Quickdraw.h): gdType 4, gdFlags 20, gdPMap 22, gdNextGD 30, gdRect 34;
// 64 bytes behind a handle.
GuestAddr screenDeviceHandle(Runtime &rt) {
    static GuestAddr deviceHandle = 0;
    if (deviceHandle) return deviceHandle;
    NSScreen *screen = NSScreen.mainScreen;
    int16_t width = int16_t(screen.frame.size.width), height = int16_t(screen.frame.size.height);

    GuestAddr pixmapBounds = rt.heap().alloc(8);
    writeRect(rt, pixmapBounds, 0, 0, height, width);
    GuestAddr pixmapHandle = newPixMapHandle(rt, 0, uint32_t(width) * 4, pixmapBounds, 32);

    deviceHandle = rt.heap().alloc(4);
    GuestAddr device = rt.heap().calloc(1, 64);
    rt.mem().write<uint32_t>(deviceHandle, device);
    rt.mem().write<int16_t>(device + 4, 2);  // directScreen
    rt.mem().write<int16_t>(device + 20, 0x0004);
    rt.mem().write<uint32_t>(device + 22, pixmapHandle);
    writeRect(rt, device + 34, 0, 0, height, width);
    return deviceHandle;
}

GuestAddr currentDevice;
GuestAddr qdDevice(Runtime &rt) { return currentDevice ?: screenDeviceHandle(rt); }

// --- offscreen GWorlds -------------------------------------------------------

// The ports made here, which have pixels of their own (a window's port is a window, in carbon_ui.mm), and
// what each draws with.
std::mutex portsLock;
std::unordered_set<GuestAddr> worldPorts;
std::unordered_map<GuestAddr, b32::appkit::PortState> portStates;

// CGrafPort: portPixMap 4, portRect 18 (the classic 32-bit layout; 100 bytes).
GuestAddr newWorldPort(Runtime &rt, GuestAddr pixmapHandle, GuestAddr bounds) {
    GuestAddr port = rt.heap().calloc(1, 100);
    rt.mem().write<uint32_t>(port + 4, pixmapHandle);
    copyRect(rt, port + 18, bounds);
    std::lock_guard guard(portsLock);
    worldPorts.insert(port);
    portStates[port] = {};
    return port;
}

b32::appkit::PortState &stateOf(GuestAddr port) {
    return portStates[port];  // a window's port gets the defaults the first time it is asked about
}

}  // namespace

namespace b32::appkit {

GuestAddr currentQuickDrawPort() { return currentPort; }

bool portPixels(Runtime &rt, GuestAddr port, PortPixels &out) {
    {
        std::lock_guard guard(portsLock);
        if (!worldPorts.count(port)) return false;
    }
    GuestAddr handle = rt.mem().read<uint32_t>(port + 4);
    if (!handle) return false;
    GuestAddr map = rt.mem().read<uint32_t>(handle);
    if (!map) return false;
    out.base = rt.mem().read<uint32_t>(map);
    out.rowBytes = rt.mem().read<uint16_t>(map + 4) & 0x3fff;
    out.top = rt.mem().read<int16_t>(map + 6);
    out.left = rt.mem().read<int16_t>(map + 8);
    out.bottom = rt.mem().read<int16_t>(map + 10);
    out.right = rt.mem().read<int16_t>(map + 12);
    out.depth = rt.mem().read<int16_t>(map + 32);
    return out.base && out.rowBytes && out.bottom > out.top && out.right > out.left;
}

PortState portState(GuestAddr port) {
    std::lock_guard guard(portsLock);
    return stateOf(port);
}

}  // namespace b32::appkit

namespace {

// Paints a rect of a port's pixels one color, clipped to them: how EraseRect clears a GWorld. 1-bit pixels
// are ink (1) for a dark color and paper (0) for a light one, as QuickDraw mapped colors to black and white.
void fillPixels(Runtime &rt, const b32::appkit::PortPixels &px, int16_t top, int16_t left, int16_t bottom, int16_t right,
                b32::appkit::QDColor color) {
    top = std::max(top, px.top);
    left = std::max(left, px.left);
    bottom = std::min(bottom, px.bottom);
    right = std::min(right, px.right);
    if (top >= bottom || left >= right) return;
    uint8_t *pixels = rt.mem().ptr<uint8_t>(px.base);
    for (int y = top; y < bottom; y++) {
        uint8_t *row = pixels + uint32_t(y - px.top) * px.rowBytes;
        for (int x = left; x < right; x++) {
            uint32_t column = uint32_t(x - px.left);
            switch (px.depth) {
            case 1: {
                bool ink = color.red * 0.299 + color.green * 0.587 + color.blue * 0.114 < 0x8000;
                uint8_t bit = uint8_t(0x80 >> (column % 8));
                row[column / 8] = ink ? row[column / 8] | bit : row[column / 8] & ~bit;
                break;
            }
            case 16: {  // xRGB, five bits each, big-endian
                uint16_t value = uint16_t((color.red >> 11) << 10 | (color.green >> 11) << 5 | color.blue >> 11);
                row[column * 2] = uint8_t(value >> 8);
                row[column * 2 + 1] = uint8_t(value);
                break;
            }
            case 32: {  // xRGB, a byte each, in that order whatever the processor
                uint8_t *p = row + column * 4;
                p[0] = 0xff;
                p[1] = uint8_t(color.red >> 8);
                p[2] = uint8_t(color.green >> 8);
                p[3] = uint8_t(color.blue >> 8);
                break;
            }
            default:
                return;
            }
        }
    }
}

// The color a classic color constant (ForeColor, BackColor) names.
b32::appkit::QDColor classicColor(int32_t constant) {
    switch (constant) {
    case 30: return {0xffff, 0xffff, 0xffff};  // whiteColor
    case 205: return {0xffff, 0, 0};           // redColor
    case 341: return {0, 0xffff, 0};           // greenColor
    case 409: return {0, 0, 0xffff};           // blueColor
    case 273: return {0, 0xffff, 0xffff};      // cyanColor
    case 137: return {0xffff, 0, 0xffff};      // magentaColor
    case 69: return {0xffff, 0xffff, 0};       // yellowColor
    default: return {0, 0, 0};                 // blackColor, and anything else
    }
}
b32::appkit::QDColor readColor(Call &c, GuestAddr rgb) {
    return {c.mem.read<uint16_t>(rgb), c.mem.read<uint16_t>(rgb + 2), c.mem.read<uint16_t>(rgb + 4)};
}
void setPortColor(GuestAddr port, bool fore, b32::appkit::QDColor color) {
    std::lock_guard guard(portsLock);
    (fore ? stateOf(port).fore : stateOf(port).back) = color;
}

}  // namespace

namespace b32::appkit {

// A window's port draws on the screen: the screen device's pixmap stands in
// for its own, which the host owns the pixels of.
GuestAddr screenPixMap(Runtime &rt) {
    GuestAddr deviceHandle = screenDeviceHandle(rt);
    return rt.mem().read<uint32_t>(rt.mem().read<uint32_t>(deviceHandle) + 22);
}

}  // namespace b32::appkit

// GDHandle GetMainDevice(void)
B32_THUNK(_GetMainDevice) { c.ret(screenDeviceHandle(c.rt)); }
// GDHandle GetNextDevice(GDHandle)
B32_THUNK(_GetNextDevice) { c.args.ptr(); c.ret(0); }
// GDHandle GetGDevice(void)
B32_THUNK(_GetGDevice) { c.ret(qdDevice(c.rt)); }
// void SetGDevice(GDHandle)
B32_THUNK(_SetGDevice) { currentDevice = c.args.ptr(); }
// GDHandle DMGetFirstScreenDevice(Boolean activeOnly): the one screen there is.
B32_THUNK(_DMGetFirstScreenDevice) {
    c.args.u32();
    c.ret(screenDeviceHandle(c.rt));
}
// GDHandle DMGetNextScreenDevice(GDHandle current, Boolean activeOnly)
B32_THUNK(_DMGetNextScreenDevice) {
    c.args.ptr();
    c.args.u32();
    c.ret(0);
}

// void GetGWorld(CGrafPtr *port, GDHandle *device)
B32_THUNK(_GetGWorld) {
    GuestAddr port = c.args.ptr(), device = c.args.ptr();
    if (port) c.mem.write<uint32_t>(port, currentPort);
    if (device) c.mem.write<uint32_t>(device, qdDevice(c.rt));
}
// void SetGWorld(CGrafPtr port, GDHandle device)
B32_THUNK(_SetGWorld) {
    GuestAddr port = c.args.ptr(), device = c.args.ptr();
    if (port) currentPort = port;
    if (device) currentDevice = device;
}
// void GetPortBounds(CGrafPtr port, Rect *out): the port's own rect, where it
// was laid out. A window's port is served in carbon_ui.mm, with its live bounds.
// PixMapHandle GetPortPixMap(CGrafPtr port)
B32_THUNK(_GetPortPixMap) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 4)); }

// QDErr NewGWorld(GWorldPtr *out, short depth, Rect *bounds, CTabHandle, GDHandle, GWorldFlags)
B32_THUNK(_NewGWorld) {
    GuestAddr out = c.args.ptr();
    int16_t depth = c.args.i32();
    GuestAddr bounds = c.args.ptr();
    c.args.ptr();
    c.args.ptr();
    c.args.u32();
    int16_t rect[4];
    for (int i = 0; i < 4; i++) rect[i] = c.mem.read<int16_t>(bounds + uint32_t(i) * 2);
    uint32_t width = uint32_t(rect[3] - rect[1]), height = uint32_t(rect[2] - rect[0]);
    uint32_t bytes = (width * uint32_t(depth) + 31) / 32 * 4;  // long-aligned rows
    GuestAddr buffer = c.heap.calloc(std::max<uint32_t>(height, 1), std::max<uint32_t>(bytes, 4));
    GuestAddr port = newWorldPort(c.rt, newPixMapHandle(c.rt, buffer, bytes, bounds, depth), bounds);
    c.mem.write<uint32_t>(out, port);
    c.ret(0);
}
// QDErr NewGWorldFromPtr(GWorldPtr *out, short depth, Rect *bounds, CTabHandle, GDHandle,
//                       GWorldFlags, Ptr base, long rowBytes): the guest's buffer, as it is.
B32_THUNK(_NewGWorldFromPtr) {
    GuestAddr out = c.args.ptr();
    int16_t depth = c.args.i32();
    GuestAddr bounds = c.args.ptr();
    c.args.ptr();
    c.args.ptr();
    c.args.u32();
    GuestAddr base = c.args.ptr();
    uint32_t rowBytes = c.args.u32();
    GuestAddr port = newWorldPort(c.rt, newPixMapHandle(c.rt, base, rowBytes & 0x3fff, bounds, depth), bounds);
    c.mem.write<uint32_t>(out, port);
    c.ret(0);
}
// void DisposeGWorld(GWorldPtr): the heap holds what it allocated until the guest ends
B32_THUNK(_DisposeGWorld) { c.args.ptr(); }
// PixMapHandle GetGWorldPixMap(GWorldPtr)
B32_THUNK(_GetGWorldPixMap) { c.ret(c.mem.read<uint32_t>(c.args.ptr() + 4)); }
// Boolean LockPixels(PixMapHandle)
B32_THUNK(_LockPixels) { c.ret(1); }
// void UnlockPixels(PixMapHandle)
B32_THUNK(_UnlockPixels) { c.args.ptr(); }
// Ptr GetPixBaseAddr(PixMapHandle)
B32_THUNK(_GetPixBaseAddr) { c.ret(c.mem.read<uint32_t>(c.mem.read<uint32_t>(c.args.ptr()))); }
// long GetPixRowBytes(PixMapHandle)
B32_THUNK(_GetPixRowBytes) { c.ret(c.mem.read<uint16_t>(c.mem.read<uint32_t>(c.args.ptr()) + 4) & 0x3fff); }
// void GetPixBounds(PixMapHandle, Rect *out)
B32_THUNK(_GetPixBounds) { copyRect(c.rt, c.args.ptr(), c.mem.read<uint32_t>(c.args.ptr()) + 6); }

// --- rect arithmetic and the drawing calls a game still makes ----------------
// (SetRect itself is in carbon_ui.mm, with the windows.)

// void OffsetRect(Rect *, short dh, short dv)
B32_THUNK(_OffsetRect) {
    GuestAddr rect = c.args.ptr();
    int16_t dh = c.args.i32(), dv = c.args.i32();
    int16_t r[4];
    for (int i = 0; i < 4; i++) r[i] = c.mem.read<int16_t>(rect + uint32_t(i) * 2);
    writeRect(c.rt, rect, int16_t(r[0] + dv), int16_t(r[1] + dh), int16_t(r[2] + dv), int16_t(r[3] + dh));
}
// Boolean SectRect(const Rect *, const Rect *, Rect *out): false when empty
B32_THUNK(_SectRect) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr(), out = c.args.ptr();
    int16_t ra[4], rb[4];
    for (int i = 0; i < 4; i++) {
        ra[i] = c.mem.read<int16_t>(a + uint32_t(i) * 2);
        rb[i] = c.mem.read<int16_t>(b + uint32_t(i) * 2);
    }
    int16_t top = std::max(ra[0], rb[0]), left = std::max(ra[1], rb[1]);
    int16_t bottom = std::min(ra[2], rb[2]), right = std::min(ra[3], rb[3]);
    writeRect(c.rt, out, top, left, bottom, right);
    c.ret(top < bottom && left < right);
}
// Points: { short v, h }, a word on the stack when passed by value (v in its low half).
// void AddPt(Point src, Point *dst), SubPt(Point src, Point *dst): dst plus or minus src.
B32_THUNK(_AddPt) {
    uint32_t src = c.args.u32();
    GuestAddr dst = c.args.ptr();
    c.mem.write<int16_t>(dst, int16_t(c.mem.read<int16_t>(dst) + int16_t(src)));
    c.mem.write<int16_t>(dst + 2, int16_t(c.mem.read<int16_t>(dst + 2) + int16_t(src >> 16)));
}
B32_THUNK(_SubPt) {
    uint32_t src = c.args.u32();
    GuestAddr dst = c.args.ptr();
    c.mem.write<int16_t>(dst, int16_t(c.mem.read<int16_t>(dst) - int16_t(src)));
    c.mem.write<int16_t>(dst + 2, int16_t(c.mem.read<int16_t>(dst + 2) - int16_t(src >> 16)));
}
// Boolean EqualPt(Point, Point)
B32_THUNK(_EqualPt) {
    uint32_t a = c.args.u32(), b = c.args.u32();
    c.ret(a == b);
}
// Boolean PtInRect(Point, const Rect *): on the top or left edge counts, the bottom or right doesn't.
B32_THUNK(_PtInRect) {
    uint32_t pt = c.args.u32();
    GuestAddr rect = c.args.ptr();
    int16_t v = int16_t(pt), h = int16_t(pt >> 16);
    c.ret(v >= c.mem.read<int16_t>(rect) && h >= c.mem.read<int16_t>(rect + 2) && v < c.mem.read<int16_t>(rect + 4) &&
          h < c.mem.read<int16_t>(rect + 6));
}
// long PinRect(const Rect *, Point): the point moved into the rect (short of its bottom and right
// edges), v in the high word and h in the low.
B32_THUNK(_PinRect) {
    GuestAddr rect = c.args.ptr();
    uint32_t pt = c.args.u32();
    int16_t top = c.mem.read<int16_t>(rect), left = c.mem.read<int16_t>(rect + 2);
    int16_t bottom = c.mem.read<int16_t>(rect + 4), right = c.mem.read<int16_t>(rect + 6);
    int16_t v = std::max(top, std::min(int16_t(pt), int16_t(bottom - 1)));
    int16_t h = std::max(left, std::min(int16_t(pt >> 16), int16_t(right - 1)));
    c.ret(uint32_t(uint16_t(v)) << 16 | uint16_t(h));
}
// void EraseRect(const Rect *): the current port's background color, in a GWorld's pixels.
B32_THUNK(_EraseRect) {
    GuestAddr rect = c.args.ptr();
    b32::appkit::PortPixels px;
    if (!rect || !b32::appkit::portPixels(c.rt, currentPort, px)) return;
    fillPixels(c.rt, px, c.mem.read<int16_t>(rect), c.mem.read<int16_t>(rect + 2), c.mem.read<int16_t>(rect + 4),
               c.mem.read<int16_t>(rect + 6), b32::appkit::portState(currentPort).back);
}
// PicHandle GetPicture(short id): none. The host has nothing left that reads a 'PICT', so a
// splash screen drawn from one is skipped, as a game does when the resource is missing.
B32_THUNK(_GetPicture) { c.ret(0); }
B32_THUNK(_DrawPicture) { c.args.ptr(); }
B32_THUNK(_KillPicture) { c.args.ptr(); }
// The rest paint nothing: the guest's own blitter or OpenGL puts the pixels up.
B32_THUNK(_PaintRect) { c.args.ptr(); }
B32_THUNK(_FrameRect) { c.args.ptr(); }
B32_THUNK(_InvalRect) { c.args.ptr(); }
B32_THUNK(_ValidRect) { c.args.ptr(); }
B32_THUNK(_ClipRect) { c.args.ptr(); }
B32_THUNK(_QDFlushPortBuffer) { c.args.ptr(); c.args.ptr(); }
B32_THUNK(_PenNormal) {}
B32_THUNK(_PenSize) { c.args.i32(); c.args.i32(); }
// The current port's colors: what text is drawn and a rect erased in.
B32_THUNK(_RGBForeColor) { setPortColor(currentPort, true, readColor(c, c.args.ptr())); }
B32_THUNK(_RGBBackColor) { setPortColor(currentPort, false, readColor(c, c.args.ptr())); }
B32_THUNK(_ForeColor) { setPortColor(currentPort, true, classicColor(c.args.i32())); }
B32_THUNK(_BackColor) { setPortColor(currentPort, false, classicColor(c.args.i32())); }
// void GetForeColor(RGBColor *), GetBackColor(RGBColor *)
B32_THUNK(_GetForeColor) {
    b32::appkit::QDColor color = b32::appkit::portState(currentPort).fore;
    const uint16_t rgb[3] = {color.red, color.green, color.blue};
    c.mem.writeArray<uint16_t>(c.args.ptr(), rgb, 3);
}
B32_THUNK(_GetBackColor) {
    b32::appkit::QDColor color = b32::appkit::portState(currentPort).back;
    const uint16_t rgb[3] = {color.red, color.green, color.blue};
    c.mem.writeArray<uint16_t>(c.args.ptr(), rgb, 3);
}

// --- the pen and the port's text settings ----------------------------------------------------------

// void MoveTo(short h, short v), Move(short dh, short dv): where the pen is, which is where text is drawn.
B32_THUNK(_MoveTo) {
    int16_t h = int16_t(c.args.i32()), v = int16_t(c.args.i32());
    std::lock_guard guard(portsLock);
    stateOf(currentPort).penH = h;
    stateOf(currentPort).penV = v;
}
B32_THUNK(_Move) {
    int16_t dh = int16_t(c.args.i32()), dv = int16_t(c.args.i32());
    std::lock_guard guard(portsLock);
    stateOf(currentPort).penH = int16_t(stateOf(currentPort).penH + dh);
    stateOf(currentPort).penV = int16_t(stateOf(currentPort).penV + dv);
}
// void GetPenState(PenState *), SetPenState(const PenState *): the pen's place is all that is kept;
// it is drawn with nowhere else. PenState is { Point pnLoc, pnSize; short pnMode; Pattern pnPat; }.
B32_THUNK(_GetPenState) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(portsLock);
    const int16_t fields[5] = {stateOf(currentPort).penV, stateOf(currentPort).penH, 1, 1, 8};  // patCopy
    c.mem.writeArray<int16_t>(out, fields, 5);
    for (int i = 0; i < 8; i++) c.mem.write<uint8_t>(out + 10 + uint32_t(i), 0xff);  // black
}
B32_THUNK(_SetPenState) {
    GuestAddr in = c.args.ptr();
    std::lock_guard guard(portsLock);
    stateOf(currentPort).penV = c.mem.read<int16_t>(in);
    stateOf(currentPort).penH = c.mem.read<int16_t>(in + 2);
}
// void TextFont(short family), TextFace(StyleParameter), TextSize(short)
B32_THUNK(_TextFont) {
    int16_t value = int16_t(c.args.i32());
    std::lock_guard guard(portsLock);
    stateOf(currentPort).textFont = value;
}
B32_THUNK(_TextFace) {
    int16_t value = int16_t(c.args.i32());
    std::lock_guard guard(portsLock);
    stateOf(currentPort).textFace = value;
}
B32_THUNK(_TextSize) {
    int16_t value = int16_t(c.args.i32());
    std::lock_guard guard(portsLock);
    stateOf(currentPort).textSize = value;
}
// short GetPortTextFont(CGrafPtr), Style GetPortTextFace(CGrafPtr), short GetPortTextSize(CGrafPtr)
B32_THUNK(_GetPortTextFont) { c.ret(uint32_t(int32_t(b32::appkit::portState(c.args.ptr()).textFont))); }
B32_THUNK(_GetPortTextFace) { c.ret(uint32_t(b32::appkit::portState(c.args.ptr()).textFace & 0xff)); }
B32_THUNK(_GetPortTextSize) { c.ret(uint32_t(int32_t(b32::appkit::portState(c.args.ptr()).textSize))); }

namespace {
// The current port's font, as CoreText has it.
CTFontRef portFont() {
    b32::appkit::PortState state = b32::appkit::portState(currentPort);
    return b32::appkit::copyQuickDrawFont(state.textFont, state.textSize, state.textFace);
}
}  // namespace
// void GetFontInfo(FontInfo *): ascent, descent, widest character and leading of the port's font, in pixels.
B32_THUNK(_GetFontInfo) {
    GuestAddr out = c.args.ptr();
    CTFontRef font = portFont();
    const int16_t info[4] = {int16_t(std::lround(CTFontGetAscent(font))), int16_t(std::lround(CTFontGetDescent(font))),
                             int16_t(std::lround(CGRectGetWidth(CTFontGetBoundingBox(font)))),
                             int16_t(std::lround(CTFontGetLeading(font)))};
    CFRelease(font);
    if (out) c.mem.writeArray<int16_t>(out, info, 4);
}
// short TextWidth(const void *text, short firstByte, short byteCount): the Mac Roman text's width in the port's font.
B32_THUNK(_TextWidth) {
    GuestAddr text = c.args.ptr();
    int16_t first = int16_t(c.args.i32()), count = int16_t(c.args.i32());
    if (!text || count <= 0) {
        c.ret(0);
        return;
    }
    NSString *string = [[NSString alloc] initWithBytes:c.mem.ptr<char>(text + uint32_t(first)) length:NSUInteger(count) encoding:NSMacOSRomanStringEncoding];
    CTFontRef font = portFont();
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:string ?: @"" attributes:@{(id)kCTFontAttributeName : (__bridge id)font}];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)attributed);
    double width = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
    CFRelease(line);
    CFRelease(font);
    [attributed release];
    [string release];
    c.ret(uint32_t(int32_t(std::lround(width))));
}
// void GetFontName(short family, Str255 name)
B32_THUNK(_GetFontName) {
    int16_t family = int16_t(c.args.i32());
    GuestAddr out = c.args.ptr();
    if (!out) return;
    NSString *name = @(b32::appkit::quickDrawFamilyName(family).c_str());
    NSData *bytes = [name dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
    uint8_t length = uint8_t(std::min<NSUInteger>(bytes.length, 255));
    c.mem.write<uint8_t>(out, length);
    c.mem.copyIn(out + 1, bytes.bytes, length);
}
// GDHandle GetGWorldDevice(GWorldPtr): the screen's, which every GWorld here is made for.
B32_THUNK(_GetGWorldDevice) {
    c.args.ptr();
    c.ret(screenDeviceHandle(c.rt));
}

// The eight-byte pattern a guest is handed a pointer to.
GuestAddr patternBytes(Call &c, uint8_t fill) {
    GuestAddr pattern = c.heap.alloc(8);
    uint8_t bytes[8];
    std::fill(bytes, bytes + 8, fill);
    c.mem.copyIn(pattern, bytes, 8);
    return pattern;
}
// ConstPatternParam GetQDGlobalsBlack(void)
B32_THUNK(_GetQDGlobalsBlack) { c.ret(patternBytes(c, 0xff)); }
// ConstPatternParam GetQDGlobalsWhite(void)
B32_THUNK(_GetQDGlobalsWhite) { c.ret(patternBytes(c, 0x00)); }
// ConstPatternParam GetQDGlobalsGray(void)
B32_THUNK(_GetQDGlobalsGray) { c.ret(patternBytes(c, 0xaa)); }

// --- regions: what a game invalidates and clips with --------------------------
// NewRgn and SetRectRgn live in carbon_ui.mm; the rest of the family takes the
// bounding box as the region, which is what they were used for here. A handle
// that isn't one (0 from a stub that had nothing) reads as an empty region.

namespace {
// The region behind a handle, or 0: what a game hands over can be a handle it
// made some other way, and a pointer into nowhere reads as no region.
GuestAddr regionOf(Call &c, GuestAddr handle) {
    if (!handle || !c.mem.isMapped(handle) || !c.mem.isMapped(handle + 4)) return 0;
    GuestAddr region = c.mem.read<uint32_t>(handle);
    return region && c.mem.isMapped(region) && c.mem.isMapped(region + 9) ? region : 0;
}
bool regionEmpty(Call &c, GuestAddr region) {
    if (!region) return true;
    return c.mem.read<int16_t>(region + 2) >= c.mem.read<int16_t>(region + 6) ||
           c.mem.read<int16_t>(region + 4) >= c.mem.read<int16_t>(region + 8);
}
}  // namespace

// void DisposeRgn(RgnHandle)
B32_THUNK(_DisposeRgn) { c.args.ptr(); }
// Boolean EmptyRgn(RgnHandle)
B32_THUNK(_EmptyRgn) { c.ret(regionEmpty(c, regionOf(c, c.args.ptr()))); }
// void GetRegionBounds(RgnHandle, Rect *out)
B32_THUNK(_GetRegionBounds) {
    GuestAddr out = c.args.ptr(), region = regionOf(c, c.args.ptr());
    if (region)
        copyRect(c.rt, out, region + 2);
    else
        writeRect(c.rt, out, 0, 0, 0, 0);
}
// void OffsetRgn(RgnHandle, short dh, short dv)
B32_THUNK(_OffsetRgn) {
    GuestAddr region = regionOf(c, c.args.ptr());
    int16_t dh = c.args.i32(), dv = c.args.i32();
    if (!region) return;
    int16_t box[4];
    for (int i = 0; i < 4; i++) box[i] = c.mem.read<int16_t>(region + 2 + uint32_t(i) * 2);
    writeRect(c.rt, region + 2, int16_t(box[0] + dv), int16_t(box[1] + dh), int16_t(box[2] + dv), int16_t(box[3] + dh));
}
// void SectRgn(RgnHandle, RgnHandle, RgnHandle out)
B32_THUNK(_SectRgn) {
    GuestAddr a = regionOf(c, c.args.ptr()), b = regionOf(c, c.args.ptr()), out = regionOf(c, c.args.ptr());
    int16_t box[4] = {0, 0, 0, 0};
    if (a && b) {
        int16_t ra[4], rb[4];
        for (int i = 0; i < 4; i++) {
            ra[i] = c.mem.read<int16_t>(a + 2 + uint32_t(i) * 2);
            rb[i] = c.mem.read<int16_t>(b + 2 + uint32_t(i) * 2);
        }
        box[0] = int16_t(std::max(ra[0], rb[0]));
        box[1] = int16_t(std::max(ra[1], rb[1]));
        box[2] = int16_t(std::min(ra[2], rb[2]));
        box[3] = int16_t(std::min(ra[3], rb[3]));
        if (box[0] >= box[2] || box[1] >= box[3]) box[0] = box[1] = box[2] = box[3] = 0;
    }
    if (out) c.mem.writeArray<int16_t>(out + 2, box, 4);
}
// void EmptyRect(Rect *)
B32_THUNK(_EmptyRect) {
    GuestAddr rect = c.args.ptr();
    writeRect(c.rt, rect, 0, 0, 0, 0);
}
// void SetEntryColor(PaletteHandle, short entry, const RGBColor *): the palette
// holds nothing to color.
B32_THUNK(_SetEntryColor) {
    c.args.ptr();
    c.args.i32();
    c.args.ptr();
    c.ret(0);
}
// void SetPortBounds(CGrafPtr, const Rect *)
B32_THUNK(_SetPortBounds) {
    GuestAddr port = c.args.ptr(), rect = c.args.ptr();
    if (port) copyRect(c.rt, port + 18, rect);
}
// Boolean EqualRect(const Rect *, const Rect *)
B32_THUNK(_EqualRect) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    bool equal = true;
    for (int i = 0; i < 8; i++) equal = equal && c.mem.read<uint8_t>(a + i) == c.mem.read<uint8_t>(b + i);
    c.ret(equal);
}
// void FillRect(const Rect *): the port's pixels are the game's business
B32_THUNK(_FillRect) { c.args.ptr(); }

// --- ports a guest makes for itself -------------------------------------------

// CGrafPtr CreateNewPort(void)
B32_THUNK(_CreateNewPort) {
    GuestAddr bounds = c.heap.calloc(1, 8);
    c.ret(newWorldPort(c.rt, 0, bounds));
}
// void DisposePort(CGrafPtr)
B32_THUNK(_DisposePort) { c.args.ptr(); }

// --- the palette and the cursor QuickDraw kept --------------------------------

// PaletteHandle NewPalette(short entries): entries of nothing, behind a handle.
B32_THUNK(_NewPalette) {
    c.args.i32();
    GuestAddr handle = c.heap.calloc(1, 4);
    c.mem.write<uint32_t>(handle, c.heap.calloc(1, 4));
    c.ret(handle);
}
// void DisposePalette(PaletteHandle)
B32_THUNK(_DisposePalette) { c.args.ptr(); }
// OSStatus QDRegisterNamedPixMapCursor(CFStringRef, PixMapHandle, PixMapHandle)
B32_THUNK(_QDRegisterNamedPixMapCursor) {
    c.args.ptr();
    c.args.ptr();
    c.args.ptr();
    c.ret(0);
}

// OSStatus QDSetNamedPixMapCursor(CFStringRef), QDUnregisterNamedPixMapCursur(CFStringRef) (sic): the
// cursor stays the system's.
B32_THUNK(_QDSetNamedPixMapCursor) {
    c.args.ptr();
    c.ret(0);
}
B32_THUNK(_QDUnregisterNamedPixMapCursur) {
    c.args.ptr();
    c.ret(0);
}

// --- the Display Manager's names for the device -------------------------------

// The one display's Display Manager ID. Not 1: games start a "same display as the last one" check at 1,
// since the IDs of the time never were.
constexpr uint32_t kDisplayID = 0x100;

// OSStatus DMGetDisplayIDByGDevice(GDHandle, DisplayIDType *out, Boolean)
B32_THUNK(_DMGetDisplayIDByGDevice) {
    c.args.ptr();
    GuestAddr out = c.args.ptr();
    c.args.u32();
    if (out) c.mem.write<uint32_t>(out, kDisplayID);
    c.ret(0);
}

// --- the Display Manager's mode lists ------------------------------------------------------------
// A game asks for the display's modes and is called back with each. The screen is never switched (a game's
// picture is scaled to it), so the list is the resolutions games of the time chose from, and the screen's
// own, each in 16 and 32-bit color at 60 Hz.
namespace {
// One mode's records, laid out as a 32-bit program has them: Displays.h's in their natural alignment, and
// the video driver's (IOMacOSVideo.h, Video.h) packed to two bytes:
//   DMDisplayModeListEntryRec 32: flags 0, switch info 4, resolution info 8, timing info 12, depth block 16,
//                                 version 20, name 24, display info 28
//   VDResolutionInfoRec 30:       previous mode 0, this mode 4, width 8, height 12, refresh rate (Fixed) 16,
//                                 deepest depth mode 20, flags 22
//   VDSwitchInfoRec 16:           depth mode 0, display mode 2, page 6, base address 8
//   DMDepthInfoBlockRec 20:       count 0, depths 4, flags 8
//   DMDepthInfoRec 20:            switch info 0, VPBlock 4, flags 8
//   VPBlock 42:                   row bytes 4, bounds 6, version 14, horizontal and vertical resolution
//                                 22 and 26, pixel type 30, pixel size 32, components 34, component size 36
constexpr uint32_t kEntrySize = 32, kResolutionSize = 32, kSwitchSize = 16, kDepthBlockSize = 20, kDepthSize = 20,
                   kVPBlockSize = 44;
constexpr uint16_t kDepths[] = {16, 32};
constexpr uint32_t kDepthCount = sizeof kDepths / sizeof kDepths[0];
constexpr uint32_t kModeSize = kEntrySize + kResolutionSize + kSwitchSize + kDepthBlockSize +
                               kDepthCount * (kDepthSize + kSwitchSize + kVPBlockSize);
// A list: its count, then each mode's records.
constexpr uint32_t kListHeader = 4;

std::vector<std::pair<uint32_t, uint32_t>> displayModes() {
    std::vector<std::pair<uint32_t, uint32_t>> modes = {{640, 480},   {800, 600},   {1024, 768},  {1152, 864},
                                                        {1280, 960},  {1280, 1024}, {1440, 900},  {1600, 1200},
                                                        {1680, 1050}, {1920, 1080}, {1920, 1200}};
    NSSize screen = NSScreen.mainScreen.frame.size;
    modes.emplace_back(uint32_t(screen.width), uint32_t(screen.height));
    std::sort(modes.begin(), modes.end());
    modes.erase(std::unique(modes.begin(), modes.end()), modes.end());
    return modes;
}

void writeMode(Call &c, GuestAddr at, uint32_t index, uint32_t width, uint32_t height) {
    GuestAddr entry = at, resolution = entry + kEntrySize, modeSwitch = resolution + kResolutionSize,
              block = modeSwitch + kSwitchSize, depths = block + kDepthBlockSize;
    uint32_t mode = 0x80 + index;  // a DisplayModeID
    c.mem.write<uint32_t>(entry + 4, modeSwitch);
    c.mem.write<uint32_t>(entry + 8, resolution);
    c.mem.write<uint32_t>(entry + 16, block);
    c.mem.write<uint32_t>(resolution + 4, mode);
    c.mem.write<uint32_t>(resolution + 8, width);
    c.mem.write<uint32_t>(resolution + 12, height);
    c.mem.write<uint32_t>(resolution + 16, 60u << 16);
    c.mem.write<uint16_t>(resolution + 20, uint16_t(0x80 + kDepthCount - 1));  // the deepest depth mode
    c.mem.write<uint16_t>(modeSwitch + 0, 0x80);
    c.mem.write<uint32_t>(modeSwitch + 2, mode);
    c.mem.write<uint32_t>(block + 0, kDepthCount);
    c.mem.write<uint32_t>(block + 4, depths);
    for (uint32_t d = 0; d < kDepthCount; d++) {
        GuestAddr depth = depths + d * kDepthSize;
        GuestAddr depthSwitch = depths + kDepthCount * kDepthSize + d * (kSwitchSize + kVPBlockSize);
        GuestAddr vp = depthSwitch + kSwitchSize;
        uint16_t bits = kDepths[d];
        c.mem.write<uint32_t>(depth + 0, depthSwitch);
        c.mem.write<uint32_t>(depth + 4, vp);
        c.mem.write<uint16_t>(depthSwitch + 0, uint16_t(0x80 + d));
        c.mem.write<uint32_t>(depthSwitch + 2, mode);
        c.mem.write<uint16_t>(vp + 4, uint16_t(width * bits / 8));
        const int16_t bounds[4] = {0, 0, int16_t(height), int16_t(width)};
        c.mem.writeArray<int16_t>(vp + 6, bounds, 4);
        c.mem.write<uint32_t>(vp + 22, 72u << 16);
        c.mem.write<uint32_t>(vp + 26, 72u << 16);
        c.mem.write<uint16_t>(vp + 30, 16);  // RGBDirect
        c.mem.write<uint16_t>(vp + 32, bits);
        c.mem.write<uint16_t>(vp + 34, 3);
        c.mem.write<uint16_t>(vp + 36, bits == 16 ? 5 : 8);
    }
}
}  // namespace

// OSErr DMNewDisplayModeList(DisplayIDType, UInt32 flags, UInt32 reserved, DMListIndexType *count, DMListType *list)
B32_THUNK(_DMNewDisplayModeList) {
    c.args.u32();
    c.args.u32();
    c.args.u32();
    GuestAddr countOut = c.args.ptr(), listOut = c.args.ptr();
    std::vector<std::pair<uint32_t, uint32_t>> modes = displayModes();
    uint32_t count = uint32_t(modes.size());
    GuestAddr list = c.heap.calloc(1, kListHeader + count * kModeSize);
    c.mem.write<uint32_t>(list, count);
    for (uint32_t i = 0; i < count; i++) writeMode(c, list + kListHeader + i * kModeSize, i, modes[i].first, modes[i].second);
    if (countOut) c.mem.write<uint32_t>(countOut, count);
    if (listOut) c.mem.write<uint32_t>(listOut, list);
    c.ret(0);
}
// OSErr DMGetIndexedDisplayModeFromList(DMListType, DMListIndexType index, UInt32 options,
//                                       DMDisplayModeListIteratorUPP, void *userData): the iterator is called
// with (userData, index, the mode's DMDisplayModeListEntryRec).
B32_THUNK(_DMGetIndexedDisplayModeFromList) {
    GuestAddr list = c.args.ptr();
    uint32_t index = c.args.u32();
    c.args.u32();
    GuestAddr iterator = c.args.ptr(), user = c.args.u32();
    constexpr int32_t kParamErr = -50;
    if (!list || index >= c.mem.read<uint32_t>(list)) {
        c.ret(uint32_t(kParamErr));
        return;
    }
    if (iterator) c.cpu.call(iterator, {user, index, list + kListHeader + index * kModeSize});
    c.ret(0);
}
// OSErr DMDisposeList(DMListType)
B32_THUNK(_DMDisposeList) {
    if (GuestAddr list = c.args.ptr()) c.heap.free(list);
    c.ret(0);
}
// On Mac OS X a UPP is the function itself.
B32_THUNK(_NewDMDisplayModeListIteratorUPP) { c.ret(c.args.ptr()); }
B32_THUNK(_DisposeDMDisplayModeListIteratorUPP) { c.args.ptr(); }
