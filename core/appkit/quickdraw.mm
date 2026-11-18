// QuickDraw's graphics model: the screen's GDevice, offscreen GWorlds with
// pixel buffers of the guest's own memory, and the current port and device.
// Drawing calls are no-ops — the games that come here draw their own pixels
// into the buffers (a texture, a cursor) or draw through OpenGL — but the
// structures they walk have to be there, in the guest's memory and byte order.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/appkit/Carbon.h"
#include "core/thunks/Thunks.h"

#import <AppKit/AppKit.h>

#include <vector>
#include <algorithm>
#include <unordered_map>

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

// CGrafPort: portPixMap 4, portRect 18 (the classic 32-bit layout; 100 bytes).
GuestAddr newWorldPort(Runtime &rt, GuestAddr pixmapHandle, GuestAddr bounds) {
    GuestAddr port = rt.heap().calloc(1, 100);
    rt.mem().write<uint32_t>(port + 4, pixmapHandle);
    copyRect(rt, port + 18, bounds);
    return port;
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
// The rest paint nothing: the guest's own blitter or OpenGL puts the pixels up.
B32_THUNK(_PaintRect) { c.args.ptr(); }
B32_THUNK(_EraseRect) { c.args.ptr(); }
B32_THUNK(_FrameRect) { c.args.ptr(); }
B32_THUNK(_InvalRect) { c.args.ptr(); }
B32_THUNK(_ValidRect) { c.args.ptr(); }
B32_THUNK(_ClipRect) { c.args.ptr(); }
B32_THUNK(_QDFlushPortBuffer) { c.args.ptr(); c.args.ptr(); }
B32_THUNK(_PenNormal) {}
B32_THUNK(_PenSize) { c.args.i32(); c.args.i32(); }
B32_THUNK(_RGBForeColor) { c.args.ptr(); }
B32_THUNK(_RGBBackColor) { c.args.ptr(); }
B32_THUNK(_ForeColor) { c.args.i32(); }
B32_THUNK(_BackColor) { c.args.i32(); }

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
