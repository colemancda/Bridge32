// The system calls SDL-style Mac games make: displays, the Carbon odds and ends
// that survived, IOKit HID and force feedback.
//
// Guest code never captures the display or changes its mode; those calls
// succeed and do nothing, so a misbehaving guest can't take over the screen.
// HID presents an empty device list: no game controllers yet.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <CoreVideo/CoreVideo.h>
#include <ImageIO/ImageIO.h>
#include <OpenGL/OpenGL.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }
void *process() { return RTLD_DEFAULT; }

const CFunction kDisplays[] = {
    {"CGMainDisplayID", "u:"},
    {"CGGetOnlineDisplayList", "i:upp"},
    {"CGGetActiveDisplayList", "i:upp"},
    {"CGDisplayIsMain", "i:u"},
    {"CGDisplayMirrorsDisplay", "u:u"},
    {"CGDisplayPixelsWide", "z:u"},
    {"CGDisplayPixelsHigh", "z:u"},
    {"CGDisplayCopyAllDisplayModes", "o:uo"},
    {"CGDisplayCopyDisplayMode", "o:u"},
    {"CGDisplayModeGetWidth", "z:o"},
    {"CGDisplayModeGetHeight", "z:o"},
    {"CGDisplayModeGetRefreshRate", "d:o"},
    {"CGDisplayModeRetain", "o:o"},
    {"CGDisplayModeRelease", "v:o"},
    {"CGDisplayIDToOpenGLDisplayMask", "u:u"},
    {"CGShieldingWindowLevel", "i:"},
    {"CGWindowLevelForKey", "i:i"},
    {"CGGetDisplayTransferByTable", "i:uuppppp"},
    {"CGAssociateMouseAndMouseCursorPosition", "i:u"},
    {"CFRunLoopRunInMode", "i:odu"},
    {"CFUUIDGetConstantUUIDWithBytes", "o:puuuuuuuuuuuuuuuu"},
};

// Not available any more; SDL only used it to name the pixel format.
CFStringRef copyPixelEncoding(CGDisplayModeRef) { return CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB"); }
}  // namespace

B32_C_FUNCTIONS(kDisplays, process);

B32_THUNK(_CGDisplayModeCopyPixelEncoding) {
    c.args.ptr();
    c.ret(bridge(c).toGuest((id)copyPixelEncoding(nullptr)));
}

B32_THUNK(_CGDisplayBounds) {
    StructResult out(c, 16);
    CGRect r = CGDisplayBounds(c.args.u32());
    c.mem.write<float>(out, float(r.origin.x));
    c.mem.write<float>(out + 4, float(r.origin.y));
    c.mem.write<float>(out + 8, float(r.size.width));
    c.mem.write<float>(out + 12, float(r.size.height));
}
B32_THUNK(_CGDisplayScreenSize) {
    StructResult out(c, 8);
    CGSize s = CGDisplayScreenSize(c.args.u32());
    c.mem.write<float>(out, float(s.width));
    c.mem.write<float>(out + 4, float(s.height));
}
B32_THUNK(_CGWarpMouseCursorPosition) {
    float x = c.args.f32();
    c.ret(CGWarpMouseCursorPosition(CGPointMake(x, c.args.f32())));
}
B32_THUNK(_CGDisplayMoveCursorToPoint) {
    uint32_t display = c.args.u32();
    float x = c.args.f32();
    c.ret(CGDisplayMoveCursorToPoint(display, CGPointMake(x, c.args.f32())));
}

// The screen stays the user's.
#define B32_SUCCEEDS(symbol) B32_THUNK(symbol) { c.ret(0); }
B32_SUCCEEDS(_CGCaptureAllDisplays)
B32_SUCCEEDS(_CGReleaseAllDisplays)
B32_SUCCEEDS(_CGDisplayCapture)
B32_SUCCEEDS(_CGDisplayRelease)
B32_SUCCEEDS(_CGDisplaySetDisplayMode)
B32_SUCCEEDS(_CGSetDisplayTransferByTable)
B32_SUCCEEDS(_CGDisplayFade)
B32_SUCCEEDS(_CGReleaseDisplayFadeReservation)
// CGDisplayErr: kCGErrorFailure, so no fade is attempted.
B32_THUNK(_CGAcquireDisplayFadeReservation) { c.ret(1000); }
B32_THUNK(_CGDisplayIOServicePort) { c.ret(0); }

B32_THUNK(_HideMenuBar) { [NSMenu setMenuBarVisible:NO]; }
B32_THUNK(_ShowMenuBar) { [NSMenu setMenuBarVisible:YES]; }
B32_THUNK(_UpdateSystemActivity) { c.ret(0); }

// CVDisplayLink: an error, which callers treat as "use the mode's refresh rate".
B32_THUNK(_CVDisplayLinkCreateWithCGDisplay) {
    c.args.u32();
    c.mem.write<uint32_t>(c.args.ptr(), 0);
    c.ret(uint32_t(-6660));  // kCVReturnError
}

// A real display link whose callback runs guest code, on the link's thread.
namespace {
struct GuestLinkCallback {
    GuestAddr function = 0, context = 0;
};
CVReturn displayLinkFired(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output, CVOptionFlags flagsIn,
                          CVOptionFlags *flagsOut, void *user) {
    auto *callback = static_cast<GuestLinkCallback *>(user);
    if (!callback->function) return kCVReturnSuccess;
    Runtime &rt = Bridge::shared()->runtime();
    Cpu &cpu = Runtime::threadCpu();
    GuestAddr stamps = rt.heap().alloc(sizeof(CVTimeStamp) * 2 + 8);
    GuestAddr guestNow = stamps, guestOutput = stamps + sizeof(CVTimeStamp), guestFlags = stamps + sizeof(CVTimeStamp) * 2;
    rt.mem().copyIn(guestNow, now, sizeof *now);
    rt.mem().copyIn(guestOutput, output, sizeof *output);
    rt.mem().write<uint64_t>(guestFlags, 0);
    // CVOptionFlags is 64-bit, so it takes two words.
    uint32_t result = uint32_t(cpu.call(callback->function, {hostHandle(link), guestNow, guestOutput, uint32_t(flagsIn),
                                                             uint32_t(flagsIn >> 32), guestFlags, callback->context}));
    rt.heap().free(stamps);
    return CVReturn(result);
}
CVDisplayLinkRef linkArg(Call &c) { return static_cast<CVDisplayLinkRef>(hostPointer(c.args.u32())); }
}  // namespace

B32_THUNK(_CVDisplayLinkCreateWithActiveCGDisplays) {
    GuestAddr out = c.args.ptr();
    CVDisplayLinkRef link = nullptr;
    CVReturn result = CVDisplayLinkCreateWithActiveCGDisplays(&link);
    c.mem.write<uint32_t>(out, link ? hostHandle(link) : 0);
    c.ret(uint32_t(result));
}
// CVReturn CVDisplayLinkSetOutputCallback(link, callback, context)
B32_THUNK(_CVDisplayLinkSetOutputCallback) {
    CVDisplayLinkRef link = linkArg(c);
    GuestAddr function = c.args.ptr();
    auto *callback = new GuestLinkCallback{function, c.args.ptr()};
    c.ret(uint32_t(CVDisplayLinkSetOutputCallback(link, displayLinkFired, callback)));
}
B32_THUNK(_CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext) {
    CVDisplayLinkRef link = linkArg(c);
    auto context = static_cast<CGLContextObj>(hostPointer(c.args.u32()));
    auto format = static_cast<CGLPixelFormatObj>(hostPointer(c.args.u32()));
    c.ret(uint32_t(CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(link, context, format)));
}
B32_THUNK(_CVDisplayLinkStart) { c.ret(uint32_t(CVDisplayLinkStart(linkArg(c)))); }
B32_THUNK(_CVDisplayLinkStop) { c.ret(uint32_t(CVDisplayLinkStop(linkArg(c)))); }
B32_THUNK(_CVDisplayLinkIsRunning) { c.ret(CVDisplayLinkIsRunning(linkArg(c))); }
B32_THUNK(_CVDisplayLinkRelease) {
    uint32_t handle = c.args.u32();
    if (handle) CVDisplayLinkRelease(static_cast<CVDisplayLinkRef>(hostPointer(handle)));
}
B32_THUNK(_CVDisplayLinkGetNominalOutputVideoRefreshPeriod) {
    StructResult out(c, 24);
    (void)out;
}

// --- keyboard layout: none, so SDL keeps its US key map --------------------------------

B32_THUNK(_TISCopyCurrentKeyboardLayoutInputSource) { c.ret(0); }
B32_THUNK(_TISGetInputSourceProperty) { c.ret(0); }
B32_THUNK(_KBGetLayoutType) { c.ret(0); }
B32_THUNK(_LMGetKbdType) { c.ret(0); }
B32_THUNK(_UCKeyTranslate) { c.ret(uint32_t(-1)); }

// --- IOKit: nothing to find ----------------------------------------------------------

constexpr uint32_t kIOReturnFailure = 0xE00002BC;
#define B32_IOKIT_ERROR(symbol) B32_THUNK(symbol) { c.ret(kIOReturnFailure); }
#define B32_NOTHING(symbol) B32_THUNK(symbol) { c.ret(0); }

B32_DATA(_kIOMasterPortDefault, 4) {}
B32_NOTHING(_IOServiceMatching)
B32_NOTHING(_IOServiceGetMatchingService)
B32_NOTHING(_IOBSDNameMatching)
B32_NOTHING(_IORegistryEntryCreateCFProperty)
B32_IOKIT_ERROR(_IOMasterPort)
B32_IOKIT_ERROR(_IOServiceGetMatchingServices)
B32_NOTHING(_IOIteratorNext)
B32_NOTHING(_IOIteratorIsValid)
B32_NOTHING(_IOObjectRelease)
B32_NOTHING(_IOObjectRetain)
B32_NOTHING(_IOObjectIsEqualTo)
B32_IOKIT_ERROR(_IORegistryEntryCreateCFProperties)
B32_IOKIT_ERROR(_IORegistryEntryGetParentEntry)
B32_NOTHING(_IODisplayCreateInfoDictionary)
B32_NOTHING(_IOPSCopyPowerSourcesInfo)
B32_NOTHING(_IOPSCopyPowerSourcesList)
B32_NOTHING(_IOPSGetPowerSourceDescription)
B32_NOTHING(_IOPMAssertionCreateWithDescription)
B32_NOTHING(_IOPMAssertionRelease)

// An IOHIDManager that opens and never reports a device.
B32_THUNK(_IOHIDManagerCreate) {
    static id manager = [[NSObject alloc] init];
    c.ret(bridge(c).toGuest(manager));
}
B32_NOTHING(_IOHIDManagerClose)
B32_NOTHING(_IOHIDManagerOpen)
B32_NOTHING(_IOHIDManagerRegisterDeviceMatchingCallback)
B32_NOTHING(_IOHIDManagerScheduleWithRunLoop)
B32_NOTHING(_IOHIDManagerSetDeviceMatchingMultiple)
B32_NOTHING(_IOHIDManagerUnscheduleFromRunLoop)
B32_NOTHING(_IOHIDDeviceCopyMatchingElements)
B32_NOTHING(_IOHIDDeviceGetProperty)
B32_NOTHING(_IOHIDDeviceGetService)
B32_IOKIT_ERROR(_IOHIDDeviceGetValue)
B32_NOTHING(_IOHIDDeviceRegisterRemovalCallback)
B32_NOTHING(_IOHIDDeviceScheduleWithRunLoop)
B32_NOTHING(_IOHIDDeviceUnscheduleFromRunLoop)
B32_NOTHING(_IOHIDElementGetChildren)
B32_NOTHING(_IOHIDElementGetCookie)
B32_NOTHING(_IOHIDElementGetLogicalMax)
B32_NOTHING(_IOHIDElementGetLogicalMin)
B32_NOTHING(_IOHIDElementGetType)
B32_NOTHING(_IOHIDElementGetTypeID)
B32_NOTHING(_IOHIDElementGetUsage)
B32_NOTHING(_IOHIDElementGetUsagePage)
B32_NOTHING(_IOHIDValueGetIntegerValue)

// Force feedback: no device has it.
constexpr uint32_t kFFErrNoInterface = 0x80004002;
#define B32_FF(symbol) B32_THUNK(symbol) { c.ret(kFFErrNoInterface); }
B32_FF(_FFIsForceFeedback)
B32_FF(_FFCreateDevice)
B32_FF(_FFDeviceCreateEffect)
B32_FF(_FFDeviceGetForceFeedbackCapabilities)
B32_FF(_FFDeviceGetForceFeedbackProperty)
B32_FF(_FFDeviceReleaseEffect)
B32_FF(_FFDeviceSendForceFeedbackCommand)
B32_FF(_FFDeviceSetForceFeedbackProperty)
B32_FF(_FFEffectGetEffectStatus)
B32_FF(_FFEffectSetParameters)
B32_FF(_FFEffectStart)
B32_FF(_FFEffectStop)
B32_FF(_FFReleaseDevice)

// Old Component Manager: SDL's audio fallback, unused when CoreAudio works.
B32_NOTHING(_FindNextComponent)
B32_NOTHING(_OpenAComponent)
B32_NOTHING(_CloseComponent)

// --- HAL properties and converters: not reached by playback through AudioUnit ----------

constexpr uint32_t kAudioUnspecified = 'what';
B32_THUNK(_AudioObjectGetPropertyData) { c.ret(kAudioUnspecified); }
B32_THUNK(_AudioObjectGetPropertyDataSize) { c.ret(kAudioUnspecified); }
B32_THUNK(_AudioObjectAddPropertyListener) { c.ret(0); }
B32_THUNK(_AudioObjectRemovePropertyListener) { c.ret(0); }
B32_THUNK(_AudioConverterNew) { c.ret(kAudioUnspecified); }
B32_THUNK(_AudioConverterDispose) { c.ret(0); }
B32_THUNK(_AudioConverterFillComplexBuffer) { c.ret(kAudioUnspecified); }

// --- image loading (SDL_image): a sequential provider's callbacks are guest code -------

// CGDataProviderRef CGDataProviderCreateSequential(void *info, const CGDataProviderSequentialCallbacks *)
// with { version, getBytes, skipForward, rewind, releaseInfo }: read it all now.
B32_THUNK(_CGDataProviderCreateSequential) {
    GuestAddr info = c.args.ptr(), callbacks = c.args.ptr();
    GuestAddr getBytes = c.mem.read<uint32_t>(callbacks + 4);
    GuestAddr release = c.mem.read<uint32_t>(callbacks + 16);
    NSMutableData *all = [NSMutableData data];
    constexpr uint32_t kChunk = 64 * 1024;
    GuestAddr buffer = c.heap.alloc(kChunk);
    for (;;) {
        uint32_t got = uint32_t(c.cpu.call(getBytes, {info, buffer, kChunk}));
        if (!got || got > kChunk) break;
        [all appendBytes:c.mem.ptr<void>(buffer) length:got];
    }
    c.heap.free(buffer);
    if (release) c.cpu.call(release, {info});
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CGDataProviderCreateWithCFData((CFDataRef)all))));
}
B32_THUNK(_CGImageSourceCreateWithURL) {
    NSURL *url = bridge(c).toHost(c.args.ptr());
    NSDictionary *options = bridge(c).toHost(c.args.ptr());
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CGImageSourceCreateWithURL((CFURLRef)url, (CFDictionaryRef)options))));
}
B32_THUNK(_CGImageSourceGetType) {
    CGImageSourceRef source = (CGImageSourceRef)bridge(c).toHost(c.args.ptr());
    c.ret(bridge(c).toGuest((id)CGImageSourceGetType(source)));
}
B32_THUNK(_CGColorSpaceGetColorTableCount) {
    c.ret(uint32_t(CGColorSpaceGetColorTableCount((CGColorSpaceRef)bridge(c).toHost(c.args.ptr()))));
}
B32_THUNK(_CGColorSpaceGetColorTable) {
    CGColorSpaceRef space = (CGColorSpaceRef)bridge(c).toHost(c.args.ptr());
    CGColorSpaceGetColorTable(space, c.mem.ptr<uint8_t>(c.args.ptr()));
}
B32_THUNK(_UTTypeConformsTo) {
    NSString *a = bridge(c).toHost(c.args.ptr());
    NSString *b = bridge(c).toHost(c.args.ptr());
    c.ret(UTTypeConformsTo((CFStringRef)a, (CFStringRef)b));
}
// OSErr Gestalt(OSType selector, SInt32 *response): the guest sees Mac OS X 10.6.8,
// the last system that ran both its PowerPC-era and Intel-era APIs.
B32_THUNK(_Gestalt) {
    uint32_t selector = c.args.u32();
    GuestAddr out = c.args.ptr();
    int32_t value = -1;
    switch (selector) {
    case 'sysv': value = 0x1068; break;
    case 'sys1': value = 10; break;
    case 'sys2': value = 6; break;
    case 'sys3': value = 8; break;
    case 'qtim': value = 0x07658000; break;  // QuickTime 7.6.5; its calls are thunks that fail softly
    default: break;
    }
    if (out) c.mem.write<int32_t>(out, value < 0 ? 0 : value);
    c.ret(value < 0 ? uint32_t(-5551) : 0);  // gestaltUndefSelectorErr
}

// AbsoluteTime is 8 bytes (EAX:EDX); as ticks of mach_absolute_time, which is
// what callers treat it as.
B32_THUNK(_UpTime) { c.ret64(mach_absolute_time()); }
// Duration: milliseconds if positive.
B32_THUNK(_AbsoluteToDuration) {
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    uint64_t ticks = c.args.u64();
    c.ret(uint32_t(ticks * base.numer / base.denom / 1000000));
}
B32_THUNK(_CFBundleGetValueForInfoDictionaryKey) {
    CFBundleRef bundle = (CFBundleRef)bridge(c).toHost(c.args.ptr());
    NSString *key = bridge(c).toHost(c.args.ptr());
    c.ret(bridge(c).toGuest((id)CFBundleGetValueForInfoDictionaryKey(bundle, (CFStringRef)key)));
}

B32_DATA(_NSAppKitVersionNumber, 8) { rt.mem().write<double>(addr, 1671.0); }  // 10.14's
B32_DATA(_NSZeroPoint, 8) {}
B32_DATA(_NSZeroSize, 8) {}
B32_DATA(_NSZeroRect, 16) {}
B32_DATA(_kCFTypeArrayCallBacks, 20) {}
