// The non-UI layers of Carbon that old Mac games lean on, for i386 guests: the
// Memory Manager, Pascal strings, dates and timing, and CoreFoundation calls
// the iOS side never needed. Carbon's windows, dialogs and QuickDraw have no
// 64-bit host to forward to and aren't here.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#import <AppKit/AppKit.h>
#include <CoreServices/CoreServices.h>
#include <dlfcn.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <cstring>
#include <ctime>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }
void *process() { return RTLD_DEFAULT; }
id object(Call &c) { return bridge(c).toHost(c.args.ptr()); }

constexpr int32_t kNoErr = 0, kMemFullErr = -108;
int32_t lastMemError = kNoErr;

const CFunction kCoreFoundation[] = {
    {"CFCharacterSetGetPredefined", "o:z"},
    {"CFCharacterSetIsCharacterMember", "B:ou"},
    {"CFBundleCopyBundleURL", "o:o"},
    {"CFBundleLoadExecutable", "B:o"},
    {"CFBundleCopyLocalizedString", "o:oooo"},
    {"CFURLCopyLastPathComponent", "o:o"},
};
}  // namespace

B32_C_FUNCTIONS(kCoreFoundation, process);

// CFIndex arguments are 'z' above, but the range passed to CFStringFindAndReplace
// is by value, so it needs its own thunk: { location, length } in two words.
B32_THUNK(_CFStringFindAndReplace) {
    NSMutableString *string = object(c);
    NSString *find = object(c), *replace = object(c);
    CFRange range;
    range.location = c.args.i32();
    range.length = c.args.i32();
    c.ret(uint32_t(CFStringFindAndReplace((CFMutableStringRef)string, (CFStringRef)find, (CFStringRef)replace, range, c.args.u32())));
}

// A guest pointer can't back a host string the way the NoCopy form wants, so it
// holds a copy. Callers fill the buffer first and then read the string.
B32_THUNK(_CFStringCreateMutableWithExternalCharactersNoCopy) {
    c.args.ptr();
    GuestAddr chars = c.args.ptr();
    int32_t length = c.args.i32();
    CFMutableStringRef string = CFStringCreateMutable(nullptr, 0);
    if (chars && length > 0) CFStringAppendCharacters(string, c.mem.ptr<UniChar>(chars), length);
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(string)));
}

// Pascal string out of a CFString: buffer holds length then bytes.
B32_THUNK(_CFStringGetPascalString) {
    NSString *string = object(c);
    GuestAddr buffer = c.args.ptr();
    int32_t size = c.args.i32();
    c.ret(CFStringGetPascalString((CFStringRef)string, c.mem.ptr<unsigned char>(buffer), size, c.args.u32()));
}
B32_THUNK(_CFURLCreateFromFSRef) {
    c.args.ptr();
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CFURLCreateFromFSRef(nullptr, c.mem.ptr<FSRef>(c.args.ptr())))));
}
B32_THUNK(_CFURLGetFSRef) {
    NSURL *url = object(c);
    c.ret(CFURLGetFSRef((CFURLRef)url, c.mem.ptr<FSRef>(c.args.ptr())));
}
// The allocator argument is a guest value the host can't use; the default is fine.
B32_THUNK(_CFBundleCreate) {
    c.args.ptr();
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CFBundleCreate(nullptr, (CFURLRef)object(c)))));
}
B32_THUNK(_CFURLCreateCopyAppendingPathComponent) {
    c.args.ptr();
    NSURL *url = object(c);
    NSString *component = object(c);
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CFURLCreateCopyAppendingPathComponent(nullptr, (CFURLRef)url, (CFStringRef)component, c.args.u32() & 0xff))));
}
B32_THUNK(_CFURLCreateCopyDeletingLastPathComponent) {
    c.args.ptr();
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CFURLCreateCopyDeletingLastPathComponent(nullptr, (CFURLRef)object(c)))));
}
// A bundle's functions are host code, which a guest can't call: 'no such function'.
B32_THUNK(_CFBundleGetFunctionPointerForName) { c.ret(0); }

// --- File Manager: FSRef and HFSUniStr255 are opaque and the same on both sides -----------

namespace {
const CFunction kFiles[] = {
    {"FSFindFolder", "i:iuup"},
    {"FSPathMakeRef", "i:ppp"},
    {"FSRefMakePath", "i:ppu"},
    {"FSGetCatalogInfo", "i:pupppp"},
    {"FSSetCatalogInfo", "i:pup"},
    {"FSDeleteObject", "i:p"},
    {"FSGetDataForkName", "i:p"},
    {"FSMakeFSRefUnicode", "i:pzpup"},
    {"FSCreateFileUnicode", "i:pzpuppp"},
    {"FSCloseFork", "i:i"},
    {"FSGetForkSize", "i:ip"},
    {"FSGetForkPosition", "i:ip"},
};
}  // namespace
B32_C_FUNCTIONS(kFiles, process);

// OSErr FSOpenFork(ref, nameLength, name, permissions, FSIORefNum *): the
// reference number is 16 bits in the guest and 32 on the host.
B32_THUNK(_FSOpenFork) {
    const FSRef *ref = c.mem.ptr<FSRef>(c.args.ptr());
    uint32_t nameLength = c.args.u32();
    const UniChar *name = c.mem.ptr<UniChar>(c.args.ptr());
    SInt8 permissions = SInt8(c.args.u32());
    GuestAddr out = c.args.ptr();
    FSIORefNum number = 0;
    OSErr error = FSOpenFork(ref, nameLength, name, permissions, &number);
    if (out) c.mem.write<int16_t>(out, int16_t(number));
    c.ret(uint32_t(int32_t(error)));
}
namespace {
// The count written comes back as a 32-bit ByteCount.
void forkTransfer(Call &c, bool write) {
    FSIORefNum number = c.args.i32();
    UInt16 mode = UInt16(c.args.u32());
    SInt64 offset = SInt64(c.args.u64());
    ByteCount count = c.args.u32();
    GuestAddr buffer = c.args.ptr(), actualOut = c.args.ptr();
    ByteCount actual = 0;
    OSErr error = write ? FSWriteFork(number, mode, offset, count, c.mem.ptr<void>(buffer), &actual)
                        : FSReadFork(number, mode, offset, count, c.mem.ptr<void>(buffer), &actual);
    if (actualOut) c.mem.write<uint32_t>(actualOut, uint32_t(actual));
    c.ret(uint32_t(int32_t(error)));
}
}  // namespace
B32_THUNK(_FSReadFork) { forkTransfer(c, false); }
B32_THUNK(_FSWriteFork) { forkTransfer(c, true); }
B32_THUNK(_FSSetForkPosition) {
    FSIORefNum number = c.args.i32();
    UInt16 mode = UInt16(c.args.u32());
    c.ret(uint32_t(int32_t(FSSetForkPosition(number, mode, SInt64(c.args.u64())))));
}
B32_THUNK(_FSSetForkSize) {
    FSIORefNum number = c.args.i32();
    UInt16 mode = UInt16(c.args.u32());
    c.ret(uint32_t(int32_t(FSSetForkSize(number, mode, SInt64(c.args.u64())))));
}

// --- Memory Manager: blocks from the guest heap -----------------------------------------

namespace {
GuestAddr newPointer(Call &c, bool clear) {
    uint32_t size = c.args.u32();
    GuestAddr p = clear ? c.heap.calloc(1, std::max(size, 1u)) : c.heap.alloc(std::max(size, 1u));
    lastMemError = p ? kNoErr : kMemFullErr;
    return p;
}
}  // namespace

B32_THUNK(_NewPtr) { c.ret(newPointer(c, false)); }
B32_THUNK(_NewPtrClear) { c.ret(newPointer(c, true)); }
B32_THUNK(_DisposePtr) {
    c.heap.free(c.args.ptr());
    lastMemError = kNoErr;
}
B32_THUNK(_GetPtrSize) { c.ret(c.heap.sizeOf(c.args.ptr())); }
B32_THUNK(_SetPtrSize) {
    GuestAddr p = c.args.ptr();
    uint32_t size = c.args.u32();
    lastMemError = size <= c.heap.sizeOf(p) ? kNoErr : kMemFullErr;  // a Ptr can't move
}
B32_THUNK(_MemError) { c.ret(uint32_t(lastMemError)); }

// --- Pascal strings ---------------------------------------------------------------------

B32_THUNK(_c2pstrcpy) {
    GuestAddr dst = c.args.ptr();
    const char *src = c.mem.cstr(c.args.ptr());
    size_t n = std::min<size_t>(std::strlen(src), 255);
    c.mem.write<uint8_t>(dst, uint8_t(n));
    c.mem.copyIn(dst + 1, src, n);
}
B32_THUNK(_p2cstrcpy) {
    GuestAddr dst = c.args.ptr(), src = c.args.ptr();
    uint32_t n = c.mem.read<uint8_t>(src);
    std::memmove(c.mem.ptr<char>(dst), c.mem.ptr<char>(src + 1), n);
    c.mem.write<uint8_t>(dst + n, 0);
}

// --- time -------------------------------------------------------------------------------

namespace {
uint64_t nanosFromTicks(uint64_t ticks) {
    static mach_timebase_info_data_t base = [] {
        mach_timebase_info_data_t b;
        mach_timebase_info(&b);
        return b;
    }();
    return ticks * base.numer / base.denom;
}
uint64_t ticksFromNanos(uint64_t nanos) {
    static mach_timebase_info_data_t base = [] {
        mach_timebase_info_data_t b;
        mach_timebase_info(&b);
        return b;
    }();
    return nanos * base.denom / base.numer;
}
// A Duration is milliseconds, or microseconds if negative.
uint64_t durationNanos(int32_t duration) {
    return duration >= 0 ? uint64_t(duration) * 1000000 : uint64_t(-int64_t(duration)) * 1000;
}
}  // namespace

// AbsoluteTime AddDurationToAbsolute(Duration, AbsoluteTime)
B32_THUNK(_AddDurationToAbsolute) {
    int32_t duration = c.args.i32();
    c.ret64(c.args.u64() + ticksFromNanos(durationNanos(duration)));
}
B32_THUNK(_DurationToAbsolute) { c.ret64(ticksFromNanos(durationNanos(c.args.i32()))); }
B32_THUNK(_AbsoluteToNanoseconds) { c.ret64(nanosFromTicks(c.args.u64())); }
// OSStatus MPDelayUntil(AbsoluteTime *)
B32_THUNK(_MPDelayUntil) {
    mach_wait_until(c.mem.read<uint64_t>(c.args.ptr()));
    c.ret(0);
}
// void GetTime(DateTimeRec *): year, month, day, hour, minute, second, day of week, as shorts.
B32_THUNK(_GetTime) {
    GuestAddr out = c.args.ptr();
    time_t now = time(nullptr);
    struct tm t;
    localtime_r(&now, &t);
    const int16_t fields[7] = {int16_t(t.tm_year + 1900), int16_t(t.tm_mon + 1), int16_t(t.tm_mday), int16_t(t.tm_hour),
                               int16_t(t.tm_min), int16_t(t.tm_sec), int16_t(t.tm_wday + 1)};
    c.mem.copyIn(out, fields, sizeof fields);
}

// --- standard alerts: the one piece of Carbon UI games need to say what's wrong ------------

B32_THUNK(_GetStandardAlertDefaultParams) { c.ret(0); }
// OSStatus CreateStandardAlert(type, CFStringRef error, CFStringRef explanation, params, DialogRef *out)
B32_THUNK(_CreateStandardAlert) {
    c.args.u32();
    NSString *title = object(c), *text = object(c);
    c.args.ptr();
    GuestAddr out = c.args.ptr();
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title ?: @"";
    alert.informativeText = text ?: @"";
    log("Carbon alert: %s / %s", alert.messageText.UTF8String, alert.informativeText.UTF8String);
    c.mem.write<uint32_t>(out, bridge(c).toGuest(alert));
    c.ret(0);
}
// OSStatus RunStandardAlert(DialogRef, filter, DialogItemIndex *hit): item 1 is the default button.
B32_THUNK(_RunStandardAlert) {
    NSAlert *alert = object(c);
    c.args.ptr();
    GuestAddr hit = c.args.ptr();
    [alert runModal];
    if (hit) c.mem.write<uint16_t>(hit, 1);
    c.ret(0);
}

B32_THUNK(_IntlScript) { c.ret(0); }  // smRoman
// short IdenticalString(ConstStr255Param, ConstStr255Param, Handle): 0 if equal.
B32_THUNK(_IdenticalString) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    uint32_t la = c.mem.read<uint8_t>(a), lb = c.mem.read<uint8_t>(b);
    c.ret(la == lb && std::memcmp(c.mem.ptr<char>(a + 1), c.mem.ptr<char>(b + 1), la) == 0 ? 0 : 1);
}
B32_THUNK(_GetScriptVariable) { c.ret(0); }
B32_THUNK(_GetScriptManagerVariable) { c.ret(0); }
B32_THUNK(_SetQDGlobalsRandomSeed) {}
B32_THUNK(_RegisterEventHotKey) { c.ret(0); }
B32_THUNK(__ZSt15set_new_handlerPFvvE) { c.ret(0); }
B32_THUNK(_GetCurrentProcess) { c.ret(0); }
B32_THUNK(_SameProcess) {
    c.args.ptr();
    c.args.ptr();
    c.mem.write<uint8_t>(c.args.ptr(), 1);
    c.ret(0);
}
B32_THUNK(_GetFrontProcess) { c.ret(0); }
B32_THUNK(_SetFrontProcess) { c.ret(0); }
B32_THUNK(_GetProcessInformation) { c.ret(uint32_t(-600)); }  // procNotFound
B32_THUNK(_EnterMovies) { c.ret(0); }
// Sound Manager channels exist but are silent so far.
B32_THUNK(_SndNewChannel) {
    GuestAddr out = c.args.ptr();
    if (!c.mem.read<uint32_t>(out)) c.mem.write<uint32_t>(out, c.heap.calloc(1, 64));
    c.ret(0);
}
B32_THUNK(_SndDisposeChannel) { c.ret(0); }
B32_THUNK(_SndPlay) { c.ret(0); }
B32_THUNK(_SndDoCommand) { c.ret(0); }
B32_THUNK(_SndDoImmediate) { c.ret(0); }
B32_THUNK(_NewSndCallBackUPP) { c.ret(c.args.ptr()); }
B32_THUNK(_DisposeSndCallBackUPP) {}
B32_THUNK(_ExitToShell) { c.rt.exit(0); }

// What crt1 from before 10.5 looks at: hooks it calls when they're set.
B32_DATA(_mach_init_routine, 4) {}
B32_DATA(__cthread_init_routine, 4) {}
B32_DATA(_bootstrap_port, 4) {}
B32_THUNK(___keymgr_dwarf2_register_sections) {}

// Seconds since 1904.
B32_THUNK(_GetDateTime) {
    GuestAddr out = c.args.ptr();
    if (out) c.mem.write<uint32_t>(out, uint32_t(int64_t(time(nullptr)) + 2082844800));
}
