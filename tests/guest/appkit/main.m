// A small AppKit app, compiled for i386 and run through the AppKit shell: a
// nib with a window, a guest NSView drawing in -drawRect:, a button whose
// action is a guest method, a text field bound to a guest model, a sheet and
// a timer. It checks itself and quits, printing "appkit passed".
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>

static int failures;
static void check(int ok, const char *what) {
    printf("%s=%s\n", what, ok ? "ok" : "FAILED");
    if (!ok) failures++;
}

@interface Model : NSObject {
    NSString *_title;
}
@property (copy) NSString *title;
@end
@implementation Model
@synthesize title = _title;
- (void)dealloc {
    [_title release];
    [super dealloc];
}
@end

@interface DrawView : NSView {
@public
    int drawCount;
}
@end
@implementation DrawView
- (void)drawRect:(NSRect)dirty {
    drawCount++;
    [[NSColor blueColor] set];
    NSRectFill([self bounds]);
    [[NSColor redColor] set];
    NSBezierPath *oval = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect([self bounds], 40, 20)];
    [oval fill];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    IBOutlet NSWindow *window;
    IBOutlet DrawView *drawView;
    IBOutlet NSButton *button;
    IBOutlet NSTextField *field;
    Model *model;
    NSPanel *sheet;
    int clicks, step;
    int sheetResult;
    void *sheetContext;
}
- (IBAction)count:(id)sender;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    check(NSApp != nil && [NSApp delegate] == self, "NSApp-delegate");
    check(window != nil && drawView != nil && button != nil && field != nil, "outlets");
    check([drawView isKindOfClass:[DrawView class]], "nib-custom-class");
    check([NSClassFromString(@"NSQuickDrawView") isSubclassOfClass:[NSView class]], "removed-class-stub");
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    model = [[Model alloc] init];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(step:) userInfo:nil repeats:YES];
}

- (IBAction)count:(id)sender {
    clicks++;
    [sender setTitle:[NSString stringWithFormat:@"Clicked %d", clicks]];
}

- (void)checkDrawing {
    NSRect bounds = [drawView bounds];
    NSBitmapImageRep *rep = [drawView bitmapImageRepForCachingDisplayInRect:bounds];
    [drawView cacheDisplayInRect:bounds toBitmapImageRep:rep];
    NSColor *center = [[rep colorAtX:(NSInteger)NSWidth(bounds) * [rep pixelsWide] / (NSInteger)NSWidth(bounds) / 2
                                   y:[rep pixelsHigh] / 2] colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    NSColor *corner = [[rep colorAtX:2 y:2] colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
    check(drawView->drawCount > 0, "drawRect-ran");
    check([center redComponent] > 0.8 && [center blueComponent] < 0.3, "oval-is-red");
    check([corner blueComponent] > 0.8 && [corner redComponent] < 0.3, "background-is-blue");

    const char *png = getenv("B32_TEST_PNG");
    if (png) {
        NSView *content = [window contentView];
        NSBitmapImageRep *all = [content bitmapImageRepForCachingDisplayInRect:[content bounds]];
        [content cacheDisplayInRect:[content bounds] toBitmapImageRep:all];
        NSData *data = [all representationUsingType:NSBitmapImageFileTypePNG properties:[NSDictionary dictionary]];
        [data writeToFile:[NSString stringWithUTF8String:png] atomically:YES];
    }
}

- (void)sheetDidEnd:(NSWindow *)panel returnCode:(NSInteger)code contextInfo:(void *)context {
    sheetResult = (int)code;
    sheetContext = context;
}

- (void)step:(NSTimer *)timer {
    switch (step++) {
    case 0:
        check(1, "timer-fired");
        [self checkDrawing];
        break;
    case 1:
        [button performClick:nil];
        check(clicks == 1, "button-action");
        check([[button title] isEqualToString:@"Clicked 1"], "button-title");
        break;
    case 2:
        [field bind:@"value" toObject:model withKeyPath:@"title" options:nil];
        [model setTitle:@"first"];
        check([[field stringValue] isEqualToString:@"first"], "binding-initial");
        model.title = @"changed by guest";
        check([[field stringValue] isEqualToString:@"changed by guest"], "binding-updates");
        break;
    case 3:
        sheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100)
                                           styleMask:NSWindowStyleMaskTitled
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
        [NSApp beginSheet:sheet
            modalForWindow:window
             modalDelegate:self
            didEndSelector:@selector(sheetDidEnd:returnCode:contextInfo:)
               contextInfo:(void *)0x1234];
        break;
    case 4:
        check([window attachedSheet] == sheet, "sheet-attached");
        [NSApp endSheet:sheet returnCode:7];
        [sheet orderOut:nil];
        check(sheetResult == 7 && sheetContext == (void *)0x1234, "sheet-ended");
        break;
    case 5:
        [timer invalidate];
        printf(failures ? "appkit FAILED\n" : "appkit passed\n");
        fflush(stdout);
        [NSApp terminate:nil];
        break;
    }
}
@end

int main(int argc, const char **argv) { return NSApplicationMain(argc, argv); }
