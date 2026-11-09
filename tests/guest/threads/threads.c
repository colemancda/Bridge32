// Guest threads sharing memory: a counter bumped with a lock-prefixed add
// from four pthreads (which an engine compiling locks as plain stores gets
// wrong), and a double coming back from the host through x87's ST(0).
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static volatile int counter;
static volatile int plain;
enum { kThreads = 4, kIterations = 200000 };

static void *bump(void *arg) {
    for (int i = 0; i < kIterations; i++) {
        __sync_fetch_and_add(&counter, 1);
        plain++;
    }
    return arg;
}

int main(void) {
    pthread_t threads[kThreads];
    for (int t = 0; t < kThreads; t++)
        if (pthread_create(&threads[t], NULL, bump, (void *)(long)(t + 1))) {
            printf("pthread_create failed\n");
            return 1;
        }
    int sum = 0;
    for (int t = 0; t < kThreads; t++) {
        void *result;
        pthread_join(threads[t], &result);
        sum += (int)(long)result;
    }
    printf("counter=%d (expected %d) plain=%d joined=%d\n", counter, kThreads * kIterations, plain, sum);
    double d = strtod("2.5", NULL);
    printf("strtod=%.3f\n", d);
    if (counter != kThreads * kIterations || sum != 10) {
        printf("threads FAILED\n");
        return 1;
    }
    printf("threads passed\n");
    return 0;
}
