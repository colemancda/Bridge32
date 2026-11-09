// Milestone 1 guest: 32-bit code calling libSystem through the bridge.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

#if defined(__i386__)
#define ARCH "i386"
#else
#define ARCH "armv7"
#endif

int main(int argc, char **argv) {
    printf("hello from " ARCH ", argc=%d argv[0]=%s\n", argc, argv[0]);

    char *buf = malloc(64);
    strcpy(buf, "guest heap");
    printf("%s len=%zu\n", buf, strlen(buf));
    free(buf);

    printf("fib(20)=%d\n", fib(20));
    printf("double=%.3f\n", 3.14159 * 2.0);
    printf("strtod=%.3f\n", strtod("2.5", NULL));  // a double returned by the host
    return 0;
}
