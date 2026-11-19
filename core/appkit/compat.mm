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

// Today's controls tell their cell when they move to a window (-_controlViewDidMoveToWindow:), which
// only button and segmented cells answer; a control of the time could hold any cell (Xcode 3 puts a
// table header cell in a button). Other cells take it and do nothing.
namespace {
void cellControlViewDidMoveToWindow(id, SEL, id) {}
[[maybe_unused]] const bool cellsTakeControlViewMoves = [] {
    class_addMethod([NSCell class], sel_registerName("_controlViewDidMoveToWindow:"),
                    reinterpret_cast<IMP>(cellControlViewDidMoveToWindow), "v@:@");
    return true;
}();
}  // namespace

// NSBundle objects lived as long as the process on the systems of the time: Foundation kept every one it
// made, and frameworks took one without retaining it and released it later (Xcode 3's smart group
// bindings hold their bundle so). Today's Foundation can free a bundle nothing else holds, so every one
// made is held here, as Foundation held it then.
namespace {
id (*hostBundleInitWithPath)(id, SEL, NSString *);
id bundleInitWithPath(id self, SEL _cmd, NSString *path) {
    static NSMutableSet *bundles = [[NSMutableSet alloc] init];
    static NSLock *lock = [[NSLock alloc] init];
    id bundle = hostBundleInitWithPath(self, _cmd, path);
    if (bundle) {
        [lock lock];
        [bundles addObject:bundle];
        [lock unlock];
    }
    return bundle;
}
[[maybe_unused]] const bool bundlesKept = [] {
    if (Method m = class_getInstanceMethod([NSBundle class], @selector(initWithPath:))) {
        hostBundleInitWithPath = reinterpret_cast<id (*)(id, SEL, NSString *)>(method_getImplementation(m));
        method_setImplementation(m, reinterpret_cast<IMP>(bundleInitWithPath));
    }
    return true;
}();
}  // namespace
