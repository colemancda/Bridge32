#include "Runtime.h"

#include "core/Log.h"
#include "core/mem/Layout.h"
#include "core/objc/Bridge.h"

#include <dlfcn.h>

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
}  // namespace

Cpu *Runtime::currentCpu() { return currentCpuForThread; }

Cpu &Runtime::threadCpu() {
    if (currentCpuForThread) return *currentCpuForThread;
    Runtime &rt = *instance;
    std::lock_guard guard(rt.attachLock_);
    // Attached threads take stack slots from the top down; guest threads
    // created with pthread_create take them from the bottom up.
    uint32_t slot = layout::kMaxThreads - 1 - uint32_t(rt.attachedCpus_.size());
    if (slot < layout::kMaxThreads / 2) fatal("too many host threads calling into the guest");
    auto cpu = rt.makeCpu_(*rt.mem_, [&rt](Cpu &c, uint32_t imm) { rt.thunks_->dispatch(rt, c, imm); });
    GuestAddr stackBottom = layout::kStackBase + slot * layout::kStackSize;
    rt.mem_->map(stackBottom, layout::kStackSize);
    cpu->setReg(Cpu::SP, stackBottom + layout::kStackSize - 16);
    currentCpuForThread = cpu.get();
    rt.attachedCpus_.push_back(std::move(cpu));
    return *currentCpuForThread;
}

std::unordered_map<std::string, DataSymbolRegistry::Entry> &DataSymbolRegistry::all() {
    static std::unordered_map<std::string, Entry> registry;
    return registry;
}

Runtime::Runtime(CpuFactory makeCpu)
    : mem_(std::make_unique<GuestMemory>()),
      heap_(std::make_unique<GuestHeap>(*mem_)),
      thunks_(std::make_unique<ThunkTable>(*mem_)),
      makeCpu_(std::move(makeCpu)) {
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

GuestAddr Runtime::resolve(const std::string &symbol) {
    if (GuestAddr data = dataSymbol(symbol)) return data;
    if (GuestAddr objcData = bridge_->resolveDataSymbol(symbol)) return objcData;
    // Object constants (notification names, keys...) the host exports.
    if (!ThunkRegistry::all().count(symbol))
        if (GuestAddr constant = bridge_->resolveHostConstant(symbol)) return constant;
    return thunks_->stubFor(symbol);
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

void Runtime::load(const std::string &path) {
    MachOLoader loader(*mem_, [this](const std::string &s) { return resolve(s); });
    loader.onDylibs = [](const std::vector<std::string> &dylibs) {
        for (const auto &d : dylibs)
            if (d.rfind("/System/Library/Frameworks/", 0) == 0) loadHostLibrary(d);
    };
    image_ = loader.load(path);
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
    // Catches host objects autoreleased outside any guest pool.
    void *pool = objc_autoreleasePoolPush();
    struct PoolPop {
        void *pool;
        ~PoolPop() { objc_autoreleasePoolPop(pool); }
    } popOnExit{pool};

    try {
        // dyld runs +load, then initializers, before the entry point.
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
