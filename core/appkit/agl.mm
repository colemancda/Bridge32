// Apple's AGL, the OpenGL context API Carbon games use, on NSOpenGLContext.

#include "Carbon.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/CTable.h"

#import <AppKit/AppKit.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>

#include <cstring>
#include <set>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;

namespace b32::gl {
// core/gl/opengl.mm
void swapGuestPixels();
void snapshotPresented();
}

namespace {
// AGL attribute numbers.
constexpr int32_t kNone = 0, kAllRenderers = 1, kRGBA = 4, kDouble = 5, kStereo = 6, kPixelSize = 2, kColorSize = 2 /* AGL_BUFFER_SIZE */,
                  kAlphaSize = 11, kDepthSize = 12, kStencilSize = 13, kAccumRed = 14, kFullscreen = 54, kAccelerated = 73,
                  kNoRecovery = 72, kPixelSizeAlias = 50, kRendererID = 70, kSampleBuffers = 55, kSamples = 56;

constexpr int32_t kSwapInterval = 222, kBufferRect = 203, kSwapRect = 200;
constexpr int32_t kDescAccelerated = 73, kDescVideoMemory = 120, kDescTextureMemory = 121, kDescRendererID = 70, kDescFullscreen = 54,
                  kDescBufferModes = 100, kDescColorModes = 103, kDescDepthModes = 105;

// An AGL context as the guest holds it: a record in its own memory, which begins as the real thing did.
// A program built with aglMacro.h doesn't call glClear(...): it calls through the record,
// (*context->disp.clear)(context->rend, ...). So the record is `rend` (here the record itself) and then the
// dispatch table, a pointer for each OpenGL function in gliDispatch.h's order, each of them a stub that
// drops `rend` and goes on to that function's own thunk.
const char *const kDispatch[] = {
#include "core/gl/gli_dispatch.inc"
};
constexpr uint32_t kDispatchSlots = sizeof kDispatch / sizeof kDispatch[0];
constexpr uint32_t kRecordSize = 4 + kDispatchSlots * 4 + 256;  // and room for what follows the table
constexpr char kForwardPrefix[] = "_gli_";

std::unordered_map<uint32_t, NSOpenGLContext *> aglContexts;

// The thunk behind every slot: the call is for the context named by its first argument.
void dispatchForward(Call &c) {
    struct Target {
        ThunkFn function;
        std::string name;
    };
    // By the stub's own name, which stays where it is for as long as the program runs.
    thread_local std::unordered_map<const char *, Target> targets;
    auto found = targets.find(c.name);
    if (found == targets.end()) {
        std::string name = std::string("_") + (c.name + sizeof kForwardPrefix - 1);
        found = targets.emplace(c.name, Target{ThunkRegistry::find(name), name}).first;
    }
    GuestAddr record = c.args.ptr();
    if (auto context = aglContexts.find(record); context != aglContexts.end() && NSOpenGLContext.currentContext != context->second)
        [context->second makeCurrentContext];
    Call call{c.rt, c.cpu, c.mem, c.heap, c.args, found->second.name.c_str()};
    found->second.function(call);
}
const int dispatchRegistration = [] {
    for (const char *function : kDispatch)
        if (function) ThunkRegistry::all().emplace(std::string(kForwardPrefix) + function, dispatchForward);
    return 0;
}();

GuestAddr aglContextRecord(Call &c, NSOpenGLContext *context) {
    GuestAddr record = c.heap.calloc(1, kRecordSize);
    c.mem.write<uint32_t>(record, record);  // rend: what the record's functions are called with
    for (uint32_t slot = 0; slot < kDispatchSlots; slot++) {
        const char *function = kDispatch[slot];
        if (!function || !ThunkRegistry::find(std::string("_") + function)) continue;
        // A string is answered per name, which the table's thunk would take the record for.
        bool string = !std::strcmp(function, "glGetString");
        c.mem.write<uint32_t>(record + 4 + slot * 4, c.rt.thunks().stubFor(string ? "_aglRecordString" : std::string(kForwardPrefix) + function));
    }
    aglContexts[record] = context;
    return record;
}
NSOpenGLContext *contextOf(uint32_t handle) {
    if (!handle) return nil;
    if (auto it = aglContexts.find(handle); it != aglContexts.end()) return it->second;
    return (NSOpenGLContext *)hostPointer(handle);
}

uint32_t currentHandle = 0;

// A CGL attribute list, copied out of the guest's byte order: attributes
// ending at a zero, most of them followed by a value (which may be zero too),
// so the ones that stand alone are named.
std::vector<CGLPixelFormatAttribute> hostAttributes(Call &c, GuestAddr list) {
    static const std::set<uint32_t> alone = {1, 5, 6, 51, 52, 53, 54, 57, 58, 59, 60, 61, 71, 72, 73, 74, 75, 76, 78, 80, 81, 83, 90, 91, 96};
    std::vector<CGLPixelFormatAttribute> attributes;
    for (uint32_t i = 0;; i++) {
        uint32_t attribute = c.mem.read<uint32_t>(list + i * 4);
        attributes.push_back(CGLPixelFormatAttribute(attribute));
        if (!attribute) return attributes;
        if (!alone.count(attribute)) attributes.push_back(CGLPixelFormatAttribute(c.mem.read<uint32_t>(list + ++i * 4)));
    }
}
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
    c.ret(context ? aglContextRecord(c, context) : 0);
}
// const GLubyte *aglRecordString(AGLRecord, GLenum name): what the record's
// +0x1d8 slot answers, on the record's own context.
B32_THUNK(_aglRecordString) {
    GuestAddr record = c.args.ptr();
    uint32_t name = c.args.u32();
    if (NSOpenGLContext *context = aglContexts[record]) [context makeCurrentContext];
    const GLubyte *string = glGetString(name);
    c.ret(string ? c.rt.internString((const char *)string) : 0);
}
B32_THUNK(_aglDestroyContext) {
    uint32_t handle = c.args.u32();
    if (auto it = aglContexts.find(handle); it != aglContexts.end()) {
        [it->second clearDrawable];
        [it->second release];
        aglContexts.erase(it);
    } else if (NSOpenGLContext *context = contextOf(handle)) {
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
    if (NSOpenGLContext *context = contextOf(handle)) {
        [context makeCurrentContext];
        // Pixel store state is the context's own, so each is told once which byte order its pixels are in.
        static std::unordered_set<uint32_t> prepared;
        if (prepared.insert(handle).second) b32::gl::swapGuestPixels();
    } else {
        [NSOpenGLContext clearCurrentContext];
    }
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
// scaled to the display rather than changing the display's mode. A size of 0 is
// the mode the display is in, which comes back as the size the game asked it for.
B32_THUNK(_aglSetFullScreen) {
    NSOpenGLContext *context = contextOf(c.args.u32());
    GLint size[2] = {c.args.i32(), c.args.i32()};
    log("aglSetFullScreen %d x %d", size[0], size[1]);
    context.view = b32::appkit::carbonFullScreenView(size[0], size[1]);
    if (size[0] > 0 && size[1] > 0) CGLSetParameter(context.CGLContextObj, kCGLCPSurfaceBackingSize, size);
    if (size[0] > 0 && size[1] > 0) CGLEnable(context.CGLContextObj, kCGLCESurfaceBackingSize);
    [context update];
    // A context's first viewport is its drawable, which was the view at its own size until just now; a
    // game that never sets one counts on it being the screen it asked for.
    if (size[0] > 0 && size[1] > 0) {
        NSOpenGLContext *previous = [NSOpenGLContext currentContext];
        [context makeCurrentContext];
        glViewport(0, 0, size[0], size[1]);
        glScissor(0, 0, size[0], size[1]);
        if (previous != context) {
            if (previous) [previous makeCurrentContext];
            else [NSOpenGLContext clearCurrentContext];
        }
    }
    c.ret(1);
}
B32_THUNK(_aglUpdateContext) {
    [contextOf(c.args.u32()) update];
    c.ret(1);
}
B32_THUNK(_aglSwapBuffers) {
    b32::gl::snapshotPresented();
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
    CGLError error = CGLChoosePixelFormat(hostAttributes(c, attribs).data(), &format, &n);
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
    GuestAddr out = c.args.ptr();
    GLint value = 0;
    CGLError error = CGLDescribePixelFormat(format, number, attribute, &value);
    c.mem.write<int32_t>(out, value);
    c.ret(uint32_t(error));
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
    GuestAddr out = c.args.ptr();
    GLint value = 0;
    CGLError error = CGLDescribeRenderer(info, renderer, property, &value);
    c.mem.write<int32_t>(out, value);
    c.ret(uint32_t(error));
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
