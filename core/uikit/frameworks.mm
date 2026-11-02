// Small pieces of UIKit, MapKit and CoreLocation that are C functions or
// constants rather than methods.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/objc/Dispatch.h"
#include "core/thunks/CTable.h"

#include <CommonCrypto/CommonDigest.h>

#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>

using namespace b32;

namespace {
void *process() { return RTLD_DEFAULT; }

constexpr CFunction kFunctions[] = {
    {"UIImagePNGRepresentation", "o:o"},
    {"UIImageJPEGRepresentation", "o:of"},
    {"UIImageWriteToSavedPhotosAlbum", "v:oopp"},
};
}  // namespace

B32_C_FUNCTIONS(kFunctions, process);

// MKCoordinateRegion MKCoordinateRegionMakeWithDistance(CLLocationCoordinate2D center,
//     CLLocationDistance latitudinalMeters, CLLocationDistance longitudinalMeters)
// Everything is double in both ABIs; the 32-byte result goes through r0.
B32_THUNK(_MKCoordinateRegionMakeWithDistance) {
    GuestAddr out = c.args.ptr();
    CLLocationCoordinate2D center;
    center.latitude = c.args.f64();
    center.longitude = c.args.f64();
    double latitudinal = c.args.f64();
    MKCoordinateRegion region = MKCoordinateRegionMakeWithDistance(center, latitudinal, c.args.f64());
    c.mem.write<double>(out, region.center.latitude);
    c.mem.write<double>(out + 8, region.center.longitude);
    c.mem.write<double>(out + 16, region.span.latitudeDelta);
    c.mem.write<double>(out + 24, region.span.longitudeDelta);
}

// CLLocationAccuracy constants are doubles.
#define B32_DOUBLE_CONSTANT(name) \
    B32_DATA(_##name, 8) { rt.mem().write<double>(addr, name); }
B32_DOUBLE_CONSTANT(kCLLocationAccuracyBest)
B32_DOUBLE_CONSTANT(kCLLocationAccuracyBestForNavigation)
B32_DOUBLE_CONSTANT(kCLLocationAccuracyNearestTenMeters)
B32_DOUBLE_CONSTANT(kCLLocationAccuracyHundredMeters)
B32_DOUBLE_CONSTANT(kCLLocationAccuracyKilometer)
B32_DOUBLE_CONSTANT(kCLLocationAccuracyThreeKilometers)
B32_DOUBLE_CONSTANT(kCLDistanceFilterNone)

B32_DATA(_UIEdgeInsetsZero, 16) {}

// void UIGraphicsBeginImageContext(CGSize size)
B32_THUNK(_UIGraphicsBeginImageContext) {
    float width = c.args.f32();
    UIGraphicsBeginImageContext(CGSizeMake(width, c.args.f32()));
}
// void UIGraphicsBeginImageContextWithOptions(CGSize size, BOOL opaque, CGFloat scale)
B32_THUNK(_UIGraphicsBeginImageContextWithOptions) {
    float width = c.args.f32(), height = c.args.f32();
    BOOL opaque = c.args.u32() != 0;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(width, height), opaque, c.args.f32());
}
B32_THUNK(_UIGraphicsGetImageFromCurrentImageContext) {
    c.ret(c.rt.bridge().toGuest(UIGraphicsGetImageFromCurrentImageContext()));
}
B32_THUNK(_UIGraphicsEndImageContext) { UIGraphicsEndImageContext(); }

// void UIAccessibilityPostNotification(UIAccessibilityNotifications, id argument):
// there's no VoiceOver for guest views to talk to.
B32_THUNK(_UIAccessibilityPostNotification) {}
B32_THUNK(_UIAccessibilityIsVoiceOverRunning) { c.ret(0); }

// -[UIDevice uniqueIdentifier] (the UDID, removed in iOS 7): 40 hex digits,
// stable for this Mac, derived from the vendor identifier.
namespace {
bool isDevice(id receiver) { return [receiver isKindOfClass:[UIDevice class]]; }
}  // namespace

B32_OVERRIDE_WHEN(isDevice, "uniqueIdentifier") {
    NSString *vendor = UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"bridge32";
    NSData *bytes = [vendor dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(bytes.bytes, CC_LONG(bytes.length), digest);
    NSMutableString *udid = [NSMutableString string];
    for (unsigned char byte : digest) [udid appendFormat:@"%02x", byte];
    o.c.ret(o.bridge.toGuest(udid));
}

// Foundation's empty array and dictionary, which newer compilers use for
// @[] and @{}: variables holding the shared empty collection.
B32_DATA(___NSArray0__, 4) { rt.mem().write<uint32_t>(addr, rt.bridge().toGuest([NSArray array])); }
B32_DATA(___NSDictionary0__, 4) { rt.mem().write<uint32_t>(addr, rt.bridge().toGuest([NSDictionary dictionary])); }

// CGFloat constants: floats in the guest.
#define B32_CGFLOAT_CONSTANT(name) \
    B32_DATA(_##name, 4) { rt.mem().write<float>(addr, float(name)); }
B32_CGFLOAT_CONSTANT(UIFontWeightUltraLight)
B32_CGFLOAT_CONSTANT(UIFontWeightThin)
B32_CGFLOAT_CONSTANT(UIFontWeightLight)
B32_CGFLOAT_CONSTANT(UIFontWeightRegular)
B32_CGFLOAT_CONSTANT(UIFontWeightMedium)
B32_CGFLOAT_CONSTANT(UIFontWeightSemibold)
B32_CGFLOAT_CONSTANT(UIFontWeightBold)
B32_CGFLOAT_CONSTANT(UIFontWeightHeavy)
B32_CGFLOAT_CONSTANT(UIFontWeightBlack)
B32_CGFLOAT_CONSTANT(UIViewNoIntrinsicMetric)
B32_CGFLOAT_CONSTANT(UITableViewAutomaticDimension)
B32_CGFLOAT_CONSTANT(UIStackViewSpacingUseDefault)
B32_CGFLOAT_CONSTANT(UIStackViewSpacingUseSystem)

#define B32_CGSIZE_CONSTANT(name)                                  \
    B32_DATA(_##name, 8) {                                         \
        rt.mem().write<float>(addr, float(name.width));            \
        rt.mem().write<float>(addr + 4, float(name.height));       \
    }
B32_CGSIZE_CONSTANT(UILayoutFittingCompressedSize)
B32_CGSIZE_CONSTANT(UILayoutFittingExpandedSize)
B32_CGSIZE_CONSTANT(UICollectionViewFlowLayoutAutomaticSize)

// id<MTLDevice> MTLCreateSystemDefaultDevice(void): no Metal for 32-bit guests,
// as on iPhones before the 5s; engines that check fall back to OpenGL ES.
B32_THUNK(_MTLCreateSystemDefaultDevice) { c.ret(0); }

// --- CloudKit -----------------------------------------------------------------------------
// A wrapped app has no iCloud container (that takes Apple's entitlement), and
// the real CKContainer throws without one. This one has no account: games
// read that as cloud saves being off. Its databases are nil, so any record
// operations are messages to nil.

@interface B32Compat_CKContainer : NSObject
@end

@implementation B32Compat_CKContainer

+ (instancetype)defaultContainer {
    static B32Compat_CKContainer *container = [[B32Compat_CKContainer alloc] init];
    return container;
}

+ (instancetype)containerWithIdentifier:(NSString *)identifier { return [self defaultContainer]; }

- (id)privateCloudDatabase { return nil; }
- (id)publicCloudDatabase { return nil; }
- (id)sharedCloudDatabase { return nil; }
- (NSString *)containerIdentifier { return nil; }

- (void)accountStatusWithCompletionHandler:(void (^)(NSInteger status, NSError *error))handler {
    if (handler) handler(3 /* CKAccountStatusNoAccount */, nil);
}

- (void)fetchUserRecordIDWithCompletionHandler:(void (^)(id recordID, NSError *error))handler {
    if (handler) handler(nil, [NSError errorWithDomain:@"CKErrorDomain" code:9 /* CKErrorNotAuthenticated */ userInfo:nil]);
}

@end
