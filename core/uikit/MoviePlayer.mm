// MPMoviePlayerController with the iPhone OS 2/3 API (movieControlMode,
// backgroundColor...), which today's MediaPlayer no longer has, and the
// MPMoviePlayerViewController (iOS 3.2) that wraps one. Games mostly use them
// for intro videos; this compat player skips the video: playing (by -play or
// by autoplay) reports the movie finished, and the game carries on as if the
// player had tapped through it.

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
@property (nonatomic) BOOL useApplicationAudioSession;
@property (nonatomic) BOOL shouldAutoplay;
@end

@implementation B32Compat_MPMoviePlayerController {
    UIView *_view;
    BOOL _playing, _finished;
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

- (void)prepareToPlay {
    if (_shouldAutoplay) [self play];
}

// Autoplay starts once the content is ready, which is right away here.
- (void)setShouldAutoplay:(BOOL)shouldAutoplay {
    _shouldAutoplay = shouldAutoplay;
    if (shouldAutoplay) [self play];
}
- (void)setFullscreen:(BOOL)fullscreen animated:(BOOL)animated { _fullscreen = fullscreen; }
- (void)setOrientation:(NSInteger)orientation animated:(BOOL)animated {}

- (void)play {
    if (_playing) return;
    _playing = YES;
    log("skipping movie %s", _contentURL.lastPathComponent.UTF8String ?: "?");
    _finished = NO;
    // A player that has played stays alive for the rest of the run: games
    // release it in their "finished" handler and still send it -stop
    // afterwards, which the real player, kept alive by MediaPlayer, survived.
    // (THPS2 does.) It's one small object per movie.
    static NSMutableSet *played = [[NSMutableSet alloc] init];
    [played addObject:self];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self finish];
    });
}

- (void)pause {}
- (void)stop { [self finish]; }

- (void)finish {
    if (_finished) return;
    _finished = YES;
    _playing = NO;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MPMoviePlayerPlaybackDidFinishNotification
                      object:self
                    userInfo:@{MPMoviePlayerPlaybackDidFinishReasonUserInfoKey : @(MPMovieFinishReasonUserExited)}];
}

@end

@interface B32Compat_MPMoviePlayerViewController : UIViewController
@property (nonatomic, readonly) B32Compat_MPMoviePlayerController *moviePlayer;
@end

@implementation B32Compat_MPMoviePlayerViewController

- (instancetype)initWithContentURL:(NSURL *)url {
    if ((self = [super initWithNibName:nil bundle:nil]))
        _moviePlayer = [[B32Compat_MPMoviePlayerController alloc] initWithContentURL:url];
    return self;
}

- (void)dealloc {
    [_moviePlayer release];
    [super dealloc];
}

- (void)loadView { self.view = _moviePlayer.view; }

// Shown with presentMoviePlayerViewControllerAnimated:, it plays by itself.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_moviePlayer play];
}

@end
