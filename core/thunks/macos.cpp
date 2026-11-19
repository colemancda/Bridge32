// libSystem calls that only Mac apps use, or that iOS apps were kept from
// (Mono's runtime, SDL and friends on the i386 guest).

#include "Thunks.h"

#include "Discs.h"
#include "Threads.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <cmath>
#include <string>
#include <array>
#include <deque>
#include <thread>
#include <vector>
#include <functional>
#include <grp.h>
#include <iconv.h>
#include <mach/mach.h>
#include <mach/semaphore.h>
#include <netdb.h>
#include <notify.h>
#include <pwd.h>
#include <signal.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <algorithm>
#include <cstring>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <unordered_map>

using namespace b32;

extern char **environ;

namespace {
// A negative result of a libc call, with the guest's errno set, or the result.
void retErrno(Call &c, int result) {
    if (result < 0) setGuestErrno(c, errno);
    c.ret(uint32_t(result));
}
}  // namespace

// --- Mach: Mono's exception port. Guest faults reach it as signals instead, so
// the port is real but nothing is ever sent to it, and its thread just waits. ----

B32_THUNK(_mach_port_allocate) {
    c.args.u32();
    uint32_t right = c.args.u32();
    GuestAddr out = c.args.ptr();
    mach_port_name_t name = 0;
    kern_return_t kr = ::mach_port_allocate(mach_task_self(), right, &name);
    c.mem.write<uint32_t>(out, name);
    c.ret(kr);
}
B32_THUNK(_mach_port_insert_right) {
    c.args.u32();
    uint32_t name = c.args.u32(), poly = c.args.u32();
    c.ret(::mach_port_insert_right(mach_task_self(), name, poly, c.args.u32()));
}
B32_THUNK(_task_set_exception_ports) { c.ret(KERN_SUCCESS); }
// mach_msg_return_t mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
B32_THUNK(_mach_msg) {
#if defined(B32_GUEST_BIG_ENDIAN)
    // The message header's fields would need converting both ways; nothing on
    // the PowerPC side has needed it yet.
    fatal("mach_msg isn't converted for big-endian guests yet");
#endif
    auto *msg = static_cast<mach_msg_header_t *>(c.mem.ptr<void>(c.args.ptr()));
    uint32_t option = c.args.u32(), sendSize = c.args.u32(), receiveSize = c.args.u32(), name = c.args.u32();
    uint32_t timeout = c.args.u32();
    c.ret(::mach_msg(msg, option, sendSize, receiveSize, name, timeout, c.args.u32()));
}
B32_THUNK(_exc_server) { c.ret(0); }
B32_THUNK(_task_for_pid) {
    c.args.u32();
    c.args.u32();
    c.mem.write<uint32_t>(c.args.ptr(), mach_task_self());
    c.ret(KERN_SUCCESS);
}
// kern_return_t semaphore_timedwait(semaphore_t, mach_timespec_t)
B32_THUNK(_semaphore_timedwait) {
    uint32_t semaphore = c.args.u32();
    mach_timespec_t wait;
    wait.tv_sec = c.args.u32();
    wait.tv_nsec = c.args.i32();
    c.ret(::semaphore_timedwait(semaphore, wait));
}

// --- odds and ends ------------------------------------------------------------------------

B32_THUNK(___bzero) {
    GuestAddr p = c.args.ptr();
    std::memset(c.mem.ptr<void>(p), 0, c.args.u32());
}
B32_THUNK(_raise) { c.ret(uint32_t(::raise(c.args.i32()))); }
// The guest's rounding state belongs to the emulated FPU, which stays at the default.
B32_THUNK(_fegetenv) { c.ret(0); }
B32_THUNK(_fesetenv) { c.ret(0); }
B32_THUNK(_fesetround) { c.ret(0); }
B32_THUNK(_fegetround) { c.ret(0); }

// --- processes --------------------------------------------------------------------------

B32_THUNK(_dup) { retErrno(c, ::dup(c.args.i32())); }
B32_THUNK(_dup2) {
    int a = c.args.i32();
    retErrno(c, ::dup2(a, c.args.i32()));
}
// struct rlimit is two 64-bit rlim_t in the 32-bit ABI too.
B32_THUNK(_getrlimit) {
    int resource = c.args.i32();
    GuestAddr out = c.args.ptr();
    struct rlimit limit {};
    int result = ::getrlimit(resource, &limit);
    if (result == 0 && out) {
        c.mem.write<uint64_t>(out, limit.rlim_cur);
        c.mem.write<uint64_t>(out + 8, limit.rlim_max);
    }
    retErrno(c, result);
}
B32_THUNK(_setrlimit) {
    int resource = c.args.i32();
    GuestAddr in = c.args.ptr();
    struct rlimit limit {c.mem.read<uint64_t>(in), c.mem.read<uint64_t>(in + 8)};
    retErrno(c, ::setrlimit(resource, &limit));
}
B32_THUNK(_kill) {
    pid_t pid = c.args.i32();
    retErrno(c, ::kill(pid, c.args.i32()));
}
// A guest can't start other programs, so there's never a child to wait for.
B32_THUNK(_execve) {
    setGuestErrno(c, ENOSYS);
    c.ret(uint32_t(-1));
}
B32_THUNK(_waitpid) {
    setGuestErrno(c, ECHILD);
    c.ret(uint32_t(-1));
}
// posix_spawn and posix_spawnp: no program starts, as for execve; the file actions and attributes the
// guest sets up for one are accepted and forgotten.
B32_THUNK(_posix_spawn) { c.ret(ENOSYS); }
B32_THUNK(_posix_spawnp) { c.ret(ENOSYS); }
#define B32_SPAWN_SETUP(symbol) \
    B32_THUNK(symbol) { c.ret(0); }
B32_SPAWN_SETUP(_posix_spawn_file_actions_init)
B32_SPAWN_SETUP(_posix_spawn_file_actions_destroy)
B32_SPAWN_SETUP(_posix_spawn_file_actions_adddup2)
B32_SPAWN_SETUP(_posix_spawn_file_actions_addclose)
B32_SPAWN_SETUP(_posix_spawn_file_actions_addopen)
B32_SPAWN_SETUP(_posix_spawnattr_init)
B32_SPAWN_SETUP(_posix_spawnattr_destroy)
B32_SPAWN_SETUP(_posix_spawnattr_setflags)
B32_SPAWN_SETUP(_posix_spawnattr_setpgroup)
B32_SPAWN_SETUP(_posix_spawnattr_setsigmask)
B32_SPAWN_SETUP(_posix_spawnattr_setsigdefault)
#undef B32_SPAWN_SETUP

// --- malloc zones: all of them the guest heap, as NSZones are ------------------------------------

namespace {
GuestAddr defaultZone(Call &c) {
    static GuestAddr zone = c.heap.calloc(1, 64);  // a malloc_zone_t the guest only passes back
    return zone;
}
}  // namespace
B32_THUNK(_malloc_default_zone) { c.ret(defaultZone(c)); }
B32_THUNK(_malloc_create_zone) { c.ret(defaultZone(c)); }
B32_THUNK(_malloc_zone_from_ptr) { c.ret(defaultZone(c)); }
B32_THUNK(_malloc_destroy_zone) {}
B32_THUNK(_malloc_set_zone_name) {}
B32_THUNK(_malloc_zone_malloc) {
    c.args.ptr();
    c.ret(c.heap.alloc(c.args.u32()));
}
B32_THUNK(_malloc_zone_calloc) {
    c.args.ptr();
    uint32_t count = c.args.u32();
    c.ret(c.heap.calloc(count, c.args.u32()));
}
B32_THUNK(_malloc_zone_realloc) {
    c.args.ptr();
    GuestAddr p = c.args.ptr();
    c.ret(c.heap.realloc(p, c.args.u32()));
}
B32_THUNK(_malloc_zone_free) {
    c.args.ptr();
    if (GuestAddr p = c.args.ptr()) c.heap.free(p);
}
B32_THUNK(_malloc_zone_valloc) {
    c.args.ptr();
    c.ret(c.heap.alloc(c.args.u32(), 4096));
}
B32_THUNK(_malloc_good_size) { c.ret((c.args.u32() + 15) & ~15u); }
B32_THUNK(_getpriority) {
    int which = c.args.i32();
    c.ret(uint32_t(::getpriority(which, c.args.u32())));
}
B32_THUNK(_setpriority) { c.ret(0); }
B32_THUNK(_umask) { c.ret(::umask(mode_t(c.args.u32()))); }
B32_THUNK(_madvise) { c.ret(0); }
B32_THUNK(_tcflush) { c.ret(0); }
B32_THUNK(_sigsetmask) { c.ret(0); }
// Nothing delivers SIGALRM or the profiling signals to a guest.
B32_THUNK(_setitimer) { c.ret(0); }
B32_THUNK(_proc_name) { c.ret(0); }

// Environment: the host's, as guest strings, built once.
B32_THUNK(__NSGetEnviron) {
    static std::mutex lock;
    static GuestAddr holder = 0;
    std::lock_guard guard(lock);
    if (!holder) {
        size_t count = 0;
        while (environ[count]) count++;
        GuestAddr list = c.heap.calloc(uint32_t(count) + 1, 4);
        for (size_t i = 0; i < count; i++) c.mem.write<uint32_t>(list + uint32_t(i) * 4, c.rt.internString(environ[i]));
        holder = c.heap.calloc(1, 4);
        c.mem.write<uint32_t>(holder, list);
    }
    c.ret(holder);
}

// int getmntinfo(struct statfs **list, int flags): the mounted volumes, in the
// plain i386 struct statfs (272 bytes; see libsystem.cpp's _statfs). Disc
// volumes (images included) are read-only, as a disc mounts: a disc check
// looks for the flag.
B32_THUNK(_getmntinfo) {
    GuestAddr out = c.args.ptr();
    int flags = c.args.i32();
    struct statfs *mounts = nullptr;
    int count = ::getmntinfo(&mounts, flags);
    std::vector<discs::Volume> discs = discs::mounted();
    GuestAddr list = c.heap.calloc(uint32_t(std::max(count, 1)), 272);
    for (int i = 0; i < count; i++) {
        GuestAddr e = list + uint32_t(i) * 272;
        const struct statfs &m = mounts[i];
        c.mem.write<int32_t>(e + 4, int32_t(m.f_bsize));
        c.mem.write<int32_t>(e + 8, int32_t(m.f_iosize));
        const uint64_t counts[] = {m.f_blocks, m.f_bfree, m.f_bavail, m.f_files, m.f_ffree};
        for (int k = 0; k < 5; k++) c.mem.write<int32_t>(e + 12 + uint32_t(k) * 4, int32_t(std::min<uint64_t>(counts[k], INT32_MAX)));
        c.mem.write<int32_t>(e + 32, m.f_fsid.val[0]);
        c.mem.write<int32_t>(e + 36, m.f_fsid.val[1]);
        c.mem.write<uint32_t>(e + 40, m.f_owner);
        c.mem.write<int16_t>(e + 46, int16_t(m.f_type));
        c.mem.write<int32_t>(e + 48, int32_t(m.f_flags));
        strlcpy(c.mem.ptr<char>(e + 60), m.f_fstypename, 15);
        strlcpy(c.mem.ptr<char>(e + 75), m.f_mntonname, 90);
        strlcpy(c.mem.ptr<char>(e + 165), m.f_mntfromname, 90);
        for (const discs::Volume &d : discs)
            if (d.mount == m.f_mntonname) {
                c.mem.write<int32_t>(e + 48, int32_t(m.f_flags) | MNT_RDONLY);
                break;
            }
    }
    c.mem.write<uint32_t>(out, list);
    c.ret(uint32_t(count));
}

// --- things Boehm's collector asks about the image --------------------------------------

B32_THUNK(__dyld_bind_fully_image_containing_address) { c.ret(1); }  // everything is bound at load
B32_THUNK(_get_end) { c.ret(c.rt.image().end); }
B32_THUNK(_get_etext) {
    const Section *text = c.rt.image().section("__TEXT", "__text");
    c.ret(text ? text->addr + text->size : 0);
}
B32_THUNK(_backtrace_symbols) { c.ret(0); }

// div_t div(int, int)
B32_THUNK(_div) {
    StructResult out(c, 8);
    int a = c.args.i32(), b = c.args.i32();
    c.mem.write<int32_t>(out, b ? a / b : 0);
    c.mem.write<int32_t>(out + 4, b ? a % b : 0);
}

// --- user and group databases, reentrant forms ------------------------------------------
// The guest structs hold 32-bit pointers into the caller's buffer.

namespace {
// Copies a string into the guest buffer, advancing it; 0 if it doesn't fit.
GuestAddr bufferString(Call &c, GuestAddr &buffer, uint32_t &left, const char *s) {
    size_t n = std::strlen(s ? s : "") + 1;
    if (n > left) return 0;
    c.mem.copyIn(buffer, s ? s : "", n);
    GuestAddr at = buffer;
    buffer += uint32_t(n);
    left -= uint32_t(n);
    return at;
}

// struct passwd: name, passwd, uid, gid, change, class, gecos, dir, shell, expire.
int writePasswd(Call &c, GuestAddr out, GuestAddr buffer, uint32_t left, const struct passwd *pw) {
    GuestAddr name = bufferString(c, buffer, left, pw->pw_name), pass = bufferString(c, buffer, left, "*"),
              cls = bufferString(c, buffer, left, ""), gecos = bufferString(c, buffer, left, pw->pw_gecos),
              dir = bufferString(c, buffer, left, pw->pw_dir), shell = bufferString(c, buffer, left, pw->pw_shell);
    if (!name || !pass || !cls || !gecos || !dir || !shell) return ERANGE;
    const uint32_t words[10] = {name, pass, pw->pw_uid, pw->pw_gid, 0, cls, gecos, dir, shell, 0};
    c.mem.writeWords(out, words, sizeof words);
    return 0;
}

// struct group: name, passwd, gid, members (an empty list here).
int writeGroup(Call &c, GuestAddr out, GuestAddr buffer, uint32_t left, const struct group *gr) {
    if (left < 4) return ERANGE;
    GuestAddr members = buffer;
    c.mem.write<uint32_t>(members, 0);
    buffer += 4;
    left -= 4;
    GuestAddr name = bufferString(c, buffer, left, gr->gr_name), pass = bufferString(c, buffer, left, "*");
    if (!name || !pass) return ERANGE;
    const uint32_t words[4] = {name, pass, uint32_t(gr->gr_gid), members};
    c.mem.writeWords(out, words, sizeof words);
    return 0;
}

template <typename Entry, typename Write>
void finishLookup(Call &c, const Entry *entry, GuestAddr out, GuestAddr buffer, uint32_t size, GuestAddr result, Write write) {
    c.mem.write<uint32_t>(result, 0);
    if (!entry) {
        c.ret(0);
        return;
    }
    int error = write(c, out, buffer, size, entry);
    if (!error) c.mem.write<uint32_t>(result, out);
    c.ret(uint32_t(error));
}
}  // namespace

// int getpwuid_r(uid_t, struct passwd *, char *buffer, size_t, struct passwd **result)
B32_THUNK(_getpwuid_r) {
    uid_t uid = c.args.u32();
    GuestAddr out = c.args.ptr(), buffer = c.args.ptr();
    uint32_t size = c.args.u32();
    finishLookup(c, ::getpwuid(uid), out, buffer, size, c.args.ptr(), writePasswd);
}
B32_THUNK(_getpwnam_r) {
    const char *name = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr(), buffer = c.args.ptr();
    uint32_t size = c.args.u32();
    finishLookup(c, ::getpwnam(name), out, buffer, size, c.args.ptr(), writePasswd);
}
B32_THUNK(_getgrgid_r) {
    gid_t gid = c.args.u32();
    GuestAddr out = c.args.ptr(), buffer = c.args.ptr();
    uint32_t size = c.args.u32();
    finishLookup(c, ::getgrgid(gid), out, buffer, size, c.args.ptr(), writeGroup);
}
B32_THUNK(_getgrnam_r) {
    const char *name = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr(), buffer = c.args.ptr();
    uint32_t size = c.args.u32();
    finishLookup(c, ::getgrnam(name), out, buffer, size, c.args.ptr(), writeGroup);
}
// struct group *getgrgid(gid_t) and getgrnam(const char *): one entry per thread, as libc keeps.
namespace {
void staticGroup(Call &c, const struct group *gr) {
    constexpr uint32_t kBuffer = 1024;
    static thread_local GuestAddr entry = 0;
    if (!entry) entry = c.heap.calloc(1, 16 + kBuffer);
    if (!gr || writeGroup(c, entry, entry + 16, kBuffer, gr)) {
        c.ret(0);
        return;
    }
    c.ret(entry);
}
}  // namespace
B32_THUNK(_getgrgid) { staticGroup(c, ::getgrgid(gid_t(c.args.u32()))); }
B32_THUNK(_getgrnam) { staticGroup(c, ::getgrnam(c.mem.cstr(c.args.ptr()))); }
B32_THUNK(_gethostid) { c.ret(uint32_t(::gethostid())); }
// uint32_t notify_post(const char *name): the host's notification center has the name too.
B32_THUNK(_notify_post) { c.ret(::notify_post(c.mem.cstr(c.args.ptr()))); }
B32_THUNK(_getprotobyname) { c.ret(0); }

// --- architectures (NXGetArchInfoFromCpuType and friends) -------------------------------------
// const NXArchInfo *: { const char *name; cpu_type_t cputype; cpu_subtype_t cpusubtype;
// enum NXByteOrder byteorder; const char *description; }, from a table in guest memory.

namespace {
struct ArchEntry {
    const char *name;
    int32_t cpu, subtype;
    uint32_t order;  // NX_LittleEndian 1, NX_BigEndian 2
    const char *description;
};
constexpr ArchEntry kArchs[] = {
    {"ppc", 18, 0, 2, "PowerPC"},           {"ppc750", 18, 9, 2, "PowerPC 750"},
    {"ppc7400", 18, 10, 2, "PowerPC 7400"}, {"ppc7450", 18, 11, 2, "PowerPC 7450"},
    {"ppc970", 18, 100, 2, "PowerPC 970"},  {"ppc64", 0x01000012, 0, 2, "PowerPC 64-bit"},
    {"i386", 7, 3, 1, "Intel 80x86"},       {"x86_64", 0x01000007, 3, 1, "Intel x86-64"},
    {"arm", 12, 0, 1, "ARM"},
};
constexpr uint32_t kArchCount = sizeof kArchs / sizeof kArchs[0];
GuestAddr archTable(Call &c) {
    static GuestAddr table = [&] {
        GuestAddr t = c.heap.calloc(kArchCount + 1, 20);
        for (uint32_t i = 0; i < kArchCount; i++) {
            const ArchEntry &a = kArchs[i];
            const uint32_t words[5] = {c.rt.internString(a.name), uint32_t(a.cpu), uint32_t(a.subtype), a.order,
                                       c.rt.internString(a.description)};
            c.mem.writeWords(t + i * 20, words, sizeof words);
        }
        return t;
    }();
    return table;
}
}  // namespace

// const NXArchInfo *NXGetArchInfoFromCpuType(cpu_type_t, cpu_subtype_t): the subtype's entry, or the
// type's general one for CPU_SUBTYPE_MULTIPLE (-1) or a subtype not in the table.
B32_THUNK(_NXGetArchInfoFromCpuType) {
    int32_t cpu = c.args.i32(), subtype = c.args.i32();
    GuestAddr table = archTable(c);
    int found = -1;
    for (uint32_t i = 0; i < kArchCount && found < 0; i++)
        if (kArchs[i].cpu == cpu && kArchs[i].subtype == (subtype & 0x00ffffff)) found = int(i);
    for (uint32_t i = 0; i < kArchCount && found < 0; i++)
        if (kArchs[i].cpu == cpu) found = int(i);
    c.ret(found < 0 ? 0 : table + uint32_t(found) * 20);
}
B32_THUNK(_NXGetArchInfoFromName) {
    std::string name = c.mem.cstr(c.args.ptr());
    GuestAddr table = archTable(c);
    for (uint32_t i = 0; i < kArchCount; i++)
        if (name == kArchs[i].name) return c.ret(table + i * 20);
    c.ret(0);
}
// cpu_type_t _CSGetProcessorArchitecture(void): CoreServices' name for the CPU, the guest's.
B32_THUNK(__CSGetProcessorArchitecture) {
#if defined(B32_GUEST_PPC)
    c.ret(18);  // CPU_TYPE_POWERPC
#else
    c.ret(7);   // CPU_TYPE_I386
#endif
}
B32_THUNK(_NXGetAllArchInfos) { c.ret(archTable(c)); }

// --- iconv: descriptors are 64-bit host pointers behind small guest handles -------------

namespace {
std::mutex iconvLock;
std::unordered_map<uint32_t, iconv_t> iconvs;
uint32_t nextIconv = 1;
}  // namespace

B32_THUNK(_iconv_open) {
    const char *to = c.mem.cstr(c.args.ptr());
    iconv_t cd = ::iconv_open(to, c.mem.cstr(c.args.ptr()));
    if (cd == iconv_t(-1)) {
        setGuestErrno(c, errno);
        c.ret(uint32_t(-1));
        return;
    }
    std::lock_guard guard(iconvLock);
    uint32_t handle = nextIconv++;
    iconvs[handle] = cd;
    c.ret(handle);
}
B32_THUNK(_iconv_close) {
    std::lock_guard guard(iconvLock);
    auto it = iconvs.find(c.args.u32());
    if (it == iconvs.end()) {
        c.ret(uint32_t(-1));
        return;
    }
    ::iconv_close(it->second);
    iconvs.erase(it);
    c.ret(0);
}
// size_t iconv(iconv_t, char **in, size_t *inLeft, char **out, size_t *outLeft)
B32_THUNK(_iconv) {
    iconv_t cd;
    {
        std::lock_guard guard(iconvLock);
        cd = iconvs.at(c.args.u32());
    }
    GuestAddr inPtr = c.args.ptr(), inLeftPtr = c.args.ptr(), outPtr = c.args.ptr(), outLeftPtr = c.args.ptr();
    GuestAddr inGuest = inPtr ? c.mem.read<uint32_t>(inPtr) : 0, outGuest = outPtr ? c.mem.read<uint32_t>(outPtr) : 0;
    char *in = inGuest ? c.mem.ptr<char>(inGuest) : nullptr, *out = outGuest ? c.mem.ptr<char>(outGuest) : nullptr;
    char *inStart = in, *outStart = out;
    size_t inLeft = inLeftPtr ? c.mem.read<uint32_t>(inLeftPtr) : 0, outLeft = outLeftPtr ? c.mem.read<uint32_t>(outLeftPtr) : 0;
    size_t result = ::iconv(cd, inPtr ? &in : nullptr, inLeftPtr ? &inLeft : nullptr, outPtr ? &out : nullptr, outLeftPtr ? &outLeft : nullptr);
    if (result == size_t(-1)) setGuestErrno(c, errno);
    if (inPtr) c.mem.write<uint32_t>(inPtr, inGuest + uint32_t(in - inStart));
    if (outPtr) c.mem.write<uint32_t>(outPtr, outGuest + uint32_t(out - outStart));
    if (inLeftPtr) c.mem.write<uint32_t>(inLeftPtr, uint32_t(inLeft));
    if (outLeftPtr) c.mem.write<uint32_t>(outLeftPtr, uint32_t(outLeft));
    c.ret(uint32_t(result));
}
B32_THUNK(_locale_charset) { c.ret(c.rt.internString("UTF-8")); }
B32_THUNK(_libiconv) { c.ret(0); }

// --- kqueue: struct kevent has a 32-bit ident and udata in the guest -------------------

B32_THUNK(_kqueue) { retErrno(c, ::kqueue()); }
// int kevent(kq, changes, nchanges, events, nevents, const struct timespec *timeout)
B32_THUNK(_kevent) {
    int kq = c.args.i32();
    GuestAddr changesAddr = c.args.ptr();
    int nchanges = c.args.i32();
    GuestAddr eventsAddr = c.args.ptr();
    int nevents = c.args.i32();
    GuestAddr timeoutAddr = c.args.ptr();
    // Guest: ident, filter(16), flags(16), fflags, data, udata: 20 bytes.
    std::vector<struct kevent> changes(size_t(nchanges > 0 ? nchanges : 0)), events(size_t(nevents > 0 ? nevents : 0));
    for (int i = 0; i < nchanges; i++) {
        GuestAddr e = changesAddr + uint32_t(i) * 20;
        changes[size_t(i)] = {c.mem.read<uint32_t>(e), c.mem.read<int16_t>(e + 4), c.mem.read<uint16_t>(e + 6),
                              c.mem.read<uint32_t>(e + 8), c.mem.read<int32_t>(e + 12), reinterpret_cast<void *>(uintptr_t(c.mem.read<uint32_t>(e + 16)))};
    }
    struct timespec timeout;
    if (timeoutAddr) timeout = {c.mem.read<int32_t>(timeoutAddr), c.mem.read<int32_t>(timeoutAddr + 4)};
    int n = ::kevent(kq, changes.data(), nchanges, events.data(), nevents, timeoutAddr ? &timeout : nullptr);
    for (int i = 0; i < n; i++) {
        GuestAddr e = eventsAddr + uint32_t(i) * 20;
        c.mem.write<uint32_t>(e, uint32_t(events[size_t(i)].ident));
        c.mem.write<int16_t>(e + 4, events[size_t(i)].filter);
        c.mem.write<uint16_t>(e + 6, events[size_t(i)].flags);
        c.mem.write<uint32_t>(e + 8, events[size_t(i)].fflags);
        c.mem.write<int32_t>(e + 12, int32_t(events[size_t(i)].data));
        c.mem.write<uint32_t>(e + 16, uint32_t(uintptr_t(events[size_t(i)].udata)));
    }
    retErrno(c, n);
}

// --- System V IPC and POSIX shared memory: Mono's cross-process handle table, which it
// does without when these fail. They'd otherwise leave objects behind in the system. -----

namespace {
void unavailable(Call &c) {
    setGuestErrno(c, ENOSYS);
    c.ret(uint32_t(-1));
}
}  // namespace

B32_THUNK(_ftok) { unavailable(c); }
B32_THUNK(_semget) { unavailable(c); }
B32_THUNK(_semop) { unavailable(c); }
B32_THUNK(_semctl) { unavailable(c); }
B32_THUNK(_shm_open) { unavailable(c); }
B32_THUNK(_shm_unlink) { unavailable(c); }
B32_THUNK(_sendmsg) { unavailable(c); }
B32_THUNK(_recvmsg) { unavailable(c); }

// --- Multiprocessing Services: critical regions and counting semaphores -----------------

namespace {
constexpr int32_t kDurationImmediate = 0, kDurationForever = 0x7FFFFFFF;
constexpr uint32_t kMPTimeoutErr = uint32_t(-29296), kMPInvalidIDErr = uint32_t(-29299);

struct Semaphore {
    std::mutex lock;
    std::condition_variable changed;
    uint32_t value, maximum;
};

std::mutex mpLock;
std::unordered_map<uint32_t, std::recursive_timed_mutex *> mpRegions;
std::unordered_map<uint32_t, Semaphore *> mpSemaphores;
uint32_t nextMpId = 0x4D500001;

// A Duration counts milliseconds, or microseconds when negative.
std::chrono::microseconds waitFor(int32_t duration) {
    return duration < 0 ? std::chrono::microseconds(-int64_t(duration)) : std::chrono::milliseconds(duration);
}
std::recursive_timed_mutex *region(uint32_t id) {
    std::lock_guard guard(mpLock);
    auto it = mpRegions.find(id);
    return it == mpRegions.end() ? nullptr : it->second;
}
Semaphore *semaphore(uint32_t id) {
    std::lock_guard guard(mpLock);
    auto it = mpSemaphores.find(id);
    return it == mpSemaphores.end() ? nullptr : it->second;
}
}  // namespace

B32_THUNK(_MPCreateCriticalRegion) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(mpLock);
    uint32_t id = nextMpId++;
    mpRegions[id] = new std::recursive_timed_mutex;
    c.mem.write<uint32_t>(out, id);
    c.ret(0);
}
B32_THUNK(_MPDeleteCriticalRegion) {
    uint32_t id = c.args.u32();
    std::lock_guard guard(mpLock);
    auto it = mpRegions.find(id);
    if (it == mpRegions.end()) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    delete it->second;
    mpRegions.erase(it);
    c.ret(0);
}
B32_THUNK(_MPEnterCriticalRegion) {
    auto *r = region(c.args.u32());
    int32_t timeout = c.args.i32();
    if (!r) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    if (timeout == kDurationForever) {
        r->lock();
    } else if (timeout == kDurationImmediate ? !r->try_lock() : !r->try_lock_for(waitFor(timeout))) {
        c.ret(kMPTimeoutErr);
        return;
    }
    c.ret(0);
}
B32_THUNK(_MPExitCriticalRegion) {
    auto *r = region(c.args.u32());
    if (!r) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    r->unlock();
    c.ret(0);
}
// OSStatus MPCreateSemaphore(maximum, initial, MPSemaphoreID *out)
B32_THUNK(_MPCreateSemaphore) {
    uint32_t maximum = c.args.u32(), initial = c.args.u32();
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(mpLock);
    uint32_t id = nextMpId++;
    auto *s = new Semaphore;
    s->value = initial;
    s->maximum = maximum;
    mpSemaphores[id] = s;
    c.mem.write<uint32_t>(out, id);
    c.ret(0);
}
B32_THUNK(_MPDeleteSemaphore) {
    uint32_t id = c.args.u32();
    std::lock_guard guard(mpLock);
    auto it = mpSemaphores.find(id);
    if (it == mpSemaphores.end()) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    delete it->second;
    mpSemaphores.erase(it);
    c.ret(0);
}
B32_THUNK(_MPSignalSemaphore) {
    auto *s = semaphore(c.args.u32());
    if (!s) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    std::lock_guard guard(s->lock);
    if (s->value >= s->maximum) {
        c.ret(uint32_t(-29295));  // kMPInsufficientResourcesErr
        return;
    }
    s->value++;
    s->changed.notify_one();
    c.ret(0);
}
B32_THUNK(_MPWaitOnSemaphore) {
    auto *s = semaphore(c.args.u32());
    int32_t timeout = c.args.i32();
    if (!s) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    std::unique_lock guard(s->lock);
    auto ready = [&] { return s->value > 0; };
    if (timeout == kDurationForever)
        s->changed.wait(guard, ready);
    else if (timeout == kDurationImmediate ? !ready() : !s->changed.wait_for(guard, waitFor(timeout), ready)) {
        c.ret(kMPTimeoutErr);
        return;
    }
    s->value--;
    c.ret(0);
}

// --- Multiprocessing Services: tasks, message queues, events and aligned memory -----------------------

namespace {
struct Queue {
    std::mutex lock;
    std::condition_variable changed;
    std::deque<std::array<uint32_t, 3>> messages;
};
struct Event {
    std::mutex lock;
    std::condition_variable changed;
    uint32_t flags = 0;
};
std::unordered_map<uint32_t, Queue *> mpQueues;
std::unordered_map<uint32_t, Event *> mpEvents;
thread_local uint32_t currentTask = 0;
// The task each thread MPCreateTask started is, by its pthread_t, for MPCurrentTaskID.
std::unordered_map<GuestAddr, uint32_t> &taskOfThread() {
    static std::unordered_map<GuestAddr, uint32_t> map;
    return map;
}

Queue *queue(uint32_t id) {
    std::lock_guard guard(mpLock);
    auto it = mpQueues.find(id);
    return it == mpQueues.end() ? nullptr : it->second;
}
Event *event(uint32_t id) {
    std::lock_guard guard(mpLock);
    auto it = mpEvents.find(id);
    return it == mpEvents.end() ? nullptr : it->second;
}
void notify(Queue *q, uint32_t a, uint32_t b, uint32_t c) {
    std::lock_guard guard(q->lock);
    q->messages.push_back({a, b, c});
    q->changed.notify_one();
}
}  // namespace

// OSStatus MPCreateQueue(MPQueueID *), MPDeleteQueue(MPQueueID)
B32_THUNK(_MPCreateQueue) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(mpLock);
    uint32_t id = nextMpId++;
    mpQueues[id] = new Queue;
    c.mem.write<uint32_t>(out, id);
    c.ret(0);
}
B32_THUNK(_MPDeleteQueue) {
    uint32_t id = c.args.u32();
    std::lock_guard guard(mpLock);
    // Kept: a task blocked on it would wake to freed memory. A deleted queue is an unknown one.
    c.ret(mpQueues.erase(id) ? 0 : kMPInvalidIDErr);
}
// OSStatus MPNotifyQueue(MPQueueID, void *param1, void *param2, void *param3)
B32_THUNK(_MPNotifyQueue) {
    Queue *q = queue(c.args.u32());
    uint32_t a = c.args.u32(), b = c.args.u32(), d = c.args.u32();
    if (!q) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    notify(q, a, b, d);
    c.ret(0);
}
// OSStatus MPWaitOnQueue(MPQueueID, void **param1, void **param2, void **param3, Duration)
B32_THUNK(_MPWaitOnQueue) {
    Queue *q = queue(c.args.u32());
    GuestAddr out[3] = {c.args.ptr(), c.args.ptr(), c.args.ptr()};
    int32_t timeout = c.args.i32();
    if (!q) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    std::unique_lock guard(q->lock);
    auto ready = [&] { return !q->messages.empty(); };
    if (timeout == kDurationForever)
        q->changed.wait(guard, ready);
    else if (timeout == kDurationImmediate ? !ready() : !q->changed.wait_for(guard, waitFor(timeout), ready)) {
        c.ret(kMPTimeoutErr);
        return;
    }
    std::array<uint32_t, 3> message = q->messages.front();
    q->messages.pop_front();
    for (int i = 0; i < 3; i++)
        if (out[i]) c.mem.write<uint32_t>(out[i], message[size_t(i)]);
    c.ret(0);
}

// OSStatus MPCreateEvent(MPEventID *), MPDeleteEvent(MPEventID)
B32_THUNK(_MPCreateEvent) {
    GuestAddr out = c.args.ptr();
    std::lock_guard guard(mpLock);
    uint32_t id = nextMpId++;
    mpEvents[id] = new Event;
    c.mem.write<uint32_t>(out, id);
    c.ret(0);
}
B32_THUNK(_MPDeleteEvent) {
    uint32_t id = c.args.u32();
    std::lock_guard guard(mpLock);
    c.ret(mpEvents.erase(id) ? 0 : kMPInvalidIDErr);
}
// OSStatus MPSetEvent(MPEventID, MPEventFlags): the flags are added to the event's.
B32_THUNK(_MPSetEvent) {
    Event *e = event(c.args.u32());
    uint32_t flags = c.args.u32();
    if (!e) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    std::lock_guard guard(e->lock);
    e->flags |= flags;
    e->changed.notify_all();
    c.ret(0);
}
// OSStatus MPWaitForEvent(MPEventID, MPEventFlags *flags, Duration): until some flag is set, which are then
// the caller's and cleared.
B32_THUNK(_MPWaitForEvent) {
    Event *e = event(c.args.u32());
    GuestAddr out = c.args.ptr();
    int32_t timeout = c.args.i32();
    if (!e) {
        c.ret(kMPInvalidIDErr);
        return;
    }
    std::unique_lock guard(e->lock);
    auto ready = [&] { return e->flags != 0; };
    if (timeout == kDurationForever)
        e->changed.wait(guard, ready);
    else if (timeout == kDurationImmediate ? !ready() : !e->changed.wait_for(guard, waitFor(timeout), ready)) {
        c.ret(kMPTimeoutErr);
        return;
    }
    if (out) c.mem.write<uint32_t>(out, e->flags);
    e->flags = 0;
    c.ret(0);
}

// OSStatus MPCreateTask(TaskProc entry, void *parameter, ByteCount stackSize, MPQueueID notifyQueue,
//                       void *terminationParameter1, void *terminationParameter2, MPTaskOptions, MPTaskID *):
// a guest thread running entry(parameter). When it ends, the notify queue (if any) gets the two termination
// parameters and what entry returned (or MPExit was given).
B32_THUNK(_MPCreateTask) {
    GuestAddr entry = c.args.ptr();
    uint32_t parameter = c.args.u32();
    c.args.u32();  // stack size: a guest thread's stack is the runtime's to size
    uint32_t notifyQueue = c.args.u32(), term1 = c.args.u32(), term2 = c.args.u32();
    c.args.u32();
    GuestAddr out = c.args.ptr();
    uint32_t id;
    {
        std::lock_guard guard(mpLock);
        id = nextMpId++;
    }
    if (out) c.mem.write<uint32_t>(out, id);  // before it runs, as the task may look itself up
    Queue *q = notifyQueue ? queue(notifyQueue) : nullptr;
    GuestAddr thread = startGuestThread(c.rt, entry, parameter, [q, term1, term2](uint32_t result) {
        if (q) notify(q, term1, term2, result);
    });
    std::lock_guard guard(mpLock);
    taskOfThread()[thread] = id;
    c.ret(0);
}
// MPTaskID MPCurrentTaskID(void): the task a thread is; a thread MPCreateTask didn't start is a task too,
// numbered the first time it asks.
B32_THUNK(_MPCurrentTaskID) {
    if (!currentTask) {
        GuestAddr self = startedGuestThread();
        std::lock_guard guard(mpLock);
        auto it = taskOfThread().find(self);
        currentTask = it != taskOfThread().end() ? it->second : nextMpId++;
    }
    c.ret(currentTask);
}
// void MPExit(OSStatus status): the task ends here, with that status for its notify queue.
B32_THUNK(_MPExit) { throw Runtime::ThreadExit{c.args.u32()}; }
// OSStatus MPSetTaskWeight(MPTaskID, MPTaskWeight): the host schedules its threads as it sees fit.
B32_THUNK(_MPSetTaskWeight) {
    c.args.u32();
    c.args.u32();
    c.ret(0);
}
// void MPYield(void)
B32_THUNK(_MPYield) { std::this_thread::yield(); }

// LogicalAddress MPAllocateAligned(ByteCount size, UInt8 alignment, MPOpaqueID options): alignment is a power
// of two by its exponent (kMPAllocateDefaultAligned, 0, being eight bytes), and the clear option (1) zeroes it.
B32_THUNK(_MPAllocateAligned) {
    uint32_t size = c.args.u32(), exponent = c.args.u32() & 0xff, options = c.args.u32();
    uint32_t alignment = 1u << std::clamp<uint32_t>(exponent ? exponent : 3, 3, 12);
    GuestAddr block = c.heap.alloc(std::max<uint32_t>(size, 1), std::max<uint32_t>(alignment, 16));
    if (block && (options & 1)) {
        std::vector<uint8_t> zeros(size, 0);
        c.mem.copyIn(block, zeros.data(), size);
    }
    c.ret(block);
}
// void MPFree(LogicalAddress)
B32_THUNK(_MPFree) {
    if (GuestAddr block = c.args.ptr()) c.heap.free(block);
}

// --- launchd and the bootstrap server ------------------------------------------------
// A guest can't reach host services by Mach message, so it finds none of them.

namespace {
constexpr uint32_t kBootstrapUnknownService = 1102;
}
B32_THUNK(_bootstrap_look_up) { c.ret(kBootstrapUnknownService); }
B32_THUNK(_launch_data_alloc) { c.ret(0); }
B32_THUNK(_launch_data_new_string) { c.ret(0); }
B32_THUNK(_launch_data_dict_insert) { c.ret(0); }
B32_THUNK(_launch_data_free) {}
B32_THUNK(_launch_msg) { c.ret(0); }

// --- CarbonCore's atomic arithmetic (DriverSynchronization.h) ----------------------------------------
// Each answers the value from before.

// SInt32 IncrementAtomic(SInt32 *), DecrementAtomic(SInt32 *), AddAtomic(SInt32 amount, SInt32 *)
B32_THUNK(_IncrementAtomic) { c.ret(uint32_t(c.mem.atomicUpdate<int32_t>(c.args.ptr(), [](int32_t v) { return v + 1; }))); }
B32_THUNK(_DecrementAtomic) { c.ret(uint32_t(c.mem.atomicUpdate<int32_t>(c.args.ptr(), [](int32_t v) { return v - 1; }))); }
B32_THUNK(_AddAtomic) {
    int32_t amount = c.args.i32();
    c.ret(uint32_t(c.mem.atomicUpdate<int32_t>(c.args.ptr(), [amount](int32_t v) { return v + amount; })));
}

// Boolean CompareAndSwap(UInt32 old, UInt32 new, UInt32 *value): the swap, if the value was still the old one.
B32_THUNK(_CompareAndSwap) {
    uint32_t expected = c.args.u32(), desired = c.args.u32();
    c.ret(c.mem.atomicCompareExchange<uint32_t>(c.args.ptr(), expected, desired) ? 1 : 0);
}
// Boolean TestAndSet(UInt32 bit, void *start), TestAndClear: the bit numbered from the first byte's high bit;
// the answer is whether it was set before.
namespace {
// Atomically, on the aligned word that holds the byte: the mask is laid out as the byte's place in memory.
bool changeBit(Call &c, bool set) {
    uint32_t bit = c.args.u32();
    GuestAddr byte = c.args.ptr() + bit / 8;
    uint8_t layout[4] = {0, 0, 0, 0};
    layout[byte % 4] = uint8_t(0x80 >> (bit % 8));
    uint32_t raw;
    std::memcpy(&raw, layout, 4);
    uint32_t mask = GuestMemory::inGuestOrder(raw);
    uint32_t before = c.mem.atomicUpdate<uint32_t>(byte & ~3u, [&](uint32_t v) { return set ? v | mask : v & ~mask; });
    return before & mask;
}
}  // namespace
B32_THUNK(_TestAndSet) { c.ret(changeBit(c, true)); }
B32_THUNK(_TestAndClear) { c.ret(changeBit(c, false)); }

// --- the 80-bit extended (fp.h's extended80: an exponent word, then the mantissa in four words) ------------

// void dtox80(const double *x, extended80 *out): the double exactly, with the 64-bit mantissa's integer bit.
B32_THUNK(_dtox80) {
    GuestAddr in = c.args.ptr(), out = c.args.ptr();
    double x = c.mem.read<double>(in);
    uint16_t sign = std::signbit(x) ? 0x8000 : 0, exponent = 0;
    uint64_t mantissa = 0;
    if (std::isnan(x)) {
        exponent = 0x7fff;
        mantissa = 0xC000000000000000ull;
    } else if (std::isinf(x)) {
        exponent = 0x7fff;
        mantissa = 0x8000000000000000ull;
    } else if (x != 0) {
        int e = 0;
        double fraction = std::frexp(std::fabs(x), &e);  // [0.5, 1)
        exponent = uint16_t(e - 1 + 16383);
        mantissa = uint64_t(std::ldexp(fraction, 64));
    }
    const uint16_t words[5] = {uint16_t(sign | exponent), uint16_t(mantissa >> 48), uint16_t(mantissa >> 32), uint16_t(mantissa >> 16),
                               uint16_t(mantissa)};
    c.mem.writeArray<uint16_t>(out, words, 5);
}
// double x80tod(const extended80 *)
B32_THUNK(_x80tod) {
    GuestAddr in = c.args.ptr();
    std::vector<uint16_t> words = c.mem.readArray<uint16_t>(in, 5);
    int exponent = words[0] & 0x7fff;
    uint64_t mantissa = uint64_t(words[1]) << 48 | uint64_t(words[2]) << 32 | uint64_t(words[3]) << 16 | words[4];
    double x = exponent == 0x7fff ? (mantissa << 1 ? NAN : INFINITY) : std::ldexp(double(mantissa), exponent - 16383 - 63);
    c.retF64((words[0] & 0x8000) ? -x : x);
}

// --- fp.h's decimal conversions (the old SANE interface, still in libSystem) --------------------------------

// void num2dec(const decform *format, double_t x, decimal *out).
// decform: a style byte (0 for a count of significant digits, 1 for a count of digits after the point), a
// spare byte, the count as a short. decimal: a sign byte, a spare byte, the exponent as a short, then the
// digits as a length byte and up to 36 characters. The value is the digits read as a whole number, times
// ten to the exponent. Zero is the one digit "0", an infinity is "I" and a NaN is "N".
B32_THUNK(_num2dec) {
    constexpr int kMostDigits = 36;
    GuestAddr format = c.args.ptr();
    double x = c.args.f64();
    GuestAddr out = c.args.ptr();
    bool fixed = c.mem.read<uint8_t>(format) == 1;
    int count = c.mem.read<int16_t>(format + 2);
    std::string digits;
    int exponent = 0;
    double magnitude = std::fabs(x);
    if (std::isnan(x)) {
        digits = "N";
    } else if (std::isinf(x)) {
        digits = "I";
    } else if (magnitude == 0) {
        digits = "0";
    } else {
        char text[512];
        if (fixed) {
            int places = std::max(0, std::min(count, 100));
            std::snprintf(text, sizeof text, "%.*f", places, magnitude);
            for (const char *p = text; *p; p++)
                if (*p != '.') digits += *p;
            digits.erase(0, std::min(digits.find_first_not_of('0'), digits.size()));
            exponent = -places;
            if (digits.empty()) {
                digits = "0";
                exponent = 0;
            }
        }
        // That many significant digits, which is also what a fixed form too long to hold comes down to.
        if (!fixed || int(digits.size()) > kMostDigits) {
            int significant = fixed ? kMostDigits : std::max(1, std::min(count, kMostDigits));
            std::snprintf(text, sizeof text, "%.*e", significant - 1, magnitude);
            digits.clear();
            const char *p = text;
            for (; *p && *p != 'e'; p++)
                if (*p != '.') digits += *p;
            exponent = std::atoi(p + 1) - (significant - 1);
        }
    }
    c.mem.write<uint8_t>(out, std::signbit(x) ? 1 : 0);
    c.mem.write<uint8_t>(out + 1, 0);
    c.mem.write<int16_t>(out + 2, int16_t(exponent));
    c.mem.write<uint8_t>(out + 4, uint8_t(digits.size()));
    c.mem.copyIn(out + 5, digits.data(), digits.size());
}

// char *strsep(char **stringp, const char *delim): the token at *stringp, ended at the first delimiter (which
// becomes a NUL), and *stringp moved past it, or to NULL after the last token.
B32_THUNK(_strsep) {
    GuestAddr stringp = c.args.ptr(), delim = c.args.ptr();
    GuestAddr token = stringp ? c.mem.read<uint32_t>(stringp) : 0;
    if (!token) {
        c.ret(0);
        return;
    }
    const char *delimiters = delim ? c.mem.cstr(delim) : "";
    GuestAddr p = token;
    for (;; p++) {
        char ch = char(c.mem.read<uint8_t>(p));
        if (ch && !std::strchr(delimiters, ch)) continue;
        if (ch) {
            c.mem.write<uint8_t>(p, 0);
            c.mem.write<uint32_t>(stringp, p + 1);
        } else {
            c.mem.write<uint32_t>(stringp, 0);
        }
        break;
    }
    c.ret(token);
}
