// Small pieces of UIKit, MapKit and CoreLocation that are C functions or
// constants rather than methods.

#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

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
