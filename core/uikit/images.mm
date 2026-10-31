// +[UIImage imageNamed:] for the guest's device. On the Mac, UIKit picks the
// asset for a 2x iPad (name@2x~ipad.png), so an iPhone game's 320-point logo
// comes back 640 points wide. The guest's device has a 1x screen, so this
// looks for name~iphone / name~ipad, then name, and loads it at scale 1.

#include "core/Device.h"
#include "core/objc/Dispatch.h"

#import <UIKit/UIKit.h>
#include <objc/runtime.h>

#include <cstring>

using namespace b32;
using namespace b32::objc;

namespace {

bool isImageClass(id receiver) { return object_isClass(receiver) && [receiver isSubclassOfClass:[UIImage class]]; }

UIImage *guestImageNamed(NSString *name) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = [[NSMutableDictionary alloc] init];
    @synchronized(cache) {
        if (UIImage *cached = cache[name]) return cached;
    }
    NSString *resources = NSBundle.mainBundle.resourcePath;
    NSString *extension = name.pathExtension.length ? name.pathExtension : nil;
    NSString *base = extension ? name.stringByDeletingPathExtension : name;
    bool iPad = std::strncmp(device::current().machine, "iPad", 4) == 0;
    NSString *idiom = iPad ? @"~ipad" : @"~iphone";
    for (NSString *ext : extension ? @[ extension ] : @[ @"png", @"jpg", @"jpeg" ]) {
        for (NSString *candidate : @[ [base stringByAppendingString:idiom], base ]) {
            NSString *path = [[resources stringByAppendingPathComponent:candidate] stringByAppendingPathExtension:ext];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data) continue;
            UIImage *image = [UIImage imageWithData:data scale:1];
            if (!image) continue;
            @synchronized(cache) {
                cache[name] = image;
            }
            return image;
        }
    }
    return nil;
}

}  // namespace

// + (UIImage *)imageNamed:(NSString *)name
B32_OVERRIDE_WHEN(isImageClass, "imageNamed:") {
    NSString *name = o.bridge.toHost(o.args.ptr());
    // Asset catalogs and anything not in the bundle as a file: UIKit's own lookup.
    UIImage *image = name ? guestImageNamed(name) : nil;
    if (!image && name) image = [UIImage imageNamed:name];
    o.c.ret(o.bridge.toGuest(image));
}
