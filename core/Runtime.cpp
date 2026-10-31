#include "Runtime.h"

#include "core/Log.h"
#include "core/mem/Layout.h"

namespace b32 {

namespace {
// Thrown by Runtime::exit from inside a thunk. SVCs are dispatched outside the
// JIT, so this only unwinds host frames.
struct ExitRequest {
    int status;
};
}  // namespace

std::unordered_map<std::string, DataSymbolRegistry::Entry> &DataSymbolRegistry::all() {
    static std::unordered_map<std::string, Entry> registry;
    return registry;
}

Runtime::Runtime(CpuFactory makeCpu)
    : mem_(std::make_unique<GuestMemory>()),
      heap_(std::make_unique<GuestHeap>(*mem_)),
      thunks_(std::make_unique<ThunkTable>(*mem_)) {
    cpu_ = makeCpu(*mem_, [this](Cpu &cpu, uint32_t imm) { thunks_->dispatch(*this, cpu, imm); });
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
    return thunks_->stubFor(symbol);
}

void Runtime::load(const std::string &path) {
    MachOLoader loader(*mem_, [this](const std::string &s) { return resolve(s); });
    image_ = loader.load(path);
    // Old binaries reach dyld through two pointers at the start of __dyld:
    // the lazy binding entry point and _dyld_func_lookup.
    if (image_.dyldSection) {
        mem_->write<uint32_t>(image_.dyldSection, thunks_->stubFor("__dyld_lazy_symbol_binding_entry_point"));
        mem_->write<uint32_t>(image_.dyldSection + 4, thunks_->stubFor("__dyld_func_lookup"));
    }
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

    try {
        // dyld runs initializers before the entry point in both binary eras.
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
