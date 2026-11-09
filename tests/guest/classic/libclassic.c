// A dylib for tools/i386-link.py --dylib: the pointers below hold addresses
// the loader has to slide, and absoluteWord is covered by an R_ABS relocation
// it must leave alone.
#include <stdlib.h>
#include <string.h>

static int values[3] = {10, 20, 30};
static int *table[3] = {&values[0], &values[1], &values[2]};

__attribute__((section("__DATA,__absolute"))) unsigned absoluteWord = 0x1234;

static int fortyTwo(void) { return (int)strlen("0123456789") + 32; }
static int (*volatile pointer)(void) = fortyTwo;

int tableSum(void) {
    int total = 0;
    for (int i = 0; i < 3; i++) total += *table[i];
    return total;
}

int callsThroughTable(void) { return pointer(); }
