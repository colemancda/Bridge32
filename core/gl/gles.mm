// OpenGL ES for the guest, on the host's own OpenGL ES. macOS keeps Apple's
// GL ES implementation (on Metal) for iOS apps on Apple Silicon at
// /System/iOSSupport/.../OpenGLES.framework; the SDK doesn't expose it to
// Mac Catalyst, but it loads and works there. EAGLContext and CAEAGLLayer are
// ordinary host classes the ObjC bridge already handles, so only the C
// functions need thunks.
//
// Functions are described in core/thunks/CTable.h's signature language.

#include "GLES.h"

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/CTable.h"

#include <dlfcn.h>

#include <cstring>
#include <unordered_map>

using namespace b32;

namespace {

constexpr const char *kOpenGLESPath = "/System/iOSSupport/System/Library/Frameworks/OpenGLES.framework/OpenGLES";
constexpr uint32_t GL_ARRAY_BUFFER_BINDING = 0x8894;
constexpr uint32_t GL_ELEMENT_ARRAY_BUFFER_BINDING = 0x8895;

void *library() {
    static void *handle = [] {
        void *h = dlopen(kOpenGLESPath, RTLD_NOW | RTLD_GLOBAL);
        if (!h) fatal("can't load the host's OpenGL ES (%s): %s", kOpenGLESPath, dlerror());
        return h;
    }();
    return handle;
}

// OpenGL ES 1.1 and the OES/EXT extensions iPhone OS games used.
constexpr CFunction kFunctions[] = {
    {"glActiveTexture", "v:u"}, {"glAlphaFunc", "v:uf"}, {"glAlphaFuncx", "v:ui"},
    {"glBindBuffer", "v:uu"}, {"glBindTexture", "v:uu"}, {"glBlendFunc", "v:uu"},
    {"glBufferData", "v:uzpu"}, {"glBufferSubData", "v:uzzp"},
    {"glClear", "v:u"}, {"glClearColor", "v:ffff"}, {"glClearColorx", "v:iiii"},
    {"glClearDepthf", "v:f"}, {"glClearDepthx", "v:i"}, {"glClearStencil", "v:i"},
    {"glClientActiveTexture", "v:u"}, {"glClipPlanef", "v:up"}, {"glClipPlanex", "v:up"},
    {"glColor4f", "v:ffff"}, {"glColor4ub", "v:uuuu"}, {"glColor4x", "v:iiii"},
    {"glColorMask", "v:uuuu"}, {"glColorPointer", "v:iuia"},
    {"glCompressedTexImage2D", "v:uiuiiiip"}, {"glCompressedTexSubImage2D", "v:uiiiiiuip"},
    {"glCopyTexImage2D", "v:uiuiiiii"}, {"glCopyTexSubImage2D", "v:uiiiiiii"},
    {"glCullFace", "v:u"}, {"glDeleteBuffers", "v:ip"}, {"glDeleteTextures", "v:ip"},
    {"glDepthFunc", "v:u"}, {"glDepthMask", "v:u"}, {"glDepthRangef", "v:ff"}, {"glDepthRangex", "v:ii"},
    {"glDisable", "v:u"}, {"glDisableClientState", "v:u"}, {"glDrawArrays", "v:uii"},
    {"glDrawElements", "v:uiue"}, {"glEnable", "v:u"}, {"glEnableClientState", "v:u"},
    {"glFinish", "v:"}, {"glFlush", "v:"},
    {"glFogf", "v:uf"}, {"glFogfv", "v:up"}, {"glFogx", "v:ui"}, {"glFogxv", "v:up"},
    {"glFrontFace", "v:u"}, {"glFrustumf", "v:ffffff"}, {"glFrustumx", "v:iiiiii"},
    {"glGenBuffers", "v:ip"}, {"glGenTextures", "v:ip"},
    {"glGetBooleanv", "v:up"}, {"glGetBufferParameteriv", "v:uup"}, {"glGetClipPlanef", "v:up"},
    {"glGetError", "u:"}, {"glGetFixedv", "v:up"}, {"glGetFloatv", "v:up"}, 
    {"glGetLightfv", "v:uup"}, {"glGetLightxv", "v:uup"}, {"glGetMaterialfv", "v:uup"}, {"glGetMaterialxv", "v:uup"},
    {"glGetString", "s:u"}, {"glGetTexEnvfv", "v:uup"}, {"glGetTexEnviv", "v:uup"}, {"glGetTexEnvxv", "v:uup"},
    {"glGetTexParameterfv", "v:uup"}, {"glGetTexParameteriv", "v:uup"}, {"glGetTexParameterxv", "v:uup"},
    {"glHint", "v:uu"}, {"glIsBuffer", "B:u"}, {"glIsEnabled", "B:u"}, {"glIsTexture", "B:u"},
    {"glLightModelf", "v:uf"}, {"glLightModelfv", "v:up"}, {"glLightModelx", "v:ui"}, {"glLightModelxv", "v:up"},
    {"glLightf", "v:uuf"}, {"glLightfv", "v:uup"}, {"glLightx", "v:uui"}, {"glLightxv", "v:uup"},
    {"glLoadIdentity", "v:"},
    {"glLoadMatrixf", "v:p"}, {"glLoadMatrixx", "v:p"}, {"glLogicOp", "v:u"},
    {"glMaterialf", "v:uuf"}, {"glMaterialfv", "v:uup"}, {"glMaterialx", "v:uui"}, {"glMaterialxv", "v:uup"},
    {"glMatrixMode", "v:u"}, {"glMultMatrixf", "v:p"}, {"glMultMatrixx", "v:p"},
    {"glMultiTexCoord4f", "v:uffff"}, {"glMultiTexCoord4x", "v:uiiii"},
    {"glNormal3f", "v:fff"}, {"glNormal3x", "v:iii"}, {"glNormalPointer", "v:uia"},
    {"glOrthof", "v:ffffff"}, {"glOrthox", "v:iiiiii"}, {"glPixelStorei", "v:ui"},
    {"glPointParameterf", "v:uf"}, {"glPointParameterfv", "v:up"}, {"glPointParameterx", "v:ui"},
    {"glPointParameterxv", "v:up"}, 
    {"glPointSizePointerOES", "v:uia"}, {"glPolygonOffset", "v:ff"}, {"glPolygonOffsetx", "v:ii"},
    {"glPopMatrix", "v:"}, {"glPushMatrix", "v:"}, {"glReadPixels", "v:iiiiuup"},
    {"glRotatef", "v:ffff"}, {"glRotatex", "v:iiii"}, {"glSampleCoverage", "v:fu"}, {"glSampleCoveragex", "v:iu"},
    {"glScalef", "v:fff"}, {"glScalex", "v:iii"}, {"glShadeModel", "v:u"},
    {"glStencilFunc", "v:uiu"}, {"glStencilMask", "v:u"}, {"glStencilOp", "v:uuu"},
    {"glTexCoordPointer", "v:iuia"},
    {"glTexEnvf", "v:uuf"}, {"glTexEnvfv", "v:uup"}, {"glTexEnvi", "v:uui"}, {"glTexEnviv", "v:uup"},
    {"glTexEnvx", "v:uui"}, {"glTexEnvxv", "v:uup"},
    {"glTexImage2D", "v:uiiiiiuup"},
    {"glTexParameterf", "v:uuf"}, {"glTexParameterfv", "v:uup"}, {"glTexParameteri", "v:uui"},
    {"glTexParameteriv", "v:uup"}, {"glTexParameterx", "v:uui"}, {"glTexParameterxv", "v:uup"},
    {"glTexSubImage2D", "v:uiiiiiuup"},
    {"glTranslatef", "v:fff"}, {"glTranslatex", "v:iii"}, {"glVertexPointer", "v:iuia"}, 

    // OES_framebuffer_object
    {"glGenFramebuffersOES", "v:ip"}, {"glGenRenderbuffersOES", "v:ip"},
    {"glDeleteFramebuffersOES", "v:ip"}, {"glDeleteRenderbuffersOES", "v:ip"},
    {"glBindFramebufferOES", "v:uu"}, {"glBindRenderbufferOES", "v:uu"},
    
    {"glCheckFramebufferStatusOES", "u:u"}, 
    {"glGetFramebufferAttachmentParameterivOES", "v:uuup"}, 
    {"glIsFramebufferOES", "B:u"}, {"glIsRenderbufferOES", "B:u"}, {"glGenerateMipmapOES", "v:u"},
    // OES_draw_texture
    {"glDrawTexfOES", "v:fffff"}, {"glDrawTexiOES", "v:iiiii"}, {"glDrawTexsOES", "v:iiiii"},
    {"glDrawTexxOES", "v:iiiii"}, {"glDrawTexfvOES", "v:p"}, {"glDrawTexivOES", "v:p"},
    {"glDrawTexsvOES", "v:p"}, {"glDrawTexxvOES", "v:p"},
    // blending and discard extensions
    {"glBlendEquationOES", "v:u"}, {"glBlendEquationSeparateOES", "v:uu"}, {"glBlendFuncSeparateOES", "v:uuuu"},
    {"glDiscardFramebufferEXT", "v:uip"},

    // OpenGL ES 2.0 (beyond what ES 1.1 shares)
    {"glAttachShader", "v:uu"}, {"glBindAttribLocation", "v:uup"}, {"glBlendColor", "v:ffff"},
    {"glBlendEquation", "v:u"}, {"glBlendEquationSeparate", "v:uu"}, {"glBlendFuncSeparate", "v:uuuu"},
    {"glBindFramebuffer", "v:uu"}, {"glBindRenderbuffer", "v:uu"}, {"glCheckFramebufferStatus", "u:u"},
    {"glCompileShader", "v:u"}, {"glCreateProgram", "u:"}, {"glCreateShader", "u:u"},
    {"glDeleteFramebuffers", "v:ip"}, {"glDeleteProgram", "v:u"}, {"glDeleteRenderbuffers", "v:ip"},
    {"glDeleteShader", "v:u"}, {"glDetachShader", "v:uu"}, {"glDisableVertexAttribArray", "v:u"},
    {"glEnableVertexAttribArray", "v:u"}, 
    {"glGenerateMipmap", "v:u"}, {"glGenFramebuffers", "v:ip"},
    {"glGenRenderbuffers", "v:ip"}, {"glGetActiveAttrib", "v:uuipppp"}, {"glGetActiveUniform", "v:uuipppp"},
    {"glGetAttachedShaders", "v:uipp"}, {"glGetAttribLocation", "i:up"}, {"glGetProgramiv", "v:uup"},
    {"glGetProgramInfoLog", "v:uipp"}, {"glGetShaderiv", "v:uup"}, {"glGetShaderInfoLog", "v:uipp"},
    {"glGetShaderSource", "v:uipp"}, {"glGetShaderPrecisionFormat", "v:uupp"}, {"glGetUniformfv", "v:uip"},
    {"glGetUniformiv", "v:uip"}, {"glGetUniformLocation", "i:up"}, {"glGetVertexAttribfv", "v:uup"},
    {"glGetVertexAttribiv", "v:uup"}, 
    {"glGetFramebufferAttachmentParameteriv", "v:uuup"}, {"glIsProgram", "B:u"}, {"glIsShader", "B:u"},
    {"glIsFramebuffer", "B:u"}, {"glIsRenderbuffer", "B:u"}, {"glLinkProgram", "v:u"},
    {"glReleaseShaderCompiler", "v:"}, {"glShaderSource", "v:uiSp"},
    {"glStencilFuncSeparate", "v:uuiu"}, {"glStencilMaskSeparate", "v:uu"}, {"glStencilOpSeparate", "v:uuuu"},
    {"glUniform1f", "v:if"}, {"glUniform2f", "v:iff"}, {"glUniform3f", "v:ifff"}, {"glUniform4f", "v:iffff"},
    {"glUniform1i", "v:ii"}, {"glUniform2i", "v:iii"}, {"glUniform3i", "v:iiii"}, {"glUniform4i", "v:iiiii"},
    {"glUniform1fv", "v:iip"}, {"glUniform2fv", "v:iip"}, {"glUniform3fv", "v:iip"}, {"glUniform4fv", "v:iip"},
    {"glUniform1iv", "v:iip"}, {"glUniform2iv", "v:iip"}, {"glUniform3iv", "v:iip"}, {"glUniform4iv", "v:iip"},
    {"glUniformMatrix2fv", "v:iiup"}, {"glUniformMatrix3fv", "v:iiup"}, {"glUniformMatrix4fv", "v:iiup"},
    {"glUseProgram", "v:u"}, {"glValidateProgram", "v:u"},
    {"glVertexAttrib1f", "v:uf"}, {"glVertexAttrib2f", "v:uff"}, {"glVertexAttrib3f", "v:ufff"},
    {"glVertexAttrib4f", "v:uffff"}, {"glVertexAttrib1fv", "v:up"}, {"glVertexAttrib2fv", "v:up"},
    {"glVertexAttrib3fv", "v:up"}, {"glVertexAttrib4fv", "v:up"}, {"glVertexAttribPointer", "v:uiuiia"},
    {"glGetBufferParameteriv", "v:uup"},
};

bool glBufferBound(char code) {
    static auto getIntegerv = reinterpret_cast<void (*)(uint32_t, int32_t *)>(dlsym(library(), "glGetIntegerv"));
    int32_t bound = 0;
    getIntegerv(code == 'a' ? GL_ARRAY_BUFFER_BINDING : GL_ELEMENT_ARRAY_BUFFER_BINDING, &bound);
    return bound != 0;
}

}  // namespace

void b32::gl::loadHostOpenGLES() {
    library();
    setBufferBoundQuery(glBufferBound);
}

B32_C_FUNCTIONS(kFunctions, library);

// --- OES_mapbuffer -----------------------------------------------------------------------
// The mapping is driver memory the guest can't address, so the guest gets a
// shadow copy in guest memory that is written back on unmap.

namespace {
constexpr uint32_t GL_BUFFER_SIZE = 0x8764;
struct Mapping {
    void *host;
    GuestAddr shadow;
    uint32_t size;
};
std::unordered_map<uint32_t, Mapping> mappings;  // by target
template <typename F> F glFunction(const char *name) { return reinterpret_cast<F>(dlsym(library(), name)); }
}  // namespace

// void *glMapBufferOES(GLenum target, GLenum access)
B32_THUNK(_glMapBufferOES) {
    uint32_t target = c.args.u32(), access = c.args.u32();
    static auto map = glFunction<void *(*)(uint32_t, uint32_t)>("glMapBufferOES");
    static auto getParam = glFunction<void (*)(uint32_t, uint32_t, int32_t *)>("glGetBufferParameteriv");
    void *host = map(target, access);
    if (!host) {
        c.ret(0);
        return;
    }
    int32_t size = 0;
    getParam(target, GL_BUFFER_SIZE, &size);
    GuestAddr shadow = c.heap.alloc(uint32_t(size));
    c.mem.copyIn(shadow, host, uint32_t(size));
    mappings[target] = {host, shadow, uint32_t(size)};
    c.ret(shadow);
}

// GLboolean glUnmapBufferOES(GLenum target)
B32_THUNK(_glUnmapBufferOES) {
    uint32_t target = c.args.u32();
    static auto unmap = glFunction<uint8_t (*)(uint32_t)>("glUnmapBufferOES");
    auto it = mappings.find(target);
    if (it != mappings.end()) {
        std::memcpy(it->second.host, c.mem.ptr<void>(it->second.shadow), it->second.size);
        c.heap.free(it->second.shadow);
        mappings.erase(it);
    }
    c.ret(unmap(target));
}

// EAGL string constants (OpenGL ES is loaded before the guest is bound).
B32_OBJC_CONSTANT(kEAGLDrawablePropertyRetainedBacking)
B32_OBJC_CONSTANT(kEAGLDrawablePropertyColorFormat)
B32_OBJC_CONSTANT(kEAGLColorFormatRGBA8)
B32_OBJC_CONSTANT(kEAGLColorFormatRGB565)
B32_OBJC_CONSTANT(kEAGLColorFormatSRGBA8)

// --- frame dumps (B32_DUMP_FRAMES=1) ------------------------------------------------------
// Every 60th presented frame is read back and written to $TMPDIR/b32-frame.png,
// so rendering can be checked without a screen (or with the display asleep).

#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include "core/objc/Dispatch.h"
#include <objc/message.h>

namespace {
constexpr uint32_t GL_RENDERBUFFER = 0x8D41, GL_RENDERBUFFER_WIDTH = 0x8D42, GL_RENDERBUFFER_HEIGHT = 0x8D43;
constexpr uint32_t GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401;

void dumpFrame() {
    static auto getParam = glFunction<void (*)(uint32_t, uint32_t, int32_t *)>("glGetRenderbufferParameteriv");
    static auto readPixels =
        glFunction<void (*)(int32_t, int32_t, int32_t, int32_t, uint32_t, uint32_t, void *)>("glReadPixels");
    int32_t width = 0, height = 0;
    getParam(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &width);
    getParam(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &height);
    if (width <= 0 || height <= 0) return;
    std::vector<uint8_t> pixels(size_t(width) * height * 4);
    readPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    // GL rows run bottom-up.
    std::vector<uint8_t> flipped(pixels.size());
    for (int32_t y = 0; y < height; y++)
        std::memcpy(&flipped[size_t(y) * width * 4], &pixels[size_t(height - 1 - y) * width * 4], size_t(width) * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(flipped.data(), size_t(width), size_t(height), 8, size_t(width) * 4,
                                                space, kCGImageAlphaNoneSkipLast);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"b32-frame.png"]];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((CFURLRef)url, CFSTR("public.png"), 1, nullptr);
    CGImageDestinationAddImage(dest, image, nullptr);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    CGContextRelease(bitmap);
    CGColorSpaceRelease(space);
}

bool dumpingFrames(id receiver) {
    static const bool enabled = getenv("B32_DUMP_FRAMES") != nullptr;
    return enabled && [receiver isKindOfClass:objc_getClass("EAGLContext")];
}
}  // namespace

// - (BOOL)presentRenderbuffer:(NSUInteger)target
B32_OVERRIDE_WHEN(dumpingFrames, "presentRenderbuffer:") {
    static uint64_t frames = 0;
    if (frames++ % 60 == 0) dumpFrame();
    NSUInteger target = o.args.u32();
    o.c.ret(reinterpret_cast<BOOL (*)(id, SEL, NSUInteger)>(objc_msgSend)(o.receiver, o.sel, target));
}
