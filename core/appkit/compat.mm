// AppKit classes the 64-bit frameworks dropped, which 32-bit apps used. They
// exist here under their own names, since a nib looks its classes up by name
// on the host, and stand in as views and objects that show nothing.

#import <AppKit/AppKit.h>

@interface NSQuickDrawView : NSView
@end
@implementation NSQuickDrawView
@end

@interface NSMovieView : NSView
@end
@implementation NSMovieView
@end

// QTKit is gone altogether. A class can inherit these, and a movie never plays.
@interface QTMovieView : NSView
@end
@implementation QTMovieView
@end

@interface QTMovie : NSObject
@end
@implementation QTMovie
- (id)initWithFile:(NSString *)path error:(NSError **)error {
    if (error) *error = nil;
    [self release];
    return nil;
}
@end

// A nib from before keyed archives (objects.nib, read by NSUnarchiver) decodes a connector's
// source and destination with plain stores into what are __weak ivars now, so the connector
// reads them back as nil and the nib's outlets and actions never connect. Each is stored again
// as the weak reference it is meant to be.
#include <objc/runtime.h>

#include <initializer_list>

namespace {
id (*hostConnectorInitWithCoder)(id, SEL, NSCoder *);
id connectorInitWithCoder(id self, SEL _cmd, NSCoder *coder) {
    id connector = hostConnectorInitWithCoder(self, _cmd, coder);
    if (!connector || coder.allowsKeyedCoding) return connector;
    Class cls = objc_getClass("NSNibConnector");
    for (const char *name : {"_source", "_destination"}) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        id *slot = reinterpret_cast<id *>(reinterpret_cast<uint8_t *>(connector) + ivar_getOffset(ivar));
        id value = *slot;
        *slot = nil;
        objc_storeWeak(slot, value);
    }
    return connector;
}
[[maybe_unused]] const bool connectorsRepaired = [] {
    if (Method m = class_getInstanceMethod(objc_getClass("NSNibConnector"), @selector(initWithCoder:))) {
        hostConnectorInitWithCoder = reinterpret_cast<id (*)(id, SEL, NSCoder *)>(method_getImplementation(m));
        method_setImplementation(m, reinterpret_cast<IMP>(connectorInitWithCoder));
    }
    return true;
}();
}  // namespace
