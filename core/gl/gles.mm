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
    {"glGetError", "u:"}, {"glGetFixedv", "v:up"}, {"glGetFloatv", "v:up"}, {"glGetIntegerv", "v:up"},
    {"glGetLightfv", "v:uup"}, {"glGetLightxv", "v:uup"}, {"glGetMaterialfv", "v:uup"}, {"glGetMaterialxv", "v:uup"},
    {"glGetString", "s:u"}, {"glGetTexEnvfv", "v:uup"}, {"glGetTexEnviv", "v:uup"}, {"glGetTexEnvxv", "v:uup"},
    {"glGetTexParameterfv", "v:uup"}, {"glGetTexParameteriv", "v:uup"}, {"glGetTexParameterxv", "v:uup"},
    {"glHint", "v:uu"}, {"glIsBuffer", "B:u"}, {"glIsEnabled", "B:u"}, {"glIsTexture", "B:u"},
    {"glLightModelf", "v:uf"}, {"glLightModelfv", "v:up"}, {"glLightModelx", "v:ui"}, {"glLightModelxv", "v:up"},
    {"glLightf", "v:uuf"}, {"glLightfv", "v:uup"}, {"glLightx", "v:uui"}, {"glLightxv", "v:uup"},
    {"glLineWidth", "v:f"}, {"glLineWidthx", "v:i"}, {"glLoadIdentity", "v:"},
    {"glLoadMatrixf", "v:p"}, {"glLoadMatrixx", "v:p"}, {"glLogicOp", "v:u"},
    {"glMaterialf", "v:uuf"}, {"glMaterialfv", "v:uup"}, {"glMaterialx", "v:uui"}, {"glMaterialxv", "v:uup"},
    {"glMatrixMode", "v:u"}, {"glMultMatrixf", "v:p"}, {"glMultMatrixx", "v:p"},
    {"glMultiTexCoord4f", "v:uffff"}, {"glMultiTexCoord4x", "v:uiiii"},
    {"glNormal3f", "v:fff"}, {"glNormal3x", "v:iii"}, {"glNormalPointer", "v:uia"},
    {"glOrthof", "v:ffffff"}, {"glOrthox", "v:iiiiii"}, {"glPixelStorei", "v:ui"},
    {"glPointParameterf", "v:uf"}, {"glPointParameterfv", "v:up"}, {"glPointParameterx", "v:ui"},
    {"glPointParameterxv", "v:up"}, {"glPointSize", "v:f"}, {"glPointSizex", "v:i"},
    {"glPointSizePointerOES", "v:uia"}, {"glPolygonOffset", "v:ff"}, {"glPolygonOffsetx", "v:ii"},
    {"glPopMatrix", "v:"}, {"glPushMatrix", "v:"}, {"glReadPixels", "v:iiiiuup"},
    {"glRotatef", "v:ffff"}, {"glRotatex", "v:iiii"}, {"glSampleCoverage", "v:fu"}, {"glSampleCoveragex", "v:iu"},
    {"glScalef", "v:fff"}, {"glScalex", "v:iii"}, {"glScissor", "v:iiii"}, {"glShadeModel", "v:u"},
    {"glStencilFunc", "v:uiu"}, {"glStencilMask", "v:u"}, {"glStencilOp", "v:uuu"},
    {"glTexCoordPointer", "v:iuia"},
    {"glTexEnvf", "v:uuf"}, {"glTexEnvfv", "v:uup"}, {"glTexEnvi", "v:uui"}, {"glTexEnviv", "v:uup"},
    {"glTexEnvx", "v:uui"}, {"glTexEnvxv", "v:uup"},
    {"glTexImage2D", "v:uiiiiiuup"},
    {"glTexParameterf", "v:uuf"}, {"glTexParameterfv", "v:uup"}, {"glTexParameteri", "v:uui"},
    {"glTexParameteriv", "v:uup"}, {"glTexParameterx", "v:uui"}, {"glTexParameterxv", "v:uup"},
    {"glTexSubImage2D", "v:uiiiiiuup"},
    {"glTranslatef", "v:fff"}, {"glTranslatex", "v:iii"}, {"glVertexPointer", "v:iuia"}, {"glViewport", "v:iiii"},

    // OES_framebuffer_object
    {"glGenFramebuffersOES", "v:ip"}, {"glGenRenderbuffersOES", "v:ip"},
    {"glDeleteFramebuffersOES", "v:ip"}, {"glDeleteRenderbuffersOES", "v:ip"},
    {"glBindFramebufferOES", "v:uu"}, {"glBindRenderbufferOES", "v:uu"},
    {"glFramebufferRenderbufferOES", "v:uuuu"}, {"glFramebufferTexture2DOES", "v:uuuui"},
    {"glCheckFramebufferStatusOES", "u:u"}, {"glGetRenderbufferParameterivOES", "v:uup"},
    {"glGetFramebufferAttachmentParameterivOES", "v:uuup"}, {"glRenderbufferStorageOES", "v:uuii"},
    {"glIsFramebufferOES", "B:u"}, {"glIsRenderbufferOES", "B:u"}, {"glGenerateMipmapOES", "v:u"},
    // OES_draw_texture
    {"glDrawTexfOES", "v:fffff"}, {"glDrawTexiOES", "v:iiiii"}, {"glDrawTexsOES", "v:iiiii"},
    {"glDrawTexxOES", "v:iiiii"}, {"glDrawTexfvOES", "v:p"}, {"glDrawTexivOES", "v:p"},
    {"glDrawTexsvOES", "v:p"}, {"glDrawTexxvOES", "v:p"},
    // blending and discard extensions
    {"glBlendEquationOES", "v:u"}, {"glBlendEquationSeparateOES", "v:uu"}, {"glBlendFuncSeparateOES", "v:uuuu"},
    {"glDiscardFramebufferEXT", "v:uip"},
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

// EAGL string constants (OpenGL ES is loaded before the guest is bound).
B32_OBJC_CONSTANT(kEAGLDrawablePropertyRetainedBacking)
B32_OBJC_CONSTANT(kEAGLDrawablePropertyColorFormat)
B32_OBJC_CONSTANT(kEAGLColorFormatRGBA8)
B32_OBJC_CONSTANT(kEAGLColorFormatRGB565)
B32_OBJC_CONSTANT(kEAGLColorFormatSRGBA8)
