// Apple's AGL, the OpenGL context API Carbon games use, on NSOpenGLContext.

#include "Carbon.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/CTable.h"

#import <AppKit/AppKit.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>

#include <unordered_map>
#include <vector>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;

namespace {
// AGL attribute numbers.
constexpr int32_t kNone = 0, kAllRenderers = 1, kRGBA = 4, kDouble = 5, kStereo = 6, kPixelSize = 2, kColorSize = 2 /* AGL_BUFFER_SIZE */,
                  kAlphaSize = 11, kDepthSize = 12, kStencilSize = 13, kAccumRed = 14, kFullscreen = 54, kAccelerated = 73,
                  kNoRecovery = 72, kPixelSizeAlias = 50, kRendererID = 70, kSampleBuffers = 55, kSamples = 56;

constexpr int32_t kSwapInterval = 222, kBufferRect = 203, kSwapRect = 200;
constexpr int32_t kDescAccelerated = 73, kDescVideoMemory = 120, kDescTextureMemory = 121, kDescRendererID = 70, kDescFullscreen = 54,
                  kDescBufferModes = 100, kDescColorModes = 103, kDescDepthModes = 105;

NSOpenGLContext *contextOf(uint32_t handle) { return handle ? (NSOpenGLContext *)hostPointer(handle) : nil; }

uint32_t currentHandle = 0;
}  // namespace

// AGLPixelFormat aglChoosePixelFormat(const AGLDevice *devs, GLint ndev, const GLint *attribs)
B32_THUNK(_aglChoosePixelFormat) {
    c.args.ptr();
    c.args.i32();
    GuestAddr attribs = c.args.ptr();
    std::vector<NSOpenGLPixelFormatAttribute> out{NSOpenGLPFAAccelerated};
    for (uint32_t i = 0;; i++) {
        int32_t attribute = c.mem.read<int32_t>(attribs + i * 4);
        if (attribute == kNone) break;
        auto value = [&] { return NSOpenGLPixelFormatAttribute(c.mem.read<int32_t>(attribs + ++i * 4)); };
        switch (attribute) {
        case kDouble: out.push_back(NSOpenGLPFADoubleBuffer); break;
        case kPixelSizeAlias:
        case kColorSize: {
            NSOpenGLPixelFormatAttribute size = value();
            out.push_back(NSOpenGLPFAColorSize);
            out.push_back(size);
            break;
        }
        case kAlphaSize:
            out.push_back(NSOpenGLPFAAlphaSize);
            out.push_back(value());
            break;
        case kDepthSize:
            out.push_back(NSOpenGLPFADepthSize);
            out.push_back(value());
            break;
        case kStencilSize:
            out.push_back(NSOpenGLPFAStencilSize);
            out.push_back(value());
            break;
        case kSampleBuffers:
            out.push_back(NSOpenGLPFASampleBuffers);
            out.push_back(value());
            break;
        case kSamples:
            out.push_back(NSOpenGLPFASamples);
            out.push_back(value());
            break;
        // Attributes with a value that doesn't matter here.
        case 8: case 9: case 10: case kAccumRed: case 15: case 16: case 17: case kRendererID: value(); break;
        default: break;
        }
    }
    out.push_back(0);
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:out.data()];
    c.ret(format ? hostHandle(format) : 0);
}
B32_THUNK(_aglDestroyPixelFormat) {}
// AGLContext aglCreateContext(pix, share)
B32_THUNK(_aglCreateContext) {
    auto *format = (NSOpenGLPixelFormat *)hostPointer(c.args.u32());
    NSOpenGLContext *share = contextOf(c.args.u32());
    NSOpenGLContext *context = [[NSOpenGLContext alloc] initWithFormat:format shareContext:share];
    c.ret(context ? hostHandle(context) : 0);
}
B32_THUNK(_aglDestroyContext) {
    uint32_t handle = c.args.u32();
    if (NSOpenGLContext *context = contextOf(handle)) {
        [context clearDrawable];
        [context release];
        forgetHostHandle(context);
    }
    if (currentHandle == handle) currentHandle = 0;
    c.ret(1);
}
B32_THUNK(_aglSetCurrentContext) {
    uint32_t handle = c.args.u32();
    currentHandle = handle;
    if (NSOpenGLContext *context = contextOf(handle)) [context makeCurrentContext];
    else [NSOpenGLContext clearCurrentContext];
    c.ret(1);
}
B32_THUNK(_aglGetCurrentContext) { c.ret(currentHandle); }
// GLboolean aglSetDrawable(ctx, AGLDrawable port)
B32_THUNK(_aglSetDrawable) {
    NSOpenGLContext *context = contextOf(c.args.u32());
    GuestAddr port = c.args.ptr();
    if (!port) [context clearDrawable];
    else if (NSView *view = b32::appkit::carbonViewForPort(port)) context.view = view;
    c.ret(1);
}
B32_THUNK(_aglGetDrawable) { c.ret(0); }
// GLboolean aglSetFullScreen(ctx, width, height, freq, device): the picture is
// scaled to the display rather than changing the display's mode.
B32_THUNK(_aglSetFullScreen) {
    NSOpenGLContext *context = contextOf(c.args.u32());
    GLint size[2] = {c.args.i32(), c.args.i32()};
    context.view = b32::appkit::carbonFullScreenView();
    if (size[0] > 0 && size[1] > 0) CGLSetParameter(context.CGLContextObj, kCGLCPSurfaceBackingSize, size);
    if (size[0] > 0 && size[1] > 0) CGLEnable(context.CGLContextObj, kCGLCESurfaceBackingSize);
    [context update];
    c.ret(1);
}
B32_THUNK(_aglUpdateContext) {
    [contextOf(c.args.u32()) update];
    c.ret(1);
}
B32_THUNK(_aglSwapBuffers) {
    [contextOf(c.args.u32()) flushBuffer];
    b32::appkit::pumpCarbonEvents(0);
}
// GLboolean aglSetInteger(ctx, pname, const GLint *params)
B32_THUNK(_aglSetInteger) {
    NSOpenGLContext *context = contextOf(c.args.u32());
    int32_t name = c.args.i32();
    GuestAddr params = c.args.ptr();
    if (name == kSwapInterval && params) {
        GLint interval = c.mem.read<int32_t>(params);
        [context setValues:&interval forParameter:NSOpenGLContextParameterSwapInterval];
    }
    (void)kBufferRect;
    (void)kSwapRect;
    c.ret(1);
}
B32_THUNK(_aglGetError) { c.ret(0); }
B32_THUNK(_aglGetVersion) {
    GuestAddr major = c.args.ptr(), minor = c.args.ptr();
    if (major) c.mem.write<int32_t>(major, 2);
    if (minor) c.mem.write<int32_t>(minor, 2);
}
B32_THUNK(_aglGetVirtualScreen) { c.ret(0); }

// --- CGL's own context creation, which uses the same host objects --------------------------

// CGLError CGLChoosePixelFormat(const CGLPixelFormatAttribute *, CGLPixelFormatObj *out, GLint *count)
B32_THUNK(_CGLChoosePixelFormat) {
    GuestAddr attribs = c.args.ptr(), out = c.args.ptr(), count = c.args.ptr();
    CGLPixelFormatObj format = nullptr;
    GLint n = 0;
    CGLError error = CGLChoosePixelFormat(c.mem.ptr<CGLPixelFormatAttribute>(attribs), &format, &n);
    c.mem.write<uint32_t>(out, format ? hostHandle(format) : 0);
    if (count) c.mem.write<int32_t>(count, n);
    c.ret(uint32_t(error));
}
B32_THUNK(_CGLDestroyPixelFormat) {
    uint32_t handle = c.args.u32();
    if (handle) CGLDestroyPixelFormat((CGLPixelFormatObj)hostPointer(handle));
    c.ret(0);
}
B32_THUNK(_CGLDescribePixelFormat) {
    auto format = (CGLPixelFormatObj)hostPointer(c.args.u32());
    GLint number = c.args.i32();
    auto attribute = CGLPixelFormatAttribute(c.args.u32());
    c.ret(uint32_t(CGLDescribePixelFormat(format, number, attribute, c.mem.ptr<GLint>(c.args.ptr()))));
}
// CGLError CGLCreateContext(pix, share, CGLContextObj *out)
B32_THUNK(_CGLCreateContext) {
    auto format = (CGLPixelFormatObj)hostPointer(c.args.u32());
    uint32_t share = c.args.u32();
    GuestAddr out = c.args.ptr();
    CGLContextObj context = nullptr;
    CGLError error = CGLCreateContext(format, share ? (CGLContextObj)hostPointer(share) : nullptr, &context);
    c.mem.write<uint32_t>(out, context ? hostHandle(context) : 0);
    c.ret(uint32_t(error));
}
B32_THUNK(_CGLDestroyContext) {
    uint32_t handle = c.args.u32();
    if (handle) CGLDestroyContext((CGLContextObj)hostPointer(handle));
    c.ret(0);
}
// CGLError CGLQueryRendererInfo(display mask, CGLRendererInfoObj *out, GLint *count)
B32_THUNK(_CGLQueryRendererInfo) {
    uint32_t mask = c.args.u32();
    GuestAddr out = c.args.ptr(), count = c.args.ptr();
    CGLRendererInfoObj info = nullptr;
    GLint n = 0;
    CGLError error = CGLQueryRendererInfo(mask, &info, &n);
    c.mem.write<uint32_t>(out, info ? hostHandle(info) : 0);
    if (count) c.mem.write<int32_t>(count, n);
    c.ret(uint32_t(error));
}
B32_THUNK(_CGLDescribeRenderer) {
    auto info = (CGLRendererInfoObj)hostPointer(c.args.u32());
    GLint renderer = c.args.i32();
    auto property = CGLRendererProperty(c.args.u32());
    c.ret(uint32_t(CGLDescribeRenderer(info, renderer, property, c.mem.ptr<GLint>(c.args.ptr()))));
}
B32_THUNK(_CGLDestroyRendererInfo) {
    uint32_t handle = c.args.u32();
    if (handle) CGLDestroyRendererInfo((CGLRendererInfoObj)hostPointer(handle));
    c.ret(0);
}

// One renderer: the host's.
namespace {
constexpr uint32_t kRendererInfo = 0x52454E44;  // any non-zero handle
}
B32_THUNK(_aglQueryRendererInfo) { c.ret(kRendererInfo); }
B32_THUNK(_aglNextRendererInfo) { c.ret(0); }
B32_THUNK(_aglDestroyRendererInfo) {}
// GLboolean aglDescribeRenderer(info, prop, GLint *value)
B32_THUNK(_aglDescribeRenderer) {
    c.args.u32();
    int32_t property = c.args.i32();
    GuestAddr out = c.args.ptr();
    int32_t value = 0;
    switch (property) {
    case kDescAccelerated: value = 1; break;
    case kDescFullscreen: value = 1; break;
    case kDescRendererID: value = 0x00022000; break;
    case kDescVideoMemory:
    case kDescTextureMemory: value = 1024 * 1024 * 1024; break;
    case kDescBufferModes: value = 0x3; break;
    case kDescColorModes: value = 0x7FFF; break;
    case kDescDepthModes: value = 0x7FFF; break;
    default: break;
    }
    if (out) c.mem.write<int32_t>(out, value);
    c.ret(1);
}
