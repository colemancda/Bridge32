// libSystem calls that only Mac apps use, or that iOS apps were kept from
// (Mono's runtime, SDL and friends on the i386 guest).

#include "Thunks.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <grp.h>
#include <iconv.h>
#include <mach/mach.h>
#include <mach/semaphore.h>
#include <netdb.h>
#include <pwd.h>
#include <signal.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
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
    c.ret(::mach_port_allocate(mach_task_self(), right, c.mem.ptr<mach_port_name_t>(c.args.ptr())));
}
B32_THUNK(_mach_port_insert_right) {
    c.args.u32();
    uint32_t name = c.args.u32(), poly = c.args.u32();
    c.ret(::mach_port_insert_right(mach_task_self(), name, poly, c.args.u32()));
}
B32_THUNK(_task_set_exception_ports) { c.ret(KERN_SUCCESS); }
// mach_msg_return_t mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify)
B32_THUNK(_mach_msg) {
    auto *msg = c.mem.ptr<mach_msg_header_t>(c.args.ptr());
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

B32_THUNK(_dup2) {
    int a = c.args.i32();
    retErrno(c, ::dup2(a, c.args.i32()));
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
    c.mem.copyIn(out, words, sizeof words);
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
    c.mem.copyIn(out, words, sizeof words);
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
B32_THUNK(_getprotobyname) { c.ret(0); }

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
