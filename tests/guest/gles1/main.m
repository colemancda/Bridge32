// Milestone 4 guest: OpenGL ES 1.1 the way the iPhone OS 2 template did it.
// An EAGLView backed by a CAEAGLLayer, an OES framebuffer bound to the
// layer's storage, an NSTimer render loop, and client-side vertex arrays.
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <stdio.h>

@interface EAGLView : UIView {
    EAGLContext *_context;
    GLuint _framebuffer, _renderbuffer;
    GLint _width, _height;
    NSTimer *_timer;
    float _angle;
    int _frames;
}
@end

@implementation EAGLView

+ (Class)layerClass { return [CAEAGLLayer class]; }

- (id)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    CAEAGLLayer *layer = (CAEAGLLayer *)self.layer;
    layer.opaque = YES;
    layer.drawableProperties = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSNumber numberWithBool:NO], kEAGLDrawablePropertyRetainedBacking,
        kEAGLColorFormatRGBA8, kEAGLDrawablePropertyColorFormat, nil];

    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
    [EAGLContext setCurrentContext:_context];
    printf("GL_RENDERER=%s GL_VERSION=%s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

    glGenFramebuffersOES(1, &_framebuffer);
    glGenRenderbuffersOES(1, &_renderbuffer);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:layer];
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, _renderbuffer);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &_width);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &_height);
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    printf("framebuffer %dx%d status=%s\n", _width, _height, status == GL_FRAMEBUFFER_COMPLETE_OES ? "complete" : "INCOMPLETE");

    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60.0 target:self selector:@selector(drawFrame) userInfo:nil repeats:YES];
    return self;
}

- (void)drawFrame {
    static const GLfloat vertices[] = {0.0f, 0.8f, -0.7f, -0.6f, 0.7f, -0.6f};
    static const GLubyte colors[] = {255, 60, 60, 255, 60, 255, 60, 255, 60, 120, 255, 255};

    [EAGLContext setCurrentContext:_context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glViewport(0, 0, _width, _height);
    glClearColor(0.08f, 0.08f, 0.12f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrthof(-1, 1, -1.5f, 1.5f, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glRotatef(_angle, 0, 0, 1);
    _angle += 2;

    glVertexPointer(2, GL_FLOAT, 0, vertices);
    glEnableClientState(GL_VERTEX_ARRAY);
    glColorPointer(4, GL_UNSIGNED_BYTE, 0, colors);
    glEnableClientState(GL_COLOR_ARRAY);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _renderbuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER_OES];
    if (++_frames % 60 == 1) printf("frame %d glGetError=0x%x\n", _frames, glGetError());
}

@end

@interface AppDelegate : NSObject <UIApplicationDelegate> {
    UIWindow *_window;
}
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(UIApplication *)application {
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    EAGLView *view = [[EAGLView alloc] initWithFrame:[_window bounds]];
    [_window addSubview:view];
    [view release];
    [_window makeKeyAndVisible];
}
@end

int main(int argc, char *argv[]) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int status = UIApplicationMain(argc, argv, nil, @"AppDelegate");
    [pool release];
    return status;
}
