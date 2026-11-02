#include "Runtime.h"

#include "core/Log.h"
#include "core/mem/Layout.h"
#include "core/objc/Bridge.h"

#include <dirent.h>
#include <dlfcn.h>
#include <unistd.h>

#include <algorithm>
#include <climits>
#include <cstring>

extern "C" void *objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void *);

namespace b32 {

namespace {
// Thrown by Runtime::exit from inside a thunk. SVCs are dispatched outside the
// JIT, so this only unwinds host frames.
struct ExitRequest {
    int status;
};

thread_local Cpu *currentCpuForThread = nullptr;
Runtime *instance = nullptr;

// An attached host thread's CPU, handed back when the thread exits. GCD
// retires its worker threads and starts new ones all the time, and each
// that calls into the guest would otherwise keep a stack slot for good
// (AIDA64 ran out after ten minutes of timers).
struct AttachedCpu {
    Cpu *cpu = nullptr;
    GuestAddr stackTop = 0;
    ~AttachedCpu() {
        if (cpu) instance->detachThreadCpu(cpu, stackTop);
    }
};
thread_local AttachedCpu attachedCpu;
}  // namespace

Cpu *Runtime::currentCpu() { return currentCpuForThread; }

Cpu &Runtime::threadCpu() {
    if (currentCpuForThread) return *currentCpuForThread;
    Runtime &rt = *instance;
    std::lock_guard guard(rt.attachLock_);
    if (!rt.idleCpus_.empty()) {
        auto [cpu, stackTop] = rt.idleCpus_.back();
        rt.idleCpus_.pop_back();
        cpu->setReg(Cpu::SP, stackTop);
        currentCpuForThread = cpu;
        cpu->bindToCurrentThread();
        attachedCpu.cpu = cpu, attachedCpu.stackTop = stackTop;
        return *cpu;
    }
    // Attached threads take stack slots from the top down; guest threads
    // created with pthread_create take them from the bottom up.
    uint32_t slot = layout::kMaxThreads - 1 - uint32_t(rt.attachedCpus_.size());
    if (slot < layout::kMaxThreads / 2) fatal("too many host threads calling into the guest");
    auto cpu = rt.makeCpu_(*rt.mem_, [&rt](Cpu &c, uint32_t imm) { rt.thunks_->dispatch(rt, c, imm); });
    GuestAddr stackBottom = layout::kStackBase + slot * layout::kStackSize;
    rt.mem_->map(stackBottom, layout::kStackSize);
    cpu->setReg(Cpu::SP, stackBottom + layout::kStackSize - 16);
    currentCpuForThread = cpu.get();
    cpu->bindToCurrentThread();
    attachedCpu.cpu = cpu.get(), attachedCpu.stackTop = stackBottom + layout::kStackSize - 16;
    rt.attachedCpus_.push_back(std::move(cpu));
    return *currentCpuForThread;
}

void Runtime::detachThreadCpu(Cpu *cpu, GuestAddr stackTop) {
    cpu->unbindThread();
    std::lock_guard guard(attachLock_);
    idleCpus_.emplace_back(cpu, stackTop);
}

std::unordered_map<std::string, DataSymbolRegistry::Entry> &DataSymbolRegistry::all() {
    static std::unordered_map<std::string, Entry> registry;
    return registry;
}

Runtime::Runtime(CpuFactory makeCpu)
    : mem_(std::make_unique<GuestMemory>()),
      heap_(std::make_unique<GuestHeap>(*mem_)),
      thunks_(std::make_unique<ThunkTable>(*mem_)),
      makeCpu_(std::move(makeCpu)),
      nextLibraryBase_(layout::kLibraryBase) {
    instance = this;
    bridge_ = std::make_unique<objc::Bridge>(*this);
    cpu_ = makeCpu_(*mem_, [this](Cpu &cpu, uint32_t imm) { thunks_->dispatch(*this, cpu, imm); });
}

uint32_t Runtime::runThread(uint32_t slot, GuestAddr fn, GuestAddr arg) {
    if (slot == 0 || slot >= layout::kMaxThreads) fatal("bad guest thread slot %u", slot);
    std::unique_ptr<Cpu> cpu = makeCpu_(*mem_, [this](Cpu &c, uint32_t imm) { thunks_->dispatch(*this, c, imm); });
    GuestAddr stackBottom = layout::kStackBase + slot * layout::kStackSize;
    if (!mem_->isMapped(stackBottom)) mem_->map(stackBottom, layout::kStackSize);
    cpu->setReg(Cpu::SP, stackBottom + layout::kStackSize - 16);
    currentCpuForThread = cpu.get();
    cpu->bindToCurrentThread();
    void *pool = objc_autoreleasePoolPush();
    uint32_t result = 0;
    try {
        result = uint32_t(cpu->call(fn, {arg}));
    } catch (const ThreadExit &exit) {
        result = exit.value;
    } catch (const ExitRequest &request) {
        std::exit(request.status);
    }
    objc_autoreleasePoolPop(pool);
    cpu->unbindThread();
    currentCpuForThread = nullptr;
    return result;
}

Runtime::~Runtime() = default;

GuestAddr Runtime::dataSymbol(const std::string &symbol) {
    if (auto it = data_.find(symbol); it != data_.end()) return it->second;
    auto &registry = DataSymbolRegistry::all();
    auto entry = registry.find(symbol);
    if (entry == registry.end()) return 0;
    GuestAddr addr = heap_->calloc(1, entry->second.size);
    data_.emplace(symbol, addr);
    entry->second.init(*this, addr);
    return addr;
}

GuestAddr Runtime::internString(const std::string &s) {
    if (auto it = strings_.find(s); it != strings_.end()) return it->second;
    GuestAddr addr = heap_->alloc(uint32_t(s.size() + 1));
    mem_->copyIn(addr, s.c_str(), s.size() + 1);
    strings_.emplace(s, addr);
    return addr;
}

namespace {
// Itanium-mangled complete and base constructors and destructors (C1, C2,
// D1, D2): the ones Apple's armv7 C++ ABI has return `this`.
bool isConstructorOrDestructor(const std::string &symbol) {
    if (symbol.rfind("__Z", 0) != 0) return false;
    for (size_t i = 0; i + 2 < symbol.size(); i++) {
        if (symbol[i + 2] != 'E') continue;
        if ((symbol[i] == 'C' || symbol[i] == 'D') && (symbol[i + 1] == '1' || symbol[i + 1] == '2')) return true;
    }
    return false;
}
}  // namespace

// Apple's armv7 ABI has constructors and destructors return `this`, and
// clang-built apps use the result; the GCC-built guest libstdc++ returns
// nothing. Apps bind to a shim that keeps r0:
//     push {r0, lr}
//     ldr  r12, [pc, #4]
//     blx  r12
//     pop  {r0, pc}
//     .word target
GuestAddr Runtime::thisReturning(GuestAddr target) {
    std::lock_guard guard(attachLock_);
    if (auto it = thisShims_.find(target); it != thisShims_.end()) return it->second;
    GuestAddr shim = heap_->alloc(20);
    const uint32_t code[5] = {0xe92d4001, 0xe59fc004, 0xe12fff3c, 0xe8bd8001, target};
    mem_->copyIn(shim, code, sizeof code);
    thisShims_[target] = shim;
    return shim;
}

GuestAddr Runtime::resolve(const std::string &symbol) {
    if (auto it = libraryExports_.find(symbol); it != libraryExports_.end())
        return isConstructorOrDestructor(symbol) ? thisReturning(it->second) : it->second;
    if (GuestAddr data = dataSymbol(symbol)) return data;
    if (GuestAddr objcData = bridge_->resolveDataSymbol(symbol)) return objcData;
    // Object constants (notification names, keys...) the host exports.
    if (!ThunkRegistry::all().count(symbol))
        if (GuestAddr constant = bridge_->resolveHostConstant(symbol)) return constant;
    return thunks_->stubFor(symbol);
}

GuestAddr Runtime::lookUp(const std::string &symbol) {
    if (auto it = image_.exports.find(symbol); it != image_.exports.end()) return it->second;
    if (libraryExports_.count(symbol) || dataSymbol(symbol) || ThunkRegistry::all().count(symbol)) return resolve(symbol);
    if (GuestAddr objcData = bridge_->resolveDataSymbol(symbol)) return objcData;
    return bridge_->resolveHostConstant(symbol);
}

namespace {
// Loads the host's copy of a framework the guest links, preferring the
// iOSSupport (Mac Catalyst) variant, so its classes and constants exist.
void loadHostLibrary(const std::string &path) {
    for (std::string candidate : {"/System/iOSSupport" + path, path})
        if (dlopen(candidate.c_str(), RTLD_NOW | RTLD_GLOBAL)) return;
    log("no host library for %s", path.c_str());
}
}  // namespace

std::string Runtime::findGuestLibrary(const std::string &installName) const {
    // Libraries the app ships itself, beside its executable or in its
    // Frameworks folder: SDL2.framework, or the Swift runtime of Swift apps
    // from before iOS 12.2.
    for (const char *prefix : {"@rpath/", "@executable_path/", "@loader_path/"}) {
        if (installName.rfind(prefix, 0) != 0) continue;
        std::string rest = installName.substr(std::strlen(prefix));
        for (const std::string &dir : {mainDir_, mainDir_ + "/Frameworks"}) {
            std::string path = dir + "/" + rest;
            if (access(path.c_str(), R_OK) == 0) return path;
        }
        return {};
    }
    std::string base = installName.substr(installName.rfind('/') + 1);
    // libstdc++.6.dylib may be there as its versioned file, libstdc++.6.0.9.dylib.
    std::string stem = base.substr(0, base.rfind(".dylib")) + ".";
    for (const auto &dir : guestLibraryDirs_) {
        std::string exact = dir + "/" + base;
        if (access(exact.c_str(), R_OK) == 0) return exact;
        if (DIR *d = opendir(dir.c_str())) {
            std::string found;
            while (dirent *e = readdir(d))
                if (std::strncmp(e->d_name, stem.c_str(), stem.size()) == 0) found = dir + "/" + e->d_name;
            closedir(d);
            if (!found.empty()) return found;
        }
    }
    return {};
}

MachOLoader Runtime::makeLoader() {
    MachOLoader loader(*mem_, [this](const std::string &s) { return resolve(s); });
    loader.onDylibs = [this](const std::vector<std::string> &dylibs) { loadLinkedLibraries(dylibs); };
    return loader;
}

// Before an image is bound: host frameworks are loaded so their classes and
// constants exist, and guest builds of libraries are loaded (dependencies
// first) so the image binds to them.
void Runtime::loadLinkedLibraries(const std::vector<std::string> &dylibs) {
    for (const auto &d : dylibs) {
        if (d.rfind("/System/Library/Frameworks/", 0) == 0) {
            loadHostLibrary(d);
            continue;
        }
        if (librariesSeen_.count(d)) continue;
        librariesSeen_[d] = true;
        std::string path = findGuestLibrary(d);
        if (path.empty() || librariesByPath_.count(path)) continue;
        loadGuestLibrary(path);
    }
}

size_t Runtime::loadGuestLibrary(const std::string &path) {
    // Each library gets its window before it loads, since its own
    // dependencies load (and take the next windows) part way through. A
    // window fits the library, in whole megabytes.
    uint32_t window = (MachOLoader::span(path) + layout::kLibraryAlignment - 1) & ~(layout::kLibraryAlignment - 1);
    GuestAddr base = nextLibraryBase_;
    nextLibraryBase_ += std::max(window, layout::kLibraryAlignment);
    if (nextLibraryBase_ > layout::kHeapBase) fatal("guest libraries have used up their address space");
    Image lib = makeLoader().load(path, base);
    for (const auto &[name, addr] : lib.exports) libraryExports_.emplace(name, addr);
    if (lib.dyldSection) {
        mem_->write<uint32_t>(lib.dyldSection, thunks_->stubFor("__dyld_lazy_symbol_binding_entry_point"));
        mem_->write<uint32_t>(lib.dyldSection + 4, thunks_->stubFor("__dyld_func_lookup"));
    }
    // Its ObjC classes, categories and selectors (SDL2's app delegate...).
    bridge_->setupImage(lib);
    log("loaded guest library %s at 0x%08x", path.c_str(), lib.slide);
    libraries_.push_back(std::move(lib));
    librariesByPath_[path] = libraries_.size() - 1;
    return libraries_.size() - 1;
}

uint32_t Runtime::openLibrary(const std::string &requested, Cpu &cpu) {
    std::lock_guard guard(openLock_);
    // As given, then relative to the app's folder (where its libraries ship).
    std::string base = requested.substr(requested.rfind('/') + 1);
    std::string path;
    for (const std::string &candidate : {requested, mainDir_ + "/" + requested, mainDir_ + "/" + base,
                                         mainDir_ + "/Frameworks/" + base})
        if (!candidate.empty() && access(candidate.c_str(), R_OK) == 0) {
            path = candidate;
            break;
        }
    if (path.empty()) path = findGuestLibrary(requested);
    if (path.empty()) return 0;
    char resolved[PATH_MAX];
    if (realpath(path.c_str(), resolved)) path = resolved;
    if (auto it = librariesByPath_.find(path); it != librariesByPath_.end()) return uint32_t(it->second + 1);

    size_t first = libraries_.size();
    size_t index = loadGuestLibrary(path);
    // Its dependencies loaded first and come before it; initialize all of
    // them in that order, as dyld does.
    for (size_t i = first; i < libraries_.size(); i++) {
        std::vector<GuestAddr> inits = libraries_[i].initializers;
        for (GuestAddr init : inits) cpu.call(init, {});
    }
    return uint32_t(index + 1);
}

GuestAddr Runtime::librarySymbol(uint32_t handle, const std::string &symbol) {
    std::lock_guard guard(openLock_);
    if (handle == 0 || handle > libraries_.size()) return 0;
    const auto &exports = libraries_[handle - 1].exports;
    auto it = exports.find(symbol);
    return it == exports.end() ? 0 : it->second;
}

void Runtime::load(const std::string &path) {
    mainDir_ = path.substr(0, path.rfind('/'));
    image_ = makeLoader().load(path);
    // Old binaries reach dyld through two pointers at the start of __dyld:
    // the lazy binding entry point and _dyld_func_lookup.
    if (image_.dyldSection) {
        mem_->write<uint32_t>(image_.dyldSection, thunks_->stubFor("__dyld_lazy_symbol_binding_entry_point"));
        mem_->write<uint32_t>(image_.dyldSection + 4, thunks_->stubFor("__dyld_func_lookup"));
    }
    bridge_->setupImage(image_);
}

GuestAddr Runtime::buildProcessStack(GuestAddr top, const std::vector<std::string> &argv,
                                     const std::vector<std::string> &envp, GuestAddr *argvOut,
                                     GuestAddr *envpOut, GuestAddr *appleOut) {
    std::vector<std::string> apple = {"executable_path=" + (argv.empty() ? image_.path : argv[0])};

    // Strings first, at the top of the stack.
    GuestAddr p = top;
    auto pushString = [&](const std::string &s) {
        p -= uint32_t(s.size() + 1);
        mem_->copyIn(p, s.c_str(), s.size() + 1);
        return p;
    };
    std::vector<GuestAddr> argvAddrs, envpAddrs, appleAddrs;
    for (const auto &s : argv) argvAddrs.push_back(pushString(s));
    for (const auto &s : envp) envpAddrs.push_back(pushString(s));
    for (const auto &s : apple) appleAddrs.push_back(pushString(s));

    // Then the block crt1's start expects at sp: argc, argv[], 0, envp[], 0, apple[], 0.
    uint32_t words = 1 + uint32_t(argvAddrs.size() + 1 + envpAddrs.size() + 1 + appleAddrs.size() + 1);
    GuestAddr sp = (p - words * 4) & ~15u;
    GuestAddr w = sp;
    auto put = [&](uint32_t v) { mem_->write<uint32_t>(w, v); w += 4; };
    put(uint32_t(argvAddrs.size()));
    *argvOut = w;
    for (auto a : argvAddrs) put(a);
    put(0);
    *envpOut = w;
    for (auto a : envpAddrs) put(a);
    put(0);
    *appleOut = w;
    for (auto a : appleAddrs) put(a);
    put(0);
    return sp;
}

int Runtime::run(const std::vector<std::string> &argv, const std::vector<std::string> &envp) {
    GuestAddr stackBottom = layout::kStackBase;
    mem_->map(stackBottom, layout::kStackSize);
    GuestAddr argvAddr, envpAddr, appleAddr;
    GuestAddr sp = buildProcessStack(stackBottom + layout::kStackSize, argv, envp, &argvAddr, &envpAddr, &appleAddr);
    cpu_->setReg(Cpu::SP, sp);
    currentCpuForThread = cpu_.get();
    cpu_->bindToCurrentThread();
    // Catches host objects autoreleased outside any guest pool.
    void *pool = objc_autoreleasePoolPush();
    struct PoolPop {
        void *pool;
        ~PoolPop() { objc_autoreleasePoolPop(pool); }
    } popOnExit{pool};

    try {
        // dyld initializes libraries first, then runs the app's +load and
        // initializers, before the entry point.
        for (const Image &lib : libraries_)
            for (GuestAddr init : lib.initializers)
                cpu_->call(init, {uint32_t(argv.size()), argvAddr, envpAddr, appleAddr});
        bridge_->runLoadMethods(*cpu_);
        for (GuestAddr init : image_.initializers)
            cpu_->call(init, {uint32_t(argv.size()), argvAddr, envpAddr, appleAddr});

        if (image_.hasMain) {
            uint64_t status = cpu_->call(image_.entry, {uint32_t(argv.size()), argvAddr, envpAddr, appleAddr});
            return int32_t(status);
        }
        // crt1's start never returns; it calls exit().
        cpu_->setReg(Cpu::LR, layout::kSentinel);
        cpu_->jump(image_.entry);
        cpu_->run();
        fatal("guest start routine returned");
    } catch (const ExitRequest &request) {
        return request.status;
    }
}

void Runtime::exit(int status) { throw ExitRequest{status}; }

}  // namespace b32
