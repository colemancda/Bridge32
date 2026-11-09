// What a binary linked for Mac OS X 10.4 looks like to the loader, linked by
// tools/i386-link.py --classic: entered at start through LC_UNIXTHREAD, its
// imports called through a self-modifying __IMPORT,__jump_table, and dyld
// reached through __DATA,__dyld. argv[1] is a dylib to open, which has to be
// slid and whose local relocations the loader applies.
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

// What crt1 does.
__asm__(
    ".text\n"
    ".globl start\n"
    "start:\n"
    "    pushl $0\n"
    "    movl %esp, %ebp\n"
    "    andl $-16, %esp\n"
    "    subl $16, %esp\n"
    "    movl 4(%ebp), %ebx\n"
    "    movl %ebx, 0(%esp)\n"
    "    leal 8(%ebp), %ecx\n"
    "    movl %ecx, 4(%esp)\n"
    "    call _main\n"
    "    movl %eax, (%esp)\n"
    "    call _exit\n"
    "    hlt\n");

__attribute__((section("__DATA,__dyld"), used)) void *dyldEntry[2];

static int check(int ok, const char *what) {
    printf("%s=%s\n", what, ok ? "ok" : "FAILED");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    int failures = 0;
    failures += check(argc == 2, "argc");

    void *lookupResult = NULL;
    ((int (*)(const char *, void **))dyldEntry[1])("__dyld_mod_term_funcs", &lookupResult);
    failures += check(lookupResult != NULL, "dyld-lookup");

    void *library = dlopen(argv[1], RTLD_NOW);
    failures += check(library != NULL, "dlopen");
    if (library) {
        int (*sum)(void) = (int (*)(void))dlsym(library, "tableSum");
        int (*local)(void) = (int (*)(void))dlsym(library, "callsThroughTable");
        unsigned *absolute = (unsigned *)dlsym(library, "absoluteWord");
        failures += check(sum && sum() == 60, "local-relocations");
        failures += check(local && local() == 42, "function-pointer");
        failures += check(absolute && *absolute == 0x1234, "absolute-relocation");
        char *copy = strdup("through the jump table");
        failures += check(strlen(copy) == 22, "jump-table");
    }
    printf(failures ? "classic FAILED\n" : "classic passed\n");
    return failures;
}
