// The i386 Darwin calling convention at the thunk boundary, and the libSystem
// layouts that differ from iOS's: long double arguments, struct results (in
// EAX:EDX, in ST(0), and through a hidden pointer the callee pops), both
// struct stat and struct dirent layouts, setjmp, and a fault handler that
// repairs the faulting state through the ucontext.
#include <dirent.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// The two layouts, spelled out, since one compile only sees one of them.
struct stat32 {
    int32_t dev;
    uint32_t ino;
    uint16_t mode, nlink;
    uint32_t uid, gid;
    int32_t rdev;
    int32_t times[6];
    int64_t size, blocks;
    int32_t blksize;
    uint32_t flags, gen;
    int32_t lspare;
    int64_t qspare[2];
};
struct stat64x {
    int32_t dev;
    uint16_t mode, nlink;
    uint64_t ino;
    uint32_t uid, gid;
    int32_t rdev;
    int32_t times[8];
    int64_t size, blocks;
    int32_t blksize;
    uint32_t flags, gen;
    int32_t lspare;
    int64_t qspare[2];
};
struct dirent32 {
    uint32_t ino;
    uint16_t reclen;
    uint8_t type, namlen;
    char name[256];
};
struct dirent64x {
    uint64_t ino, seekoff;
    uint16_t reclen, namlen;
    uint8_t type;
    char name[1024];
};
int stat32_(const char *, struct stat32 *) __asm("_stat");
int stat64_(const char *, struct stat64x *) __asm("_stat$INODE64");
struct dirent32 *readdir32(void *) __asm("_readdir");
struct dirent64x *readdir64x(void *) __asm("_readdir$INODE64");

// Just the fields compared below of the two struct statfs layouts.
struct statfs32 {
    int16_t otype, oflags;
    int32_t bsize, iosize, blocks, bfree, bavail, files, ffree;
    int32_t fsid[2];
    uint32_t owner;
    int16_t reserved1, type;
    int32_t flags;
    int32_t reserved2[2];
    char fstypename[15], mntonname[90], mntfromname[90], reserved3;
    int32_t reserved4[4];
};
struct statfs64x {
    uint32_t bsize;
    int32_t iosize;
    uint64_t blocks, bfree, bavail, files, ffree;
    int32_t fsid[2];
    uint32_t owner, type, flags, fssubtype;
    char fstypename[16], mntonname[1024], mntfromname[1024];
    uint32_t reserved[8];
};
int statfs32_(const char *, struct statfs32 *) __asm("_statfs");
int statfs64_(const char *, struct statfs64x *) __asm("_statfs$INODE64");

typedef struct { float x, y, w, h; } Rect;
typedef struct { long location, length; } Range;
Rect CGRectInset(Rect, float, float);
const void *CFStringCreateWithCString(const void *, const char *, unsigned);
Range CFStringGetRangeOfComposedCharactersAtIndex(const void *, long);

static volatile uint32_t *badPointer = (uint32_t *)0x7000;
static volatile uint32_t faultAddress, faultEip;

// A real one: { trapno, cpu, err, faultvaddr }, then x86_thread_state32.
struct mcontext32 {
    uint16_t trapno, cpu;
    uint32_t err, faultvaddr;
    uint32_t eax, ebx, ecx, edx, edi, esi, ebp, esp, ss, eflags, eip, cs, ds, es, fs, gs;
};
struct ucontext32 {
    int onstack;
    uint32_t sigmask;
    void *ss_sp;
    uint32_t ss_size;
    int ss_flags;
    void *link;
    uint32_t mcsize;
    struct mcontext32 *mcontext;
};

// Skips the faulting movl (%eax), %edx and leaves a value in the register it
// was to load, proving registers written to the context are the ones resumed.
static void handler(int sig, siginfo_t *info, void *context) {
    struct ucontext32 *uc = context;
    faultAddress = (uint32_t)(uintptr_t)info->si_addr;
    faultEip = uc->mcontext->eip;
    uc->mcontext->edx = 0x600D;
    uc->mcontext->eip += 2;
}

static uint32_t currentEsp(void) {
    uint32_t esp;
    __asm__("movl %%esp, %0" : "=r"(esp));
    return esp;
}

static int check(int ok, const char *what) {
    printf("%s=%s\n", what, ok ? "ok" : "FAILED");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    int failures = 0;

    // long double: 16 bytes of argument words holding the x87 format.
    long double value = 2.5L;
    char text[64];
    snprintf(text, sizeof text, "%d %.2Lf %d", 1, value * argc, 3);
    failures += check(strcmp(text, "1 2.50 3") == 0, "long-double-vararg");
    failures += check(strtold("1.25", NULL) == 1.25L, "long-double-result");

    // Two words in EAX:EDX.
    const unsigned kUTF8 = 0x08000100;
    Range u = CFStringGetRangeOfComposedCharactersAtIndex(CFStringCreateWithCString(NULL, "abc", kUTF8), 1);
    failures += check(u.location == 1 && u.length == 1, "struct-in-registers");

    // Through a hidden pointer, which the thunk must pop: the compiler adjusts
    // the stack back down after the call only because the callee popped.
    Rect r = {0, 0, 10, 20};
    uint32_t before = currentEsp();
    Rect inset = CGRectInset(r, 1, 2);
    failures += check(currentEsp() == before, "callee-pop");
    failures += check(inset.x == 1 && inset.y == 2 && inset.w == 8 && inset.h == 16, "struct-in-memory");

    // Both stat layouts see the same file.
    struct stat32 st32;
    struct stat64x st64;
    memset(&st32, 0xEE, sizeof st32);
    memset(&st64, 0xEE, sizeof st64);
    int rc32 = stat32_(argv[0], &st32), rc64 = stat64_(argv[0], &st64);
    failures += check(rc32 == 0 && rc64 == 0, "stat-calls");
    failures += check(st32.size == st64.size && st32.size > 0, "stat-size");
    failures += check(st32.mode == st64.mode && (st32.mode & S_IFMT) == S_IFREG, "stat-mode");
    failures += check(st32.ino == (uint32_t)st64.ino, "stat-ino");
    failures += check(st32.blksize == st64.blksize && st32.blksize > 0, "stat-blksize");

    // Both dirent layouts see the same directory.
    int found32 = 0, found64 = 0;
    DIR *d = opendir("/");
    for (struct dirent32 *e; (e = readdir32(d));) found32 += strcmp(e->name, "usr") == 0 && e->namlen == 3;
    closedir(d);
    d = opendir("/");
    for (struct dirent64x *e; (e = readdir64x(d));) found64 += strcmp(e->name, "usr") == 0 && e->namlen == 3;
    closedir(d);
    failures += check(found32 == 1 && found64 == 1, "dirent");

    struct statfs32 fs32;
    struct statfs64x fs64;
    int fsrc32 = statfs32_("/", &fs32), fsrc64 = statfs64_("/", &fs64);
    failures += check(fsrc32 == 0 && fsrc64 == 0, "statfs-calls");
    failures += check(strcmp(fs32.fstypename, fs64.fstypename) == 0 && fs32.fstypename[0] != 0, "statfs-type");
    failures += check(strcmp(fs32.mntonname, "/") == 0 && (uint32_t)fs32.bsize == fs64.bsize, "statfs-layout");

    jmp_buf jump;
    volatile int steps = 0;
    if (setjmp(jump) == 0) {
        steps = 1;
        longjmp(jump, 7);
    } else {
        steps += 2;
    }
    failures += check(steps == 3, "setjmp");

    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = handler;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &action, NULL);
    uint32_t result = 0, faulting = 0;
    __asm__(
        "movl %2, %%eax\n"
        "call 1f\n"
        "1: popl %1\n"
        "addl $4, %1\n"
        "movl (%%eax), %%edx\n"
        "movl %%edx, %0\n"
        : "=&r"(result), "=&r"(faulting)
        : "r"(badPointer)
        : "eax", "edx", "cc");
    failures += check(faultAddress == (uint32_t)(uintptr_t)badPointer, "fault-address");
    failures += check(faultEip == faulting, "fault-eip");
    failures += check(result == 0x600D, "fault-resume");

    printf(failures ? "abi FAILED\n" : "abi passed\n");
    return failures;
}
