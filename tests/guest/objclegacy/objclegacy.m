// What the legacy runtime brings that the armv7 objc test can't cover:
// fragile ivars read directly, a chain of guest superclasses, +load and
// +initialize, properties with atomic accessors, protocols, setjmp-based
// exceptions (including across host frames, and thrown by the host),
// garbage-collector write barriers, and classes made at run time.
#define OBJC_SILENCE_GC_DEPRECATIONS 1
#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/objc-auto.h>
#include <objc/runtime.h>
#include <stdio.h>

static int failures;
static void check(int ok, const char *what) {
    printf("%s=%s\n", what, ok ? "ok" : "FAILED");
    if (!ok) failures++;
}

static int loadCalls, initializeCalls;

@protocol Greeter <NSObject>
- (NSString *)greeting;
@optional
- (void)wave;
@end

@interface Base : NSObject <Greeter> {
@public
    char _tag;
    int _value;
    double _weight;
    NSString *_atomicName;
}
@property (retain) NSString *atomicName;
- (int)value;
+ (id)baseWithValue:(int)value;
@end

@implementation Base
@synthesize atomicName = _atomicName;
+ (void)load { loadCalls++; }
+ (void)initialize { initializeCalls++; }
+ (id)baseWithValue:(int)value {
    Base *base = [[[self alloc] init] autorelease];
    base->_value = value;
    return base;
}
- (int)value { return _value; }
- (NSString *)greeting { return @"base"; }
- (double)weight { return _weight; }
- (NSRange)range { NSRange r = {(NSUInteger)_value, 2}; return r; }
- (void)explode { [NSException raise:@"Boom" format:@"value %d", _value]; }
- (void)dealloc {
    [_atomicName release];
    [super dealloc];
}
@end

@interface Derived : Base {
@public
    int _extra;
}
@end

@implementation Derived
- (id)init {
    if ((self = [super init])) {
        _value = 7;
        _extra = 11;
        _weight = 2.5;
    }
    return self;
}
- (int)value { return [super value] + _extra; }
- (NSString *)greeting { return [[super greeting] stringByAppendingString:@"+derived"]; }
@end

@interface Base (Extras)
- (int)doubled;
@end
@implementation Base (Extras)
- (int)doubled { return [self value] * 2; }
@end

@interface Thrower : NSObject
- (void)throwIt:(id)ignored;
@end
@implementation Thrower
- (void)throwIt:(id)ignored { @throw [NSException exceptionWithName:@"FromGuest" reason:@"crossing" userInfo:nil]; }
@end

static int madeValue(id self, SEL _cmd) {
    void *slot = NULL;
    object_getInstanceVariable(self, "_slot", &slot);
    return (int)(intptr_t)slot;
}

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    Derived *d = [[Derived alloc] init];
    check(d->_value == 7 && d->_extra == 11, "fragile-ivars");
    check(d->_weight == 2.5, "fragile-double-ivar");
    check(class_getInstanceSize([Derived class]) >= sizeof(int) * 2, "instance-size");
    check([d value] == 18, "super-send");
    check([[d greeting] isEqualToString:@"base+derived"], "super-string");
    check([d doubled] == 36, "category");
    check([d weight] == 2.5, "double-return");
    NSRange range = [d range];
    check(range.location == 7 && range.length == 2, "range-return");
    check(loadCalls == 1, "load");
    check(initializeCalls >= 1, "initialize");
    Base *made = [Base baseWithValue:5];
    check([made value] == 5 && [made isKindOfClass:[Base class]], "class-method");
    check([d isKindOfClass:[Base class]] && [d isKindOfClass:[NSObject class]], "isKindOf");
    check([NSStringFromClass([d superclass]) isEqualToString:@"Base"], "superclass-name");

    d.atomicName = @"held";
    check([d.atomicName isEqualToString:@"held"], "atomic-property");

    check([d conformsToProtocol:@protocol(Greeter)], "conforms");
    check([d respondsToSelector:@selector(greeting)] && ![d respondsToSelector:@selector(wave)], "responds");
    struct objc_method_description wave = protocol_getMethodDescription(@protocol(Greeter), @selector(wave), NO, YES);
    check(wave.name == @selector(wave), "protocol-optional");
    check(strcmp(protocol_getName(@protocol(Greeter)), "Greeter") == 0, "protocol-name");

    // Plain guest @throw and @catch, with @finally.
    int finallyRan = 0, caught = 0;
    @try {
        @throw [NSException exceptionWithName:@"Local" reason:@"r" userInfo:nil];
    } @catch (NSString *wrongType) {
        caught = -1;
    } @catch (NSException *e) {
        caught = [[e name] isEqualToString:@"Local"];
    } @finally {
        finallyRan = 1;
    }
    check(caught == 1 && finallyRan == 1, "try-catch-finally");

    // A throw from the host.
    caught = 0;
    @try {
        [[NSArray array] objectAtIndex:3];
    } @catch (NSException *e) {
        caught = [[e name] isEqualToString:NSRangeException];
    }
    check(caught == 1, "host-throw");

    @try {
        [d explode];
    } @catch (id e) {
        caught = [[e name] isEqualToString:@"Boom"] ? 2 : 0;
    }
    check(caught == 2, "raise-from-guest-method");

    // A guest throw that has to cross host frames to reach this @try.
    caught = 0;
    Thrower *thrower = [[[Thrower alloc] init] autorelease];
    NSArray *targets = [NSArray arrayWithObject:thrower];
    @try {
        [targets makeObjectsPerformSelector:@selector(throwIt:) withObject:nil];
    } @catch (NSException *e) {
        caught = [[e name] isEqualToString:@"FromGuest"];
    }
    check(caught == 1, "throw-across-host-frames");

    // Nested, rethrown.
    caught = 0;
    @try {
        @try {
            @throw [NSException exceptionWithName:@"Inner" reason:@"r" userInfo:nil];
        } @finally {
            caught = 1;
        }
    } @catch (NSException *e) {
        caught += [[e name] isEqualToString:@"Inner"] ? 10 : 0;
    }
    check(caught == 11, "rethrow-through-finally");

    // The stack still works after all that.
    check([d value] == 18, "after-exceptions");

    id store[2] = {nil, nil};
    objc_assign_strongCast(@"barrier", store);
    check(store[0] == (id)@"barrier", "write-barrier");

    Class dynamic = objc_allocateClassPair([NSObject class], "MadeAtRunTime", 0);
    class_addIvar(dynamic, "_slot", 4, 2, "i");
    class_addMethod(dynamic, @selector(hash), (IMP)madeValue, "I@:");
    objc_registerClassPair(dynamic);
    id instance = [[dynamic alloc] init];
    object_setInstanceVariable(instance, "_slot", (void *)77);
    check([instance hash] == 77, "class-made-at-run-time");
    check(strcmp(class_getName(dynamic), "MadeAtRunTime") == 0, "made-class-name");
    [instance release];

    [d release];
    [pool release];
    printf(failures ? "objclegacy FAILED\n" : "objclegacy passed\n");
    return failures;
}
