// Tests of the PowerPC guest's CPU: the Unicorn engine behind PowerCpu, big-
// endian guest memory, Darwin's calling convention at a thunk trap and for
// host-to-guest calls, signal delivery, and the engine patches
// (external/unicorn-ppc.patch). The guest code is tests/ppc/cpu-test.s,
// assembled into cpu-test-code.h by tools/ppc-asm.py.
//
// No loader is involved: the code is copied into guest memory and called.

#include "core/arch/Arch.h"
#include "core/cpu/UnicornPowerCpu.h"
#include "core/mem/Layout.h"

#include "cpu-test-code.h"

#include <signal.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

using namespace b32;
using namespace ppccode;

namespace {

int failures = 0;

#define CHECK(condition)                                                          \
    do {                                                                          \
        if (!(condition)) {                                                       \
            std::printf("FAIL: line %d: %s\n", __LINE__, #condition);             \
            failures++;                                                           \
        }                                                                         \
    } while (0)

constexpr GuestAddr kCode = 0x10000, kData = 0x20000, kStackTop = 0x40000;
constexpr uint32_t kStackSlot = 0x4000;  // one stack per thread, below kStackTop

// What the thunks saw, for the tests to check.
struct Seen {
    std::vector<uint32_t> args;
    uint32_t returnAddress = 0;
    std::vector<uint32_t> chain;
    int traps = 0;
} seen;

// The test thunks: stub index -> what the host does. Index 0 sums nine
// arguments, 1 calls back into the guest, 2 records the frame chain, 3 and 4
// return floating-point results.
void thunk(Cpu &cpu, uint32_t index) {
    auto &c = static_cast<PowerCpu &>(cpu);
    seen.traps++;
    switch (index) {
    case 0: {
        uint32_t sum = 0;
        seen.args.clear();
        for (int i = 0; i < 9; i++) {
            seen.args.push_back(c.arg(i));
            sum += c.arg(i);
        }
        seen.returnAddress = c.returnAddress();
        c.setResult(sum);
        break;
    }
    case 1: {
        GuestAddr fn = c.arg(0);
        uint64_t doubled = c.call(fn, {c.arg(1)});
        c.setResult(uint32_t(doubled) + 1);
        break;
    }
    case 2:
        seen.chain = c.frameChain(8);
        break;
    case 3: c.setDoubleResult(2.5); break;
    case 4: c.setFloatResult(1.25f); break;
    default: std::printf("FAIL: unexpected thunk %u\n", index); failures++;
    }
}

GuestMemory &memory() {
    static GuestMemory *mem = [] {
        auto *m = new GuestMemory;
        m->map(kCode, 0x10000);
        m->map(kData, 0x10000);
        m->map(kStackTop - 0x10000, 0x10000);
        m->map(layout::kStubBase, GuestMemory::kPageSize);
        m->map(layout::kSentinel, GuestMemory::kPageSize);
        for (uint32_t i = 0; i < 8; i++) arch::writeThunkStub(*m, layout::kStubBase + i * arch::kThunkStubSize, i);
        arch::writeSentinel(*m, layout::kSentinel);
        for (uint32_t i = 0; i < sizeof kWords / 4; i++) m->write<uint32_t>(kCode + i * 4, kWords[i]);
        return m;
    }();
    return *mem;
}

std::unique_ptr<UnicornPowerCpu> makeCpu(int thread = 0) {
    auto cpu = std::make_unique<UnicornPowerCpu>(memory(), thunk);
    cpu->setReg(PowerCpu::SP, kStackTop - uint32_t(thread) * kStackSlot - 0x100);
    return cpu;
}

// Runs the guest function at `fn` with the registers as the test set them,
// leaving the results in the registers (call() would put them back).
void runAt(UnicornPowerCpu &cpu, GuestAddr fn) {
    cpu.setReg(PowerCpu::LR, layout::kSentinel);
    cpu.setReg(PowerCpu::PC, fn);
    cpu.run();
}

uint8_t byteAt(GuestAddr addr) { return memory().ptr<uint8_t>(addr)[0]; }

void testEndianness() {
    auto cpu = makeCpu();
    cpu->call(kCode + kStore, {kData, 0x12345678});
    CHECK(byteAt(kData) == 0x12 && byteAt(kData + 1) == 0x34 && byteAt(kData + 2) == 0x56 && byteAt(kData + 3) == 0x78);
    CHECK(memory().read<uint32_t>(kData) == 0x12345678);
    memory().write<uint32_t>(kData + 4, 0xCAFEF00D);
    CHECK(uint32_t(cpu->call(kCode + kLoad, {kData + 4})) == 0xCAFEF00D);
    // A 64-bit value comes back in r3:r4, high word first.
    uint64_t result = cpu->call(kCode + kRet64, {});
    CHECK(uint32_t(result) == 0x01234567 && uint32_t(result >> 32) == 0x89ABCDEF);
    // A call puts everything back.
    cpu->setReg(PowerCpu::R0 + 14, 0xAAAA5555);
    uint32_t sp = cpu->reg(PowerCpu::SP);
    cpu->call(kCode + kLoad, {kData});
    CHECK(cpu->reg(PowerCpu::R0 + 14) == 0xAAAA5555 && cpu->reg(PowerCpu::SP) == sp);
}

void testArguments() {
    auto cpu = makeCpu();
    // Eight words in registers and two on the stack.
    CHECK(uint32_t(cpu->call(kCode + kSum10, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10})) == 55);
    // The same nine words as a thunk sees them, with its return address.
    seen = Seen{};
    CHECK(uint32_t(cpu->call(kCode + kCallthunk, {})) == 45);
    CHECK(seen.args == (std::vector<uint32_t>{1, 2, 3, 4, 5, 6, 7, 8, 9}));
    CHECK(seen.returnAddress == kCode + kCallReturn);
}

void testReentrancy() {
    auto cpu = makeCpu();
    // The thunk calls twice(21) in the guest and adds one.
    CHECK(uint32_t(cpu->call(kCode + kViathunk, {})) == 43);
}

void testFrameChain() {
    auto cpu = makeCpu();
    seen = Seen{};
    cpu->call(kCode + kOuter, {});
    CHECK(seen.chain.size() >= 2);
    if (seen.chain.size() >= 2) {
        CHECK(seen.chain[0] == kCode + kInnerReturn);  // where the thunk returns
        CHECK(seen.chain[1] == kCode + kOuterReturn);  // where inner returns
    }
}

void testFloatingPoint() {
    auto cpu = makeCpu();
    // Results in f1: a double, and a float widened.
    memory().write<double>(kData + 0x40, -6.25);
    cpu->call(kCode + kRetdbl, {kData + 0x40});
    CHECK(cpu->floatingResult(false) == -6.25);
    cpu->call(kCode + kFloats, {});
    CHECK(memory().read<double>(kData + 0x10) == 2.5 && memory().read<double>(kData + 0x18) == 1.25);
    // The FPU computes, with doubles stored big-endian.
    memory().write<double>(kData + 0x80, 1.5);
    memory().write<double>(kData + 0x88, 2.25);
    cpu->call(kCode + kFpu, {kData + 0x80});
    CHECK(memory().read<double>(kData + 0x90) == 3.75 && memory().read<double>(kData + 0x98) == 3.375);
    // The register API.
    cpu->setFpr(7, 3.14159);
    CHECK(cpu->fpr(7) == 3.14159);
}

void testAltiVec() {
    auto cpu = makeCpu();
    const float a[4] = {1, 2, 3, 4}, b[4] = {10, 20, 30, 40};
    for (int i = 0; i < 4; i++) {
        memory().write<float>(kData + 0xC0 + i * 4, a[i]);
        memory().write<float>(kData + 0xD0 + i * 4, b[i]);
    }
    cpu->call(kCode + kVec, {kData + 0xC0});
    for (int i = 0; i < 4; i++) CHECK(memory().read<float>(kData + 0xE0 + i * 4) == a[i] + b[i]);
    // Through the registers: v3 holds the sum, most significant byte first.
    cpu->setReg(PowerCpu::R3, kData + 0xC0);
    runAt(*cpu, kCode + kVec);
    uint8_t v3[16];
    cpu->vr(3, v3);
    CHECK(std::memcmp(v3, memory().ptr<uint8_t>(kData + 0xE0), 16) == 0);
    uint8_t pattern[16], back[16];
    for (int i = 0; i < 16; i++) pattern[i] = uint8_t(0xA0 + i);
    cpu->setVr(9, pattern);
    cpu->vr(9, back);
    CHECK(std::memcmp(pattern, back, 16) == 0);
}

void testRegisters() {
    auto cpu = makeCpu();
    // Integer instructions and the condition register.
    cpu->setReg(PowerCpu::R3, 0x00123456);
    runAt(*cpu, kCode + kBits);
    CHECK(cpu->reg(PowerCpu::R4) == 11);        // cntlzw
    CHECK(cpu->reg(PowerCpu::R0 + 5) == 0x00005600);  // rlwimi: (x << 8) & 0xFF00
    CHECK((cpu->reg(PowerCpu::R0 + 6) >> 28) == 0x4);  // cr0: greater than
    CHECK(cpu->reg(PowerCpu::R0 + 7) == 0x56341200);   // lwbrx
    // XER keeps its summary overflow, overflow and carry bits.
    cpu->setReg(PowerCpu::XER, 0xE0000000);
    CHECK(cpu->reg(PowerCpu::XER) == 0xE0000000);
    cpu->setReg(PowerCpu::CR, 0x12345678);
    CHECK(cpu->reg(PowerCpu::CR) == 0x12345678);
    // The guest runs with the FPU and AltiVec on.
    CHECK((cpu->reg(PowerCpu::MSR) & (1u << 13)) && (cpu->reg(PowerCpu::MSR) & (1u << 25)));
}

// mftb and mftbu read a clock that runs, at the 25 MHz of a G4 Mac.
void testTimeBase() {
    auto cpu = makeCpu();
    uint32_t first = uint32_t(cpu->call(kCode + kTb, {}));
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    uint32_t second = uint32_t(cpu->call(kCode + kTb, {}));
    uint32_t elapsed = second - first;  // 20 ms is 500,000 ticks
    CHECK(elapsed > 400000 && elapsed < 5000000);
    CHECK(uint32_t(cpu->call(kCode + kTbhi, {})) < 0x100000);
}

void testFault() {
    auto cpu = makeCpu();
    memory().write<uint32_t>(kData, 0);
    Cpu::setSignalAction(SIGSEGV, {kCode + kHandler, 0, 0});
    // The store to 0x70000000 faults, the handler records it and skips the
    // store, and r3 is as the fault left it.
    CHECK(uint32_t(cpu->call(kCode + kFault, {})) == 7);
    Cpu::setSignalAction(SIGSEGV, {});
    CHECK(memory().read<uint32_t>(kData) == uint32_t(SIGSEGV));
    CHECK(memory().read<uint32_t>(kData + 4) == 0x70000000);
    CHECK(memory().read<uint32_t>(kData + 8) & (1u << 25));  // a store
}

// Four engines over the same memory, each adding to one word with lwarx and
// stwcx.: they only agree if the reservation really is atomic.
void testAtomics() {
    constexpr int kThreads = 4;
    constexpr uint32_t kIterations = 200000;
    memory().write<uint32_t>(kData + 0x100, 0);
    std::vector<std::thread> threads;
    for (int t = 0; t < kThreads; t++)
        threads.emplace_back([t] {
            auto cpu = makeCpu(t);
            cpu->call(kCode + kIncr, {kData + 0x100, kIterations});
        });
    for (auto &thread : threads) thread.join();
    CHECK(memory().read<uint32_t>(kData + 0x100) == kThreads * kIterations);
}

// The stub and method-stub encodings against what the assembler produces.
void testStubs() {
    CHECK(memory().read<uint32_t>(layout::kStubBase) == 0x44000002);      // sc
    CHECK(memory().read<uint32_t>(layout::kStubBase + 4) == 0x4E800020);  // blr
    GuestAddr stub = kData + 0x200;
    arch::writeMethodStub(memory(), stub, 0x12345678, 0xF0000008);
    const uint32_t expected[] = {0x3d801234, 0x618c5678, 0x3d60f000, 0x616b0008, 0x7d6903a6, 0x4e800420};
    for (int i = 0; i < 6; i++) CHECK(memory().read<uint32_t>(stub + uint32_t(i) * 4) == expected[i]);
}

}  // namespace

int main() {
    std::setvbuf(stdout, nullptr, _IONBF, 0);  // a fatal() in the middle must not lose what came before
    testEndianness();
    testArguments();
    testReentrancy();
    testFrameChain();
    testFloatingPoint();
    testAltiVec();
    testRegisters();
    testTimeBase();
    testFault();
    testAtomics();
    testStubs();
    if (failures) {
        std::printf("FAIL: %d checks failed\n", failures);
        return 1;
    }
    std::printf("ppc cpu passed\n");
    return 0;
}
