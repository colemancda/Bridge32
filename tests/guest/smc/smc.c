// Guest code that rewrites itself, in ordinary data memory. Writes only need
// the emulator's slow path on pages holding translated code, and every case
// here is a way of getting that wrong and running stale code.
#include <stdint.h>
#include <stdio.h>

#define PAGE 4096

static uint8_t storage[PAGE * 4];

// mov eax, imm32; ret
#define FN_SIZE 6
static void emit(volatile uint8_t *at, uint32_t value) {
    at[0] = 0xB8;
    at[1] = value & 0xFF;
    at[2] = (value >> 8) & 0xFF;
    at[3] = (value >> 16) & 0xFF;
    at[4] = (value >> 24) & 0xFF;
    at[5] = 0xC3;
}

static uint32_t run(volatile uint8_t *at) { return ((uint32_t(*)(void))(uintptr_t)at)(); }

static int failures;
static void expect(const char *what, uint32_t got, uint32_t want) {
    if (got == want) return;
    printf("%s: got %u, want %u\n", what, got, want);
    failures++;
}

int main(void) {
    volatile uint8_t *page = (volatile uint8_t *)(((uintptr_t)storage + PAGE - 1) & ~(uintptr_t)(PAGE - 1));

    // A page already written as plain data, which then gains code.
    for (int i = 0; i < PAGE; i++) page[i] = 0;
    emit(page, 1);
    expect("data page gains code", run(page), 1);

    // Rewriting the only block on a page, again and again, with data writes
    // to the same page in between.
    for (uint32_t i = 2; i < 2000; i++) {
        page[PAGE - 1] = (uint8_t)i;
        emit(page, i);
        page[PAGE - 2] = (uint8_t)i;
        expect("rewritten block", run(page), i);
    }

    // Two blocks on one page: rewriting the first must leave the page
    // protected for the second.
    volatile uint8_t *second = page + 64;
    for (uint32_t i = 1; i < 1000; i++) {
        emit(page, i);
        emit(second, i + 1);
        expect("first of two", run(page), i);
        expect("second of two", run(second), i + 1);
        page[1] = (uint8_t)(i * 3);
        page[2] = page[3] = page[4] = 0;
        second[1] = (uint8_t)(i * 5);
        second[2] = second[3] = second[4] = 0;
        expect("first of two, rewritten", run(page), (uint8_t)(i * 3));
        expect("second of two, rewritten", run(second), (uint8_t)(i * 5));
    }

    // A block across two pages, changed through its second page only.
    volatile uint8_t *across = page + 2 * PAGE - 3;
    emit(across, 0x11223344);
    expect("across pages", run(across), 0x11223344);
    across[3] = 0x77;
    expect("across pages, second page", run(across), 0x11773344);

    if (failures) {
        printf("smc failed: %d\n", failures);
        return 1;
    }
    printf("smc passed\n");
    return 0;
}
