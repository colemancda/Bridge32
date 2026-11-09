#include "Thunks.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/arch/Arch.h"
#include "core/mem/Layout.h"

#include <cstdlib>
#include <cstring>

namespace b32 {

std::unordered_map<std::string, ThunkFn> &ThunkRegistry::all() {
    static std::unordered_map<std::string, ThunkFn> registry;
    return registry;
}

namespace {
const char *const kVariantSuffixes[] = {"$UNIX2003", "$INODE64", "$NOCANCEL", "$DARWIN_EXTSN", "$1050", "$1060", "$1070"};

// Removes the variant suffixes from `symbol`, keeping $INODE64 when asked.
std::string withoutVariants(std::string symbol, bool keepInode64) {
    for (bool changed = true; changed;) {
        changed = false;
        for (const char *suffix : kVariantSuffixes) {
            if (keepInode64 && std::strcmp(suffix, "$INODE64") == 0) continue;
            size_t at = symbol.find(suffix);
            if (at == std::string::npos) continue;
            symbol.erase(at, std::strlen(suffix));
            changed = true;
        }
    }
    return symbol;
}
}  // namespace

std::string baseSymbol(const std::string &symbol) { return withoutVariants(symbol, false); }

ThunkFn ThunkRegistry::find(const std::string &symbol) {
    auto &registry = all();
    auto it = registry.find(symbol);
    if (it == registry.end()) it = registry.find(withoutVariants(symbol, true));
    if (it == registry.end()) it = registry.find(baseSymbol(symbol));
    return it == registry.end() ? nullptr : it->second;
}

StructResult::StructResult(Call &c, uint32_t size) : c_(c), inMemory_(arch::structReturnedInMemory(size)) {
    addr_ = inMemory_ ? c.args.ptr() : c.heap.calloc(1, 8);
}

StructResult::~StructResult() {
    if (inMemory_) {
        c_.cpu.popStructPointer();
        return;
    }
    c_.cpu.setResult64(c_.mem.read<uint64_t>(addr_));
    c_.heap.free(addr_);
}

ThunkTable::ThunkTable(GuestMemory &mem) : mem_(mem) {
    mem_.map(layout::kStubBase, layout::kStubRegionSize);
    // The sentinel is the first page after the stubs.
    mem_.map(layout::kSentinel, GuestMemory::kPageSize);
    arch::writeSentinel(mem_, layout::kSentinel);
}

GuestAddr ThunkTable::stubFor(const std::string &symbol) {
    std::lock_guard guard(lock_);
    auto [it, inserted] = byName_.try_emplace(symbol, uint32_t(entries_.size()));
    uint32_t index = it->second;
    if (inserted) {
        if ((index + 1) * arch::kThunkStubSize > layout::kStubRegionSize) fatal("out of thunk stubs");
        entries_.push_back({symbol, ThunkRegistry::find(symbol)});
        arch::writeThunkStub(mem_, layout::kStubBase + index * arch::kThunkStubSize, index);
    }
    return layout::kStubBase + index * arch::kThunkStubSize;
}

void ThunkTable::dispatch(Runtime &rt, Cpu &cpu, uint32_t index) {
    ThunkFn fn;
    const char *name;
    {
        std::lock_guard guard(lock_);
        if (index >= entries_.size()) fatal("trap #0x%x at 0x%08x is not a thunk", index, cpu.pc());
        // Deque elements never move, so the name stays valid after unlocking.
        fn = entries_[index].fn;
        name = entries_[index].name.c_str();
    }
    if (!fn) fatal("missing symbol %s (called from 0x%08x)", name, cpu.returnAddress());
    // B32_TRACE_THUNKS=1 logs every import called; any other value only the
    // imports whose names contain it.
    static const char *trace = getenv("B32_TRACE_THUNKS");
    if (trace && (!strcmp(trace, "1") || strstr(name, trace)))
        log("%s from 0x%08x", name, cpu.returnAddress());
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
