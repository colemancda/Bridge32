// POSIX and Mach odds and ends: files and directories, time, Mach timing and
// semaphores, setjmp/longjmp, zlib and sscanf. Structures whose 32-bit
// layout differs from the host's (stat, statvfs, tm, z_stream) are converted
// field by field.

#include "Format.h"
#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/semaphore.h>
#include <poll.h>
#include <pwd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/file.h>
#include <sys/uio.h>
#include <sys/statvfs.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include <utime.h>
#include <zlib.h>

#include <cerrno>
#include <cstdio>
#include <algorithm>
#include <cstring>
#include <ctime>
#include <cwchar>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

using namespace b32;

// --- files ------------------------------------------------------------------------------

// B32_TRACE_FILES=1 logs file system calls.
const bool traceFiles = getenv("B32_TRACE_FILES") != nullptr;
#define B32_FILE_LOG(...) \
    do {                  \
        if (traceFiles) log(__VA_ARGS__); \
    } while (0)

B32_THUNK(_open) {
    const char *path = c.mem.cstr(c.args.ptr());
    int flags = c.args.i32();
    int mode = c.args.i32();
    int fd = ::open(path, flags, mode);
    if (fd < 0) log("open(%s) failed: %s", path, std::strerror(errno));
    B32_FILE_LOG("open(%s, 0x%x) = %d", path, flags, fd);
    c.ret(uint32_t(fd));
}

// off_t lseek(int fd, off_t offset, int whence): off_t is 64-bit.
B32_THUNK(_lseek) {
    int fd = c.args.i32();
    off_t offset = off_t(c.args.u64());
    int whence = c.args.i32();
    off_t result = ::lseek(fd, offset, whence);
    B32_FILE_LOG("lseek(%d, %lld, %d) = %lld", fd, (long long)offset, whence, (long long)result);
    c.ret64(uint64_t(result));
}

B32_THUNK(_fcntl) {
    int fd = c.args.i32();
    int cmd = c.args.i32();
    c.ret(uint32_t(::fcntl(fd, cmd, c.args.i32())));
}

#define B32_PATH_CALL(symbol, call)                       \
    B32_THUNK(symbol) {                                   \
        const char *path = c.mem.cstr(c.args.ptr());      \
        c.ret(uint32_t(call));                            \
    }
B32_PATH_CALL(_unlink, ::unlink(path))
B32_PATH_CALL(_remove, std::remove(path))
B32_PATH_CALL(_rmdir, ::rmdir(path))
B32_THUNK(_chdir) {
    const char *path = c.mem.cstr(c.args.ptr());
    int rc = ::chdir(path);
    B32_FILE_LOG("chdir(%s) = %d", path, rc);
    c.ret(uint32_t(rc));
}
B32_THUNK(_mkdir) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::mkdir(path, mode_t(c.args.u32()))));
}
B32_THUNK(_chmod) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::chmod(path, mode_t(c.args.u32()))));
}
B32_THUNK(_rename) {
    const char *from = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(std::rename(from, c.mem.cstr(c.args.ptr()))));
}
B32_THUNK(_truncate) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::truncate(path, off_t(c.args.u64()))));
}
B32_THUNK(_access) {
    const char *path = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::access(path, c.args.i32())));
}

// The guest's struct stat (64-bit inode variant, 32-bit time_t and long):
//   dev 0, mode 4, nlink 6, ino 8, uid 16, gid 20, rdev 24, atime 28, mtime 36,
//   ctime 44, birthtime 52, size 60, blocks 68, blksize 76, flags 80, gen 84
namespace {
void writeStat(GuestMemory &mem, GuestAddr out, const struct stat &st) {
    std::memset(mem.ptr<uint8_t>(out), 0, 108);
    mem.write<int32_t>(out, int32_t(st.st_dev));
    mem.write<uint16_t>(out + 4, st.st_mode);
    mem.write<uint16_t>(out + 6, st.st_nlink);
    mem.write<uint64_t>(out + 8, st.st_ino);
    mem.write<uint32_t>(out + 16, st.st_uid);
    mem.write<uint32_t>(out + 20, st.st_gid);
    mem.write<int32_t>(out + 24, int32_t(st.st_rdev));
    const struct timespec *times[] = {&st.st_atimespec, &st.st_mtimespec, &st.st_ctimespec, &st.st_birthtimespec};
    for (int i = 0; i < 4; i++) {
        mem.write<int32_t>(out + 28 + i * 8, int32_t(times[i]->tv_sec));
        mem.write<int32_t>(out + 32 + i * 8, int32_t(times[i]->tv_nsec));
    }
    mem.write<int64_t>(out + 60, st.st_size);
    mem.write<int64_t>(out + 68, st.st_blocks);
    mem.write<int32_t>(out + 76, st.st_blksize);
    mem.write<uint32_t>(out + 80, st.st_flags);
    mem.write<uint32_t>(out + 84, st.st_gen);
}
}  // namespace

B32_THUNK(_stat) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    struct stat st;
    int rc = ::stat(path, &st);
    if (rc == 0) writeStat(c.mem, out, st);
    B32_FILE_LOG("stat(%s) = %d", path, rc);
    c.ret(uint32_t(rc));
}
B32_THUNK(_lstat) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    struct stat st;
    int rc = ::lstat(path, &st);
    if (rc == 0) writeStat(c.mem, out, st);
    c.ret(uint32_t(rc));
}
B32_THUNK(_fstat) {
    int fd = c.args.i32();
    GuestAddr out = c.args.ptr();
    struct stat st;
    int rc = ::fstat(fd, &st);
    if (rc == 0) writeStat(c.mem, out, st);
    c.ret(uint32_t(rc));
}

// struct statvfs is eleven 32-bit fields in the guest.
B32_THUNK(_statvfs) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    struct statvfs st;
    int rc = ::statvfs(path, &st);
    if (rc == 0) {
        uint32_t fields[] = {uint32_t(st.f_bsize), uint32_t(st.f_frsize), uint32_t(st.f_blocks), uint32_t(st.f_bfree),
                             uint32_t(st.f_bavail), uint32_t(st.f_files), uint32_t(st.f_ffree), uint32_t(st.f_favail),
                             uint32_t(st.f_fsid), uint32_t(st.f_flag), uint32_t(st.f_namemax)};
        c.mem.copyIn(out, fields, sizeof fields);
    }
    c.ret(uint32_t(rc));
}

// --- directories: DIR * is a guest block; struct dirent matches the host's ----------------

namespace {
std::mutex dirsLock;
struct GuestDir {
    DIR *host;
    GuestAddr entry;  // guest copy of the last dirent
};
std::unordered_map<GuestAddr, GuestDir> dirs;
}  // namespace

B32_THUNK(_opendir) {
    const char *path = c.mem.cstr(c.args.ptr());
    DIR *d = ::opendir(path);
    B32_FILE_LOG("opendir(%s) = %p", path, (void *)d);
    if (!d) {
        c.ret(0);
        return;
    }
    GuestAddr handle = c.heap.calloc(1, 16);
    std::lock_guard guard(dirsLock);
    dirs[handle] = {d, c.heap.calloc(1, sizeof(struct dirent))};
    c.ret(handle);
}

B32_THUNK(_readdir) {
    GuestAddr handle = c.args.ptr();
    GuestDir d;
    {
        std::lock_guard guard(dirsLock);
        d = dirs.at(handle);
    }
    struct dirent *e = ::readdir(d.host);
    if (!e) {
        c.ret(0);
        return;
    }
    c.mem.copyIn(d.entry, e, sizeof *e);
    c.ret(d.entry);
}

B32_THUNK(_closedir) {
    GuestAddr handle = c.args.ptr();
    std::lock_guard guard(dirsLock);
    auto it = dirs.find(handle);
    if (it == dirs.end()) {
        c.ret(uint32_t(-1));
        return;
    }
    int rc = ::closedir(it->second.host);
    c.heap.free(it->second.entry);
    c.heap.free(handle);
    dirs.erase(it);
    c.ret(uint32_t(rc));
}

// --- environment and errors -----------------------------------------------------------------

B32_THUNK(_getenv) {
    const char *value = ::getenv(c.mem.cstr(c.args.ptr()));
    c.ret(value ? c.rt.internString(value) : 0);
}
B32_THUNK(_strerror) { c.ret(c.rt.internString(std::strerror(c.args.i32()))); }
B32_THUNK(_gethostname) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    std::strncpy(c.mem.ptr<char>(buf), "iPhone", size);
    c.ret(0);
}
B32_THUNK(_getdomainname) {
    GuestAddr buf = c.args.ptr();
    if (c.args.u32()) c.mem.write<char>(buf, '\0');
    c.ret(0);
}
B32_THUNK(_atexit) { c.ret(0); }     // the process exits without running guest atexit handlers
B32_THUNK(_signal) { c.ret(0); }     // SIG_DFL: guest signal handlers aren't installed
B32_THUNK(___fixunsdfdi) {
    double d = c.args.f64();
    c.ret64(d <= 0 ? 0 : d >= 18446744073709551615.0 ? UINT64_MAX : uint64_t(d));
}

// --- time ----------------------------------------------------------------------------------

B32_THUNK(_tzset) { ::tzset(); }

// struct tm in the guest: nine ints, then long tm_gmtoff and char *tm_zone.
namespace {
thread_local GuestAddr tmBuffer = 0;
GuestAddr guestTm(Call &c, const struct tm &t) {
    if (!tmBuffer) tmBuffer = c.heap.calloc(1, 44);
    int32_t ints[] = {t.tm_sec, t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon, t.tm_year, t.tm_wday, t.tm_yday, t.tm_isdst};
    c.mem.copyIn(tmBuffer, ints, sizeof ints);
    c.mem.write<int32_t>(tmBuffer + 36, int32_t(t.tm_gmtoff));
    c.mem.write<uint32_t>(tmBuffer + 40, t.tm_zone ? c.rt.internString(t.tm_zone) : 0);
    return tmBuffer;
}
}  // namespace

namespace {
struct tm hostTm(Call &c, GuestAddr p) {
    struct tm t{};
    int32_t ints[9];
    std::memcpy(ints, c.mem.ptr<void>(p), sizeof ints);
    t.tm_sec = ints[0], t.tm_min = ints[1], t.tm_hour = ints[2], t.tm_mday = ints[3], t.tm_mon = ints[4];
    t.tm_year = ints[5], t.tm_wday = ints[6], t.tm_yday = ints[7], t.tm_isdst = ints[8];
    t.tm_gmtoff = c.mem.read<int32_t>(p + 36);
    if (GuestAddr zone = c.mem.read<uint32_t>(p + 40)) t.tm_zone = const_cast<char *>(c.mem.cstr(zone));
    return t;
}
}  // namespace

// size_t strftime(char *s, size_t max, const char *format, const struct tm *tm)
B32_THUNK(_strftime) {
    char *out = c.mem.ptr<char>(c.args.ptr());
    size_t max = c.args.u32();
    const char *format = c.mem.cstr(c.args.ptr());
    struct tm t = hostTm(c, c.args.ptr());
    c.ret(uint32_t(std::strftime(out, max, format, &t)));
}

// size_t strftime_l(char *, size_t, const char *, const struct tm *, locale_t):
// always the C locale.
B32_THUNK(_strftime_l) {
    char *out = c.mem.ptr<char>(c.args.ptr());
    size_t max = c.args.u32();
    const char *format = c.mem.cstr(c.args.ptr());
    struct tm t = hostTm(c, c.args.ptr());
    c.ret(uint32_t(std::strftime(out, max, format, &t)));
}

// size_t wcsftime(wchar_t *s, size_t max, const wchar_t *format, const struct tm *tm)
B32_THUNK(_wcsftime) {
    wchar_t *out = c.mem.ptr<wchar_t>(c.args.ptr());
    size_t max = c.args.u32();
    const wchar_t *format = c.mem.ptr<wchar_t>(c.args.ptr());
    struct tm t = hostTm(c, c.args.ptr());
    c.ret(uint32_t(std::wcsftime(out, max, format, &t)));
}

B32_THUNK(_localtime) {
    time_t t = c.mem.read<int32_t>(c.args.ptr());
    struct tm result;
    ::localtime_r(&t, &result);
    c.ret(guestTm(c, result));
}
B32_THUNK(_gmtime) {
    time_t t = c.mem.read<int32_t>(c.args.ptr());
    struct tm result;
    ::gmtime_r(&t, &result);
    c.ret(guestTm(c, result));
}

// char *tzname[2]: the standard and daylight saving names of the host's time
// zone, copied into guest memory (Marmalade reads tzname[0] for the device's
// time zone).
B32_DATA(_tzname, 8) {
    ::tzset();
    for (uint32_t i = 0; i < 2; i++) {
        const char *name = ::tzname[i] ? ::tzname[i] : "";
        GuestAddr copy = rt.heap().alloc(uint32_t(std::strlen(name) + 1));
        rt.mem().copyIn(copy, name, std::strlen(name) + 1);
        rt.mem().write<uint32_t>(addr + 4 * i, copy);
    }
}

// --- Mach -----------------------------------------------------------------------------------

B32_DATA(_mach_task_self_, 4) { rt.mem().write<uint32_t>(addr, mach_task_self()); }
B32_THUNK(_mach_absolute_time) { c.ret64(mach_absolute_time()); }
// struct mach_timebase_info { uint32_t numer, denom } matches the host's.
B32_THUNK(_mach_timebase_info) { c.ret(mach_timebase_info(c.mem.ptr<mach_timebase_info_data_t>(c.args.ptr()))); }

// Semaphores are Mach port names, the same 32-bit values in both.
B32_THUNK(_semaphore_create) {
    task_t task = c.args.u32();
    GuestAddr out = c.args.ptr();
    int policy = c.args.i32();
    int value = c.args.i32();
    semaphore_t s = 0;
    kern_return_t kr = semaphore_create(task, &s, policy, value);
    c.mem.write<uint32_t>(out, s);
    c.ret(uint32_t(kr));
}
B32_THUNK(_semaphore_destroy) {
    task_t task = c.args.u32();
    c.ret(uint32_t(semaphore_destroy(task, c.args.u32())));
}
B32_THUNK(_semaphore_signal) { c.ret(uint32_t(semaphore_signal(c.args.u32()))); }
B32_THUNK(_semaphore_wait) { c.ret(uint32_t(semaphore_wait(c.args.u32()))); }

// --- setjmp / longjmp -------------------------------------------------------------------------
// The guest jmp_buf holds what we choose: r4-r11, sp, lr and d8-d15 (26
// words; the buffer has room for 27). setjmp returns through the caller's lr
// as usual; longjmp resumes at the saved lr with r0 = value.

namespace {
void saveContext(Call &c, GuestAddr buf) {
    for (int r = 4; r <= 11; r++) c.mem.write<uint32_t>(buf + (r - 4) * 4, c.cpu.reg(r));
    c.mem.write<uint32_t>(buf + 32, c.cpu.reg(Cpu::SP));
    c.mem.write<uint32_t>(buf + 36, c.cpu.reg(Cpu::LR));
    for (int s = 16; s < 32; s++) c.mem.write<uint32_t>(buf + 40 + (s - 16) * 4, c.cpu.extReg(s));
}
void restoreContext(Call &c, GuestAddr buf, uint32_t value) {
    for (int r = 4; r <= 11; r++) c.cpu.setReg(r, c.mem.read<uint32_t>(buf + (r - 4) * 4));
    c.cpu.setReg(Cpu::SP, c.mem.read<uint32_t>(buf + 32));
    for (int s = 16; s < 32; s++) c.cpu.setExtReg(s, c.mem.read<uint32_t>(buf + 40 + (s - 16) * 4));
    c.cpu.setReg(0, value ? value : 1);
    c.cpu.jump(c.mem.read<uint32_t>(buf + 36));
}
}  // namespace

B32_THUNK(_setjmp) {
    saveContext(c, c.args.ptr());
    c.ret(0);
}
B32_THUNK(__setjmp) {
    saveContext(c, c.args.ptr());
    c.ret(0);
}
B32_THUNK(_sigsetjmp) {
    saveContext(c, c.args.ptr());
    c.ret(0);
}
B32_THUNK(_longjmp) {
    GuestAddr buf = c.args.ptr();
    restoreContext(c, buf, c.args.u32());
}
B32_THUNK(__longjmp) {
    GuestAddr buf = c.args.ptr();
    restoreContext(c, buf, c.args.u32());
}
B32_THUNK(_siglongjmp) {
    GuestAddr buf = c.args.ptr();
    restoreContext(c, buf, c.args.u32());
}

// --- zlib ------------------------------------------------------------------------------------
// Guest z_stream (32-bit): next_in 0, avail_in 4, total_in 8, next_out 12,
// avail_out 16, total_out 20, msg 24, state 28, zalloc 32, zfree 36,
// opaque 40, data_type 44, adler 48, reserved 52. Each guest stream has a
// host z_stream; the buffers stay in guest memory.

namespace {
std::mutex zLock;
std::unordered_map<GuestAddr, z_stream *> zstreams;

z_stream *hostStream(GuestAddr strm) {
    std::lock_guard guard(zLock);
    auto it = zstreams.find(strm);
    return it == zstreams.end() ? nullptr : it->second;
}

void loadStream(Call &c, GuestAddr g, z_stream *z) {
    GuestAddr in = c.mem.read<uint32_t>(g), out = c.mem.read<uint32_t>(g + 12);
    z->next_in = in ? c.mem.ptr<Bytef>(in) : nullptr;
    z->avail_in = c.mem.read<uint32_t>(g + 4);
    z->next_out = out ? c.mem.ptr<Bytef>(out) : nullptr;
    z->avail_out = c.mem.read<uint32_t>(g + 16);
}

void storeStream(Call &c, GuestAddr g, z_stream *z) {
    c.mem.write<uint32_t>(g, z->next_in ? c.mem.guestAddrOf(z->next_in) : 0);
    c.mem.write<uint32_t>(g + 4, z->avail_in);
    c.mem.write<uint32_t>(g + 8, uint32_t(z->total_in));
    c.mem.write<uint32_t>(g + 12, z->next_out ? c.mem.guestAddrOf(z->next_out) : 0);
    c.mem.write<uint32_t>(g + 16, z->avail_out);
    c.mem.write<uint32_t>(g + 20, uint32_t(z->total_out));
    c.mem.write<uint32_t>(g + 24, 0);
    c.mem.write<uint32_t>(g + 44, uint32_t(z->data_type));
    c.mem.write<uint32_t>(g + 48, uint32_t(z->adler));
}

int startInflate(Call &c, GuestAddr g, int windowBits) {
    auto *z = new z_stream{};
    loadStream(c, g, z);
    int rc = inflateInit2(z, windowBits);
    {
        std::lock_guard guard(zLock);
        zstreams[g] = z;
    }
    storeStream(c, g, z);
    return rc;
}
}  // namespace

// int inflateInit_(z_streamp, const char *version, int stream_size)
B32_THUNK(_inflateInit_) { c.ret(uint32_t(startInflate(c, c.args.ptr(), MAX_WBITS))); }
// int inflateInit2_(z_streamp, int windowBits, const char *version, int stream_size)
B32_THUNK(_inflateInit2_) {
    GuestAddr g = c.args.ptr();
    c.ret(uint32_t(startInflate(c, g, c.args.i32())));
}

B32_THUNK(_inflate) {
    GuestAddr g = c.args.ptr();
    int flush = c.args.i32();
    z_stream *z = hostStream(g);
    if (!z) {
        c.ret(uint32_t(Z_STREAM_ERROR));
        return;
    }
    loadStream(c, g, z);
    int rc = ::inflate(z, flush);
    storeStream(c, g, z);
    c.ret(uint32_t(rc));
}

B32_THUNK(_inflateEnd) {
    GuestAddr g = c.args.ptr();
    z_stream *z = hostStream(g);
    int rc = z ? ::inflateEnd(z) : Z_STREAM_ERROR;
    {
        std::lock_guard guard(zLock);
        zstreams.erase(g);
    }
    delete z;
    c.ret(uint32_t(rc));
}

B32_THUNK(_inflateReset) {
    z_stream *z = hostStream(c.args.ptr());
    c.ret(uint32_t(z ? ::inflateReset(z) : Z_STREAM_ERROR));
}

// --- sscanf ------------------------------------------------------------------------------------
// Each conversion runs through the host's sscanf on its own (with %n to see
// how much it consumed) and the result is stored through the guest pointer.

// Scans `input` by `format`, storing through the guest pointers `args`
// supplies; returns sscanf's result, and how much input it used in *consumed.
int b32::scanGuest(Call &c, Args &args, const char *input, const char *format, size_t *consumed) {
    const char *pos = input;
    int assigned = 0;

    for (const char *f = format; *f;) {
        // Copy literal text and whitespace up to the next conversion into the piece.
        std::string piece;
        while (*f && *f != '%') piece += *f++;
        if (*f == '%' && f[1] == '%') {
            piece += "%%";
            f += 2;
            int used = -1;
            std::sscanf(pos, (piece + "%n").c_str(), &used);
            if (used < 0) break;
            pos += used;
            continue;
        }
        if (!*f) {
            int used = -1;
            std::sscanf(pos, (piece + "%n").c_str(), &used);
            break;
        }

        // The conversion: flags, width, length, type (and [...] sets).
        std::string spec = "%";
        f++;
        bool suppress = *f == '*';
        if (suppress) spec += *f++;
        while (*f >= '0' && *f <= '9') spec += *f++;
        std::string length;
        while (*f && std::strchr("hlqjztL", *f)) length += *f++;
        char conv = *f;
        spec += length;
        if (conv == '[') {
            while (*f && *f != ']') spec += *f++;
            if (*f == ']') spec += *f++;
            if (spec.back() != ']' && *f) spec += *f++;
        } else {
            spec += *f++;
        }
        piece += spec;

        int used = -1, matched;
        union {
            int i;
            long long ll;
            float fl;
            double d;
            char buf[4096];
        } value{};
        bool wide = length == "ll" || length == "q" || length == "j";
        if (suppress) {
            std::sscanf(pos, (piece + "%n").c_str(), &used);
            matched = used >= 0 ? 0 : -1;
        } else if (conv == 'n') {
            c.mem.write<int32_t>(args.ptr(), int32_t(pos - input));
            continue;
        } else {
            matched = std::sscanf(pos, (piece + "%n").c_str(), &value, &used);
        }
        if (matched < 1 && !suppress) break;
        if (used < 0) break;
        pos += used;
        if (suppress) continue;

        GuestAddr out = args.ptr();
        switch (conv) {
        case 'd': case 'i': case 'u': case 'x': case 'X': case 'o':
            if (wide)
                c.mem.write<int64_t>(out, value.ll);
            else if (length == "hh")
                c.mem.write<int8_t>(out, int8_t(value.i));
            else if (length == "h")
                c.mem.write<int16_t>(out, int16_t(value.i));
            else
                c.mem.write<int32_t>(out, value.i);
            break;
        case 'f': case 'e': case 'g': case 'E': case 'G': case 'a':
            if (length == "l" || length == "L")
                c.mem.write<double>(out, value.d);
            else
                c.mem.write<float>(out, value.fl);
            break;
        case 's': case '[': c.mem.copyIn(out, value.buf, std::strlen(value.buf) + 1); break;
        case 'c': c.mem.copyIn(out, value.buf, 1); break;
        case 'p': c.mem.write<uint32_t>(out, uint32_t(value.ll)); break;
        default: fatal("sscanf conversion %%%c is not supported", conv);
        }
        assigned++;
    }
    if (consumed) *consumed = size_t(pos - input);
    return assigned == 0 && *pos == '\0' && *input == '\0' ? -1 : assigned;
}

B32_THUNK(_sscanf) {
    const char *input = c.mem.cstr(c.args.ptr());
    const char *format = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(scanGuest(c, c.args, input, format)));
}

// int vsscanf(const char *, const char *format, va_list)
B32_THUNK(_vsscanf) {
    const char *input = c.mem.cstr(c.args.ptr());
    const char *format = c.mem.cstr(c.args.ptr());
    Args va = Args::fromVaList(c.cpu, c.args.ptr());
    c.ret(uint32_t(scanGuest(c, va, input, format)));
}

// int sscanf_l(const char *, locale_t, const char *format, ...): always the C locale.
B32_THUNK(_sscanf_l) {
    const char *input = c.mem.cstr(c.args.ptr());
    c.args.ptr();
    const char *format = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(scanGuest(c, c.args, input, format)));
}

// --- memory and descriptors ------------------------------------------------------------------

// Guest memory is always readable, writable and executable.
B32_THUNK(_mprotect) { c.ret(0); }
B32_THUNK(_getpagesize) { c.ret(4096); }

// Only the int-argument requests sockets and streams use: non-blocking mode
// (FIONBIO) and bytes waiting (FIONREAD). Both have the same values on both.
B32_THUNK(_ioctl) {
    int fd = c.args.i32();
    unsigned long request = c.args.u32();
    GuestAddr arg = c.args.ptr();
    if ((request == FIONBIO || request == FIONREAD) && arg) {
        int r = ::ioctl(fd, request, c.mem.ptr<int>(arg));
        if (r < 0) setGuestErrno(c, errno);
        c.ret(uint32_t(r));
        return;
    }
    setGuestErrno(c, ENOTTY);
    c.ret(uint32_t(-1));
}

// struct pollfd { int fd; short events, revents; } matches the host's.
B32_THUNK(_poll) {
    auto *fds = c.mem.ptr<struct pollfd>(c.args.ptr());
    nfds_t count = c.args.u32();
    c.ret(uint32_t(::poll(fds, count, c.args.i32())));
}

// ssize_t writev(int fd, const struct iovec *iov, int count): guest iovecs
// are pairs of 32-bit words.
B32_THUNK(_writev) {
    int fd = c.args.i32();
    GuestAddr iov = c.args.ptr();
    int count = c.args.i32();
    std::vector<struct iovec> host(size_t(std::max(count, 0)));
    for (int i = 0; i < count; i++) {
        GuestAddr base = c.mem.read<uint32_t>(iov + i * 8);
        host[size_t(i)] = {base ? c.mem.ptr<void>(base) : nullptr, c.mem.read<uint32_t>(iov + i * 8 + 4)};
    }
    c.ret(uint32_t(::writev(fd, host.data(), count)));
}

// --- Mach-O ------------------------------------------------------------------------------------

// char *getsectdatafromheader(const struct mach_header *mhp, const char *segname,
//                             const char *sectname, uint32_t *size)
// Walks a guest image's 32-bit load commands; like the original, it returns
// the section's unslid address.
B32_THUNK(_getsectdatafromheader) {
    GuestAddr header = c.args.ptr();
    std::string segname = c.mem.cstr(c.args.ptr()), sectname = c.mem.cstr(c.args.ptr());
    GuestAddr sizeOut = c.args.ptr();
    uint32_t ncmds = c.mem.read<uint32_t>(header + 16);
    GuestAddr cmd = header + 28;  // sizeof(struct mach_header)
    for (uint32_t i = 0; i < ncmds; i++) {
        uint32_t type = c.mem.read<uint32_t>(cmd), size = c.mem.read<uint32_t>(cmd + 4);
        if (type == 0x1 /* LC_SEGMENT */) {
            uint32_t nsects = c.mem.read<uint32_t>(cmd + 48);
            for (uint32_t k = 0; k < nsects; k++) {
                GuestAddr sect = cmd + 56 + k * 68;  // section: sectname[16], segname[16], addr, size...
                if (strncmp(c.mem.cstr(sect), sectname.c_str(), 16) == 0 &&
                    strncmp(c.mem.cstr(sect + 16), segname.c_str(), 16) == 0) {
                    if (sizeOut) c.mem.write<uint32_t>(sizeOut, c.mem.read<uint32_t>(sect + 36));
                    c.ret(c.mem.read<uint32_t>(sect + 32));
                    return;
                }
            }
        }
        cmd += size;
    }
    if (sizeOut) c.mem.write<uint32_t>(sizeOut, 0);
    c.ret(0);
}

// --- paths and terminals ------------------------------------------------------------------------

B32_THUNK(_getcwd) {
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    if (!buf) fatal("getcwd(NULL) isn't supported");
    c.ret(::getcwd(c.mem.ptr<char>(buf), size) ? buf : 0);
}

// char *realpath(const char *path, char *resolved): resolved holds PATH_MAX
// (1024) bytes, or is allocated when NULL.
B32_THUNK(_realpath$DARWIN_EXTSN) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr out = c.args.ptr();
    char resolved[PATH_MAX];
    if (!::realpath(path, resolved)) {
        c.ret(0);
        return;
    }
    if (!out) out = c.heap.alloc(uint32_t(std::strlen(resolved) + 1));
    c.mem.copyIn(out, resolved, std::strlen(resolved) + 1);
    c.ret(out);
}

// No terminal behind the guest's descriptors.
B32_THUNK(_tcgetattr) {
    errno = ENOTTY;
    c.ret(uint32_t(-1));
}
B32_THUNK(_tcsetattr) {
    errno = ENOTTY;
    c.ret(uint32_t(-1));
}

// --- environment and syslog --------------------------------------------------------------------

B32_THUNK(_setenv) {
    const char *name = c.mem.cstr(c.args.ptr());
    const char *value = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::setenv(name, value, c.args.i32())));
}
B32_THUNK(_unsetenv) { c.ret(uint32_t(::unsetenv(c.mem.cstr(c.args.ptr())))); }

// syslog goes to Bridge32's log.
B32_THUNK(_openlog) {}
B32_THUNK(_closelog) {}
B32_THUNK(_syslog) {
    c.args.i32();  // priority
    log("syslog: %s", formatGuest(c, c.mem.cstr(c.args.ptr()), c.args).c_str());
}

// --- process and system -------------------------------------------------------------------------

B32_THUNK(__Exit) { c.rt.exit(c.args.i32()); }

// long sysconf(int): long is 32-bit in the guest, and pages are 4 KB there.
B32_THUNK(_sysconf) {
    int name = c.args.i32();
    long value = name == _SC_PAGESIZE ? 4096 : ::sysconf(name);
    c.ret(uint32_t(int32_t(std::min<long>(value, INT32_MAX))));
}

// double difftime(time_t, time_t): time_t is 32-bit in the guest.
B32_THUNK(_difftime) {
    int32_t end = c.args.i32();
    c.retF64(double(end) - double(c.args.i32()));
}

// int utime(const char *, const struct utimbuf *): { time_t actime, modtime } of 32-bit words.
B32_THUNK(_utime) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr times = c.args.ptr();
    struct utimbuf host = {};
    if (times) host = {c.mem.read<int32_t>(times), c.mem.read<int32_t>(times + 4)};
    c.ret(uint32_t(::utime(path, times ? &host : nullptr)));
}

// bool __availability_version_check(uint32_t count, dyld_build_version_t versions[]):
// behind @available. Each { platform, version } is checked against the iOS
// the guest was built for (B32GuestSDKVersion): code needing anything newer
// was compiled out of it, so taking those branches would only reach
// half-built paths (SDL then names controllers in a way its own mapping
// database doesn't know). Without the key, everything is available.
namespace {
uint32_t guestIOSVersion() {
    static uint32_t version = [] {
        CFStringRef value = static_cast<CFStringRef>(
            CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), CFSTR("B32GuestSDKVersion")));
        char text[32] = {};
        if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
            !CFStringGetCString(value, text, sizeof text, kCFStringEncodingUTF8))
            return UINT32_MAX;
        unsigned major = 0, minor = 0, patch = 0;
        std::sscanf(text, "%u.%u.%u", &major, &minor, &patch);
        return (major << 16) | (minor << 8) | patch;  // dyld's packed xxxx.yy.zz
    }();
    return version;
}
constexpr uint32_t kPlatformIOS = 2;
}  // namespace

B32_THUNK(__availability_version_check) {
    uint32_t count = c.args.u32();
    GuestAddr versions = c.args.ptr();
    for (uint32_t i = 0; i < count; i++) {
        uint32_t platform = c.mem.read<uint32_t>(versions + i * 8), version = c.mem.read<uint32_t>(versions + i * 8 + 4);
        if (platform == kPlatformIOS && version > guestIOSVersion()) {
            c.ret(0);
            return;
        }
    }
    c.ret(1);
}

// --- more files ----------------------------------------------------------------------------------

// ssize_t pread(int, void *, size_t, off_t) and pwrite: off_t is 64-bit.
B32_THUNK(_pread) {
    int fd = c.args.i32();
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    off_t offset = off_t(c.args.u64());
    c.ret(uint32_t(::pread(fd, c.mem.ptr<void>(buf), size, offset)));
}
B32_THUNK(_pwrite) {
    int fd = c.args.i32();
    GuestAddr buf = c.args.ptr();
    uint32_t size = c.args.u32();
    off_t offset = off_t(c.args.u64());
    c.ret(uint32_t(::pwrite(fd, c.mem.ptr<void>(buf), size, offset)));
}
B32_THUNK(_ftruncate) {
    int fd = c.args.i32();
    c.ret(uint32_t(::ftruncate(fd, off_t(c.args.u64()))));
}
B32_THUNK(_fsync) { c.ret(uint32_t(::fsync(c.args.i32()))); }
B32_THUNK(_fchmod) {
    int fd = c.args.i32();
    c.ret(uint32_t(::fchmod(fd, mode_t(c.args.u32()))));
}
B32_THUNK(_flock) {
    int fd = c.args.i32();
    c.ret(uint32_t(::flock(fd, c.args.i32())));
}
// ssize_t readlink(const char *, char *, size_t)
B32_THUNK(_readlink) {
    const char *path = c.mem.cstr(c.args.ptr());
    GuestAddr buf = c.args.ptr();
    c.ret(uint32_t(::readlink(path, c.mem.ptr<char>(buf), c.args.u32())));
}
B32_THUNK(_symlink) {
    const char *target = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::symlink(target, c.mem.cstr(c.args.ptr()))));
}
// char *mkdtemp(char *template): fills in the guest's template in place.
B32_THUNK(_mkdtemp) {
    GuestAddr path = c.args.ptr();
    c.ret(::mkdtemp(c.mem.ptr<char>(path)) ? path : 0);
}

namespace {
// Two guest timevals (atime, mtime), or none for "now".
bool readTimes(Call &c, GuestAddr times, struct timeval out[2]) {
    if (!times) return false;
    for (int i = 0; i < 2; i++) out[i] = {c.mem.read<int32_t>(times + i * 8), c.mem.read<int32_t>(times + i * 8 + 4)};
    return true;
}
}  // namespace

B32_THUNK(_utimes) {
    const char *path = c.mem.cstr(c.args.ptr());
    struct timeval times[2];
    c.ret(uint32_t(::utimes(path, readTimes(c, c.args.ptr(), times) ? times : nullptr)));
}
B32_THUNK(_futimes) {
    int fd = c.args.i32();
    struct timeval times[2];
    c.ret(uint32_t(::futimes(fd, readTimes(c, c.args.ptr(), times) ? times : nullptr)));
}

// File system details (struct statfs differs between the ABIs) aren't
// offered; callers fall back to statvfs, which is converted.
B32_THUNK(_fstatfs) {
    setGuestErrno(c, ENOTSUP);
    c.ret(uint32_t(-1));
}
B32_THUNK(_getfsstat) {
    setGuestErrno(c, ENOTSUP);
    c.ret(uint32_t(-1));
}
B32_THUNK(_fsctl) {
    setGuestErrno(c, ENOTSUP);
    c.ret(uint32_t(-1));
}

// --- users and processes --------------------------------------------------------------------------

B32_THUNK(_geteuid) { c.ret(::geteuid()); }

// struct passwd *getpwuid(uid_t): the guest's is ten words { pw_name, pw_passwd,
// pw_uid, pw_gid, pw_change, pw_class, pw_gecos, pw_dir, pw_shell, pw_expire },
// built once from the host's entry, with the app's own home directory.
B32_THUNK(_getpwuid) {
    static GuestAddr entry = 0;
    if (!entry) {
        const struct passwd *pw = ::getpwuid(::getuid());
        entry = c.heap.calloc(1, 40);
        GuestAddr empty = c.rt.internString("");
        uint32_t words[10] = {c.rt.internString(pw ? pw->pw_name : "mobile"), empty, ::getuid(), ::getgid(), 0,
                              empty, c.rt.internString(pw ? pw->pw_gecos : "Mobile User"),
                              c.rt.internString(getenv("HOME") ? getenv("HOME") : "/"), c.rt.internString("/bin/sh"), 0};
        c.mem.copyIn(entry, words, sizeof words);
    }
    c.args.u32();
    c.ret(entry);
}

// A guest can't start other programs.
B32_THUNK(_execv) {
    setGuestErrno(c, ENOTSUP);
    c.ret(uint32_t(-1));
}
B32_THUNK(_execvp) {
    setGuestErrno(c, ENOTSUP);
    c.ret(uint32_t(-1));
}
// int system(const char *command): no shell either; system(NULL) asks
// whether there is one.
B32_THUNK(_system) {
    GuestAddr command = c.args.ptr();
    if (command) log("system(\"%s\") ignored", c.mem.cstr(command));
    c.ret(command ? uint32_t(-1) : 0);
}

// --- logging: os_log goes nowhere -----------------------------------------------------------------
// os_log_type_enabled says no, so code that checks first skips building messages.

B32_DATA(__os_log_default, 4) {}
// os_log_t os_log_create(const char *subsystem, const char *category): any
// non-NULL value works, since every os_log call ignores it.
B32_THUNK(_os_log_create) { c.ret(c.rt.dataSymbol("__os_log_default")); }
B32_THUNK(_os_log_type_enabled) { c.ret(0); }
B32_THUNK(__os_log_impl) {}
// size_t _os_log_pack_size(size_t os_log_format_size): a header plus the arguments.
B32_THUNK(__os_log_pack_size) { c.ret(c.args.u32() + 32); }
// uint8_t *_os_log_pack_fill(os_log_pack_t pack, size_t size, int errno, const void *dso, const char *fmt):
// the arguments go right after the header.
B32_THUNK(__os_log_pack_fill) {
    GuestAddr pack = c.args.ptr();
    c.ret(pack + 32);
}
B32_THUNK(_os_log_pack_send) { c.ret(0); }

// --- UUIDs (uuid_t is 16 bytes in both) -------------------------------------------------------------

B32_THUNK(_uuid_generate) { ::uuid_generate(c.mem.ptr<unsigned char>(c.args.ptr())); }
B32_THUNK(_uuid_generate_random) { ::uuid_generate_random(c.mem.ptr<unsigned char>(c.args.ptr())); }
B32_THUNK(_uuid_unparse) {
    const unsigned char *uu = c.mem.ptr<unsigned char>(c.args.ptr());
    ::uuid_unparse(uu, c.mem.ptr<char>(c.args.ptr()));
}
B32_THUNK(_uuid_unparse_lower) {
    const unsigned char *uu = c.mem.ptr<unsigned char>(c.args.ptr());
    ::uuid_unparse_lower(uu, c.mem.ptr<char>(c.args.ptr()));
}
B32_THUNK(_uuid_unparse_upper) {
    const unsigned char *uu = c.mem.ptr<unsigned char>(c.args.ptr());
    ::uuid_unparse_upper(uu, c.mem.ptr<char>(c.args.ptr()));
}
B32_THUNK(_uuid_clear) { ::uuid_clear(c.mem.ptr<unsigned char>(c.args.ptr())); }
B32_THUNK(_uuid_is_null) { c.ret(uint32_t(::uuid_is_null(c.mem.ptr<unsigned char>(c.args.ptr())))); }
B32_THUNK(_uuid_copy) {
    unsigned char *dst = c.mem.ptr<unsigned char>(c.args.ptr());
    ::uuid_copy(dst, c.mem.ptr<unsigned char>(c.args.ptr()));
}
B32_THUNK(_uuid_compare) {
    const unsigned char *a = c.mem.ptr<unsigned char>(c.args.ptr());
    c.ret(uint32_t(::uuid_compare(a, c.mem.ptr<unsigned char>(c.args.ptr()))));
}
B32_THUNK(_uuid_parse) {
    const char *in = c.mem.cstr(c.args.ptr());
    c.ret(uint32_t(::uuid_parse(in, c.mem.ptr<unsigned char>(c.args.ptr()))));
}
