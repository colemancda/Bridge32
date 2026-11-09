#include "UnicornPowerCpu.h"

#include "core/Log.h"
#include "core/arch/Arch.h"
#include "core/mem/Layout.h"

#include <unicorn/unicorn.h>

#include <cstring>

namespace b32 {

namespace {

// MSR bits Mac OS X leaves on for a process: floating point and AltiVec.
constexpr uint32_t kMsrFp = 1u << 13, kMsrVec = 1u << 25;
// QEMU's exception number for `sc`.
constexpr int kSyscallException = 8;

void check(uc_err err, const char *what) {
    if (err != UC_ERR_OK) fatal("unicorn: %s: %s", what, uc_strerror(err));
}

int ucReg(int n) {
    switch (n) {
    case PowerCpu::PC: return UC_PPC_REG_PC;
    case PowerCpu::LR: return UC_PPC_REG_LR;
    case PowerCpu::CTR: return UC_PPC_REG_CTR;
    case PowerCpu::CR: return UC_PPC_REG_CR;
    case PowerCpu::XER: return UC_PPC_REG_XER;
    case PowerCpu::MSR: return UC_PPC_REG_MSR;
    default: return UC_PPC_REG_0 + n;
    }
}

bool onUnmapped(uc_engine *, uc_mem_type, uint64_t address, int, int64_t, void *user) {
    return static_cast<UnicornPowerCpu *>(user)->mapAroundForHook(address);
}

// Every exception comes here: `sc` is a thunk trap, anything else (a program
// check, an unavailable unit) is a fault the run loop reports. QEMU has
// already moved the PC past the instruction.
void onInterrupt(uc_engine *uc, uint32_t number, void *user) {
    static_cast<UnicornPowerCpu *>(user)->interrupted(number);
    uc_emu_stop(uc);
}

}  // namespace

UnicornPowerCpu::UnicornPowerCpu(GuestMemory &mem, SvcHandler handler)
    : PowerCpu(mem, std::move(handler)), mapped_(GuestMemory::kSize / GuestMemory::kPageSize / 8) {
    check(uc_open(UC_ARCH_PPC, uc_mode(UC_MODE_PPC32 | UC_MODE_BIG_ENDIAN), &uc_), "open");
    // The Mac of the era: a 7447A, the G4 of the last PowerBooks (AltiVec
    // included; the 7400 and 7450 differ only in details no app depends on).
    check(uc_ctl_set_cpu_model(uc_, UC_CPU_PPC32_7447A_V1_2), "cpu model");
    uint32_t msr = reg(MSR) | kMsrFp | kMsrVec;
    setReg(MSR, msr);
    uc_hook hook;
    check(uc_hook_add(uc_, &hook, UC_HOOK_MEM_UNMAPPED, reinterpret_cast<void *>(onUnmapped), this, 1, 0),
          "unmapped hook");
    check(uc_hook_add(uc_, &hook, UC_HOOK_INTR, reinterpret_cast<void *>(onInterrupt), this, 1, 0), "interrupt hook");
}

UnicornPowerCpu::~UnicornPowerCpu() { uc_close(uc_); }

bool UnicornPowerCpu::mapAroundForHook(uint64_t address) {
    return address < GuestMemory::kSize && mapAround(GuestAddr(address));
}

void UnicornPowerCpu::mapPages(uint32_t first, uint32_t end) {
    uint64_t start = uint64_t(first) * GuestMemory::kPageSize, size = uint64_t(end - first) * GuestMemory::kPageSize;
    check(uc_mem_map_ptr(uc_, start, size, UC_PROT_ALL, mem().base() + start), "map");
    for (uint32_t p = first; p < end; p++) mapped_[p / 8] |= uint8_t(1u << (p % 8));
}

bool UnicornPowerCpu::mapAround(GuestAddr addr) {
    constexpr uint32_t kPages = GuestMemory::kSize / GuestMemory::kPageSize;
    uint32_t page = addr / GuestMemory::kPageSize;
    if (!mem().isMapped(addr)) {
        fault_ = Fault{addr, false};
        return false;
    }
    if (isPageMapped(page)) return true;
    uint32_t lo = page, hi = page + 1;
    while (lo > 0 && mem().isMapped((lo - 1) * GuestMemory::kPageSize) && !isPageMapped(lo - 1)) lo--;
    while (hi < kPages && mem().isMapped(hi * GuestMemory::kPageSize) && !isPageMapped(hi)) hi++;
    mapPages(lo, hi);
    return true;
}

uint32_t UnicornPowerCpu::reg(int n) const {
    uint32_t value = 0;
    check(uc_reg_read(uc_, ucReg(n), &value), "reg read");
    return value;
}

void UnicornPowerCpu::setReg(int n, uint32_t value) { check(uc_reg_write(uc_, ucReg(n), &value), "reg write"); }

double UnicornPowerCpu::fpr(int n) const {
    uint64_t bits = 0;
    check(uc_reg_read(uc_, UC_PPC_REG_FPR0 + n, &bits), "fpr read");
    double value;
    std::memcpy(&value, &bits, 8);
    return value;
}

void UnicornPowerCpu::setFpr(int n, double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, 8);
    check(uc_reg_write(uc_, UC_PPC_REG_FPR0 + n, &bits), "fpr write");
}

void UnicornPowerCpu::vr(int n, uint8_t out[16]) const { check(uc_reg_read(uc_, UC_PPC_REG_VR0 + n, out), "vr read"); }

void UnicornPowerCpu::setVr(int n, const uint8_t in[16]) { check(uc_reg_write(uc_, UC_PPC_REG_VR0 + n, in), "vr write"); }

// A saved state is a uc_context, kept alive until restored; the vector holds
// its pointer.
std::vector<uint8_t> UnicornPowerCpu::saveState() {
    uc_context *ctx = nullptr;
    check(uc_context_alloc(uc_, &ctx), "context alloc");
    check(uc_context_save(uc_, ctx), "context save");
    std::vector<uint8_t> state(sizeof ctx);
    std::memcpy(state.data(), &ctx, sizeof ctx);
    return state;
}

void UnicornPowerCpu::restoreState(const std::vector<uint8_t> &state) {
    uc_context *ctx = nullptr;
    std::memcpy(&ctx, state.data(), sizeof ctx);
    check(uc_context_restore(uc_, ctx), "context restore");
    uc_context_free(ctx);
}

uint32_t UnicornPowerCpu::runUntilSvc() {
    for (;;) {
        fault_.reset();
        interrupt_ = -1;
        enterGuest();
        uc_err err = uc_emu_start(uc_, reg(PC), 0, 0, 0);
        leaveGuest();
        uint32_t pc = reg(PC);
        switch (err) {
        case UC_ERR_OK: {
            if (interrupt_ < 0) continue;  // a halt request (suspend): the guest stopped wherever it was
            // The PC is past the instruction that raised the exception.
            GuestAddr trap = pc - 4;
            if (interrupt_ != kSyscallException)
                fatal("guest exception %d at 0x%08x (r1=0x%08x, msr=0x%08x)", interrupt_, trap, reg(SP), reg(MSR));
            if (trap == layout::kSentinel) return kSentinelSvc;
            if (trap >= layout::kStubBase && trap < layout::kStubBase + layout::kStubRegionSize &&
                (trap - layout::kStubBase) % arch::kThunkStubSize == 0)
                return (trap - layout::kStubBase) / arch::kThunkStubSize;
            fatal("guest system call at 0x%08x (r0=%u): Mac OS X programs call libSystem, not the kernel", trap, reg(R0));
        }
        case UC_ERR_READ_UNMAPPED:
        case UC_ERR_WRITE_UNMAPPED:
        case UC_ERR_FETCH_UNMAPPED:
        case UC_ERR_READ_PROT:
        case UC_ERR_WRITE_PROT:
        case UC_ERR_FETCH_PROT: {
            Fault f = fault_.value_or(Fault{0, false});
            f.write = err == UC_ERR_WRITE_UNMAPPED || err == UC_ERR_WRITE_PROT;
            deliverFault(f.addr, f.write);
            continue;
        }
        default:
            fatal("unicorn stopped: %s at pc=0x%08x r1=0x%08x", uc_strerror(err), pc, reg(SP));
        }
    }
}

void UnicornPowerCpu::requestHalt() { uc_emu_stop(uc_); }

}  // namespace b32
