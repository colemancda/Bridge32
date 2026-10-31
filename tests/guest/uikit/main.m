// Milestone 3 guest: an iPhone OS 2-style UIKit app. The app delegate builds
// a window by hand and adds a UIView subclass that draws with CoreGraphics
// and tracks touches. Manual retain/release.
#import <UIKit/UIKit.h>
#include <stdio.h>

@interface TouchView : UIView {
    CGPoint _touch;
    int _touches;
}
@end

@implementation TouchView

- (id)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _touch = CGPointMake(160, 240);
        printf("TouchView initWithFrame: %.0fx%.0f\n", frame.size.width, frame.size.height);
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetRGBFillColor(ctx, 0.1f, 0.2f, 0.6f, 1.0f);
    CGContextFillRect(ctx, [self bounds]);
    // A yellow dot at the last touch, inside a white frame.
    CGContextSetRGBFillColor(ctx, 1.0f, 0.85f, 0.0f, 1.0f);
    CGContextFillEllipseInRect(ctx, CGRectMake(_touch.x - 20, _touch.y - 20, 40, 40));
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 1);
    CGContextSetLineWidth(ctx, 4);
    CGContextStrokeRect(ctx, CGRectInset([self bounds], 10, 10));
    printf("drawRect %.0fx%.0f touch=(%.0f,%.0f)\n", rect.size.width, rect.size.height, _touch.x, _touch.y);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    _touch = [[touches anyObject] locationInView:self];
    _touches++;
    printf("touch %d at (%.0f,%.0f)\n", _touches, _touch.x, _touch.y);
    [self setNeedsDisplay];
}

@end

@interface AppDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    CGRect bounds = [[UIScreen mainScreen] bounds];
    printf("applicationDidFinishLaunching: screen %.0fx%.0f\n", bounds.size.width, bounds.size.height);
    _window = [[UIWindow alloc] initWithFrame:bounds];
    TouchView *view = [[TouchView alloc] initWithFrame:[_window bounds]];
    [_window addSubview:view];
    [view release];
    [_window makeKeyAndVisible];
}

- (void)dealloc {
    [_window release];
    [super dealloc];
}

@end

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int status = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    [pool release];
    return status;
}
