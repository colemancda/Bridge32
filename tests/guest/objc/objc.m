// Milestone 2 guest: a guest class on top of host NSObject, host Foundation
// objects used from the guest, and the host calling back into guest methods.
// Manual retain/release, like apps of the iPhone OS 2-4 era.
#import <Foundation/Foundation.h>
#include <stdio.h>

@interface Counter : NSObject {
    int _count;
    NSString *_name;
}
@property (nonatomic, copy) NSString *name;
- (void)increment;
- (int)count;
@end

@implementation Counter
@synthesize name = _name;

- (id)init {
    if ((self = [super init])) _count = 100;
    return self;
}

- (void)increment { _count++; }
- (int)count { return _count; }

// Called by the host when the object is formatted with %@.
- (NSString *)description {
    return [NSString stringWithFormat:@"<Counter %@: %d>", _name, _count];
}

- (void)dealloc {
    printf("dealloc %s\n", [_name UTF8String]);
    [_name release];
    [super dealloc];
}
@end

@interface NSString (Shout)
- (NSString *)shout;
@end

@implementation NSString (Shout)
- (NSString *)shout { return [[self uppercaseString] stringByAppendingString:@"!"]; }
@end

int main(int argc, char **argv) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    Counter *counter = [[Counter alloc] init];
    counter.name = @"pac";
    [counter increment];
    [counter increment];
    printf("count=%d name=%s\n", [counter count], [counter.name UTF8String]);

    NSString *formatted = [NSString stringWithFormat:@"%@ / %d / %.1f", counter, 7, 2.5];
    printf("formatted=%s\n", [formatted UTF8String]);

    NSArray *array = [NSArray arrayWithObjects:@"a", @"b", @"c", nil];
    NSMutableString *joined = [NSMutableString string];
    for (NSString *item in array) [joined appendString:item];
    printf("array count=%u joined=%s csv=%s\n", (unsigned)[array count], [joined UTF8String],
           [[array componentsJoinedByString:@","] UTF8String]);

    NSNumber *number = [NSNumber numberWithInt:41];
    printf("number=%d\n", [number intValue] + 1);

    printf("shout=%s\n", [[@"waka" shout] UTF8String]);
    printf("class=%s super=%s\n", [NSStringFromClass([counter class]) UTF8String],
           [NSStringFromClass([counter superclass]) UTF8String]);
    NSLog(@"logged %@", array);

    [counter release];
    [pool release];
    printf("done\n");
    return 0;
}
