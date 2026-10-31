// Renders the guest's screen at a multiple of its size, so 3D scenes stay
// sharp when the Mac window scales the guest up. The drawable (and any
// renderbuffer the guest sizes to match it, like the depth buffer) gets
// `factor` times the pixels; framebuffers drawing into them have their
// pixel-unit state (viewport, scissor, line width, point size) scaled to
// match, and every size the guest can query reads back unscaled, so the guest
// never sees the difference. Offscreen framebuffers are left alone.
//
// The factor follows the window: 1 at its smallest, and as it's enlarged the
// guest renders at the zoom, rounded (up to 4x); the screen's renderbuffers
// are reallocated just before the guest's next present. B32RenderScale in
// Info.plist or B32_RENDER_SCALE pins it instead (1 turns scaling off).
//
// Not scaled: glReadPixels and glCopyTex[Sub]Image2D from the screen, and
// ES2 shaders that use gl_FragCoord or gl_PointSize.

#include "GLES.h"

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

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <unordered_map>
#include <unordered_set>
#include <vector>

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

constexpr int kMaxFactor = 4;

// The pinned factor, or 0 when it follows the window.
int pinnedFactor() {
    static int value = [] {
        id setting = getenv("B32_RENDER_SCALE")
                         ? (id)[NSString stringWithUTF8String:getenv("B32_RENDER_SCALE")]
                         : [[NSBundle mainBundle] objectForInfoDictionaryKey:@"B32RenderScale"];
        if (!setting) return 0;
        int v = [setting intValue];
        return v < 1 ? 1 : v;
    }();
    return value;
}
bool following() { return pinnedFactor() == 0; }

std::atomic<int> currentFactor{0};  // what the screen's renderbuffers have now
std::atomic<int> wantedFactor{1};   // what the window asks for

int factor() {
    int f = currentFactor.load();
    if (f) return f;
    f = following() ? 1 : pinnedFactor();
    currentFactor = f;
    return f;
}
// Whether to track the screen's buffers: always when following the window,
// which may enlarge them later.
bool tracking() { return following() || factor() > 1; }

std::mutex lock;
std::unordered_set<uint32_t> scaledRenderbuffers;
std::unordered_set<uint32_t> scaledFramebuffers;
// Framebuffers whose color target is a texture or an unscaled renderbuffer
// (a game's offscreen passes), and what each depth or stencil renderbuffer is
// attached to: its size has to match its framebuffer's color target.
std::unordered_set<uint32_t> unscaledFramebuffers;
std::unordered_map<uint32_t, uint32_t> attachedTo;  // renderbuffer -> framebuffer
int32_t drawableWidth = 0, drawableHeight = 0;  // the guest's own idea of the drawable's size
uint32_t drawableRenderbuffer = 0;
CALayer *drawableLayer = nil;
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

bool isScaled(uint32_t framebuffer) {
    std::lock_guard<std::mutex> guard(lock);
    return scaledFramebuffers.count(framebuffer) != 0;
}

bool scaling() { return isScaled(boundFramebuffer()); }

bool isContext(id receiver) { return [receiver isKindOfClass:objc_getClass("EAGLContext")]; }

}  // namespace

// The scale the guest gave a layer we render at a multiple of, kept on the layer.
namespace {
char kGuestScale;
NSNumber *guestScaleOf(CALayer *layer) { return layer ? objc_getAssociatedObject(layer, &kGuestScale) : nil; }
bool isScaledLayer(id receiver) { return [receiver isKindOfClass:[CALayer class]] && guestScaleOf(receiver); }
bool hasScaledLayer(id receiver) {
    return [receiver respondsToSelector:@selector(layer)] && [receiver isKindOfClass:objc_getClass("UIView")] &&
           guestScaleOf([receiver layer]);
}
}  // namespace

// Guests size their 2D overlays by the scale they asked for; they get it back.
B32_OVERRIDE_WHEN(isScaledLayer, "contentsScale") { o.c.retF32(float(guestScaleOf(o.receiver).doubleValue)); }
B32_OVERRIDE_WHEN(hasScaledLayer, "contentScaleFactor") {
    o.c.retF32(float(guestScaleOf([o.receiver layer]).doubleValue));
}

// - (BOOL)renderbufferStorage:(NSUInteger)target fromDrawable:(id<EAGLDrawable>)drawable
B32_OVERRIDE_WHEN(isContext, "renderbufferStorage:fromDrawable:") {
    NSUInteger target = o.args.u32();
    id drawable = o.bridge.toHost(o.args.ptr());
    CALayer *layer = [drawable isKindOfClass:[CALayer class]] ? (CALayer *)drawable : nil;
    // The scale the guest gave the layer, remembered: a guest that sets up
    // its drawable again finds the layer already scaled.
    NSNumber *remembered = guestScaleOf(layer);
    CGFloat guestScale = remembered ? remembered.doubleValue : layer ? layer.contentsScale : 1;
    if (layer && !remembered)
        objc_setAssociatedObject(layer, &kGuestScale, @(guestScale), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (layer && factor() > 1) layer.contentsScale = guestScale * factor();
    BOOL ok = reinterpret_cast<BOOL (*)(id, SEL, NSUInteger, id)>(objc_msgSend)(o.receiver, o.sel, target, drawable);
    if (ok && layer && tracking()) {
        std::lock_guard<std::mutex> guard(lock);
        drawableWidth = int32_t(std::lround(layer.bounds.size.width * guestScale));
        drawableHeight = int32_t(std::lround(layer.bounds.size.height * guestScale));
        drawableRenderbuffer = boundRenderbuffer();
        drawableLayer = [layer retain];
        scaledRenderbuffers.insert(drawableRenderbuffer);
        if (factor() > 1) log("rendering the %dx%d screen at %dx", drawableWidth, drawableHeight, factor());
    }
    o.c.ret(ok);
}

namespace {

// Storage the size of the drawable is the screen's depth, stencil or
// multisample buffer, and grows with it, unless it's attached to an
// offscreen framebuffer (whose color target keeps the guest's size). A
// renderbuffer not attached yet is settled when it is.
int32_t storageScale(int32_t width, int32_t height) {
    uint32_t renderbuffer = boundRenderbuffer();
    std::lock_guard<std::mutex> guard(lock);
    auto owner = attachedTo.find(renderbuffer);
    bool offscreen = owner != attachedTo.end() && unscaledFramebuffers.count(owner->second);
    bool scale = tracking() && width > 0 && width == drawableWidth && height == drawableHeight && !offscreen;
    if (scale) scaledRenderbuffers.insert(renderbuffer);
    else scaledRenderbuffers.erase(renderbuffer);
    return scale ? factor() : 1;
}

// glRenderbufferStorage[OES](target, internalformat, width, height)
void renderbufferStorage(Call &c, const char *name) {
    static auto storageOES = glFunction<void (*)(uint32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorageOES");
    static auto storage = glFunction<void (*)(uint32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorage");
    uint32_t target = c.args.u32(), format = c.args.u32();
    int32_t width = c.args.i32(), height = c.args.i32();
    int32_t f = storageScale(width, height);
    (std::strcmp(name, "OES") == 0 ? storageOES : storage)(target, format, width * f, height * f);
}

// glRenderbufferStorageMultisample[APPLE](target, samples, internalformat, width, height)
void renderbufferStorageMultisample(Call &c, const char *name) {
    auto storage = glFunction<void (*)(uint32_t, int32_t, uint32_t, int32_t, int32_t)>(name);
    uint32_t target = c.args.u32();
    int32_t samples = c.args.i32();
    uint32_t format = c.args.u32();
    int32_t width = c.args.i32(), height = c.args.i32();
    int32_t f = storageScale(width, height);
    storage(target, samples, format, width * f, height * f);
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

constexpr uint32_t GL_DEPTH_ATTACHMENT = 0x8D00, GL_STENCIL_ATTACHMENT = 0x8D20;
constexpr uint32_t GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE = 0x8CD0, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME = 0x8CD1;
constexpr uint32_t GL_RENDERBUFFER_TARGET = 0x8D41, GL_FRAMEBUFFER_TARGET = 0x8D40;

// Gives a drawable-sized depth or stencil renderbuffer the size its
// framebuffer's color target has: scaled for the screen, the guest's own for
// an offscreen pass. Called with `lock` not held.
void matchDepthAndStencil(uint32_t framebuffer, bool scaled) {
    static auto getAttachment = glFunction<void (*)(uint32_t, uint32_t, uint32_t, int32_t *)>(
        "glGetFramebufferAttachmentParameteriv");
    static auto bindRenderbuffer = glFunction<void (*)(uint32_t, uint32_t)>("glBindRenderbuffer");
    static auto getParam = glFunction<void (*)(uint32_t, uint32_t, int32_t *)>("glGetRenderbufferParameteriv");
    static auto storage = glFunction<void (*)(uint32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorage");
    static auto storageMultisample =
        glFunction<void (*)(uint32_t, int32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorageMultisampleAPPLE");
    constexpr uint32_t GL_RENDERBUFFER_INTERNAL_FORMAT = 0x8D44, GL_RENDERBUFFER_SAMPLES = 0x8CAB;
    if (framebuffer == 0 || !tracking()) return;
    for (uint32_t attachment : {GL_DEPTH_ATTACHMENT, GL_STENCIL_ATTACHMENT}) {
        int32_t type = 0, name = 0;
        getAttachment(GL_FRAMEBUFFER_TARGET, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE, &type);
        if (type != int32_t(GL_RENDERBUFFER_TARGET)) continue;
        getAttachment(GL_FRAMEBUFFER_TARGET, attachment, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME, &name);
        uint32_t rb = uint32_t(name);
        int32_t width, height, f = factor();
        {
            std::lock_guard<std::mutex> guard(lock);
            if (rb == drawableRenderbuffer || drawableWidth == 0) continue;
            width = drawableWidth;
            height = drawableHeight;
        }
        uint32_t previous = boundRenderbuffer();
        bindRenderbuffer(GL_RENDERBUFFER_TARGET, rb);
        int32_t current = 0, format = 0, samples = 0;
        getParam(GL_RENDERBUFFER_TARGET, GL_RENDERBUFFER_WIDTH, &current);
        getParam(GL_RENDERBUFFER_TARGET, GL_RENDERBUFFER_INTERNAL_FORMAT, &format);
        getParam(GL_RENDERBUFFER_TARGET, GL_RENDERBUFFER_SAMPLES, &samples);
        bool isScreenSized = current == width || current == width * f;
        int32_t wanted = scaled ? f : 1;
        if (isScreenSized && current != width * wanted) {
            if (samples > 0) storageMultisample(GL_RENDERBUFFER_TARGET, samples, uint32_t(format), width * wanted, height * wanted);
            else storage(GL_RENDERBUFFER_TARGET, uint32_t(format), width * wanted, height * wanted);
        }
        bindRenderbuffer(GL_RENDERBUFFER_TARGET, previous);
        if (isScreenSized) {
            std::lock_guard<std::mutex> guard(lock);
            if (scaled) scaledRenderbuffers.insert(rb);
            else scaledRenderbuffers.erase(rb);
        }
    }
}

// A framebuffer is scaled while its color attachment is a scaled renderbuffer.
void framebufferRenderbuffer(Call &c, bool oes) {
    static auto attachOES = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t)>("glFramebufferRenderbufferOES");
    static auto attach = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t)>("glFramebufferRenderbuffer");
    uint32_t target = c.args.u32(), attachment = c.args.u32(), rbTarget = c.args.u32(), renderbuffer = c.args.u32();
    uint32_t framebuffer = boundFramebuffer();
    int colorState = -1;  // 1 scaled, 0 offscreen, -1 not known yet
    {
        std::lock_guard<std::mutex> guard(lock);
        if (attachment == GL_COLOR_ATTACHMENT0) {
            bool scaled = scaledRenderbuffers.count(renderbuffer) != 0;
            if (scaled) {
                scaledFramebuffers.insert(framebuffer);
                unscaledFramebuffers.erase(framebuffer);
            } else {
                scaledFramebuffers.erase(framebuffer);
                unscaledFramebuffers.insert(framebuffer);
            }
        } else if (renderbuffer) {
            attachedTo[renderbuffer] = framebuffer;
        }
        if (scaledFramebuffers.count(framebuffer)) colorState = 1;
        else if (unscaledFramebuffers.count(framebuffer)) colorState = 0;
    }
    (oes ? attachOES : attach)(target, attachment, rbTarget, renderbuffer);
    if (colorState >= 0) matchDepthAndStencil(framebuffer, colorState == 1);
}

void framebufferTexture2D(Call &c, bool oes) {
    static auto attachOES = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t, int32_t)>("glFramebufferTexture2DOES");
    static auto attach = glFunction<void (*)(uint32_t, uint32_t, uint32_t, uint32_t, int32_t)>("glFramebufferTexture2D");
    uint32_t target = c.args.u32(), attachment = c.args.u32(), texTarget = c.args.u32(), texture = c.args.u32();
    int32_t level = c.args.i32();
    uint32_t framebuffer = boundFramebuffer();
    bool color = attachment == GL_COLOR_ATTACHMENT0;
    if (color) {
        std::lock_guard<std::mutex> guard(lock);
        scaledFramebuffers.erase(framebuffer);
        unscaledFramebuffers.insert(framebuffer);
    }
    (oes ? attachOES : attach)(target, attachment, texTarget, texture, level);
    // Rendering to a texture: its depth and stencil keep the guest's size.
    if (color) matchDepthAndStencil(framebuffer, false);
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
B32_THUNK(_glRenderbufferStorageMultisampleAPPLE) {
    renderbufferStorageMultisample(c, "glRenderbufferStorageMultisampleAPPLE");
}
B32_THUNK(_glRenderbufferStorageMultisample) { renderbufferStorageMultisample(c, "glRenderbufferStorageMultisample"); }

// glBlitFramebuffer(srcX0, srcY0, srcX1, srcY1, dstX0, dstY0, dstX1, dstY1, mask, filter):
// each rectangle is in its own framebuffer's pixels (OpenGL ES 3).
B32_THUNK(_glBlitFramebuffer) {
    static auto blit = glFunction<void (*)(int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t, int32_t,
                                           uint32_t, uint32_t)>("glBlitFramebuffer");
    constexpr uint32_t GL_READ_FRAMEBUFFER_BINDING = 0x8CAA, GL_DRAW_FRAMEBUFFER_BINDING = 0x8CA6;
    int32_t v[8];
    for (auto &x : v) x = c.args.i32();
    uint32_t mask = c.args.u32(), filter = c.args.u32();
    int32_t src = isScaled(binding(GL_READ_FRAMEBUFFER_BINDING)) ? factor() : 1;
    int32_t dst = isScaled(binding(GL_DRAW_FRAMEBUFFER_BINDING)) ? factor() : 1;
    blit(v[0] * src, v[1] * src, v[2] * src, v[3] * src, v[4] * dst, v[5] * dst, v[6] * dst, v[7] * dst, mask, filter);
}
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

// --- following the window --------------------------------------------------------------------------

void b32::gl::setDisplayZoom(double zoom) {
    if (!following()) return;
    wantedFactor = std::clamp(int(std::lround(zoom)), 1, kMaxFactor);
}

namespace {

constexpr uint32_t GL_RENDERBUFFER = 0x8D41, GL_RENDERBUFFER_INTERNAL_FORMAT = 0x8D44;
constexpr uint32_t GL_RENDERBUFFER_SAMPLES = 0x8CAB;

// Before a present, on the guest's GL thread with its context current: when
// the window wants another factor, reallocate the screen's renderbuffers at
// it, keeping the guest's bindings, and carry the viewport and scissor over.
void followWindow(Call &) {
    if (!following()) return;  // a pinned factor stays put
    int wanted = wantedFactor.load(), old = factor();
    if (wanted == old || !drawableLayer) return;
    // EAGL has no headers in the Catalyst SDK.
    id context = reinterpret_cast<id (*)(id, SEL)>(objc_msgSend)(objc_getClass("EAGLContext"),
                                                                 sel_registerName("currentContext"));
    if (!context) return;
    static auto getIntegerv = glFunction<void (*)(uint32_t, int32_t *)>("glGetIntegerv");
    static auto bindRenderbuffer = glFunction<void (*)(uint32_t, uint32_t)>("glBindRenderbuffer");
    static auto getParam = glFunction<void (*)(uint32_t, uint32_t, int32_t *)>("glGetRenderbufferParameteriv");
    static auto storage = glFunction<void (*)(uint32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorage");
    static auto storageMultisample =
        glFunction<void (*)(uint32_t, int32_t, uint32_t, int32_t, int32_t)>("glRenderbufferStorageMultisampleAPPLE");
    static auto viewport = glFunction<void (*)(int32_t, int32_t, int32_t, int32_t)>("glViewport");
    static auto scissor = glFunction<void (*)(int32_t, int32_t, int32_t, int32_t)>("glScissor");

    std::vector<uint32_t> renderbuffers;
    int32_t width, height;
    uint32_t drawable;
    {
        std::lock_guard<std::mutex> guard(lock);
        renderbuffers.assign(scaledRenderbuffers.begin(), scaledRenderbuffers.end());
        width = drawableWidth;
        height = drawableHeight;
        drawable = drawableRenderbuffer;
    }
    bool screenBound = scaling();
    int32_t view[4], box[4];
    getIntegerv(GL_VIEWPORT, view);
    getIntegerv(GL_SCISSOR_BOX, box);
    uint32_t previous = boundRenderbuffer();

    NSNumber *guestScale = guestScaleOf(drawableLayer);
    for (uint32_t rb : renderbuffers) {
        bindRenderbuffer(GL_RENDERBUFFER, rb);
        if (rb == drawable) {
            drawableLayer.contentsScale = (guestScale ? guestScale.doubleValue : 1) * wanted;
            reinterpret_cast<BOOL (*)(id, SEL, NSUInteger, id)>(objc_msgSend)(
                context, sel_registerName("renderbufferStorage:fromDrawable:"), GL_RENDERBUFFER, drawableLayer);
            continue;
        }
        int32_t format = 0, samples = 0;
        getParam(GL_RENDERBUFFER, GL_RENDERBUFFER_INTERNAL_FORMAT, &format);
        getParam(GL_RENDERBUFFER, GL_RENDERBUFFER_SAMPLES, &samples);
        if (samples > 0) storageMultisample(GL_RENDERBUFFER, samples, uint32_t(format), width * wanted, height * wanted);
        else storage(GL_RENDERBUFFER, uint32_t(format), width * wanted, height * wanted);
    }
    bindRenderbuffer(GL_RENDERBUFFER, previous);
    currentFactor = wanted;
    if (screenBound) {
        viewport(view[0] / old * wanted, view[1] / old * wanted, view[2] / old * wanted, view[3] / old * wanted);
        scissor(box[0] / old * wanted, box[1] / old * wanted, box[2] / old * wanted, box[3] / old * wanted);
    }
    log("rendering the %dx%d screen at %dx", width, height, wanted);
}

[[maybe_unused]] const int registered = (b32::gl::addPresentHook(followWindow), 0);

}  // namespace
