#include "Thunks.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/mem/Layout.h"

#include <cstdlib>
#include <cstring>

namespace b32 {

namespace {
constexpr uint32_t kArmSvc = 0xEF000000;
constexpr uint32_t kArmBxLr = 0xE12FFF1E;
}  // namespace

std::unordered_map<std::string, ThunkFn> &ThunkRegistry::all() {
    static std::unordered_map<std::string, ThunkFn> registry;
    return registry;
}

ThunkTable::ThunkTable(GuestMemory &mem) : mem_(mem) {
    mem_.map(layout::kStubBase, layout::kStubRegionSize);
    // The sentinel is the first page after the stubs.
    mem_.map(layout::kSentinel, GuestMemory::kPageSize);
    mem_.write<uint32_t>(layout::kSentinel, kArmSvc | Cpu::kSentinelSvc);
}

GuestAddr ThunkTable::stubFor(const std::string &symbol) {
    std::lock_guard guard(lock_);
    auto [it, inserted] = byName_.try_emplace(symbol, uint32_t(entries_.size()));
    uint32_t index = it->second;
    if (inserted) {
        if ((index + 1) * 8 > layout::kStubRegionSize) fatal("out of thunk stubs");
        auto &registry = ThunkRegistry::all();
        auto fn = registry.find(symbol);
        entries_.push_back({symbol, fn == registry.end() ? nullptr : fn->second});
        GuestAddr stub = layout::kStubBase + index * 8;
        mem_.write<uint32_t>(stub, kArmSvc | index);
        mem_.write<uint32_t>(stub + 4, kArmBxLr);
    }
    return layout::kStubBase + index * 8;
}

void ThunkTable::dispatch(Runtime &rt, Cpu &cpu, uint32_t index) {
    ThunkFn fn;
    const char *name;
    {
        std::lock_guard guard(lock_);
        if (index >= entries_.size()) fatal("SVC #0x%x at 0x%08x is not a thunk", index, cpu.reg(Cpu::PC) - 4);
        // Deque elements never move, so the name stays valid after unlocking.
        fn = entries_[index].fn;
        name = entries_[index].name.c_str();
    }
    if (!fn) fatal("missing symbol %s (called from 0x%08x)", name, cpu.reg(Cpu::LR));
    // B32_TRACE_THUNKS=1 logs every import called; any other value only the
    // imports whose names contain it.
    static const char *trace = getenv("B32_TRACE_THUNKS");
    if (trace && (!strcmp(trace, "1") || strstr(name, trace)))
        log("%s from 0x%08x", name, cpu.reg(Cpu::LR));
    Call call{rt, cpu, rt.mem(), rt.heap(), Args(cpu), name};
    fn(call);
}

std::string ThunkTable::nameOf(uint32_t index) const {
    std::lock_guard guard(lock_);
    return index < entries_.size() ? entries_[index].name : "";
}

std::vector<std::string> ThunkTable::missing() const {
    std::lock_guard guard(lock_);
    std::vector<std::string> names;
    for (const auto &e : entries_)
        if (!e.fn) names.push_back(e.name);
    return names;
}

}  // namespace b32
