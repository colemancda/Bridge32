// Phase 0 measurements (docs/i386-mac-plan.md): the cost of a thunk round
// trip and the speed of translated code, printed as time per operation so
// the same source built natively gives the baseline.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

static double now(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static int fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

static volatile int sink;

// Inputs come from argv so the native build can't fold the work away.
int main(int argc, char **argv) {
    enum { kCalls = 2000000, kSieve = 20000000, kMandel = 400 };
    double t;
    char text[64];
    snprintf(text, sizeof text, "thunk round trip %d", argc);
    int depth = 30 + argc;

    // Thunk round trips: strlen is a host function with a trivial body.
    t = now();
    for (int i = 0; i < kCalls; i++) sink += (int)strlen(text);
    t = now() - t;
    printf("thunk: %.3f us per call (%d calls)\n", t / kCalls * 1e6, kCalls);

    // Integer code: calls, branches, arithmetic.
    t = now();
    int f = fib(depth);
    t = now() - t;
    printf("fib(%d)=%d: %.3f s\n", depth, f, t);

    // Memory: a byte sieve.
    char *sieve = malloc(kSieve);
    memset(sieve, 1, kSieve);
    t = now();
    int primes = 0;
    for (int i = 2; i < kSieve; i++) {
        if (!sieve[i]) continue;
        primes++;
        for (int j = i * 2; j < kSieve; j += i) sieve[j] = 0;
    }
    t = now() - t;
    printf("sieve(%d)=%d primes: %.3f s\n", kSieve, primes, t);
    free(sieve);

    // Floating point: a Mandelbrot set in doubles.
    t = now();
    int inside = 0;
    for (int py = 0; py < kMandel; py++)
        for (int px = 0; px < kMandel; px++) {
            double cr = -2.0 + 3.0 * px / kMandel, ci = -1.5 + 3.0 * py / kMandel, zr = 0, zi = 0;
            int k = 0;
            for (; k < 200 && zr * zr + zi * zi < 4.0; k++) {
                double nr = zr * zr - zi * zi + cr;
                zi = 2 * zr * zi + ci;
                zr = nr;
            }
            inside += k == 200;
        }
    t = now() - t;
    printf("mandelbrot(%dx%d)=%d inside: %.3f s\n", kMandel, kMandel, inside, t);

    // Atomics: a locked add in a single thread.
    t = now();
    int counter = 0;
    for (int i = 0; i < 10000000; i++) __sync_fetch_and_add(&counter, 1);
    t = now() - t;
    printf("lock xadd x10M=%d: %.3f s\n", counter, t);
    return 0;
}
