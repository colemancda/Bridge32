// The classic File Manager (FSSpec, directory IDs, reference numbers), which
// 64-bit Carbon dropped. A directory ID is an index into a table of host paths,
// with 2 as the root; files are host descriptors.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/Thunks.h"

#import <Foundation/Foundation.h>
#include <CoreServices/CoreServices.h>
#include <CoreText/CoreText.h>
#include <CoreText/CoreText.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>
#include <mutex>
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
// An FSRef is 80 opaque bytes the guest only hands back to these calls, so the
// host's can sit in guest memory whatever the byte order.
FSRef *fsRef(Call &c, GuestAddr p) { return static_cast<FSRef *>(c.mem.ptr<void>(p)); }
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
// The host has volume reference numbers of its own (-100 on), which its FSRefs carry in
// their first bytes and games crack out; those resolve here too.
namespace {
struct Volume {
    std::string mount, name;
    int16_t hostRef = 0;
};
std::vector<Volume> mountedVolumes() {
    std::vector<Volume> list = {{"/", "Macintosh HD", 0}};
    struct statfs *mounts = nullptr;
    int count = ::getmntinfo(&mounts, MNT_NOWAIT);
    for (int i = 0; i < count; i++) {
        std::string path = mounts[i].f_mntonname;
        if (path.rfind("/Volumes/", 0) == 0 && path.find("TimeMachine") == std::string::npos) list.push_back({path, leafOf(path), 0});
    }
    for (ItemCount i = 1;; i++) {
        FSVolumeRefNum ref = 0;
        HFSUniStr255 name;
        FSRef root;
        if (FSGetVolumeInfo(kFSInvalidVolumeRefNum, i, &ref, kFSVolInfoNone, nullptr, &name, &root) != noErr) break;
        char path[PATH_MAX] = "";
        if (FSRefMakePath(&root, reinterpret_cast<uint8_t *>(path), sizeof path) != noErr) continue;
        for (Volume &v : list)
            if (v.mount == path) {
                v.hostRef = ref;
                NSString *own = [NSString stringWithCharacters:name.unicode length:name.length];
                if (own.length) v.name = own.fileSystemRepresentation;  // the volume's own name beats the mount point's leaf
            }
    }
    return list;
}
// Where a volume reference points: ours is -1.. as ioVRefNum hands it out; the host's
// own is -100.. as its FSRefs carry it.
int positionOf(const std::vector<Volume> &volumes, int16_t index, int16_t reference) {
    if (index > 0) return index - 1;
    if (reference >= 0) return 0;
    if (size_t(-reference) <= volumes.size()) return -reference - 1;
    for (size_t i = 0; i < volumes.size(); i++)
        if (volumes[i].hostRef == reference) return int(i);
    return -1;
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
void writeCatalogInfo(Call &c, GuestAddr info, const std::string &path, const struct stat &st);
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
    int position = positionOf(volumes, 0, volume);
    return position >= 0 && size_t(position) < volumes.size() ? idForPath(volumes[position].mount) : dir;
}
}  // namespace

// OSErr FSGetCatalogInfo(const FSRef *ref, FSCatalogInfoBitmap whichInfo, FSCatalogInfo *catalogInfo,
//                        HFSUniStr255 *outName, FSSpec *outSpec, FSRef *parentRef): explicit, so the
// node and parent IDs are this file's, which the classic calls (HSetVol, FSpMakeFSRef) resolve.
// The rest of the record comes from stat: dates as seconds since 1904, sizes and permissions;
// what stat has no word for (finder info, sharing) stays zero.
B32_THUNK(_FSGetCatalogInfo) {
    GuestAddr ref = c.args.ptr();
    uint32_t which = c.args.u32();
    GuestAddr info = c.args.ptr(), outName = c.args.ptr(), outSpec = c.args.ptr(), parentRef = c.args.ptr();
    char path[PATH_MAX] = "";
    if (FSRefMakePath(fsRef(c, ref), reinterpret_cast<uint8_t *>(path), sizeof path) != noErr || !exists(path)) {
        c.ret(uint32_t(kFnfErr));
        return;
    }
    struct stat st;
    ::stat(path, &st);
    writeCatalogInfo(c, info, path, st);
    (void)which;  // the fields it asked for are the ones filled; the rest are harmless
    if (outName) {
        NSString *leaf = @(leafOf(path).c_str());
        NSUInteger length = MIN(leaf.length, NSUInteger(255));
        c.mem.write<uint16_t>(outName, uint16_t(length));
        std::vector<UniChar> characters(length);
        [leaf getCharacters:characters.data() range:NSMakeRange(0, length)];
        c.mem.writeArray<UniChar>(outName + 2, characters.data(), length);
    }
    if (parentRef) {
        FSRef parent;
        std::string up = parentOf(path);
        if (FSPathMakeRef(reinterpret_cast<const uint8_t *>(up.c_str()), &parent, nullptr) == noErr)
            c.mem.copyIn(parentRef, &parent, sizeof parent);
    }
    if (outSpec) writeSpec(c, outSpec, path);
    c.ret(0);
}

// FSIterator: this file's directory table does the walking, so what it hands out
// (ids, specs) matches the rest; the host's iterator would give the host's CNIDs.
namespace {
struct DirectoryIterator {
    std::string base;                  // the directory it walks
    std::vector<std::string> entries;  // leaf names, from the moment it opened
    size_t position = 0;
};
std::mutex directoryIteratorLock;
std::unordered_map<uint32_t, DirectoryIterator> directoryIterators;
uint32_t nextDirectoryIterator = 0x30000000;

// A 32-bit program's FSCatalogInfo, 144 bytes with 2-byte packing: nodeFlags 0, volume 2, parentDirID 4,
// nodeID 8, sharingFlags 12, userPrivileges 13, then five UTCDateTimes (create 16, content change 24,
// attribute change 32, access 40, backup 48), permissions 56 (user, group, a reserved byte, userAccess,
// mode, and a reserved word), finderInfo 72, extFinderInfo 88, the data fork's logical and physical sizes
// 104 and 112, the resource fork's 120 and 128, valence 136, textEncodingHint 140. (The host's own is four
// bytes longer from the permissions on, which hold a pointer there.)
constexpr uint32_t kCatalogInfoSize = 144;
void writeCatalogInfo(Call &c, GuestAddr info, const std::string &path, const struct stat &st) {
    if (!info) return;
    bool directory = S_ISDIR(st.st_mode);
    c.mem.write<uint16_t>(info + 0, directory ? 0x10 : 0);  // kFSNodeIsDirectoryMask
    c.mem.write<int16_t>(info + 2, kVolume);
    c.mem.write<int32_t>(info + 4, isVolumeRoot(path) ? kRootParent : idForPath(parentOf(path)));
    c.mem.write<int32_t>(info + 8, idForPath(path));
    auto date = [&](uint32_t at, time_t when) {  // UTCDateTime: high then low half of seconds since 1904, then a fraction
        uint64_t seconds = uint64_t(when) + 2082844800;
        c.mem.write<uint16_t>(info + at, uint16_t(seconds >> 32));
        c.mem.write<uint32_t>(info + at + 2, uint32_t(seconds));
        c.mem.write<uint16_t>(info + at + 6, 0);
    };
    date(16, st.st_birthtimespec.tv_sec);
    date(24, st.st_mtimespec.tv_sec);
    date(32, st.st_ctimespec.tv_sec);
    date(40, st.st_atimespec.tv_sec);
    c.mem.write<uint32_t>(info + 56, st.st_uid);
    c.mem.write<uint32_t>(info + 60, st.st_gid);
    c.mem.write<uint8_t>(info + 65, 0);  // userAccess
    c.mem.write<uint16_t>(info + 66, uint16_t(st.st_mode));
    if (directory) {
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(path.c_str()) error:nil];
        c.mem.write<uint32_t>(info + 136, uint32_t(entries.count));  // valence: how many items it holds
    } else {
        c.mem.write<uint64_t>(info + 104, uint64_t(st.st_size));
        c.mem.write<uint64_t>(info + 112, uint64_t(st.st_blocks) * 512);
    }
}
}  // namespace

// OSErr FSOpenIterator(const FSRef *container, FSIteratorFlags, FSIterator *out)
B32_THUNK(_FSOpenIterator) {
    GuestAddr container = c.args.ptr();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    char path[PATH_MAX] = "";
    if (FSRefMakePath(fsRef(c, container), reinterpret_cast<uint8_t *>(path), sizeof path) != noErr || !isDirectory(path)) {
        c.ret(uint32_t(kDirNFErr));
        return;
    }
    uint32_t handle;
    {
        std::lock_guard guard(directoryIteratorLock);
        handle = nextDirectoryIterator++;
        DirectoryIterator &it = directoryIterators[handle];
        it.base = path;
        it.position = 0;
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(path) error:nil];
        it.entries.reserve(entries.count);
        for (NSString *entry in entries) it.entries.push_back(entry.fileSystemRepresentation);
    }
    if (out) c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}
// OSErr FSCloseIterator(FSIterator)
B32_THUNK(_FSCloseIterator) {
    uint32_t handle = c.args.u32();
    std::lock_guard guard(directoryIteratorLock);
    if (directoryIterators.erase(handle) == 0) {
        c.ret(uint32_t(kParamErr));
        return;
    }
    c.ret(0);
}
// OSErr FSGetCatalogInfoBulk(FSIterator, ItemCount maximum, ItemCount *actual, Boolean *containerChanged,
//                            FSCatalogInfoBitmap, FSCatalogInfo[] infos, FSRef[] refs, FSSpec[] specs,
//                            HFSUniStr255[] names): one stride each — FSCatalogInfo 144, FSRef 80, FSSpec 70,
//                            HFSUniStr255 512. Past the last item the answer is errFSNoMoreItems, with
//                            however many there were, which is how callers stop.
B32_THUNK(_FSGetCatalogInfoBulk) {
    uint32_t handle = c.args.u32();
    uint32_t maximum = c.args.u32();
    GuestAddr actual = c.args.ptr(), changes = c.args.ptr();
    c.args.u32();  // whichInfo: the fields it asked for are the ones filled
    GuestAddr infos = c.args.ptr(), refs = c.args.ptr(), specs = c.args.ptr(), names = c.args.ptr();
    uint32_t count = 0;
    {
        std::lock_guard guard(directoryIteratorLock);
        auto found = directoryIterators.find(handle);
        if (found == directoryIterators.end()) {
            c.ret(uint32_t(kParamErr));
            return;
        }
        DirectoryIterator &it = found->second;
        for (; count < maximum && it.position < it.entries.size(); count++, it.position++) {
            const std::string &leaf = it.entries[it.position];
            std::string path = (it.base == "/" ? "" : it.base) + "/" + leaf;
            struct stat st;
            ::stat(path.c_str(), &st);
            writeCatalogInfo(c, infos ? infos + uint32_t(count) * kCatalogInfoSize : 0, path, st);
            if (names) {
                NSString *name = @(leaf.c_str());
                NSUInteger length = MIN(name.length, NSUInteger(255));
                GuestAddr out = names + uint32_t(count) * 512;
                c.mem.write<uint16_t>(out, uint16_t(length));
                std::vector<UniChar> characters(length);
                [name getCharacters:characters.data() range:NSMakeRange(0, length)];
                c.mem.writeArray<UniChar>(out + 2, characters.data(), length);
            }
            if (refs) {
                FSRef ref;
                if (FSPathMakeRef(reinterpret_cast<const uint8_t *>(path.c_str()), &ref, nullptr) == noErr)
                    c.mem.copyIn(refs + uint32_t(count) * 80, &ref, sizeof ref);
                else
                    c.mem.write<uint32_t>(refs + uint32_t(count) * 80, 0);
            }
            if (specs) writeSpec(c, specs + uint32_t(count) * 70, path);
        }
    }
    constexpr int32_t kNoMoreItems = -1417;
    if (changes) c.mem.write<uint8_t>(changes, 0);
    if (actual) c.mem.write<uint32_t>(actual, count);
    c.ret(uint32_t(count < maximum ? kNoMoreItems : kNoErr));
}

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
    // A folder that isn't there, and wasn't asked for, isn't found.
    if (!isDirectory(path.fileSystemRepresentation)) {
        c.ret(uint32_t(kFnfErr));
        return;
    }
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
    c.ret(uint32_t(int32_t(FSPathMakeRef(reinterpret_cast<const UInt8 *>(path.c_str()), fsRef(c, c.args.ptr()), nullptr))));
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
// The default volume and directory HSetVol sets, as the pair the caller gave:
// the ids are this file's (idForPath), which FSGetCatalogInfo below hands out,
// so what went in comes back out.
std::mutex defaultDirLock;
int16_t defaultDirVolume = -1;
int32_t defaultDirId = kRootDir;
std::string defaultDirName;
// OSErr HSetVol(ConstStr255Param name, short vRefNum, long dirID)
B32_THUNK(_HSetVol) {
    c.args.ptr();
    int16_t volume = c.args.i32();
    int32_t dir = c.args.i32();
    {
        std::lock_guard guard(defaultDirLock);
        defaultDirVolume = volume;
        defaultDirId = dir;
        std::string path = pathForId(dir);
        defaultDirName = path == "/" ? std::string() : leafOf(path);
    }
    c.ret(0);
}
// OSErr HGetVol(StringPtr name, short *vRefNum, long *dirID)
B32_THUNK(_HGetVol) {
    GuestAddr name = c.args.ptr(), volume = c.args.ptr(), dir = c.args.ptr();
    {
        std::lock_guard guard(defaultDirLock);
        if (name) writePascal(c, name, defaultDirName);
        if (volume) c.mem.write<int16_t>(volume, defaultDirVolume);
        if (dir) c.mem.write<int32_t>(dir, defaultDirId);
    }
    c.ret(0);
}

// Boolean FSResolveAliasFile(FSRef *theRef, Boolean targetIsFolder, Boolean *wasAliased):
// no aliases are made here; what it pointed at is what it is.
B32_THUNK(_FSResolveAliasFile) {
    c.args.ptr();
    c.args.u32();
    GuestAddr wasAliased = c.args.ptr();
    if (wasAliased) c.mem.write<uint8_t>(wasAliased, 0);
    c.ret(1);
}

// OSStatus ATSFontActivateFromFileSpecification(const FSSpec *, ATSFontContext, ATSFontFormat,
//                                               ATSFontFilter, OptionBits, ATSFontContainerRef *):
// CoreText registers the font file for the process.
namespace {
std::unordered_map<uint32_t, CFURLRef> fontContainers;  // the guest's container → its file
uint32_t nextFontContainer = 0x60000001;
}
B32_THUNK(_ATSFontActivateFromFileSpecification) {
    GuestAddr spec = c.args.ptr();
    c.args.u32();
    c.args.u32();
    c.args.u32();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    std::string path = specPath(c, spec);
    if (!exists(path)) {
        c.ret(uint32_t(kFnfErr));
        return;
    }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8 *>(path.c_str()), path.size(), false);
    CFErrorRef error = nullptr;
    bool ok = CTFontManagerRegisterFontsForURL(url, kCTFontManagerScopeProcess, &error);
    if (error) CFRelease(error);
    uint32_t container = 0;
    if (ok) {
        container = nextFontContainer++;
        fontContainers[container] = url;  // kept, for deactivation
    } else if (url) {
        CFRelease(url);
    }
    if (out) c.mem.write<uint32_t>(out, container);
    c.ret(ok ? 0 : uint32_t(kFnfErr));
}
// OSStatus ATSFontDeactivate(ATSFontContainerRef, ATSFontDeactivateOptions, ItemCount)
B32_THUNK(_ATSFontDeactivate) {
    uint32_t container = c.args.u32();
    c.args.u32();
    c.args.u32();
    if (auto it = fontContainers.find(container); it != fontContainers.end()) {
        CFErrorRef error = nullptr;
        CTFontManagerUnregisterFontsForURL(it->second, kCTFontManagerScopeProcess, &error);
        if (error) CFRelease(error);
        CFRelease(it->second);
        fontContainers.erase(it);
    }
    c.ret(0);
}

// OSErr PBHGetVInfoSync(HParmBlkPtr): ioNamePtr 18, ioVRefNum 22, ioVolIndex 28,
// ioVNmAlBlks 46, ioVAlBlkSiz 48, ioVFrBlk 62. An index above 0 enumerates, and
// past the last volume the answer is nsvErr, which is how callers stop.
B32_THUNK(_PBHGetVInfoSync) {
    constexpr int32_t kNoSuchVolume = -35;
    GuestAddr pb = c.args.ptr();
    int16_t index = c.mem.read<int16_t>(pb + 28), reference = c.mem.read<int16_t>(pb + 22);
    std::vector<Volume> volumes = mountedVolumes();
    int position = positionOf(volumes, index, reference);
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
    // The sizes this call reports stop at 2 GB, as they always did for the programs that multiply the block
    // counts out in 32 bits: with more than that free, such a sum wraps round to something small.
    constexpr uint64_t kMostReported = 0x7FFFFFFF;
    total = std::min(total, kMostReported);
    free = std::min(free, total);
    uint32_t blockSize = uint32_t(std::max<uint64_t>(total / 65535 + 1, 512));
    if (GuestAddr name = c.mem.read<uint32_t>(pb + 18)) writePascal(c, name, volume.name, 27);
    c.mem.write<int16_t>(pb + 22, int16_t(-(position + 1)));
    c.mem.write<uint16_t>(pb + 46, uint16_t(std::min<uint64_t>(total / blockSize, 65535)));
    c.mem.write<uint32_t>(pb + 48, blockSize);
    c.mem.write<uint16_t>(pb + 62, uint16_t(std::min<uint64_t>(free / blockSize, 65535)));
    c.ret(0);
}

// OSErr FSGetVolumeInfo(FSVolumeRefNum volume, ItemCount index, FSVolumeRefNum *actualVolume,
//     FSVolumeInfoBitmap whichInfo, FSVolumeInfo *info, HFSUniStr255 *name, FSRef *rootDirectory):
// one of the volumes the classic calls number, as statfs has it. FSVolumeInfo is 2-byte aligned:
// four UTCDateTimes, fileCount 32, folderCount 36, totalBytes 40, freeBytes 48, blockSize 56,
// totalBlocks 60, freeBlocks 64, ... signature 120, 126 bytes in all. Only the sizes are known; the
// rest is zero.
B32_THUNK(_FSGetVolumeInfo) {
    constexpr int32_t kNoSuchVolume = -35;
    int16_t reference = int16_t(c.args.u32());
    uint32_t index = c.args.u32();
    GuestAddr actual = c.args.ptr();
    c.args.u32();  // whichInfo
    GuestAddr info = c.args.ptr(), name = c.args.ptr(), root = c.args.ptr();
    std::vector<Volume> volumes = mountedVolumes();
    int position = positionOf(volumes, int16_t(index), reference);
    if (position < 0 || size_t(position) >= volumes.size()) {
        c.ret(uint32_t(kNoSuchVolume));
        return;
    }
    const Volume &volume = volumes[size_t(position)];
    if (actual) c.mem.write<int16_t>(actual, int16_t(-(position + 1)));
    if (info) {
        std::memset(c.mem.ptr<uint8_t>(info), 0, 126);
        struct statfs st;
        if (::statfs(volume.mount.c_str(), &st) == 0) {
            c.mem.write<uint64_t>(info + 40, uint64_t(st.f_blocks) * st.f_bsize);
            c.mem.write<uint64_t>(info + 48, uint64_t(st.f_bavail) * st.f_bsize);
            c.mem.write<uint32_t>(info + 56, st.f_bsize);
            c.mem.write<uint32_t>(info + 60, uint32_t(std::min<uint64_t>(st.f_blocks, UINT32_MAX)));
            c.mem.write<uint32_t>(info + 64, uint32_t(std::min<uint64_t>(st.f_bavail, UINT32_MAX)));
        }
        c.mem.write<uint16_t>(info + 120, 0x482B);  // 'H+'
    }
    if (name) {
        NSString *text = @(volume.name.c_str());
        NSUInteger length = MIN(text.length, NSUInteger(255));
        c.mem.write<uint16_t>(name, uint16_t(length));
        std::vector<UniChar> characters(length);
        [text getCharacters:characters.data() range:NSMakeRange(0, length)];
        c.mem.writeArray<UniChar>(name + 2, characters.data(), length);
    }
    if (root) {
        FSRef ref;
        if (FSPathMakeRef(reinterpret_cast<const UInt8 *>(volume.mount.c_str()), &ref, nullptr) == noErr)
            c.mem.copyIn(root, &ref, sizeof ref);
    }
    c.ret(0);
}

// OSErr PBHGetVolParmsSync(HParmBlkPtr): ioNamePtr 18, ioVRefNum 22, ioBuffer 32, ioReqCount 36,
// ioActCount 40. The GetVolParmsInfoBuffer (version 3, 2-byte aligned) says which device the volume is
// on: vMVersion 0, vMAttrib 2, vMLocalHand 6, vMServerAdr 10, vMVolumeGrade 14, vMForeignPrivID 18,
// vMExtendedAttributes 20, vMDeviceID 24 (a C string naming the BSD device, like "disk3s1").
B32_THUNK(_PBHGetVolParmsSync) {
    constexpr int32_t kNoSuchVolume = -35;
    constexpr uint32_t kInfoSize = 28;
    GuestAddr pb = c.args.ptr();
    int16_t reference = c.mem.read<int16_t>(pb + 22);
    GuestAddr buffer = c.mem.read<uint32_t>(pb + 32);
    uint32_t count = c.mem.read<uint32_t>(pb + 36);
    std::vector<Volume> volumes = mountedVolumes();
    int position = positionOf(volumes, 0, reference);
    if (position < 0 || size_t(position) >= volumes.size()) {
        c.ret(uint32_t(kNoSuchVolume));
        return;
    }
    // vMDeviceID points at the device's name, kept for as long as the guest runs.
    static std::unordered_map<std::string, GuestAddr> deviceNames;
    std::string device;
    struct statfs st;
    if (::statfs(volumes[size_t(position)].mount.c_str(), &st) == 0) {
        device = st.f_mntfromname;
        if (device.rfind("/dev/", 0) == 0) device.erase(0, 5);
        else device.clear();
    }
    GuestAddr deviceName = 0;
    if (!device.empty()) {
        GuestAddr &slot = deviceNames[device];
        if (!slot) {
            slot = c.heap.alloc(uint32_t(device.size() + 1));
            c.mem.copyIn(slot, device.c_str(), device.size() + 1);
        }
        deviceName = slot;
    }
    uint8_t info[kInfoSize] = {};
    auto put16 = [&](uint32_t at, uint16_t v) { std::memcpy(info + at, &v, 2); };
    auto put32 = [&](uint32_t at, uint32_t v) { std::memcpy(info + at, &v, 4); };
    put16(0, 3);          // vMVersion
    put32(2, 0);          // vMAttrib
    put32(14, 0);         // vMVolumeGrade
    put32(24, deviceName);  // vMDeviceID
    uint32_t written = std::min(count, kInfoSize);
    if (buffer && written) c.mem.copyIn(buffer, info, written);
    c.mem.write<uint32_t>(pb + 40, written);
    c.ret(0);
}

// OSErr PBHGetDirAccessSync(HParmBlkPtr): who may do what in a directory. ioACUser 31 (what the caller is
// denied: nothing), ioACOwnerID 36, ioACGroupID 40, ioACAccess 44 (see, read and write for owner, group
// and everyone, as the directory's own mode bits say).
B32_THUNK(_PBHGetDirAccessSync) {
    GuestAddr pb = c.args.ptr();
    int32_t dir = directoryOn(c.mem.read<int16_t>(pb + 22), c.mem.read<int32_t>(pb + 48));
    GuestAddr namePtr = c.mem.read<uint32_t>(pb + 18);
    std::string path = namePtr ? resolve(dir, pascalString(c, namePtr)) : pathForId(dir);
    struct stat st;
    if (::stat(path.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
        c.ret(uint32_t(kDirNFErr));
        return;
    }
    // Each byte: search 1, read 2, write 4. Unix has one bit for search and read's listing both.
    auto rights = [](mode_t bits) { return uint32_t((bits & 1 ? 1 : 0) | (bits & 4 ? 2 : 0) | (bits & 2 ? 4 : 0)); };
    uint32_t access = rights(st.st_mode >> 6) << 24 | rights(st.st_mode >> 6) << 16 | rights(st.st_mode >> 3) << 8 | rights(st.st_mode);
    c.mem.write<uint8_t>(pb + 31, 0);
    c.mem.write<int32_t>(pb + 36, int32_t(st.st_uid));
    c.mem.write<int32_t>(pb + 40, int32_t(st.st_gid));
    c.mem.write<uint32_t>(pb + 44, access);
    c.ret(0);
}

// OSStatus FMActivateFonts(const FSSpec *container, const FSFilter *, void *refCon, OptionBits): a game's own
// font file, made available to this process alone. FMDeactivateFonts takes the same arguments.
B32_THUNK(_FMActivateFonts) {
    std::string path = specPath(c, c.args.ptr());
    NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
    CTFontManagerRegisterFontsForURL((CFURLRef)url, kCTFontManagerScopeProcess, nullptr);
    c.ret(0);
}
B32_THUNK(_FMDeactivateFonts) {
    std::string path = specPath(c, c.args.ptr());
    NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
    CTFontManagerUnregisterFontsForURL((CFURLRef)url, kCTFontManagerScopeProcess, nullptr);
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
    const FSRef *ref = fsRef(c, c.args.ptr());
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
