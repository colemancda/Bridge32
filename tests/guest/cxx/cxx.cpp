// C++ runtime guest: operator new/delete, guarded statics, SjLj frame
// registration (a try block that never throws), virtual dispatch, and, on
// ARM, the armv6 integer/VFP helpers called directly.
#include <stdio.h>

#if defined(__arm__)
extern "C" {
int __divsi3(int, int);
int __modsi3(int, int);
unsigned __udivsi3(unsigned, unsigned);
long long __divdi3(long long, long long);
float __addsf3vfp(float, float);
float __divsf3vfp(float, float);
int __ltsf2vfp(float, float);
int __fixsfsivfp(float);
double __muldf3vfp(double, double);
}
#endif

struct Shape {
    virtual ~Shape() {}
    virtual int area() const = 0;
};
struct Rect : Shape {
    int w, h;
    Rect(int w, int h) : w(w), h(h) {}
    int area() const override { return w * h; }
};

static int counter() {
    static int calls = 0;
    struct Init {
        Init() { printf("static init ran\n"); }
    };
    static Init once;  // guarded by __cxa_guard_acquire/release
    return ++calls;
}

__attribute__((noinline)) static int mayThrow(int x) {
    try {
        if (x < 0) throw x;
        return x * 2;
    } catch (int) {
        return -1;
    }
}

int main() {
    Shape *s = new Rect(6, 7);
    printf("area=%d\n", s->area());
    delete s;

    int *array = new int[4];
    for (int i = 0; i < 4; i++) array[i] = i * i;
    printf("array[3]=%d\n", array[3]);
    delete[] array;

    counter();
    printf("counter=%d\n", counter());
    volatile int input = 21;
    printf("try=%d\n", mayThrow(input));

#if defined(__arm__)
    printf("div=%d mod=%d udiv=%u ldiv=%lld\n", __divsi3(-17, 5), __modsi3(-17, 5), __udivsi3(17, 5),
           __divdi3(-10000000000LL, 3));
    printf("fadd=%.2f fdiv=%.2f flt=%d fix=%d dmul=%.1f\n", __addsf3vfp(1.5f, 2.25f), __divsf3vfp(1.0f, 4.0f),
           __ltsf2vfp(1.0f, 2.0f), __fixsfsivfp(-3.75f), __muldf3vfp(1.5, -4.0));
#endif
    return 0;
}
