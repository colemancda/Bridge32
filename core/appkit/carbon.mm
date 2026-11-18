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
#include <string>
#include <vector>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;
using namespace b32::objc;

namespace {
Bridge &bridge(Call &c) { return c.rt.bridge(); }
void *process() { return RTLD_DEFAULT; }
id object(Call &c) { return bridge(c).toHost(c.args.ptr()); }
// An FSRef is 80 opaque bytes the guest only hands back to these calls, so the
// host's can sit in guest memory whatever the byte order.
FSRef *fsRef(Call &c, GuestAddr p) { return static_cast<FSRef *>(c.mem.ptr<void>(p)); }

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

// Strings over the caller's own characters. A program can keep a string over a buffer of its own, have CF
// edit the string, and read the result in its buffer, as a string class over a fixed buffer does.
#if !defined(B32_GUEST_BIG_ENDIAN)
// Guest memory is the host's, and its UniChars are in the host's order, so the host string uses the buffer
// itself. It is never the string's to free (whatever deallocator the guest named is the guest's), and an
// edit that outgrows it moves the string to CF's own storage, as one past the buffer's capacity did.
B32_THUNK(_CFStringCreateMutableWithExternalCharactersNoCopy) {
    c.args.ptr();
    GuestAddr chars = c.args.ptr();
    int32_t length = c.args.i32(), capacity = c.args.i32();
    UniChar *buffer = chars ? c.mem.ptr<UniChar>(chars) : nullptr;
    CFMutableStringRef string = CFStringCreateMutableWithExternalCharactersNoCopy(nullptr, buffer, buffer ? length : 0, buffer ? capacity : 0, kCFAllocatorNull);
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(string)));
}
// void CFStringSetExternalCharactersNoCopy(CFMutableStringRef, UniChar *, CFIndex length, CFIndex capacity)
B32_THUNK(_CFStringSetExternalCharactersNoCopy) {
    CFMutableStringRef string = (CFMutableStringRef)object(c);
    GuestAddr chars = c.args.ptr();
    int32_t length = c.args.i32(), capacity = c.args.i32();
    UniChar *buffer = chars ? c.mem.ptr<UniChar>(chars) : nullptr;
    CFStringSetExternalCharactersNoCopy(string, buffer, buffer ? length : 0, buffer ? capacity : 0);
}
#else
// A big-endian guest's UniChars are the other way round, so its string holds a copy: callers fill the
// buffer first and then read the string, and edits don't reach the buffer.
B32_THUNK(_CFStringCreateMutableWithExternalCharactersNoCopy) {
    c.args.ptr();
    GuestAddr chars = c.args.ptr();
    int32_t length = c.args.i32();
    CFMutableStringRef string = CFStringCreateMutable(nullptr, 0);
    if (chars && length > 0) {
        std::vector<UniChar> text = c.mem.readArray<UniChar>(chars, size_t(length));
        CFStringAppendCharacters(string, text.data(), length);
    }
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(string)));
}
// void CFStringSetExternalCharactersNoCopy(CFMutableStringRef, UniChar *, CFIndex, CFIndex): the same copy,
// replacing what the string holds.
B32_THUNK(_CFStringSetExternalCharactersNoCopy) {
    CFMutableStringRef string = (CFMutableStringRef)object(c);
    GuestAddr chars = c.args.ptr();
    int32_t length = c.args.i32();
    c.args.i32();  // the capacity of the buffer it would point at
    CFStringDelete(string, CFRangeMake(0, CFStringGetLength(string)));
    if (chars && length > 0) {
        std::vector<UniChar> text = c.mem.readArray<UniChar>(chars, size_t(length));
        CFStringAppendCharacters(string, text.data(), length);
    }
}
#endif
// void CFStringDelete(CFMutableStringRef, CFRange): the range by value, location then length.
B32_THUNK(_CFStringDelete) {
    CFMutableStringRef string = (CFMutableStringRef)object(c);
    CFRange range;
    range.location = c.args.i32();
    range.length = c.args.i32();
    CFIndex length = CFStringGetLength(string);
    if (range.location < 0 || range.length < 0 || range.location + range.length > length) return;
    CFStringDelete(string, range);
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
    c.ret(bridge(c).toGuest((id)CFBridgingRelease(CFURLCreateFromFSRef(nullptr, fsRef(c, c.args.ptr())))));
}
B32_THUNK(_CFURLGetFSRef) {
    NSURL *url = object(c);
    c.ret(CFURLGetFSRef((CFURLRef)url, fsRef(c, c.args.ptr())));
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
// void *CFBundleGetFunctionPointerForName(CFBundleRef, CFStringRef name): how a program asks a framework
// for a function it may not have (OpenGL's extensions, looked up one name at a time). A function with a
// thunk is that thunk's stub, and the program's own is its export; anything else is "no such function".
B32_THUNK(_CFBundleGetFunctionPointerForName) {
    object(c);
    NSString *name = object(c);
    if (![name isKindOfClass:[NSString class]] || !name.length) {
        c.ret(0);
        return;
    }
    c.ret(c.rt.lookUp(std::string("_") + name.UTF8String, true));
}

// --- File Manager: FSRef is opaque and the same on both sides ------------------------------
// The rest isn't for a big-endian guest: UTF-16 names, 64-bit outputs and the
// catalog info structure, which have the host's byte order, get thunks of their
// own below.

namespace {
const CFunction kFiles[] = {
    {"FSFindFolder", "i:iuup"},
    {"FSPathMakeRef", "i:ppp"},
    {"FSRefMakePath", "i:ppu"},
    {"FSDeleteObject", "i:p"},
    {"FSCloseFork", "i:i"},
#if !defined(B32_GUEST_BIG_ENDIAN)
    {"FSGetDataForkName", "i:p"},
    {"FSGetForkSize", "i:ip"},
    {"FSGetForkPosition", "i:ip"},
#endif
};
}  // namespace
B32_C_FUNCTIONS(kFiles, process);

// OSErr FSMakeFSRefUnicode(const FSRef *parent, UniCharCount, const UniChar *, TextEncoding, FSRef *):
// explicit for both guests, to name what wasn't found.
B32_THUNK(_FSMakeFSRefUnicode) {
    GuestAddr parent = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr name = c.args.ptr();
    TextEncoding hint = c.args.u32();
    GuestAddr out = c.args.ptr();
    std::vector<UniChar> text = c.mem.readArray<UniChar>(name, length);
    OSErr error = FSMakeFSRefUnicode(fsRef(c, parent), length, text.data(), hint, fsRef(c, out));
    if (error) {  // the name it wanted, and where: a missing resource named for the log
        char path[PATH_MAX] = "";
        FSRefMakePath(fsRef(c, parent), reinterpret_cast<uint8_t *>(path), sizeof path);
        CFStringRef string = CFStringCreateWithCharacters(nullptr, text.data(), length);
        log("FSMakeFSRefUnicode %s/%s -> %d", path, [(__bridge NSString *)string UTF8String] ?: "?", error);
        if (string) CFRelease(string);
    }
    c.ret(uint32_t(int32_t(error)));
}

#if defined(B32_GUEST_BIG_ENDIAN)
// OSErr FSGetDataForkName(HFSUniStr255 *): { UInt16 length; UniChar unicode[255] }
B32_THUNK(_FSGetDataForkName) {
    GuestAddr out = c.args.ptr();
    HFSUniStr255 name;
    OSErr error = FSGetDataForkName(&name);
    c.mem.write<uint16_t>(out, name.length);
    c.mem.writeArray<UniChar>(out + 2, name.unicode, name.length);
    c.ret(uint32_t(int32_t(error)));
}
// OSErr FSCreateFileUnicode(parent, UniCharCount, name, whichInfo, const FSCatalogInfo *, FSRef *, FSSpec *):
B32_THUNK(_FSGetForkSize) {
    FSIORefNum number = c.args.i32();
    SInt64 size = 0;
    OSErr error = FSGetForkSize(number, &size);
    c.mem.write<int64_t>(c.args.ptr(), size);
    c.ret(uint32_t(int32_t(error)));
}
B32_THUNK(_FSGetForkPosition) {
    FSIORefNum number = c.args.i32();
    SInt64 position = 0;
    OSErr error = FSGetForkPosition(number, &position);
    c.mem.write<int64_t>(c.args.ptr(), position);
    c.ret(uint32_t(int32_t(error)));
}
#endif

// --- catalog info --------------------------------------------------------------------------------
// A 32-bit program's FSCatalogInfo is 144 bytes; the host's is 148, its permissions holding a pointer where
// the guest's has a reserved word, so everything after them sits four bytes further on. The record is
// rebuilt field by field in either direction, never passed through.
namespace {
UTCDateTime guestDate(Call &c, GuestAddr p) {
    return {c.mem.read<uint16_t>(p), c.mem.read<uint32_t>(p + 2), c.mem.read<uint16_t>(p + 6)};
}
// Finder info is sixteen bytes of fields, whose sizes depend on what it describes; `sizes` gives them.
void finderFieldsFromGuest(Call &c, GuestAddr p, UInt8 *host, const char *sizes) {
    for (uint32_t at = 0; *sizes; at += uint32_t(*sizes - '0'), sizes++) {
        if (*sizes == '4') {
            uint32_t value = c.mem.read<uint32_t>(p + at);
            std::memcpy(host + at, &value, 4);
        } else {
            uint16_t value = c.mem.read<uint16_t>(p + at);
            std::memcpy(host + at, &value, 2);
        }
    }
}
FSCatalogInfo catalogInfoFromGuest(Call &c, GuestAddr p, bool directory) {
    FSCatalogInfo info = {};
    info.nodeFlags = c.mem.read<uint16_t>(p);
    info.sharingFlags = c.mem.read<uint8_t>(p + 12);
    info.userPrivileges = c.mem.read<uint8_t>(p + 13);
    info.createDate = guestDate(c, p + 16);
    info.contentModDate = guestDate(c, p + 24);
    info.attributeModDate = guestDate(c, p + 32);
    info.accessDate = guestDate(c, p + 40);
    info.backupDate = guestDate(c, p + 48);
    info.permissions.userID = c.mem.read<uint32_t>(p + 56);
    info.permissions.groupID = c.mem.read<uint32_t>(p + 60);
    info.permissions.userAccess = c.mem.read<uint8_t>(p + 65);
    info.permissions.mode = c.mem.read<uint16_t>(p + 66);
    // A file's: type, creator, flags, location (two shorts), a reserved short. A folder's: its window's
    // rectangle (four shorts), flags, location, a reserved short.
    finderFieldsFromGuest(c, p + 72, info.finderInfo, directory ? "22222222" : "442222");
    // A file's: four reserved shorts, extended flags, a reserved short, the put-away folder. A folder's:
    // a scroll position (two shorts), a reserved long, extended flags, a reserved short, the put-away folder.
    finderFieldsFromGuest(c, p + 88, info.extFinderInfo, directory ? "224224" : "2222224");
    info.textEncodingHint = c.mem.read<uint32_t>(p + 140);
    return info;
}
// The fields a program may set on creating or changing an item; the rest of the bitmap is what the file
// system decides (sizes, IDs), which the host refuses to be told.
constexpr FSCatalogInfoBitmap kSettableInfo = kFSCatInfoNodeFlags | kFSCatInfoCreateDate | kFSCatInfoContentMod | kFSCatInfoAttrMod |
                                              kFSCatInfoAccessDate | kFSCatInfoBackupDate | kFSCatInfoPermissions | kFSCatInfoFinderInfo |
                                              kFSCatInfoFinderXInfo | kFSCatInfoTextEncoding;
}  // namespace

// OSErr FSSetCatalogInfo(const FSRef *, FSCatalogInfoBitmap whichInfo, const FSCatalogInfo *)
B32_THUNK(_FSSetCatalogInfo) {
    FSRef *ref = fsRef(c, c.args.ptr());
    FSCatalogInfoBitmap which = c.args.u32() & kSettableInfo;
    GuestAddr guest = c.args.ptr();
    if (!guest || !which) {
        c.ret(0);
        return;
    }
    FSCatalogInfo current = {};
    bool directory = FSGetCatalogInfo(ref, kFSCatInfoNodeFlags, &current, nullptr, nullptr, nullptr) == noErr && (current.nodeFlags & kFSNodeIsDirectoryMask);
    FSCatalogInfo info = catalogInfoFromGuest(c, guest, directory);
    c.ret(uint32_t(int32_t(FSSetCatalogInfo(ref, which, &info))));
}

// OSErr FSCreateFileUnicode(parent, UniCharCount, name, whichInfo, const FSCatalogInfo *, FSRef *, FSSpec *)
B32_THUNK(_FSCreateFileUnicode) {
    GuestAddr parent = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr name = c.args.ptr();
    FSCatalogInfoBitmap which = c.args.u32() & kSettableInfo;
    GuestAddr guest = c.args.ptr();
    GuestAddr out = c.args.ptr();
    std::vector<UniChar> text = c.mem.readArray<UniChar>(name, length);
    FSCatalogInfo info = {};
    if (guest && which) info = catalogInfoFromGuest(c, guest, false);
    else which = kFSCatInfoNone;
    c.ret(uint32_t(int32_t(FSCreateFileUnicode(fsRef(c, parent), length, text.data(), which, which ? &info : nullptr, out ? fsRef(c, out) : nullptr, nullptr))));
}

// OSErr FSCreateDirectoryUnicode(parent, UniCharCount, name, whichInfo, const FSCatalogInfo *, FSRef *,
//                                FSSpec *, UInt32 *newDirID): the catalog info isn't converted.
B32_THUNK(_FSCreateDirectoryUnicode) {
    GuestAddr parent = c.args.ptr();
    uint32_t length = c.args.u32();
    GuestAddr name = c.args.ptr();
    c.args.u32();
    c.args.ptr();
    GuestAddr out = c.args.ptr();
    c.args.ptr();
    GuestAddr directoryID = c.args.ptr();
    std::vector<UniChar> text = c.mem.readArray<UniChar>(name, length);
    UInt32 id = 0;
    OSErr error = FSCreateDirectoryUnicode(fsRef(c, parent), length, text.data(), 0, nullptr, out ? fsRef(c, out) : nullptr, nullptr, &id);
    // A directory that already exists reports dupFNErr without a reference, yet
    // callers go on to ask for its path, so hand back a reference to it.
    if (error == dupFNErr && out) {
        UInt8 base[1024];
        NSString *leaf = [NSString stringWithCharacters:text.data() length:text.size()];
        if (FSRefMakePath(fsRef(c, parent), base, sizeof base) == noErr) {
            NSString *path = [[NSString stringWithUTF8String:reinterpret_cast<char *>(base)] stringByAppendingPathComponent:leaf];
            if (FSPathMakeRef(reinterpret_cast<const UInt8 *>(path.fileSystemRepresentation), fsRef(c, out), nullptr) == noErr) error = noErr;
        }
    }
    if (directoryID) c.mem.write<uint32_t>(directoryID, id);
    c.ret(uint32_t(int32_t(error)));
}
// OSErr FSOpenFork(ref, nameLength, name, permissions, FSIORefNum *): the
// reference number is 16 bits in the guest and 32 on the host.
B32_THUNK(_FSOpenFork) {
    const FSRef *ref = fsRef(c, c.args.ptr());
    uint32_t nameLength = c.args.u32();
    std::vector<UniChar> name = c.mem.readArray<UniChar>(c.args.ptr(), nameLength);
    SInt8 permissions = SInt8(c.args.u32());
    GuestAddr out = c.args.ptr();
    FSIORefNum number = 0;
    OSErr error = FSOpenFork(ref, nameLength, name.data(), permissions, &number);
    if (out) c.mem.write<int16_t>(out, int16_t(number));
    c.ret(uint32_t(int32_t(error)));
}
// OSErr FSFlushFork(FSIORefNum)
B32_THUNK(_FSFlushFork) { c.ret(uint32_t(int32_t(FSFlushFork(FSIORefNum(c.args.i32()))))); }
// OSErr FSCreateFork(const FSRef *, UniCharCount nameLength, const UniChar *name)
B32_THUNK(_FSCreateFork) {
    const FSRef *ref = fsRef(c, c.args.ptr());
    uint32_t nameLength = c.args.u32();
    std::vector<UniChar> name = c.mem.readArray<UniChar>(c.args.ptr(), nameLength);
    c.ret(uint32_t(int32_t(FSCreateFork(ref, nameLength, name.data()))));
}
// OSErr FSAllocateFork(FSIORefNum, FSAllocationFlags, UInt16 positionMode, SInt64 positionOffset,
//                      UInt64 requestCount, UInt64 *actualCount)
B32_THUNK(_FSAllocateFork) {
    FSIORefNum number = c.args.i32();
    FSAllocationFlags flags = FSAllocationFlags(c.args.u32());
    UInt16 mode = UInt16(c.args.u32());
    SInt64 offset = SInt64(c.args.u64());
    UInt64 request = c.args.u64();
    GuestAddr actualOut = c.args.ptr();
    UInt64 actual = 0;
    OSErr error = FSAllocateFork(number, flags, mode, offset, request, &actual);
    if (actualOut) c.mem.write<uint64_t>(actualOut, actual);
    c.ret(uint32_t(int32_t(error)));
}
// OSErr FSIterateForks(const FSRef *, CatPositionRec *iterator, HFSUniStr255 *forkName, SInt64 *forkSize,
//                      UInt64 *forkPhysicalSize): the iterator is a long that starts at 0 and six shorts the
// file system keeps its place in.
B32_THUNK(_FSIterateForks) {
    const FSRef *ref = fsRef(c, c.args.ptr());
    GuestAddr position = c.args.ptr(), nameOut = c.args.ptr(), sizeOut = c.args.ptr(), physicalOut = c.args.ptr();
    CatPositionRec iterator = {};
    iterator.initialize = c.mem.read<int32_t>(position);
    for (int i = 0; i < 6; i++) iterator.priv[i] = c.mem.read<int16_t>(position + 4 + uint32_t(i) * 2);
    HFSUniStr255 name = {};
    SInt64 size = 0;
    UInt64 physical = 0;
    OSErr error = FSIterateForks(ref, &iterator, &name, &size, &physical);
    c.mem.write<int32_t>(position, int32_t(iterator.initialize));
    for (int i = 0; i < 6; i++) c.mem.write<int16_t>(position + 4 + uint32_t(i) * 2, iterator.priv[i]);
    if (error == noErr) {
        if (nameOut) {
            c.mem.write<uint16_t>(nameOut, name.length);
            c.mem.writeArray<UniChar>(nameOut + 2, name.unicode, name.length);
        }
        if (sizeOut) c.mem.write<int64_t>(sizeOut, size);
        if (physicalOut) c.mem.write<uint64_t>(physicalOut, physical);
    }
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
    c.mem.writeArray<int16_t>(out, fields, 7);
}

// Classic dates count seconds from the start of 1904, in local time.
namespace {
constexpr int64_t kSecondsFrom1904To1970 = 2082844800;
struct tm classicDate(int64_t seconds) {
    time_t unixTime = time_t(seconds - kSecondsFrom1904To1970);
    struct tm t;
    gmtime_r(&unixTime, &t);  // the count is local already
    return t;
}
}  // namespace
// void SecondsToDate(UInt32 seconds, DateTimeRec *): the seven shorts GetTime gives.
B32_THUNK(_SecondsToDate) {
    struct tm t = classicDate(c.args.u32());
    const int16_t fields[7] = {int16_t(t.tm_year + 1900), int16_t(t.tm_mon + 1), int16_t(t.tm_mday), int16_t(t.tm_hour),
                               int16_t(t.tm_min), int16_t(t.tm_sec), int16_t(t.tm_wday + 1)};
    c.mem.writeArray<int16_t>(c.args.ptr(), fields, 7);
}
// void LongSecondsToDate(const LongDateTime *seconds (64 bits), LongDateRec *): era, year, month, day, hour,
// minute, second, day of week, day of year, week of year, pm, and three reserved, as shorts.
B32_THUNK(_LongSecondsToDate) {
    struct tm t = classicDate(c.mem.read<int64_t>(c.args.ptr()));
    const int16_t fields[14] = {0, int16_t(t.tm_year + 1900), int16_t(t.tm_mon + 1), int16_t(t.tm_mday), int16_t(t.tm_hour),
                                int16_t(t.tm_min), int16_t(t.tm_sec), int16_t(t.tm_wday + 1), int16_t(t.tm_yday + 1),
                                int16_t(t.tm_yday / 7 + 1), int16_t(t.tm_hour >= 12), 0, 0, 0};
    c.mem.writeArray<int16_t>(c.args.ptr(), fields, 14);
}
// void ReadLocation(MachineLocation *): latitude and longitude (not known: 0), then the offset from GMT in
// seconds in the low three bytes, under a byte that is 0x80 during daylight saving time.
B32_THUNK(_ReadLocation) {
    GuestAddr out = c.args.ptr();
    time_t now = time(nullptr);
    struct tm t;
    localtime_r(&now, &t);
    c.mem.write<int32_t>(out, 0);
    c.mem.write<int32_t>(out + 4, 0);
    c.mem.write<uint32_t>(out + 8, (t.tm_isdst > 0 ? 0x80000000u : 0) | (uint32_t(t.tm_gmtoff) & 0x00FFFFFF));
}
// void CFBundleGetPackageInfo(bundle, UInt32 *type, UInt32 *creator)
B32_THUNK(_CFBundleGetPackageInfo) {
    id bundle = object(c);
    GuestAddr type = c.args.ptr(), creator = c.args.ptr();
    UInt32 hostType = 0, hostCreator = 0;
    if (bundle) CFBundleGetPackageInfo((CFBundleRef)bundle, &hostType, &hostCreator);
    if (type) c.mem.write<uint32_t>(type, hostType);
    if (creator) c.mem.write<uint32_t>(creator, hostCreator);
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
    // The guest's frames too: an alert with empty text still says who is asking.
    std::string frames;
    for (uint32_t ret : c.cpu.frameChain(12)) {
        char text[16];
        std::snprintf(text, sizeof text, " %08x", ret);
        frames += text;
    }
    log("Carbon alert: %s / %s; frames%s", alert.messageText.UTF8String, alert.informativeText.UTF8String, frames.c_str());
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

// WindowRef GetDialogWindow(DialogRef): a standard alert is the host's, with no Carbon window behind it.
B32_THUNK(_GetDialogWindow) { c.ret(0); }

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
// The movie toolbox: nothing plays, and a movie that isn't found is skipped
// where one that fails to open gets retried.
// OSErr OpenMovieFile(const FSSpec *, short *refNum, SInt8 permission)
B32_THUNK(_OpenMovieFile) {
    c.args.ptr();
    c.args.ptr();
    c.args.u32();
    c.ret(uint32_t(-43));  // fnfErr
}
// OSErr CloseMovieFile(short refNum)
B32_THUNK(_CloseMovieFile) { c.args.u32(); c.ret(0); }
// OSErr NewMovieFromFile(Movie *, short refNum, short *id, StringPtr, short flags, Boolean *changed)
B32_THUNK(_NewMovieFromFile) {
    c.args.ptr();
    c.args.u32();
    c.args.ptr();
    c.args.ptr();
    c.args.u32();
    c.args.ptr();
    c.ret(uint32_t(-2010));  // invalidMovie
}
// TimeValue GetMovieDuration(Movie) / void GetMovieBox(Movie, Rect *) / void SetMovieBox(Movie, const Rect *)
B32_THUNK(_GetMovieDuration) {
    c.args.ptr();
    c.ret(0);
}
B32_THUNK(_GetMovieBox) {
    c.args.ptr();
    GuestAddr box = c.args.ptr();
    for (int i = 0; i < 8; i++) c.mem.write<uint8_t>(box + i, 0);
}
B32_THUNK(_SetMovieBox) {
    c.args.ptr();
    c.args.ptr();
}
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
