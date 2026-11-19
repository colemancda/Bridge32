// Starting other programs: exec, fork and vfork followed by exec, posix_spawn, and waiting for them.
//
// A child is a host process. A Mach-O program for this guest's CPU runs in a new copy of this
// launcher (b32-run and the app shell both take --b32-exec <path> <argv...>); anything else, a script
// or a host tool, runs as itself. Descriptors, the working directory and the environment are the
// host's, which the guest shares, so the child inherits them as it would on a Mac.
//
// fork and vfork are both vfork. The child runs in the parent's place, on its stack, until it execs
// or exits (the CPU's half of that is in core/arch); meanwhile the dup2s and closes it makes are
// saved for the program it starts instead of done. Then the parent carries on from fork, given the
// child's pid. A child that exits without starting anything leaves a pid that only wait knows,
// which reports its status.

#include "Thunks.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <mach-o/dyld.h>

#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

extern char **environ;

using namespace b32;

namespace {

// B32_TRACE_SPAWN=1 logs each program started.
const bool traceSpawn = getenv("B32_TRACE_SPAWN") != nullptr;

#if defined(B32_GUEST_PPC)
constexpr uint32_t kGuestCpuType = 18;  // CPU_TYPE_POWERPC
#else
constexpr uint32_t kGuestCpuType = 7;  // CPU_TYPE_I386
#endif

const std::string &launcher() {
    static const std::string path = [] {
        char buf[PATH_MAX];
        uint32_t size = sizeof buf;
        return _NSGetExecutablePath(buf, &size) == 0 ? std::string(buf) : std::string();
    }();
    return path;
}

// Whether `path` is a Mach-O program this guest's CPU runs: thin, or fat with a slice for it.
bool runsAsGuest(const std::string &path) {
    int fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) return false;
    uint8_t head[4096];
    ssize_t n = ::read(fd, head, sizeof head);
    ::close(fd);
    if (n < 8) return false;
    auto be32 = [&](size_t o) { return uint32_t(head[o]) << 24 | uint32_t(head[o + 1]) << 16 | uint32_t(head[o + 2]) << 8 | head[o + 3]; };
    auto le32 = [&](size_t o) { return uint32_t(head[o + 3]) << 24 | uint32_t(head[o + 2]) << 16 | uint32_t(head[o + 1]) << 8 | head[o]; };
    if (be32(0) == 0xcafebabe) {
        uint32_t count = be32(4);
        for (uint32_t i = 0; i < count && 8 + 20 * size_t(i) + 20 <= size_t(n); i++)
            if (be32(8 + 20 * size_t(i)) == kGuestCpuType) return true;
        return false;
    }
    if (le32(0) == 0xfeedface) return le32(4) == kGuestCpuType;  // little-endian: i386
    if (be32(0) == 0xfeedface) return be32(4) == kGuestCpuType;  // big-endian: PowerPC
    return false;
}

// The program execvp would run for `file`: itself if it names a path, else the first executable
// file of that name in PATH; empty if there's none.
std::string findProgram(const std::string &file) {
    if (file.empty() || file.find('/') != std::string::npos) return file;
    const char *path = getenv("PATH");
    std::string dirs = path ? path : "/usr/bin:/bin";
    for (size_t start = 0;;) {
        size_t end = dirs.find(':', start);
        std::string dir = dirs.substr(start, end == std::string::npos ? std::string::npos : end - start);
        std::string candidate = (dir.empty() ? std::string(".") : dir) + "/" + file;
        if (::access(candidate.c_str(), X_OK) == 0) return candidate;
        if (end == std::string::npos) return {};
        start = end + 1;
    }
}

std::vector<std::string> guestStrings(Call &c, GuestAddr list) {
    std::vector<std::string> out;
    if (!list) return out;
    for (GuestAddr p = list;; p += 4) {
        GuestAddr s = c.mem.read<uint32_t>(p);
        if (!s) break;
        out.emplace_back(c.mem.cstr(s));
    }
    return out;
}

std::vector<char *> pointers(std::vector<std::string> &strings) {
    std::vector<char *> out;
    for (auto &s : strings) out.push_back(s.data());
    out.push_back(nullptr);
    return out;
}

// Starts `path` with `argv`, in `envp` (the guest's own environment, plus Bridge32's settings) or
// the host's environment. The pid, or -errno.
pid_t start(const std::string &path, const std::vector<std::string> &argv, const std::vector<std::string> *envp,
            const posix_spawn_file_actions_t *actions, short flags = 0) {
    std::vector<std::string> args;
    std::string program = path;
    if (runsAsGuest(path)) {
        program = launcher();
        args = {program, "--b32-exec", path};
    }
    args.insert(args.end(), argv.begin(), argv.end());
    if (args.empty()) args.push_back(path);
    std::vector<char *> argp = pointers(args);

    std::vector<std::string> env;
    if (envp) {
        env = *envp;
        for (char **e = environ; *e; e++)
            if (!std::strncmp(*e, "B32_", 4)) env.emplace_back(*e);
    }
    std::vector<char *> envPointers = pointers(env);

    if (traceSpawn) {
        std::string line;
        for (auto &a : argv) line += " " + a;
        log("spawn %s:%s", path.c_str(), line.c_str());
    }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    if (flags) posix_spawnattr_setflags(&attr, flags);
    if (flags & POSIX_SPAWN_SETEXEC) {
        std::fflush(stdout);
        std::fflush(stderr);
    }
    pid_t pid = 0;
    int rc = ::posix_spawn(&pid, program.c_str(), actions, &attr, argp.data(), envp ? envPointers.data() : environ);
    posix_spawnattr_destroy(&attr);
    return rc ? -rc : pid;
}

// Children that exited without starting a program, by the pids they were given.
std::mutex exitedLock;
std::map<pid_t, int> exited;
pid_t nextExitedPid = 1000000;  // above any real pid

// The fork child is done: it started `pid` (or exited as it). The parent resumes from fork.
void endForkChild(Call &c, pid_t pid) {
    ForkChild *child = forkChild;
    forkChild = nullptr;
    posix_spawn_file_actions_destroy(&child->actions);
    auto resume = std::move(child->resumeParent);
    delete child;
    resume(c, uint32_t(pid));
}

void exec(Call &c, const std::string &path, const std::vector<std::string> &argv, const std::vector<std::string> *envp) {
    if (path.empty() || ::access(path.c_str(), X_OK) != 0) {
        setGuestErrno(c, path.empty() ? ENOENT : errno);
        c.ret(uint32_t(-1));
        return;
    }
    if (ForkChild *child = forkChild) {
        pid_t pid = start(path, argv, envp, &child->actions);
        if (pid < 0) {
            setGuestErrno(c, -pid);
            c.ret(uint32_t(-1));
            return;
        }
        endForkChild(c, pid);
        return;
    }
    // No fork before it: the program takes this process's place.
    pid_t result = start(path, argv, envp, nullptr, POSIX_SPAWN_SETEXEC);
    setGuestErrno(c, -result);
    c.ret(uint32_t(-1));
}

// waitpid for real children and for those that only exited.
pid_t waitFor(Call &c, pid_t pid, GuestAddr status, int options) {
    {
        std::lock_guard guard(exitedLock);
        auto it = pid == -1 ? exited.begin() : exited.find(pid);
        if (it != exited.end()) {
            pid_t done = it->first;
            if (status) c.mem.write<int32_t>(status, (it->second & 0xff) << 8);
            exited.erase(it);
            return done;
        }
    }
    int st = 0;
    pid_t result = ::waitpid(pid, &st, options);
    if (result > 0 && status) c.mem.write<int32_t>(status, st);
    return result;
}

// posix_spawn_file_actions_t is a pointer-sized handle in the guest, for the host's.
std::mutex actionsLock;
std::unordered_map<uint32_t, posix_spawn_file_actions_t *> actionsByHandle;
uint32_t nextActions = 1;

posix_spawn_file_actions_t *hostActions(Call &c, GuestAddr guest) {
    if (!guest) return nullptr;
    std::lock_guard guard(actionsLock);
    auto it = actionsByHandle.find(c.mem.read<uint32_t>(guest));
    return it == actionsByHandle.end() ? nullptr : it->second;
}

void spawn(Call &c, bool searchPath) {
    GuestAddr pidOut = c.args.ptr();
    std::string file = c.mem.cstr(c.args.ptr());
    posix_spawn_file_actions_t *actions = hostActions(c, c.args.ptr());
    c.args.ptr();  // attributes: process groups, signal masks and the like aren't the guest's to set
    std::vector<std::string> argv = guestStrings(c, c.args.ptr());
    GuestAddr envList = c.args.ptr();
    std::vector<std::string> envp = guestStrings(c, envList);
    std::string path = searchPath ? findProgram(file) : file;
    if (path.empty()) return c.ret(ENOENT);
    pid_t pid = start(path, argv, envList ? &envp : nullptr, actions);
    if (pid < 0) return c.ret(uint32_t(-pid));
    if (pidOut) c.mem.write<int32_t>(pidOut, pid);
    c.ret(0);
}

// `s` in single quotes, for the shell.
std::string shellQuoted(const std::string &s) {
    std::string out = "'";
    for (char ch : s) out += ch == '\'' ? std::string("'\\''") : std::string(1, ch);
    return out + "'";
}

}  // namespace

std::string b32::hostShellCommand(const std::string &command) {
    // The first word, unquoted as the shell would: plain, or in single or double quotes.
    size_t i = command.find_first_not_of(" \t");
    if (i == std::string::npos) return command;
    std::string word;
    for (char quote = 0; i < command.size(); i++) {
        char ch = command[i];
        if (quote) {
            if (ch == quote) quote = 0;
            else if (quote == '"' && ch == '\\' && i + 1 < command.size()) word += command[++i];
            else word += ch;
        } else if (ch == '\'' || ch == '"') {
            quote = ch;
        } else if (ch == ' ' || ch == '\t' || ch == ';' || ch == '|' || ch == '&' || ch == '<' || ch == '>') {
            break;
        } else {
            word += ch;
        }
    }
    std::string path = findProgram(word);
    if (path.empty() || !runsAsGuest(path)) return command;
    if (traceSpawn) log("shell runs %s", path.c_str());
    // The original word stays, as the program's argv[0].
    return shellQuoted(launcher()) + " --b32-exec " + shellQuoted(path) + " " + command.substr(command.find_first_not_of(" \t"));
}

void b32::beginForkChild(Call &c, std::function<void(Call &, uint32_t pid)> resumeParent) {
    auto *child = new ForkChild;
    posix_spawn_file_actions_init(&child->actions);
    child->resumeParent = std::move(resumeParent);
    child->exited = [](Call &c, int status) {
        pid_t pid;
        {
            std::lock_guard guard(exitedLock);
            pid = nextExitedPid++;
            exited[pid] = status;
        }
        endForkChild(c, pid);
    };
    forkChild = child;
    (void)c;
}

// int execv(const char *path, char *const argv[]), execvp(const char *file, ...) and
// execve(const char *path, char *const argv[], char *const envp[])
B32_THUNK(_execv) {
    std::string path = c.mem.cstr(c.args.ptr());
    exec(c, path, guestStrings(c, c.args.ptr()), nullptr);
}
B32_THUNK(_execvp) {
    std::string file = c.mem.cstr(c.args.ptr());
    exec(c, findProgram(file), guestStrings(c, c.args.ptr()), nullptr);
}
B32_THUNK(_execve) {
    std::string path = c.mem.cstr(c.args.ptr());
    std::vector<std::string> argv = guestStrings(c, c.args.ptr());
    std::vector<std::string> envp = guestStrings(c, c.args.ptr());
    exec(c, path, argv, &envp);
}

// pid_t waitpid(pid_t, int *status, int options), wait(int *status), wait3(int *, int, struct rusage *)
// and wait4(pid_t, int *, int, struct rusage *): the rusage is left alone.
B32_THUNK(_waitpid) {
    pid_t pid = c.args.i32();
    GuestAddr status = c.args.ptr();
    retErrno(c, waitFor(c, pid, status, c.args.i32()));
}
B32_THUNK(_wait) { retErrno(c, waitFor(c, -1, c.args.ptr(), 0)); }
B32_THUNK(_wait3) {
    GuestAddr status = c.args.ptr();
    retErrno(c, waitFor(c, -1, status, c.args.i32()));
}
B32_THUNK(_wait4) {
    pid_t pid = c.args.i32();
    GuestAddr status = c.args.ptr();
    retErrno(c, waitFor(c, pid, status, c.args.i32()));
}

// int posix_spawn(pid_t *, const char *path, const posix_spawn_file_actions_t *, const posix_spawnattr_t *,
//     char *const argv[], char *const envp[]) and posix_spawnp, which searches PATH.
B32_THUNK(_posix_spawn) { spawn(c, false); }
B32_THUNK(_posix_spawnp) { spawn(c, true); }

B32_THUNK(_posix_spawn_file_actions_init) {
    GuestAddr out = c.args.ptr();
    auto *actions = new posix_spawn_file_actions_t;
    posix_spawn_file_actions_init(actions);
    std::lock_guard guard(actionsLock);
    uint32_t handle = nextActions++;
    actionsByHandle[handle] = actions;
    c.mem.write<uint32_t>(out, handle);
    c.ret(0);
}
B32_THUNK(_posix_spawn_file_actions_destroy) {
    GuestAddr guest = c.args.ptr();
    std::lock_guard guard(actionsLock);
    auto it = actionsByHandle.find(c.mem.read<uint32_t>(guest));
    if (it != actionsByHandle.end()) {
        posix_spawn_file_actions_destroy(it->second);
        delete it->second;
        actionsByHandle.erase(it);
    }
    c.ret(0);
}
B32_THUNK(_posix_spawn_file_actions_adddup2) {
    posix_spawn_file_actions_t *actions = hostActions(c, c.args.ptr());
    int fd = c.args.i32(), to = c.args.i32();
    c.ret(actions ? uint32_t(posix_spawn_file_actions_adddup2(actions, fd, to)) : EINVAL);
}
B32_THUNK(_posix_spawn_file_actions_addclose) {
    posix_spawn_file_actions_t *actions = hostActions(c, c.args.ptr());
    int fd = c.args.i32();
    c.ret(actions ? uint32_t(posix_spawn_file_actions_addclose(actions, fd)) : EINVAL);
}
B32_THUNK(_posix_spawn_file_actions_addopen) {
    posix_spawn_file_actions_t *actions = hostActions(c, c.args.ptr());
    int fd = c.args.i32();
    std::string path = c.mem.cstr(c.args.ptr());
    int flags = c.args.i32();
    mode_t mode = mode_t(c.args.u32());
    c.ret(actions ? uint32_t(posix_spawn_file_actions_addopen(actions, fd, path.c_str(), flags, mode)) : EINVAL);
}
#define B32_SPAWN_ATTRIBUTE(symbol) \
    B32_THUNK(symbol) { c.ret(0); }
B32_SPAWN_ATTRIBUTE(_posix_spawnattr_init)
B32_SPAWN_ATTRIBUTE(_posix_spawnattr_destroy)
B32_SPAWN_ATTRIBUTE(_posix_spawnattr_setflags)
B32_SPAWN_ATTRIBUTE(_posix_spawnattr_setpgroup)
B32_SPAWN_ATTRIBUTE(_posix_spawnattr_setsigmask)
B32_SPAWN_ATTRIBUTE(_posix_spawnattr_setsigdefault)
#undef B32_SPAWN_ATTRIBUTE
