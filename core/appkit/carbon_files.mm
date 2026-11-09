// The classic File Manager (FSSpec, directory IDs, reference numbers), which
// 64-bit Carbon dropped. A directory ID is an index into a table of host paths,
// with 2 as the root; files are host descriptors.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Thunks.h"

#import <Foundation/Foundation.h>
#include <CoreServices/CoreServices.h>
#include <fcntl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

using namespace b32;

namespace {
constexpr int32_t kNoErr = 0, kFnfErr = -43, kDirNFErr = -120, kEofErr = -39, kParamErr = -50, kDupFNErr = -48, kIoErr = -36;
constexpr int16_t kVolume = -1;
constexpr int32_t kRootParent = 1, kRootDir = 2;

std::vector<std::string> directories = {"", "", "/"};  // index 2 is the root
std::unordered_map<std::string, int32_t> directoryIds = {{"/", kRootDir}};

int32_t idForPath(std::string path) {
    while (path.size() > 1 && path.back() == '/') path.pop_back();
    auto it = directoryIds.find(path);
    if (it != directoryIds.end()) return it->second;
    int32_t id = int32_t(directories.size());
    directories.push_back(path);
    directoryIds[path] = id;
    return id;
}
std::string pathForId(int32_t id) {
    if (id >= kRootDir && size_t(id) < directories.size()) return directories[size_t(id)];
    return "/";
}
std::string parentOf(const std::string &path) {
    size_t slash = path.find_last_of('/');
    return slash == 0 || slash == std::string::npos ? "/" : path.substr(0, slash);
}
std::string leafOf(const std::string &path) { return path.substr(path.find_last_of('/') + 1); }

std::string macRomanToUtf8(const char *bytes, size_t n) {
    NSString *s = [[[NSString alloc] initWithBytes:bytes length:n encoding:NSMacOSRomanStringEncoding] autorelease];
    return s.UTF8String ?: "";
}
std::string pascalString(Call &c, GuestAddr p) {
    return p ? macRomanToUtf8(c.mem.ptr<char>(p + 1), c.mem.read<uint8_t>(p)) : "";
}
void writePascal(Call &c, GuestAddr out, const std::string &utf8, uint32_t max = 255) {
    NSString *s = @(utf8.c_str());
    NSData *bytes = [s dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES];
    uint32_t n = std::min(uint32_t(bytes.length), max);
    c.mem.write<uint8_t>(out, uint8_t(n));
    c.mem.copyIn(out + 1, bytes.bytes, n);
}
// A name relative to a directory; ':' separates components, and a leading one means "relative".
std::string resolve(int32_t dir, const std::string &name) {
    std::string base = pathForId(dir), rest = name;
    bool absolute = !rest.empty() && rest[0] != ':' && rest.find(':') != std::string::npos;
    if (absolute) {
        // "Volume:Folder:File" names from the root.
        rest = rest.substr(rest.find(':') + 1);
        base = "/";
    } else if (!rest.empty() && rest[0] == ':') {
        rest = rest.substr(1);
    }
    std::replace(rest.begin(), rest.end(), ':', '/');
    if (rest.empty()) return base;
    return (base == "/" ? "" : base) + "/" + rest;
}
bool exists(const std::string &path) {
    struct stat st;
    return ::stat(path.c_str(), &st) == 0;
}
bool isDirectory(const std::string &path) {
    struct stat st;
    return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// FSSpec: vRefNum (2), parID (4), Str63 name, packed to 70 bytes.
constexpr uint32_t kSpecParent = 2, kSpecName = 6;
void writeSpec(Call &c, GuestAddr spec, const std::string &path) {
    c.mem.write<int16_t>(spec, kVolume);
    c.mem.write<int32_t>(spec + kSpecParent, path == "/" ? kRootParent : idForPath(parentOf(path)));
    writePascal(c, spec + kSpecName, path == "/" ? "Macintosh HD" : leafOf(path), 63);
}
std::string specPath(Call &c, GuestAddr spec) {
    return resolve(c.mem.read<int32_t>(spec + kSpecParent), pascalString(c, spec + kSpecName));
}

int32_t errnoStatus() { return errno == ENOENT ? kFnfErr : errno == EEXIST ? kDupFNErr : kIoErr; }

// Reference numbers are small: the host descriptor, as guests store them in shorts.
void fileRead(Call &c, bool write) {
    int fd = int16_t(c.args.u32());
    GuestAddr countAddr = c.args.ptr(), buffer = c.args.ptr();
    uint32_t wanted = c.mem.read<uint32_t>(countAddr);
    ssize_t done = write ? ::write(fd, c.mem.ptr<void>(buffer), wanted) : ::read(fd, c.mem.ptr<void>(buffer), wanted);
    c.mem.write<uint32_t>(countAddr, done > 0 ? uint32_t(done) : 0);
    c.ret(uint32_t(done < 0 ? kIoErr : (!write && uint32_t(done) < wanted) ? kEofErr : kNoErr));
}
}  // namespace

// Mounted volumes are numbered from 1 and addressed as -index: the first is the
// boot volume. Pseudo and system mounts aren't shown, as the Finder doesn't show them.
namespace {
struct Volume {
    std::string mount, name;
};
std::vector<Volume> mountedVolumes() {
    std::vector<Volume> list = {{"/", "Macintosh HD"}};
    struct statfs *mounts = nullptr;
    int count = ::getmntinfo(&mounts, MNT_NOWAIT);
    for (int i = 0; i < count; i++) {
        std::string path = mounts[i].f_mntonname;
        if (path.rfind("/Volumes/", 0) == 0 && path.find("TimeMachine") == std::string::npos) list.push_back({path, leafOf(path)});
    }
    return list;
}
bool isVolumeRoot(const std::string &path) {
    if (path == "/") return true;
    for (const Volume &v : mountedVolumes())
        if (v.mount == path) return true;
    return false;
}
}  // namespace

namespace {
int32_t directoryOn(int16_t volume, int32_t dir);
}

// OSErr PBGetCatInfoSync(CInfoPBRec *): ioNamePtr 18, ioVRefNum 22, ioFDirIndex 28,
// ioFlAttrib 30, ioDrDirID 48, ioDrParID 100. An index of -1 asks about the
// directory itself; 0 about the named item.
B32_THUNK(_PBGetCatInfoSync) {
    GuestAddr pb = c.args.ptr();
    GuestAddr namePtr = c.mem.read<uint32_t>(pb + 18);
    int16_t index = c.mem.read<int16_t>(pb + 28);
    int32_t dir = directoryOn(c.mem.read<int16_t>(pb + 22), c.mem.read<int32_t>(pb + 48));
    std::string path = index < 0 || !namePtr ? pathForId(dir) : resolve(dir, pascalString(c, namePtr));
    if (index > 0) {
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(path.c_str()) error:nil];
        if (size_t(index) > entries.count) {
            c.ret(uint32_t(kFnfErr));
            return;
        }
        path = (path == "/" ? "" : path) + "/" + [entries[size_t(index) - 1] fileSystemRepresentation];
    }
    if (!exists(path)) {
        c.ret(uint32_t(kFnfErr));
        return;
    }
    if (namePtr) writePascal(c, namePtr, path == "/" ? "Macintosh HD" : leafOf(path));
    c.mem.write<int16_t>(pb + 22, kVolume);
    bool directory = isDirectory(path);
    c.mem.write<uint8_t>(pb + 30, directory ? 0x10 : 0);
    if (directory) c.mem.write<int32_t>(pb + 48, idForPath(path));
    c.mem.write<int32_t>(pb + 100, isVolumeRoot(path) ? kRootParent : idForPath(parentOf(path)));
    c.ret(0);
}

namespace {
// A directory ID within a volume: 2 (or 0) is that volume's root.
int32_t directoryOn(int16_t volume, int32_t dir) {
    if ((dir != kRootDir && dir != 0) || volume >= 0) return dir;
    std::vector<Volume> volumes = mountedVolumes();
    size_t position = size_t(-volume - 1);
    return position < volumes.size() ? idForPath(volumes[position].mount) : dir;
}
}  // namespace

// OSErr FindFolder(vRefNum, folderType, createFolder, short *foundVRefNum, long *foundDirID)
B32_THUNK(_FindFolder) {
    c.args.u32();
    uint32_t type = c.args.u32();
    bool create = c.args.u32() & 0xff;
    GuestAddr vref = c.args.ptr(), dir = c.args.ptr();
    NSSearchPathDirectory which = NSApplicationSupportDirectory;
    switch (type) {
    case 'pref': which = NSLibraryDirectory; break;
    case 'desk': which = NSDesktopDirectory; break;
    case 'docs': which = NSDocumentDirectory; break;
    case 'cach': which = NSCachesDirectory; break;
    case 'asup': which = NSApplicationSupportDirectory; break;
    default: break;
    }
    NSString *path = NSSearchPathForDirectoriesInDomains(which, NSUserDomainMask, YES).firstObject;
    if (type == 'pref') path = [path stringByAppendingPathComponent:@"Preferences"];
    if (type == 'temp' || type == 'flnt') path = NSTemporaryDirectory();
    if (create) [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    if (vref) c.mem.write<int16_t>(vref, kVolume);
    if (dir) c.mem.write<int32_t>(dir, idForPath(path.fileSystemRepresentation));
    c.ret(0);
}

// OSErr FSMakeFSSpec(vRefNum, dirID, ConstStr255Param name, FSSpec *out)
B32_THUNK(_FSMakeFSSpec) {
    int16_t volume = int16_t(c.args.u32());
    int32_t dir = directoryOn(volume, c.args.i32());
    std::string name = pascalString(c, c.args.ptr());
    GuestAddr out = c.args.ptr();
    std::string path = resolve(dir, name);
    writeSpec(c, out, path);
    c.ret(uint32_t(exists(path) ? kNoErr : exists(parentOf(path)) ? kFnfErr : kDirNFErr));
}
// OSErr FSpOpenDF(spec, permission, short *ref)
B32_THUNK(_FSpOpenDF) {
    std::string path = specPath(c, c.args.ptr());
    int permission = c.args.u32() & 0xff;
    GuestAddr out = c.args.ptr();
    int flags = permission == 1 ? O_RDONLY : permission == 2 ? O_WRONLY : O_RDWR;
    int fd = ::open(path.c_str(), flags);
    if (fd < 0 && (flags & O_RDWR)) fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        c.ret(uint32_t(errnoStatus()));
        return;
    }
    c.mem.write<int16_t>(out, int16_t(fd));
    c.ret(0);
}
// OSErr FSpCreate(spec, creator, type, script)
B32_THUNK(_FSpCreate) {
    std::string path = specPath(c, c.args.ptr());
    int fd = ::open(path.c_str(), O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) {
        c.ret(uint32_t(errnoStatus()));
        return;
    }
    ::close(fd);
    c.ret(0);
}
B32_THUNK(_FSpDelete) {
    std::string path = specPath(c, c.args.ptr());
    c.ret(uint32_t((isDirectory(path) ? ::rmdir(path.c_str()) : ::unlink(path.c_str())) == 0 ? kNoErr : errnoStatus()));
}
B32_THUNK(_FSpSetFInfo) { c.ret(0); }
// OSErr FSpMakeFSRef(spec, FSRef *)
B32_THUNK(_FSpMakeFSRef) {
    std::string path = specPath(c, c.args.ptr());
    c.ret(uint32_t(int32_t(FSPathMakeRef(reinterpret_cast<const UInt8 *>(path.c_str()), c.mem.ptr<FSRef>(c.args.ptr()), nullptr))));
}
B32_THUNK(_FSRead) { fileRead(c, false); }
B32_THUNK(_FSWrite) { fileRead(c, true); }
B32_THUNK(_FSClose) { c.ret(uint32_t(::close(int16_t(c.args.u32())) == 0 ? kNoErr : kParamErr)); }
// OSErr SetFPos(ref, mode, offset): start 1, end 2, mark 3.
B32_THUNK(_SetFPos) {
    int fd = int16_t(c.args.u32());
    int mode = int16_t(c.args.u32());
    int32_t offset = c.args.i32();
    off_t at = ::lseek(fd, offset, mode == 1 ? SEEK_SET : mode == 2 ? SEEK_END : SEEK_CUR);
    c.ret(uint32_t(at < 0 ? kIoErr : kNoErr));
}
B32_THUNK(_GetEOF) {
    int fd = int16_t(c.args.u32());
    GuestAddr out = c.args.ptr();
    struct stat st;
    if (::fstat(fd, &st) != 0) {
        c.ret(uint32_t(kParamErr));
        return;
    }
    c.mem.write<int32_t>(out, int32_t(st.st_size));
    c.ret(0);
}
B32_THUNK(_SetEOF) {
    int fd = int16_t(c.args.u32());
    c.ret(uint32_t(::ftruncate(fd, c.args.i32()) == 0 ? kNoErr : kIoErr));
}
B32_THUNK(_HSetVol) { c.ret(0); }

// OSErr PBHGetVInfoSync(HParmBlkPtr): ioNamePtr 18, ioVRefNum 22, ioVolIndex 28,
// ioVNmAlBlks 46, ioVAlBlkSiz 48, ioVFrBlk 62. An index above 0 enumerates, and
// past the last volume the answer is nsvErr, which is how callers stop.
B32_THUNK(_PBHGetVInfoSync) {
    constexpr int32_t kNoSuchVolume = -35;
    GuestAddr pb = c.args.ptr();
    int16_t index = c.mem.read<int16_t>(pb + 28), reference = c.mem.read<int16_t>(pb + 22);
    std::vector<Volume> volumes = mountedVolumes();
    int position = index > 0 ? index - 1 : reference < 0 ? -reference - 1 : 0;
    if (position < 0 || size_t(position) >= volumes.size()) {
        c.ret(uint32_t(kNoSuchVolume));
        return;
    }
    const Volume &volume = volumes[size_t(position)];
    struct statfs st;
    uint64_t total = 0, free = 0;
    if (::statfs(volume.mount.c_str(), &st) == 0) {
        total = uint64_t(st.f_blocks) * st.f_bsize;
        free = uint64_t(st.f_bavail) * st.f_bsize;
    }
    uint32_t blockSize = uint32_t(std::max<uint64_t>(total / 65535 + 1, 512));
    if (GuestAddr name = c.mem.read<uint32_t>(pb + 18)) writePascal(c, name, volume.name, 27);
    c.mem.write<int16_t>(pb + 22, int16_t(-(position + 1)));
    c.mem.write<uint16_t>(pb + 46, uint16_t(std::min<uint64_t>(total / blockSize, 65535)));
    c.mem.write<uint32_t>(pb + 48, blockSize);
    c.mem.write<uint16_t>(pb + 62, uint16_t(std::min<uint64_t>(free / blockSize, 65535)));
    c.ret(0);
}

// --- Resource Manager: the host's reads the files; handles are copied to the guest -------
// A wrapped app can't carry resource forks (code signing refuses them), so
// tools/make-app.sh puts each one in Contents/B32Guest/Forks as a plain file.

namespace {
std::unordered_map<Handle, GuestAddr> guestHandles;

std::string forkPath(const std::string &path) {
    NSString *contents = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents"];
    NSString *full = @(path.c_str());
    if (![full hasPrefix:contents]) return "";
    NSString *relative = [full substringFromIndex:contents.length + 1];
    NSString *fork = [[contents stringByAppendingPathComponent:@"B32Guest/Forks"] stringByAppendingPathComponent:relative];
    return [NSFileManager.defaultManager fileExistsAtPath:fork] ? fork.fileSystemRepresentation : "";
}

// A guest Handle: a pointer to a pointer to the bytes.
GuestAddr toGuestHandle(Call &c, Handle host) {
    if (!host) return 0;
    if (auto it = guestHandles.find(host); it != guestHandles.end()) return it->second;
    Size size = GetHandleSize(host);
    GuestAddr bytes = c.heap.alloc(uint32_t(std::max<Size>(size, 1))), master = c.heap.calloc(1, 4);
    c.mem.copyIn(bytes, *host, size_t(size));
    c.mem.write<uint32_t>(master, bytes);
    guestHandles[host] = master;
    return master;
}
}  // namespace

// ResFileRefNum FSOpenResFile(const FSRef *, SInt8 permission)
B32_THUNK(_FSOpenResFile) {
    const FSRef *ref = c.mem.ptr<FSRef>(c.args.ptr());
    SInt8 permission = SInt8(c.args.u32());
    UInt8 path[1024];
    ResFileRefNum number = -1;
    if (FSRefMakePath(ref, path, sizeof path) == noErr) {
        std::string fork = forkPath(reinterpret_cast<char *>(path));
        FSRef forkRef;
        if (!fork.empty() && FSPathMakeRef(reinterpret_cast<const UInt8 *>(fork.c_str()), &forkRef, nullptr) == noErr) {
            HFSUniStr255 dataFork;
            FSGetDataForkName(&dataFork);
            FSOpenResourceFile(&forkRef, dataFork.length, dataFork.unicode, fsRdPerm, &number);
        } else {
            number = FSOpenResFile(ref, permission);
        }
    }
    c.ret(uint32_t(int32_t(number)));
}
B32_THUNK(_UseResFile) { UseResFile(ResFileRefNum(int16_t(c.args.u32()))); }
B32_THUNK(_CurResFile) { c.ret(uint32_t(int32_t(CurResFile()))); }
B32_THUNK(_CloseResFile) { CloseResFile(ResFileRefNum(int16_t(c.args.u32()))); }
B32_THUNK(_ResError) { c.ret(uint32_t(int32_t(ResError()))); }
B32_THUNK(_GetResource) {
    uint32_t type = c.args.u32();
    c.ret(toGuestHandle(c, GetResource(type, ResID(int16_t(c.args.u32())))));
}
B32_THUNK(_Get1Resource) {
    uint32_t type = c.args.u32();
    c.ret(toGuestHandle(c, Get1Resource(type, ResID(int16_t(c.args.u32())))));
}
B32_THUNK(_LoadResource) {}
B32_THUNK(_ReleaseResource) {}
B32_THUNK(_HLock) {}
B32_THUNK(_HUnlock) {}
B32_THUNK(_GetHandleSize) {
    GuestAddr master = c.args.ptr();
    c.ret(master ? c.heap.sizeOf(c.mem.read<uint32_t>(master)) : 0);
}
B32_THUNK(_DisposeHandle) {}
// void GetIndString(Str255 out, resID, index): the index'th Pascal string of a 'STR#' resource.
B32_THUNK(_GetIndString) {
    GuestAddr out = c.args.ptr();
    ResID id = ResID(int16_t(c.args.u32()));
    int index = int16_t(c.args.u32());
    c.mem.write<uint8_t>(out, 0);
    Handle list = GetResource('STR#', id);
    if (!list || GetHandleSize(list) < 2) return;
    const uint8_t *p = reinterpret_cast<const uint8_t *>(*list);
    int count = p[0] << 8 | p[1];
    p += 2;
    for (int i = 1; i <= count; i++) {
        if (i == index) {
            c.mem.copyIn(out, p, size_t(p[0]) + 1);
            return;
        }
        p += size_t(p[0]) + 1;
    }
}
