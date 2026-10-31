// UIAlertView for the guest. Mac Catalyst doesn't support it, so the bridge
// maps the guest's UIAlertView to B32Compat_UIAlertView (see Bridge::stubForName): the same API, presented as a
// UIAlertController in a window of its own (the guest may have no root view
// controller to present from), calling the old UIAlertViewDelegate methods.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Dispatch.h"

#import <UIKit/UIKit.h>

using namespace b32;
using namespace b32::objc;

@interface B32Compat_UIAlertView : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, assign) id delegate;
@property (nonatomic, assign) NSInteger cancelButtonIndex;
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
@end

@implementation B32Compat_UIAlertView {
    NSMutableArray<NSString *> *_buttons;
    UIWindow *_window;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _buttons = [[NSMutableArray alloc] init];
        _cancelButtonIndex = -1;
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message delegate:(id)delegate
            cancelButtonTitle:(NSString *)cancelTitle {
    if ((self = [self initWithFrame:CGRectZero])) {
        self.title = title;
        self.message = message;
        self.delegate = delegate;
        if (cancelTitle) _cancelButtonIndex = [self addButtonWithTitle:cancelTitle];
    }
    return self;
}

- (void)dealloc {
    [_buttons release];
    [_title release];
    [_message release];
    [_window release];
    [super dealloc];
}

- (NSInteger)addButtonWithTitle:(NSString *)title {
    [_buttons addObject:title ?: @""];
    return NSInteger(_buttons.count) - 1;
}

- (NSInteger)numberOfButtons { return NSInteger(_buttons.count); }
- (NSInteger)firstOtherButtonIndex { return _cancelButtonIndex == 0 ? (_buttons.count > 1 ? 1 : -1) : (_buttons.count ? 0 : -1); }
- (NSString *)buttonTitleAtIndex:(NSInteger)index {
    return index >= 0 && index < NSInteger(_buttons.count) ? _buttons[NSUInteger(index)] : nil;
}

- (void)show {
    if (_window) return;
    [self retain];  // until dismissed, like UIAlertView
    if ([_delegate respondsToSelector:@selector(willPresentAlertView:)]) [_delegate willPresentAlertView:(id)self];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:_title
                                                                   message:_message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [_buttons enumerateObjectsUsingBlock:^(NSString *button, NSUInteger i, BOOL *) {
        UIAlertActionStyle style = NSInteger(i) == _cancelButtonIndex ? UIAlertActionStyleCancel : UIAlertActionStyleDefault;
        [alert addAction:[UIAlertAction actionWithTitle:button style:style handler:^(UIAlertAction *) {
                   [self finishWithButtonIndex:NSInteger(i)];
               }]];
    }];

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:[UIWindowScene class]]) scene = (UIWindowScene *)s;
    _window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _window.windowLevel = UIWindowLevelAlert;
    _window.rootViewController = [[[UIViewController alloc] init] autorelease];
    _window.hidden = NO;
    [_window.rootViewController presentViewController:alert animated:YES completion:^{
        if ([_delegate respondsToSelector:@selector(didPresentAlertView:)]) [_delegate didPresentAlertView:(id)self];
    }];
    log("alert shown: %s / %s", _title.UTF8String ?: "", _message.UTF8String ?: "");
}

- (BOOL)isVisible { return _window != nil; }

- (void)dismissWithClickedButtonIndex:(NSInteger)index animated:(BOOL)animated {
    if (!_window) return;
    [_window.rootViewController dismissViewControllerAnimated:animated completion:nil];
    [self finishWithButtonIndex:index];
}

- (void)finishWithButtonIndex:(NSInteger)index {
    if (!_window) return;
    id delegate = _delegate;
    if ([delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)])
        [delegate alertView:(id)self clickedButtonAtIndex:index];
    if ([delegate respondsToSelector:@selector(alertView:willDismissWithButtonIndex:)])
        [delegate alertView:(id)self willDismissWithButtonIndex:index];
    _window.hidden = YES;
    [_window release];
    _window = nil;
    if ([delegate respondsToSelector:@selector(alertView:didDismissWithButtonIndex:)])
        [delegate alertView:(id)self didDismissWithButtonIndex:index];
    [self autorelease];
}

@end

namespace {
bool isAlertView(id receiver) { return [receiver isKindOfClass:[B32Compat_UIAlertView class]]; }
}  // namespace

// - (id)initWithTitle:message:delegate:cancelButtonTitle:otherButtonTitles:, ...
// The other button titles are nil-terminated guest varargs.
B32_OVERRIDE_WHEN(isAlertView, "initWithTitle:message:delegate:cancelButtonTitle:otherButtonTitles:") {
    NSString *title = o.bridge.toHost(o.args.ptr());
    NSString *message = o.bridge.toHost(o.args.ptr());
    id delegate = o.bridge.toHost(o.args.ptr());
    NSString *cancel = o.bridge.toHost(o.args.ptr());
    B32Compat_UIAlertView *alert = [(B32Compat_UIAlertView *)o.receiver initWithTitle:title message:message delegate:delegate
                                                  cancelButtonTitle:cancel];
    for (GuestAddr other = o.args.ptr(); other; other = o.args.ptr())
        [alert addButtonWithTitle:o.bridge.toHost(other)];
    o.c.ret(o.bridge.toGuest(alert));
}
