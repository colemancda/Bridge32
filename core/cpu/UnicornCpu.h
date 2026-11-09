#pragma once

#include "core/arch/i386/X86Cpu.h"

#include <optional>

struct uc_struct;

namespace b32 {

// X86Cpu backed by Unicorn's x86 engine (QEMU's TCG). One engine per guest
// thread, all over the same guest memory: committed pages are mapped into an
// engine the first time it touches them.
class UnicornCpu final : public X86Cpu {
public:
    UnicornCpu(GuestMemory &mem, SvcHandler handler);
    ~UnicornCpu() override;

    uint32_t reg(int n) const override;
    void setReg(int n, uint32_t value) override;
    void pushX87(double value) override;
    double popX87() override;
    std::vector<uint8_t> saveState() override;
    void restoreState(const std::vector<uint8_t> &state) override;

    // For the engine's unmapped-memory hook.
    bool mapAroundForHook(uint64_t address);

protected:
    uint32_t runUntilSvc() override;
    void requestHalt() override;
    void tsdChanged() override;
    bool x87HasResult() override;

private:
    struct Fault {
        uint32_t addr;
        bool write;
    };

    // Maps the committed pages around `addr` into the engine; false (with the
    // fault recorded) if the guest never mapped `addr`.
    bool mapAround(GuestAddr addr);
    void mapPages(uint32_t first, uint32_t end);
    bool isPageMapped(uint32_t page) const { return mapped_[page / 8] & (1u << (page % 8)); }
    void writeGdt();
    uint16_t fpsw() const;
    uint16_t fptag() const;

    uc_struct *uc_ = nullptr;
    std::vector<uint8_t> mapped_;  // one bit per host page mapped into this engine
    GuestAddr gdt_ = 0;
    std::optional<Fault> fault_;
};

}  // namespace b32
