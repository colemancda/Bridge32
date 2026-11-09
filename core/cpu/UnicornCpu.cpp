#include "UnicornCpu.h"

#include "core/Log.h"
#include "core/arch/Arch.h"
#include "core/mem/Layout.h"

#include <unicorn/unicorn.h>

#include <cstring>
#include <mutex>

namespace b32 {

namespace {

constexpr int kRegIds[] = {UC_X86_REG_EAX, UC_X86_REG_ECX, UC_X86_REG_EDX, UC_X86_REG_EBX, UC_X86_REG_ESP,
                           UC_X86_REG_EBP, UC_X86_REG_ESI, UC_X86_REG_EDI, UC_X86_REG_EIP, UC_X86_REG_EFLAGS};

void check(uc_err err, const char *what) {
    if (err != UC_ERR_OK) fatal("unicorn: %s: %s", what, uc_strerror(err));
}

// Each CPU's GDT: a null descriptor, flat code and data, and a data segment
// based at the thread's TSD for %gs. They live in the sentinel's page, which
// the thunk table maps before any CPU exists.
constexpr GuestAddr kGdtArena = layout::kSentinel + 0x100;
constexpr uint32_t kGdtSize = 32;
constexpr uint32_t kGdtSlots = (GuestMemory::kPageSize - 0x100) / kGdtSize;
constexpr uint16_t kCodeSelector = 0x08, kDataSelector = 0x10, kGsSelector = 0x18;
std::mutex gdtLock;
std::vector<uint32_t> freeGdts;
uint32_t nextGdt = 0;

GuestAddr allocGdt() {
    std::lock_guard guard(gdtLock);
    if (!freeGdts.empty()) {
        uint32_t slot = freeGdts.back();
        freeGdts.pop_back();
        return kGdtArena + slot * kGdtSize;
    }
    if (nextGdt >= kGdtSlots) fatal("out of GDT slots for guest threads");
    return kGdtArena + nextGdt++ * kGdtSize;
}

void freeGdt(GuestAddr gdt) {
    std::lock_guard guard(gdtLock);
    freeGdts.push_back((gdt - kGdtArena) / kGdtSize);
}

// A segment descriptor: 4 GB limit (granularity 4 KB), 32-bit, present,
// ring 0; `access` is the type byte (0x9A code, 0x92 data).
uint64_t descriptor(uint32_t base, uint8_t access) {
    const uint32_t limit = 0xFFFFF;
    uint64_t d = limit & 0xFFFF;
    d |= uint64_t(base & 0xFFFF) << 16;
    d |= uint64_t((base >> 16) & 0xFF) << 32;
    d |= uint64_t(access) << 40;
    d |= uint64_t((limit >> 16) & 0xF) << 48;
    d |= uint64_t(0xC) << 52;  // G, D/B
    d |= uint64_t(base & 0xFF000000) << 32;
    return d;
}

bool onUnmapped(uc_engine *, uc_mem_type type, uint64_t address, int, int64_t, void *user) {
    auto *cpu = static_cast<UnicornCpu *>(user);
    (void)type;
    return cpu->mapAroundForHook(address);
}

}  // namespace

UnicornCpu::UnicornCpu(GuestMemory &mem, SvcHandler handler)
    : X86Cpu(mem, std::move(handler)), mapped_(GuestMemory::kSize / GuestMemory::kPageSize / 8) {
    check(uc_open(UC_ARCH_X86, UC_MODE_32, &uc_), "open");
    // The Mac of the era: Penryn Core 2 (SSE4.1 and everything before it).
    check(uc_ctl_set_cpu_model(uc_, UC_CPU_X86_PENRYN), "cpu model");
    // Unicorn enables SSE (CR4.OSFXSR) only for CPU models with XSAVE, which
    // Penryn predates; Darwin's kernel always has it on.
    uint32_t cr4 = 0;
    check(uc_reg_read(uc_, UC_X86_REG_CR4, &cr4), "cr4");
    cr4 |= 0x200 | 0x400;  // OSFXSR, OSXMMEXCPT
    check(uc_reg_write(uc_, UC_X86_REG_CR4, &cr4), "cr4");
    uc_hook hook;
    check(uc_hook_add(uc_, &hook, UC_HOOK_MEM_UNMAPPED, reinterpret_cast<void *>(onUnmapped), this, 1, 0),
          "unmapped hook");

    // The sentinel's page, eagerly: it holds the GDT, which segment loads
    // read outside of emulation.
    uint32_t page = layout::kSentinel / GuestMemory::kPageSize;
    mapPages(page, page + 1);
    gdt_ = allocGdt();
    writeGdt();
}

UnicornCpu::~UnicornCpu() {
    freeGdt(gdt_);
    uc_close(uc_);
}

bool UnicornCpu::mapAroundForHook(uint64_t address) {
    return address < GuestMemory::kSize && mapAround(GuestAddr(address));
}

void UnicornCpu::mapPages(uint32_t first, uint32_t end) {
    uint64_t start = uint64_t(first) * GuestMemory::kPageSize, size = uint64_t(end - first) * GuestMemory::kPageSize;
    check(uc_mem_map_ptr(uc_, start, size, UC_PROT_ALL, mem().base() + start), "map");
    for (uint32_t p = first; p < end; p++) mapped_[p / 8] |= uint8_t(1u << (p % 8));
}

bool UnicornCpu::mapAround(GuestAddr addr) {
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

void UnicornCpu::writeGdt() {
    mem().write<uint64_t>(gdt_, 0);
    mem().write<uint64_t>(gdt_ + 8, descriptor(0, 0x9A));
    mem().write<uint64_t>(gdt_ + 16, descriptor(0, 0x92));
    mem().write<uint64_t>(gdt_ + 24, descriptor(tsd_, 0x92));
    uc_x86_mmr gdtr{};
    gdtr.base = gdt_;
    gdtr.limit = kGdtSize - 1;
    check(uc_reg_write(uc_, UC_X86_REG_GDTR, &gdtr), "gdtr");
    // Every segment comes from the GDT: QEMU recomputes the 32-bit code and
    // stack flags from the CS and SS descriptors on any segment load, and
    // the reset-state descriptors would make them 16-bit.
    uint16_t cs = kCodeSelector, ds = kDataSelector, gs = kGsSelector;
    check(uc_reg_write(uc_, UC_X86_REG_CS, &cs), "cs");
    check(uc_reg_write(uc_, UC_X86_REG_SS, &ds), "ss");
    check(uc_reg_write(uc_, UC_X86_REG_DS, &ds), "ds");
    check(uc_reg_write(uc_, UC_X86_REG_ES, &ds), "es");
    check(uc_reg_write(uc_, UC_X86_REG_FS, &ds), "fs");
    check(uc_reg_write(uc_, UC_X86_REG_GS, &gs), "gs");
}

void UnicornCpu::tsdChanged() { writeGdt(); }

uint32_t UnicornCpu::reg(int n) const {
    uint32_t value = 0;
    check(uc_reg_read(uc_, kRegIds[n], &value), "reg read");
    return value;
}

void UnicornCpu::setReg(int n, uint32_t value) { check(uc_reg_write(uc_, kRegIds[n], &value), "reg write"); }

uint16_t UnicornCpu::fpsw() const {
    uint16_t sw = 0;
    check(uc_reg_read(uc_, UC_X86_REG_FPSW, &sw), "fpsw");
    return sw;
}

uint16_t UnicornCpu::fptag() const {
    uint16_t tag = 0;
    check(uc_reg_read(uc_, UC_X86_REG_FPTAG, &tag), "fptag");
    return tag;
}

// The x87 stack grows down through the eight physical registers; TOP is
// bits 11-13 of the status word, and the tag word has two bits per physical
// register (11 = empty).
void UnicornCpu::pushX87(double value) {
    uint16_t sw = fpsw();
    uint32_t top = ((sw >> 11) + 7) & 7;
    sw = uint16_t((sw & ~0x3800) | (top << 11));
    check(uc_reg_write(uc_, UC_X86_REG_FPSW, &sw), "fpsw");
    uint16_t tag = uint16_t(fptag() & ~(3u << (top * 2)));
    check(uc_reg_write(uc_, UC_X86_REG_FPTAG, &tag), "fptag");
    uint8_t bytes[10];
    toFloat80(value, bytes);
    check(uc_reg_write(uc_, UC_X86_REG_ST0, bytes), "st0");
}

double UnicornCpu::popX87() {
    uint16_t sw = fpsw();
    uint32_t top = (sw >> 11) & 7;
    uint8_t bytes[10];
    check(uc_reg_read(uc_, UC_X86_REG_ST0, bytes), "st0");
    uint16_t tag = uint16_t(fptag() | (3u << (top * 2)));
    check(uc_reg_write(uc_, UC_X86_REG_FPTAG, &tag), "fptag");
    sw = uint16_t((sw & ~0x3800) | (((top + 1) & 7) << 11));
    check(uc_reg_write(uc_, UC_X86_REG_FPSW, &sw), "fpsw");
    return fromFloat80(bytes);
}

bool UnicornCpu::x87HasResult() {
    uint32_t top = (fpsw() >> 11) & 7;
    return ((fptag() >> (top * 2)) & 3) != 3;
}

// A saved state is a uc_context, kept alive until restored; the vector holds
// its pointer.
std::vector<uint8_t> UnicornCpu::saveState() {
    uc_context *ctx = nullptr;
    check(uc_context_alloc(uc_, &ctx), "context alloc");
    check(uc_context_save(uc_, ctx), "context save");
    std::vector<uint8_t> state(sizeof ctx);
    std::memcpy(state.data(), &ctx, sizeof ctx);
    return state;
}

void UnicornCpu::restoreState(const std::vector<uint8_t> &state) {
    uc_context *ctx = nullptr;
    std::memcpy(&ctx, state.data(), sizeof ctx);
    check(uc_context_restore(uc_, ctx), "context restore");
    uc_context_free(ctx);
}

uint32_t UnicornCpu::runUntilSvc() {
    for (;;) {
        fault_.reset();
        enterGuest();
        uc_err err = uc_emu_start(uc_, reg(EIP), 0, 0, 0);
        leaveGuest();
        uint32_t eip = reg(EIP);
        switch (err) {
        case UC_ERR_OK: {
            // A hlt leaves eip just past itself; a halt request (suspend)
            // leaves it wherever the guest was.
            GuestAddr trap = eip - 1;
            if (trap == layout::kSentinel) return kSentinelSvc;
            if (trap >= layout::kStubBase && trap < layout::kStubBase + layout::kStubRegionSize &&
                (trap - layout::kStubBase) % arch::kThunkStubSize == 0)
                return (trap - layout::kStubBase) / arch::kThunkStubSize;
            continue;
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
        case UC_ERR_INSN_INVALID: {
            uint8_t bytes[8] = {};
            if (mem().isMapped(eip) && mem().isMapped(eip + 7)) std::memcpy(bytes, mem().ptr<uint8_t>(eip), 8);
            fatal("invalid guest instruction at 0x%08x: %02x %02x %02x %02x %02x %02x %02x %02x (esp=0x%08x)", eip,
                  bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], reg(ESP));
        }
        default:
            fatal("unicorn stopped: %s at eip=0x%08x esp=0x%08x (a software interrupt, or a misaligned locked "
                  "instruction)",
                  uc_strerror(err), eip, reg(ESP));
        }
    }
}

void UnicornCpu::requestHalt() { uc_emu_stop(uc_); }

}  // namespace b32
