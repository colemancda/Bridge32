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
