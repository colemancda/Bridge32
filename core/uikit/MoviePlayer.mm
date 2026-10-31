// MPMoviePlayerController with the iPhone OS 2/3 API (movieControlMode,
// backgroundColor...), which today's MediaPlayer no longer has. Games mostly
// use it for intro videos; this compat player skips the video: play() reports
// the movie finished, and the game carries on as if the player had tapped
// through it.

#include "core/Log.h"

#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

using namespace b32;

@interface B32Compat_MPMoviePlayerController : NSObject
@property (nonatomic, copy) NSURL *contentURL;
@property (nonatomic, retain) UIColor *backgroundColor;
@property (nonatomic) NSInteger scalingMode, movieControlMode, controlStyle, repeatMode;
@property (nonatomic) double initialPlaybackTime;
@property (nonatomic, getter=isFullscreen) BOOL fullscreen;
@end

@implementation B32Compat_MPMoviePlayerController {
    UIView *_view;
    BOOL _finished;
}

- (instancetype)initWithContentURL:(NSURL *)url {
    if ((self = [super init])) self.contentURL = url;
    return self;
}

- (void)dealloc {
    [_contentURL release];
    [_backgroundColor release];
    [_view release];
    [super dealloc];
}

- (UIView *)view {
    if (!_view) _view = [[UIView alloc] initWithFrame:CGRectZero];
    return _view;
}

- (void)prepareToPlay {}
- (void)setFullscreen:(BOOL)fullscreen animated:(BOOL)animated { _fullscreen = fullscreen; }
- (void)setOrientation:(NSInteger)orientation animated:(BOOL)animated {}

- (void)play {
    log("skipping movie %s", _contentURL.lastPathComponent.UTF8String ?: "?");
    _finished = NO;
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finish];
        [self release];
    });
}

- (void)pause {}
- (void)stop { [self finish]; }

- (void)finish {
    if (_finished) return;
    _finished = YES;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MPMoviePlayerPlaybackDidFinishNotification
                      object:self
                    userInfo:@{MPMoviePlayerPlaybackDidFinishReasonUserInfoKey : @(MPMovieFinishReasonUserExited)}];
}

@end
