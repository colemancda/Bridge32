// The i386 message-send ABI against host classes, from C so no ObjC metadata
// is involved (that is the legacy runtime's job): floating-point results in
// ST(0), a struct in EAX:EDX, a struct through a callee-popped hidden pointer,
// the nil-receiver forms of each, and a guest method called from the host.
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>

typedef struct { float x, y, w, h; } Rect;
typedef struct { unsigned location, length; } Range;

typedef id (*IdFromDouble)(id, SEL, double);
typedef id (*IdFromFloat)(id, SEL, float);
typedef id (*IdFromRange)(id, SEL, Range);
typedef id (*IdFromRect)(id, SEL, Rect);
typedef id (*IdFromCString)(id, SEL, const char *);
typedef double (*DoubleSend)(id, SEL);
typedef float (*FloatSend)(id, SEL);
typedef Range (*RangeSend)(id, SEL);
typedef Rect (*RectSend)(id, SEL);
typedef id (*IdSend)(id, SEL, id);

static uint32_t currentEsp(void) {
    uint32_t esp;
    __asm__("movl %%esp, %0" : "=r"(esp));
    return esp;
}

static int check(int ok, const char *what) {
    printf("%s=%s\n", what, ok ? "ok" : "FAILED");
    return ok ? 0 : 1;
}

static double guestDouble(id self, SEL _cmd) { return 6.75; }
static float guestFloat(id self, SEL _cmd) { return 1.5f; }
static Rect guestRect(id self, SEL _cmd) {
    Rect r = {1, 2, 3, 4};
    return r;
}

int main(void) {
    int failures = 0;
    Class number = objc_getClass("NSNumber"), value = objc_getClass("NSValue");
    id n = ((IdFromDouble)objc_msgSend)((id)number, sel_registerName("numberWithDouble:"), 2.5);
    failures += check(((DoubleSend)objc_msgSend_fpret)(n, sel_registerName("doubleValue")) == 2.5, "fpret-double");
    id f = ((IdFromFloat)objc_msgSend)((id)number, sel_registerName("numberWithFloat:"), 0.25f);
    failures += check(((FloatSend)objc_msgSend_fpret)(f, sel_registerName("floatValue")) == 0.25f, "fpret-float");

    Range range = {3, 4};
    id boxed = ((IdFromRange)objc_msgSend)((id)value, sel_registerName("valueWithRange:"), range);
    Range out = ((RangeSend)objc_msgSend)(boxed, sel_registerName("rangeValue"));
    failures += check(out.location == 3 && out.length == 4, "struct-in-registers");

    Rect rect = {5, 6, 7, 8};
    id boxedRect = ((IdFromRect)objc_msgSend)((id)value, sel_registerName("valueWithRect:"), rect);
    uint32_t before = currentEsp();
    Rect back = ((RectSend)objc_msgSend_stret)(boxedRect, sel_registerName("rectValue"));
    failures += check(currentEsp() == before, "stret-callee-pop");
    failures += check(back.x == 5 && back.y == 6 && back.w == 7 && back.h == 8, "stret");

    failures += check(((DoubleSend)objc_msgSend_fpret)(nil, sel_registerName("doubleValue")) == 0, "nil-fpret");
    before = currentEsp();
    Rect untouched = {9, 9, 9, 9};
    untouched = ((RectSend)objc_msgSend_stret)(nil, sel_registerName("rectValue"));
    failures += check(currentEsp() == before, "nil-stret-callee-pop");
    (void)untouched;

    // Host to guest: key-value coding boxes what the guest method returns.
    Class cls = objc_getClass("NSObject");
    class_addMethod(cls, sel_registerName("guestDouble"), (IMP)guestDouble, "d@:");
    class_addMethod(cls, sel_registerName("guestFloat"), (IMP)guestFloat, "f@:");
    class_addMethod(cls, sel_registerName("guestRect"), (IMP)guestRect, "{CGRect={CGPoint=ff}{CGSize=ff}}@:");
    id object = ((id (*)(id, SEL))objc_msgSend)((id)cls, sel_registerName("new"));
    Class string = objc_getClass("NSString");
    SEL make = sel_registerName("stringWithUTF8String:"), kvc = sel_registerName("valueForKey:");
    id key = ((IdFromCString)objc_msgSend)((id)string, make, "guestDouble");
    id result = ((IdSend)objc_msgSend)(object, kvc, key);
    failures += check(((DoubleSend)objc_msgSend_fpret)(result, sel_registerName("doubleValue")) == 6.75, "guest-double");
    key = ((IdFromCString)objc_msgSend)((id)string, make, "guestFloat");
    result = ((IdSend)objc_msgSend)(object, kvc, key);
    failures += check(((FloatSend)objc_msgSend_fpret)(result, sel_registerName("floatValue")) == 1.5f, "guest-float");
    key = ((IdFromCString)objc_msgSend)((id)string, make, "guestRect");
    result = ((IdSend)objc_msgSend)(object, kvc, key);
    Rect fromGuest = ((RectSend)objc_msgSend_stret)(result, sel_registerName("rectValue"));
    failures += check(fromGuest.x == 1 && fromGuest.y == 2 && fromGuest.w == 3 && fromGuest.h == 4, "guest-stret");

    printf(failures ? "objcabi FAILED\n" : "objcabi passed\n");
    return failures;
}
