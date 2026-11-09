#pragma once

#include "core/arch/ppc/PowerCpu.h"

#include <optional>

struct uc_struct;

namespace b32 {

// PowerCpu backed by Unicorn's PowerPC engine (QEMU's TCG, a G4 model). One
// engine per guest thread, all over the same guest memory: committed pages are
// mapped into an engine the first time it touches them. The guest runs with
// the FPU and AltiVec enabled, as Mac OS X leaves them for a process.
class UnicornPowerCpu final : public PowerCpu {
public:
    UnicornPowerCpu(GuestMemory &mem, SvcHandler handler);
    ~UnicornPowerCpu() override;

    uint32_t reg(int n) const override;
    void setReg(int n, uint32_t value) override;
    double fpr(int n) const override;
    void setFpr(int n, double value) override;
    void vr(int n, uint8_t out[16]) const override;
    void setVr(int n, const uint8_t in[16]) override;
    std::vector<uint8_t> saveState() override;
    void restoreState(const std::vector<uint8_t> &state) override;

    // For the engine's hooks.
    bool mapAroundForHook(uint64_t address);
    void interrupted(uint32_t number) { interrupt_ = int(number); }

protected:
    uint32_t runUntilSvc() override;
    void requestHalt() override;

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

    uc_struct *uc_ = nullptr;
    std::vector<uint8_t> mapped_;  // one bit per host page mapped into this engine
    std::optional<Fault> fault_;
    int interrupt_ = -1;  // the exception that stopped the engine, if one did
};

}  // namespace b32
