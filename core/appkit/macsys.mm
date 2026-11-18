// The system calls SDL-style Mac games make: displays, the Carbon odds and ends
// that survived, IOKit HID and force feedback.
//
// Guest code never captures the display or changes its mode; those calls
// succeed and do nothing, so a misbehaving guest can't take over the screen.
// HID presents an empty device list: no game controllers yet.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/appkit/Carbon.h"
#include "core/thunks/CTable.h"
#include "core/thunks/Discs.h"

#import <AppKit/AppKit.h>
#include <ApplicationServices/ApplicationServices.h>
#include <CoreVideo/CoreVideo.h>
#include <ImageIO/ImageIO.h>
#include <OpenGL/OpenGL.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }
void *process() { return RTLD_DEFAULT; }

const CFunction kDisplays[] = {
    {"CGMainDisplayID", "u:"},
#if !defined(B32_GUEST_BIG_ENDIAN)
    {"CGGetOnlineDisplayList", "i:upp"},
    {"CGGetActiveDisplayList", "i:upp"},
#endif
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
#if !defined(B32_GUEST_BIG_ENDIAN)
    {"CGGetDisplayTransferByTable", "i:uuppppp"},
#endif
    {"CGAssociateMouseAndMouseCursorPosition", "i:u"},
    {"CGDisplayHideCursor", "i:u"},
    {"CGDisplayShowCursor", "i:u"},
    {"CGCursorIsVisible", "u:"},
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
    float x = c.args.structFloat();  // a CGPoint passed by value
    c.ret(CGWarpMouseCursorPosition(appkit::gameScreenPoint(CGPointMake(x, c.args.structFloat()))));
}
B32_THUNK(_CGDisplayMoveCursorToPoint) {
    uint32_t display = c.args.u32();
    float x = c.args.structFloat();
    c.ret(CGDisplayMoveCursorToPoint(display, appkit::gameScreenPoint(CGPointMake(x, c.args.structFloat()))));
}

#if defined(B32_GUEST_BIG_ENDIAN)
// The display lists and the gamma table are arrays of 32-bit integers and floats,
// written to the guest in its byte order.
namespace {
void displayList(Call &c, bool active) {
    uint32_t maximum = c.args.u32();
    GuestAddr out = c.args.ptr(), count = c.args.ptr();
    std::vector<CGDirectDisplayID> ids(maximum);
    uint32_t n = 0;
    CGError error = active ? CGGetActiveDisplayList(maximum, ids.data(), &n) : CGGetOnlineDisplayList(maximum, ids.data(), &n);
    if (out) c.mem.writeArray<uint32_t>(out, ids.data(), std::min(n, maximum));
    if (count) c.mem.write<uint32_t>(count, n);
    c.ret(uint32_t(error));
}
}  // namespace
B32_THUNK(_CGGetActiveDisplayList) { displayList(c, true); }
B32_THUNK(_CGGetOnlineDisplayList) { displayList(c, false); }
// CGError CGGetDisplayTransferByTable(display, capacity, red[], green[], blue[], uint32_t *sampleCount)
B32_THUNK(_CGGetDisplayTransferByTable) {
    uint32_t display = c.args.u32(), capacity = c.args.u32();
    GuestAddr tables[3] = {c.args.ptr(), c.args.ptr(), c.args.ptr()};
    GuestAddr countOut = c.args.ptr();
    std::vector<CGGammaValue> channels[3] = {std::vector<CGGammaValue>(capacity), std::vector<CGGammaValue>(capacity),
                                             std::vector<CGGammaValue>(capacity)};
    uint32_t samples = 0;
    CGError error = CGGetDisplayTransferByTable(display, capacity, channels[0].data(), channels[1].data(), channels[2].data(), &samples);
    for (int i = 0; i < 3; i++)
        if (tables[i]) c.mem.writeArray<float>(tables[i], channels[i].data(), std::min(samples, capacity));
    if (countOut) c.mem.write<uint32_t>(countOut, samples);
    c.ret(uint32_t(error));
}
#endif

// The legacy display modes, CFDictionaries of the main display's width, height,
// depth and refresh rate. Modes are only described, never switched to: a game
// asking for another size gets a dictionary saying so, and its picture is
// scaled to the screen (aglSetFullScreen).
namespace {
NSDictionary *modeDictionary(size_t width, size_t height, double refresh) {
    return @{@"Width" : @(width), @"Height" : @(height), @"BitsPerPixel" : @32, @"BitsPerSample" : @8,
             @"SamplesPerPixel" : @3, @"RefreshRate" : @(refresh), @"UsableForDesktopGUI" : @YES};
}
}  // namespace
B32_THUNK(_CGDisplayCurrentMode) {
    CGDirectDisplayID display = c.args.u32();
    c.ret(bridge(c).toGuest(modeDictionary(CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display), 60)));
}
// CFDictionaryRef CGDisplayBestModeForParametersAndRefreshRate(display, bitsPerPixel, width, height, refresh,
//                                                              boolean_t *exactMatch)
B32_THUNK(_CGDisplayBestModeForParametersAndRefreshRate) {
    c.args.u32();
    c.args.u32();
    size_t width = c.args.u32(), height = c.args.u32();
    double refresh = c.args.f64();
    GuestAddr exact = c.args.ptr();
    if (exact) c.mem.write<uint32_t>(exact, 1);
    appkit::setRequestedDisplaySize(int(width), int(height));
    c.ret(bridge(c).toGuest(modeDictionary(width, height, refresh > 0 ? refresh : 60)));
}
// DMGetGDeviceByDisplayID(DisplayIDType, GDHandle *, Boolean failToMain): a handle to a blank GDevice.
B32_THUNK(_DMGetGDeviceByDisplayID) {
    c.args.u32();
    GuestAddr out = c.args.ptr();
    static GuestAddr handle = 0;
    if (!handle) {
        handle = c.heap.calloc(1, 4);
        c.mem.write<uint32_t>(handle, c.heap.calloc(1, 64));
    }
    if (out) c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}
// CFDictionaryRef CGDisplayBestModeForParameters(display, bitsPerPixel, width, height, boolean_t *exactMatch):
// the screen never changes; what it is is the best there is.
B32_THUNK(_CGDisplayBestModeForParameters) {
    uint32_t display = c.args.u32();
    c.args.u32();
    size_t width = c.args.u32(), height = c.args.u32();
    GuestAddr exact = c.args.ptr();
    if (exact) c.mem.write<uint32_t>(exact, 1);
    c.ret(bridge(c).toGuest(modeDictionary(width, height, 60)));
}
// CGDataProviderRef CGDataProviderCreateWithURL(CFURLRef)
B32_THUNK(_CGDataProviderCreateWithURL) {
    NSURL *url = (NSURL *)bridge(c).toHost(c.args.ptr());
    CGDataProviderRef provider = url ? CGDataProviderCreateWithURL((__bridge CFURLRef)url) : nullptr;
    c.ret(provider ? bridge(c).toGuest((id)CFBridgingRelease(provider)) : 0);
}

// The screen stays the user's.
#define B32_SUCCEEDS(symbol) B32_THUNK(symbol) { c.ret(0); }
B32_SUCCEEDS(_CGDisplaySwitchToMode)
B32_SUCCEEDS(_CGDisplayCaptureWithOptions)
B32_THUNK(_CGDisplayIsCaptured) { c.ret(0); }
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

// --- IOKit: the registry where a device name leads, and discs of its own --------------
//
// A disc check (Age of Mythology's) matches a volume by name, reads the mount table for a
// read-only local one, and asks IOKit whether its device sits on CD media. The host has no
// discs, but its disc images are discs to a guest: asked for optical media, each mounted
// disc volume (core/thunks/Discs.h) gets an IOCDMedia of its own, with the volume's IOMedia
// under it as a partition's is on the real thing.

constexpr uint32_t kIOReturnFailure = 0xE00002BC;
#define B32_IOKIT_ERROR(symbol) B32_THUNK(symbol) { c.ret(kIOReturnFailure); }
#define B32_NOTHING(symbol) B32_THUNK(symbol) { c.ret(0); }

B32_DATA(_kIOMasterPortDefault, 4) {}
B32_NOTHING(_IOServiceGetMatchingService)
B32_IOKIT_ERROR(_IORegistryEntryCreateCFProperties)

// The registry entries a guest sees for a disc: the IOCDMedia that is its whole media, and
// the IOMedia of each volume mounted from it. A handle is minted far above the mach ports
// io_object_t values are, so the host's own can't be mistaken for one. Entries live as long
// as the guest runs; an iterator goes when released.
namespace {
struct FakeEntry {
    const char *cls = nullptr;  // the class IOObjectGetClass reports; null when the handle is the host's
    std::string bsd;            // the media's "BSD Name"
    uint32_t parent = 0;        // the entry above, 0 at the top
};
std::mutex fakeLock;
std::unordered_map<uint32_t, FakeEntry> fakeRegistry;
std::unordered_map<uint32_t, std::vector<uint32_t>> fakeIterators;  // what an iterator has left
uint32_t nextFakeHandle = 0x70000000;

uint32_t mintFake(const char *cls, std::string bsd, uint32_t parent) {
    std::lock_guard guard(fakeLock);
    uint32_t handle = nextFakeHandle++;
    fakeRegistry.emplace(handle, FakeEntry{cls, std::move(bsd), parent});
    return handle;
}
uint32_t mintFakeIterator(std::vector<uint32_t> entries) {
    std::lock_guard guard(fakeLock);
    uint32_t handle = nextFakeHandle++;
    fakeIterators.emplace(handle, std::move(entries));
    return handle;
}
FakeEntry fakeEntry(uint32_t handle) {
    std::lock_guard guard(fakeLock);
    auto it = fakeRegistry.find(handle);
    return it == fakeRegistry.end() ? FakeEntry{} : it->second;
}
bool isFakeHandle(uint32_t handle) {
    std::lock_guard guard(fakeLock);
    return fakeRegistry.count(handle) != 0 || fakeIterators.count(handle) != 0;
}
}  // namespace

// CFMutableDictionaryRef IOServiceMatching(const char *className): a real dictionary, which
// IOServiceGetMatchingServices answers.
B32_THUNK(_IOServiceMatching) {
    GuestAddr name = c.args.ptr();
    CFMutableDictionaryRef matching = name ? IOServiceMatching(c.mem.cstr(name)) : nullptr;
    c.ret(matching ? bridge(c).toGuest((id)CFBridgingRelease(matching)) : 0);
}
// kern_return_t IOMasterPort(mach_port_t bootstrapPort, mach_port_t *masterPort)
B32_THUNK(_IOMasterPort) {
    c.args.u32();
    GuestAddr out = c.args.ptr();
    if (out) c.mem.write<uint32_t>(out, kIOMasterPortDefault);
    c.ret(kIOReturnSuccess);
}

// CFMutableDictionaryRef IOBSDNameMatching(masterPort, options, const char *name)
B32_THUNK(_IOBSDNameMatching) {
    c.args.u32();
    uint32_t options = c.args.u32();
    GuestAddr name = c.args.ptr();
    CFMutableDictionaryRef matching = name ? IOBSDNameMatching(kIOMasterPortDefault, options, c.mem.cstr(name)) : nullptr;
    c.ret(matching ? bridge(c).toGuest((id)CFBridgingRelease(matching)) : 0);
}
// kern_return_t IOServiceGetMatchingServices(masterPort, matching, io_iterator_t *): the call consumes the
// dictionary, which the bridge still owns a reference to. The host's matches come first and the discs' after:
// the host's iterator is drained on the spot, so both flow through one handle of ours.
B32_THUNK(_IOServiceGetMatchingServices) {
    c.args.u32();
    GuestAddr matching = c.args.ptr(), out = c.args.ptr();
    if (!matching) {
        c.ret(kIOReturnFailure);
        return;
    }
    CFDictionaryRef dictionary = (CFDictionaryRef)bridge(c).toHost(matching);
    CFRetain(dictionary);
    io_iterator_t iterator = 0;
    kern_return_t status = IOServiceGetMatchingServices(kIOMasterPortDefault, dictionary, &iterator);
    if (status != KERN_SUCCESS) {
        if (out) c.mem.write<uint32_t>(out, 0);
        c.ret(uint32_t(status));
        return;
    }
    std::vector<uint32_t> entries;
    while (io_object_t entry = IOIteratorNext(iterator)) entries.push_back(entry);
    IOObjectRelease(iterator);
    CFStringRef provider = (CFStringRef)CFDictionaryGetValue(dictionary, CFSTR("IOProviderClass"));
    bool optical = provider && (CFStringCompare(provider, CFSTR("IOCDMedia"), 0) == 0 ||
                                CFStringCompare(provider, CFSTR("IODVDMedia"), 0) == 0 ||
                                CFStringCompare(provider, CFSTR("IOBDMedia"), 0) == 0);
    if (optical)
        for (const discs::Volume &volume : discs::mounted()) {
            // A CD's shape: the whole media is the IOCDMedia, and the mounted volume's
            // IOMedia hangs under it, as a partition's does on the real thing.
            uint32_t disc = mintFake("IOCDMedia", volume.whole.substr(5), 0);
            mintFake("IOMedia", volume.device.substr(5), disc);
            entries.push_back(disc);
        }
    if (out) c.mem.write<uint32_t>(out, mintFakeIterator(std::move(entries)));
    c.ret(kIOReturnSuccess);
}

// io_object_t IOIteratorNext(io_iterator_t iterator)
B32_THUNK(_IOIteratorNext) {
    uint32_t iterator = c.args.u32();
    uint32_t next = 0;
    bool fake = false;
    {
        std::lock_guard guard(fakeLock);
        if (auto it = fakeIterators.find(iterator); it != fakeIterators.end()) {
            fake = true;
            if (!it->second.empty()) {
                next = it->second.front();
                it->second.erase(it->second.begin());
            }
        }
    }
    c.ret(fake ? next : IOIteratorNext(iterator));
}
// boolean IOIteratorIsValid(io_iterator_t iterator)
B32_THUNK(_IOIteratorIsValid) { uint32_t iterator = c.args.u32(); c.ret(isFakeHandle(iterator) ? 1 : IOIteratorIsValid(iterator)); }
// kern_return_t IOObjectRelease(io_object_t object)
B32_THUNK(_IOObjectRelease) {
    uint32_t object = c.args.u32();
    bool fake = isFakeHandle(object);
    if (fake) {
        std::lock_guard guard(fakeLock);
        fakeIterators.erase(object);
    }
    c.ret(fake ? kIOReturnSuccess : IOObjectRelease(object));
}
// kern_return_t IOObjectRetain(io_object_t object)
B32_THUNK(_IOObjectRetain) { uint32_t object = c.args.u32(); c.ret(isFakeHandle(object) ? kIOReturnSuccess : IOObjectRetain(object)); }
// boolean IOObjectIsEqualTo(io_object_t a, io_object_t b)
B32_THUNK(_IOObjectIsEqualTo) {
    uint32_t a = c.args.u32(), b = c.args.u32();
    c.ret((isFakeHandle(a) || isFakeHandle(b)) ? uint32_t(a == b) : uint32_t(IOObjectIsEqualTo(a, b)));
}
// kern_return_t IOObjectGetClass(io_object_t object, io_name_t className)
B32_THUNK(_IOObjectGetClass) {
    uint32_t object = c.args.u32();
    GuestAddr name = c.args.ptr();
    if (FakeEntry entry = fakeEntry(object); entry.cls) {
        strlcpy(c.mem.ptr<char>(name), entry.cls, sizeof(io_name_t));
        c.ret(kIOReturnSuccess);
        return;
    }
    c.ret(IOObjectGetClass(object, c.mem.ptr<char>(name)));
}
// kern_return_t IORegistryEntryGetParentEntry(io_registry_entry_t entry, const io_name_t plane,
//                                             io_registry_entry_t *parent)
B32_THUNK(_IORegistryEntryGetParentEntry) {
    uint32_t entry = c.args.u32();
    GuestAddr plane = c.args.ptr(), parent = c.args.ptr();
    if (FakeEntry fake = fakeEntry(entry); fake.cls) {
        bool servicePlane = plane && !strcmp(c.mem.cstr(plane), "IOService");
        if (servicePlane && fake.parent) {
            c.mem.write<uint32_t>(parent, fake.parent);
            c.ret(kIOReturnSuccess);
        } else {
            c.ret(kIOReturnNoDevice);
        }
        return;
    }
    io_object_t hostParent = 0;
    kern_return_t status = IORegistryEntryGetParentEntry(entry, plane ? c.mem.cstr(plane) : nullptr, &hostParent);
    if (status == KERN_SUCCESS && parent) c.mem.write<uint32_t>(parent, hostParent);
    c.ret(uint32_t(status));
}
// kern_return_t IORegistryEntryCreateIterator(io_registry_entry_t entry, const io_name_t plane,
//                                             IOOptionBits options, io_iterator_t *iter)
B32_THUNK(_IORegistryEntryCreateIterator) {
    uint32_t entry = c.args.u32();
    GuestAddr plane = c.args.ptr();
    uint32_t options = c.args.u32();
    GuestAddr out = c.args.ptr();
    if (FakeEntry fake = fakeEntry(entry); fake.cls) {
        std::vector<uint32_t> walk;
        if (plane && !strcmp(c.mem.cstr(plane), "IOService")) {
            if (options & kIORegistryIterateParents) {  // up: the chain this entry hangs from
                for (uint32_t up = fake.parent; up; up = fakeEntry(up).parent) walk.push_back(up);
            } else {                                    // down: the entries hanging from this one
                std::lock_guard guard(fakeLock);
                for (const auto &[handle, child] : fakeRegistry)
                    if (child.parent == entry) walk.push_back(handle);
            }
        }
        if (out) c.mem.write<uint32_t>(out, mintFakeIterator(std::move(walk)));
        c.ret(kIOReturnSuccess);
        return;
    }
    io_iterator_t hostIterator = 0;
    kern_return_t status = IORegistryEntryCreateIterator(entry, plane ? c.mem.cstr(plane) : nullptr, options, &hostIterator);
    if (status == KERN_SUCCESS && out) c.mem.write<uint32_t>(out, hostIterator);
    c.ret(uint32_t(status));
}
// CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t entry, CFStringRef name,
//                                            CFAllocatorRef allocator, IOOptionBits options)
B32_THUNK(_IORegistryEntryCreateCFProperty) {
    uint32_t entry = c.args.u32();
    NSString *key = (NSString *)bridge(c).toHost(c.args.u32());
    CFAllocatorRef allocator = (CFAllocatorRef)bridge(c).toHost(c.args.u32());
    uint32_t options = c.args.u32();
    if (FakeEntry fake = fakeEntry(entry); fake.cls) {
        id value = nil;
        if ([key isEqualToString:@"BSD Name"]) value = [[NSString alloc] initWithUTF8String:fake.bsd.c_str()];
        else if ([key isEqualToString:@"Ejectable"] || [key isEqualToString:@"Removable"])
            value = [[NSNumber alloc] initWithBool:YES];
        else if ([key isEqualToString:@"Whole"]) value = [[NSNumber alloc] initWithBool:fake.parent == 0];
        else if ([key isEqualToString:@"Writable"]) value = [[NSNumber alloc] initWithBool:NO];
        c.ret(value ? bridge(c).toGuest(value) : 0);
        return;
    }
    CFTypeRef value = IORegistryEntryCreateCFProperty(entry, (__bridge CFStringRef)key, allocator ?: kCFAllocatorDefault, options);
    c.ret(value ? bridge(c).toGuest((id)CFBridgingRelease(value)) : 0);
}
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

// Old Component Manager: on the big-endian guest, which has no AudioUnits yet, nothing is found (SDL's audio
// fallback, unused when CoreAudio works). The little-endian guest's are AudioUnits (core/audio/audiounit.mm).
#if defined(B32_GUEST_BIG_ENDIAN)
B32_NOTHING(_FindNextComponent)
B32_NOTHING(_OpenAComponent)
B32_NOTHING(_CloseComponent)
#endif

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
    case 'ram ':   // physical RAM, bytes, as capped at 2 GB in the era
    case 'lram':   // logical RAM, bytes
    case 'ramm': {  // physical RAM, megabytes: a game with too little refuses to start
        static uint64_t bytes = [] {
            uint64_t mem = 0;
            size_t size = sizeof mem;
            sysctlbyname("hw.memsize", &mem, &size, nullptr, 0);
            return mem ? mem : uint64_t(4) << 30;
        }();
        if (selector == 'ramm') value = int32_t(bytes >> 20);
        else value = int32_t(selector == 'ram ' ? std::min<uint64_t>(bytes, uint64_t(2) << 30) : bytes);
        break;
    }
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
