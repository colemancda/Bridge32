// Renders the guest's screen at a multiple of its size, so 3D scenes stay
// sharp when the Mac window scales the guest up. The drawable (and any
// renderbuffer the guest sizes to match it, like the depth buffer) gets
// `factor` times the pixels; framebuffers drawing into them have their
// pixel-unit state (viewport, scissor, line width, point size) scaled to
// match, and every size the guest can query reads back unscaled, so the guest
// never sees the difference. Offscreen framebuffers are left alone.
//
// The factor is B32RenderScale in Info.plist or B32_RENDER_SCALE (default 4;
// 1 turns it off).
//
// Not scaled: glReadPixels and glCopyTex[Sub]Image2D from the screen, and
// ES2 shaders that use gl_FragCoord or gl_PointSize.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/objc/Dispatch.h"
#include "core/thunks/Thunks.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <cmath>
#include <mutex>
#include <unordered_set>

using namespace b32;

namespace {

constexpr uint32_t GL_VIEWPORT = 0x0BA2, GL_SCISSOR_BOX = 0x0C10;
constexpr uint32_t GL_FRAMEBUFFER_BINDING = 0x8CA6, GL_RENDERBUFFER_BINDING = 0x8CA7;
constexpr uint32_t GL_RENDERBUFFER_WIDTH = 0x8D42, GL_RENDERBUFFER_HEIGHT = 0x8D43;
constexpr uint32_t GL_COLOR_ATTACHMENT0 = 0x8CE0;

template <typename F> F glFunction(const char *name) {
    static void *library =
        dlopen("/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW | RTLD_GLOBAL);
    return reinterpret_cast<F>(dlsym(library, name));
}

int factor() {
    static int value = [] {
        id setting = getenv("B32_RENDER_SCALE")
                         ? (id)[NSString stringWithUTF8String:getenv("B32_RENDER_SCALE")]
                         : [[NSBundle mainBundle] objectForInfoDictionaryKey:@"B32RenderScale"];
        int v = setting ? [setting intValue] : 4;
        return v < 1 ? 1 : v;
    }();
    return value;
}

std::mutex lock;
std::unordered_set<uint32_t> scaledRenderbuffers;
std::unordered_set<uint32_t> scaledFramebuffers;
int32_t drawableWidth = 0, drawableHeight = 0;  // the guest's own idea of the drawable's size
uint32_t binding(uint32_t pname) {
    static auto getIntegerv = glFunction<void (*)(uint32_t, int32_t *)>("glGetIntegerv");
    int32_t name = 0;
    getIntegerv(pname, &name);
    return uint32_t(name);
}

// Asked of GL rather than tracked: guests set up the screen on one thread
// and draw on another.
uint32_t boundRenderbuffer() { return binding(GL_RENDERBUFFER_BINDING); }
uint32_t boundFramebuffer() { return binding(GL_FRAMEBUFFER_BINDING); }

bool scaling() {
    uint32_t framebuffer = boundFramebuffer();
    std::lock_guard<std::mutex> guard(lock);
    return scaledFramebuffers.count(framebuffer) != 0;
}

bool isContext(id receiver) { return [receiver isKindOfClass:objc_getClass("EAGLContext")]; }

}  // namespace

// - (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable
B32_OVERRIDE_WHEN(isContext, "renderbufferStorage:fromDrawable:") {
    NSUInteger target = o.args.u32();
    id drawable = o.bridge.toHost(o.args.ptr());
    CALayer *layer = [drawable isKindOfClass:[CALayer class]] ? (CALayer *)drawable : nil;
    CGFloat guestScale = layer ? layer.contentsScale : 1;
    if (layer && factor() > 1) layer.contentsScale = guestScale * factor();
    BOOL ok = reinterpret_cast<BOOL (*)(id, SEL, NSUInteger, id)>(objc_msgSend)(o.receiver, o.sel, target, drawable);
    if (ok && layer && factor() > 1) {
        std::lock_guard<std::mutex> guard(lock);
        drawableWidth = int32_t(std::lround(layer.bounds.size.width * guestScale));
        drawableHeight = int32_t(std::lround(layer.bounds.size.height * guestScale));
        scaledRenderbuffers.insert(boundRenderbuffer());
        log("rendering the %dx%d screen at %dx", drawableWidth, drawableHeight, factor());
    }
    o.c.ret(ok);
}

namespace {

// glRenderbufferStorage[OES](target, internalformat, width, height): storage
// the size of the drawable is the screen's depth or stencil buffer.
void renderbufferStorage(Call &c, const char *name) {
    static auto storageOES = glFunction<void (*)(uint32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorageOES");
    static auto storage = glFunction<void (*)(uint32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorage");
    uint32_t target = c.args.u32(), format = c.args.u32();
    int32_t width = c.args.i32(), height = c.args.i32();
    uint32_t renderbuffer = boundRenderbuffer();
    bool scale;
    {
        std::lock_guard<std::mutex> guard(lock);
        scale = factor() > 1 && width == drawableWidth && height == drawableHeight;
        if (scale) scaledRenderbuffers.insert(renderbuffer);
        else scaledRenderbuffers.erase(renderbuffer);
    }
    int32_t f = scale ? factor() : 1;
    (std::strcmp(name, "OES") == 0 ? storageOES : storage)(target, format, width * f, height * f);
}

// glGetRenderbufferParameteriv[OES](target, pname, params)
void getRenderbufferParameter(Call &c, bool oes) {
    static auto getOES = glFunction<void (*)(uint32_t, uint32_t, int32_t *)>("glGetRenderbufferParameterivOES");
    static auto get = glFunction<void (*)(uint32_t, uint32_t, int32_t *)>("glGetRenderbufferParameteriv");
    uint32_t target = c.args.u32(), pname = c.args.u32();
    GuestAddr out = c.args.ptr();
    int32_t value = 0;
    (oes ? getOES : get)(target, pname, &value);
    if (pname == GL_RENDERBUFFER_WIDTH || pname == GL_RENDERBUFFER_HEIGHT) {
        std::lock_guard<std::mutex> guard(lock);
        if (scaledRenderbuffers.count(boundRenderbuffer())) value /= factor();
    }
    if (out) c.mem.write<int32_t>(out, value);
}

// A framebuffer is scaled while its color attachment is a scaled renderbuffer.
void framebufferRenderbuffer(Call &c, bool oes) {
    static auto attachOES = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t)>("glFramebufferRenderbufferOES");
    static auto attach = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t)>("glFramebufferRenderbuffer");
    uint32_t target = c.args.u32(), attachment = c.args.u32(), rbTarget = c.args.u32(), renderbuffer = c.args.u32();
    if (attachment == GL_COLOR_ATTACHMENT0) {
        uint32_t framebuffer = boundFramebuffer();
        std::lock_guard<std::mutex> guard(lock);
        if (scaledRenderbuffers.count(renderbuffer)) scaledFramebuffers.insert(framebuffer);
        else scaledFramebuffers.erase(framebuffer);
    }
    (oes ? attachOES : attach)(target, attachment, rbTarget, renderbuffer);
}

void framebufferTexture2D(Call &c, bool oes) {
    static auto attachOES = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t, int32_t)>("glFramebufferTexture2DOES");
    static auto attach = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t, int32_t)>("glFramebufferTexture2D");
    uint32_t target = c.args.u32(), attachment = c.args.u32(), texTarget = c.args.u32(), texture = c.args.u32();
    int32_t level = c.args.i32();
    if (attachment == GL_COLOR_ATTACHMENT0) {
        uint32_t framebuffer = boundFramebuffer();
        std::lock_guard<std::mutex> guard(lock);
        scaledFramebuffers.erase(framebuffer);
    }
    (oes ? attachOES : attach)(target, attachment, texTarget, texture, level);
}

void rect(Call &c, const char *name) {
    int32_t x = c.args.i32(), y = c.args.i32(), w = c.args.i32(), h = c.args.i32();
    int32_t f = scaling() ? factor() : 1;
    glFunction<void (*)(int32_t, int32_t, int32_t, int32_t)>(name)(x * f, y * f, w * f, h * f);
}

void width(Call &c, const char *name) {
    float value = c.args.f32();
    glFunction<void (*)(float)>(name)(scaling() ? value * factor() : value);
}

void widthFixed(Call &c, const char *name) {
    int32_t value = c.args.i32();
    glFunction<void (*)(int32_t)>(name)(scaling() ? value * factor() : value);
}

}  // namespace

B32_THUNK(_glRenderbufferStorageOES) { renderbufferStorage(c, "OES"); }
B32_THUNK(_glRenderbufferStorage) { renderbufferStorage(c, ""); }
B32_THUNK(_glGetRenderbufferParameterivOES) { getRenderbufferParameter(c, true); }
B32_THUNK(_glGetRenderbufferParameteriv) { getRenderbufferParameter(c, false); }
B32_THUNK(_glFramebufferRenderbufferOES) { framebufferRenderbuffer(c, true); }
B32_THUNK(_glFramebufferRenderbuffer) { framebufferRenderbuffer(c, false); }
B32_THUNK(_glFramebufferTexture2DOES) { framebufferTexture2D(c, true); }
B32_THUNK(_glFramebufferTexture2D) { framebufferTexture2D(c, false); }
B32_THUNK(_glViewport) { rect(c, "glViewport"); }
B32_THUNK(_glScissor) { rect(c, "glScissor"); }
B32_THUNK(_glLineWidth) { width(c, "glLineWidth"); }
B32_THUNK(_glPointSize) { width(c, "glPointSize"); }
B32_THUNK(_glLineWidthx) { widthFixed(c, "glLineWidthx"); }
B32_THUNK(_glPointSizex) { widthFixed(c, "glPointSizex"); }

// void glGetIntegerv(GLenum pname, GLint *params): the viewport and scissor
// box read back in the guest's units.
B32_THUNK(_glGetIntegerv) {
    static auto getIntegerv = glFunction<void (*)(uint32_t, int32_t *)>("glGetIntegerv");
    uint32_t pname = c.args.u32();
    GuestAddr out = c.args.ptr();
    if (!out) return;
    int32_t *values = c.mem.ptr<int32_t>(out);
    getIntegerv(pname, values);
    if ((pname == GL_VIEWPORT || pname == GL_SCISSOR_BOX) && scaling())
        for (int i = 0; i < 4; i++) values[i] /= factor();
}
