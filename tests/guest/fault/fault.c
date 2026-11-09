// A bad memory access has to fault at that instruction, not somewhere later
// in its block: crash handlers and managed runtimes rely on the state they see.
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static sigjmp_buf resume;
static volatile uintptr_t faultAddress;
static volatile int faults;

static void onFault(int sig, siginfo_t *info, void *context) {
    (void)sig;
    (void)context;
    faults++;
    faultAddress = (uintptr_t)info->si_addr;
    siglongjmp(resume, 1);
}

static volatile int marker;
static volatile int value;
static volatile int *volatile bad = (volatile int *)0xC8000000;  // between the heap and the stacks

int main(void) {
    struct sigaction action = {0};
    action.sa_sigaction = onFault;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);

    volatile int *target = bad;
    if (sigsetjmp(resume, 1) == 0) {
        marker = 1;
        *target = 7;
        marker = 2;
    }
    printf("write: marker=%d faults=%d addr=0x%lx\n", marker, faults, (unsigned long)faultAddress);
    int ok = marker == 1 && faults == 1 && faultAddress == 0xC8000000;

    marker = 0;
    if (sigsetjmp(resume, 1) == 0) {
        marker = 1;
        value = *target;
        marker = 2;
    }
    printf("read: marker=%d faults=%d addr=0x%lx\n", marker, faults, (unsigned long)faultAddress);
    ok = ok && marker == 1 && faults == 2 && faultAddress == 0xC8000000;

    // Translated code still runs normally after the faults.
    int sum = 0;
    for (int i = 0; i < 100000; i++) sum += i & 3;
    printf("%s sum=%d\n", ok && sum == 150000 ? "fault passed" : "fault FAILED", sum);
    // Not return: main is still inside the handler call siglongjmp left.
    exit(ok ? 0 : 1);
}
