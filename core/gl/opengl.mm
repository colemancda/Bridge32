// Desktop OpenGL for i386 Mac guests: the host's OpenGL.framework through a
// generated table (opengl_table.inc), plus CGL and the corners of NSOpenGL
// that hand out raw context pointers. A guest's GL calls happen on the thread
// that owns the context, as the host expects, since guest threads are host
// threads.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Dispatch.h"
#include "core/thunks/CTable.h"

#import <AppKit/AppKit.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <dlfcn.h>

#include <algorithm>
#include <cstring>
#include <regex>
#include <string>
#include <vector>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

using namespace b32;
using namespace b32::objc;

namespace {
void *library() {
    static void *handle = [] {
        void *h = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_NOW | RTLD_GLOBAL);
        if (!h) fatal("can't load OpenGL.framework: %s", dlerror());
        return h;
    }();
    return handle;
}

const CFunction kFunctions[] = {
#include "opengl_table.inc"
};

// Whether the array pointer a guest passes is an offset into a bound buffer.
bool glBufferBound(char code) {
    GLint bound = 0;
    glGetIntegerv(code == 'a' ? GL_ARRAY_BUFFER_BINDING : GL_ELEMENT_ARRAY_BUFFER_BINDING, &bound);
    return bound != 0;
}
const int installQuery = (setBufferBoundQuery(glBufferBound), 0);

// CGL: contexts and pixel formats are opaque host pointers behind guest handles.
const CFunction kCGL[] = {
    {"CGLGetCurrentContext", "h:"},
    {"CGLSetCurrentContext", "i:h"},
    {"CGLLockContext", "i:h"},
    {"CGLUnlockContext", "i:h"},
    {"CGLSetParameter", "i:hup"},
    {"CGLGetParameter", "i:hup"},
    {"CGLEnable", "i:hu"},
    {"CGLDisable", "i:hu"},
    {"CGLIsEnabled", "i:hup"},
    {"CGLRetainContext", "h:h"},
    {"CGLReleaseContext", "v:h"},
    {"CGLGetPixelFormat", "h:h"},
    {"CGLUpdateContext", "i:h"},
    {"CGLClearDrawable", "i:h"},
    {"CGLErrorString", "s:i"},
    {"gluCheckExtension", "B:pp"},
    {"gluLookAt", "v:ddddddddd"},
};
}  // namespace

namespace b32::gl {
// Tells the current context the pixels it is handed, and hands back, are in the guest's byte order.
void swapGuestPixels() {
#if defined(B32_GUEST_BIG_ENDIAN)
    glPixelStorei(GL_UNPACK_SWAP_BYTES, GL_TRUE);
    glPixelStorei(GL_PACK_SWAP_BYTES, GL_TRUE);
#endif
}
}  // namespace b32::gl

// --- the limits an ARB program may have --------------------------------------------------------------
// Programs of the AGL era tell a card's generation by these: a renderer that says it runs vertex programs of
// any length is, to them, a card newer than the data they shipped with, which some then refuse. The host's
// are far beyond any card of the time (262,144 instructions), so a vertex program's limits stop at a
// GeForce 6800's, the Shader Model 3 card most of those games list (512 instructions, 256 parameters,
// 32 temporaries). Their own programs fit well within them.
namespace {
GLint eraLimit(GLenum target, GLenum name, GLint value) {
    if (target != GL_VERTEX_PROGRAM_ARB) return value;
    switch (name) {
    case GL_MAX_PROGRAM_INSTRUCTIONS_ARB:
    case GL_MAX_PROGRAM_NATIVE_INSTRUCTIONS_ARB:
        return std::min(value, 512);
    case GL_MAX_PROGRAM_PARAMETERS_ARB:
    case GL_MAX_PROGRAM_NATIVE_PARAMETERS_ARB:
        return std::min(value, 256);
    case GL_MAX_PROGRAM_TEMPORARIES_ARB:
    case GL_MAX_PROGRAM_NATIVE_TEMPORARIES_ARB:
        return std::min(value, 32);
    default:
        return value;
    }
}
}  // namespace
// void glGetProgramivARB(target, pname, GLint *params): one value for the names this is asked.
B32_THUNK(_glGetProgramivARB) {
    GLenum target = c.args.u32(), name = c.args.u32();
    GuestAddr out = c.args.ptr();
    GLint value = 0;
    glGetProgramivARB(target, name, &value);
    if (out) c.mem.write<int32_t>(out, eraLimit(target, name, value));
}

// --- big-endian guests ------------------------------------------------------------------------
// The table hands a pointer argument to the host as it is, which suits bytes and nothing else: a PowerPC
// guest's floats, doubles and ints behind a pointer are in its byte order. These are the fixed-function
// calls that carry such values, converted on the way in or out; being registered before the table, they
// are the ones called. Pixel data is left to GL itself (see glPixelStorei below). Client vertex arrays
// aren't converted yet.
#if defined(B32_GUEST_BIG_ENDIAN)
namespace {
// How many values a parameter of glFog, glLight, glMaterial, glLightModel, glTexEnv or glTexParameter has.
size_t valueCount(GLenum name) {
    switch (name) {
    case GL_AMBIENT: case GL_DIFFUSE: case GL_SPECULAR: case GL_EMISSION: case GL_POSITION:
    case GL_AMBIENT_AND_DIFFUSE: case GL_FOG_COLOR: case GL_LIGHT_MODEL_AMBIENT: case GL_TEXTURE_ENV_COLOR:
    case GL_TEXTURE_BORDER_COLOR:
        return 4;
    case GL_SPOT_DIRECTION: case GL_COLOR_INDEXES:
        return 3;
    default:
        return 1;
    }
}
// A glGet's answer has as many values as its name says, which the host knows and this doesn't: the values
// it wrote are the ones that no longer hold the filler.
template <typename T, typename Get> void getValues(Call &c, Get get) {
    GLenum name = c.args.u32();
    GuestAddr out = c.args.ptr();
    constexpr size_t kMost = 32;
    T values[kMost];
    uint8_t filler[sizeof(T)];
    std::memset(filler, 0xA5, sizeof filler);
    for (T &value : values) std::memcpy(&value, filler, sizeof(T));
    get(name, values);
    size_t count = kMost;
    while (count > 0 && std::memcmp(&values[count - 1], filler, sizeof(T)) == 0) count--;
    if (out && count) c.mem.writeArray<T>(out, values, count);
}
}  // namespace

#define B32_GL_FLOATS(name, count) \
    B32_THUNK(_##name) { name(c.mem.readArray<GLfloat>(c.args.ptr(), count).data()); }
#define B32_GL_DOUBLES(name, count) \
    B32_THUNK(_##name) { name(c.mem.readArray<GLdouble>(c.args.ptr(), count).data()); }
B32_GL_FLOATS(glLoadMatrixf, 16)
B32_GL_FLOATS(glMultMatrixf, 16)
B32_GL_DOUBLES(glLoadMatrixd, 16)
B32_GL_DOUBLES(glMultMatrixd, 16)
B32_GL_FLOATS(glColor3fv, 3)
B32_GL_FLOATS(glColor4fv, 4)
B32_GL_FLOATS(glVertex2fv, 2)
B32_GL_FLOATS(glVertex3fv, 3)
B32_GL_FLOATS(glVertex4fv, 4)
B32_GL_FLOATS(glNormal3fv, 3)
B32_GL_FLOATS(glTexCoord2fv, 2)
B32_GL_FLOATS(glTexCoord3fv, 3)
B32_GL_FLOATS(glRasterPos2fv, 2)

// void glFogfv(pname, params), glLightModelfv(pname, params)
B32_THUNK(_glFogfv) {
    GLenum name = c.args.u32();
    glFogfv(name, c.mem.readArray<GLfloat>(c.args.ptr(), valueCount(name)).data());
}
B32_THUNK(_glLightModelfv) {
    GLenum name = c.args.u32();
    glLightModelfv(name, c.mem.readArray<GLfloat>(c.args.ptr(), valueCount(name)).data());
}
// void glLightfv(light, pname, params), and the others with a target before the name.
#define B32_GL_TARGET_FLOATS(function) \
    B32_THUNK(_##function) { \
        GLenum target = c.args.u32(), name = c.args.u32(); \
        function(target, name, c.mem.readArray<GLfloat>(c.args.ptr(), valueCount(name)).data()); \
    }
B32_GL_TARGET_FLOATS(glLightfv)
B32_GL_TARGET_FLOATS(glMaterialfv)
B32_GL_TARGET_FLOATS(glTexEnvfv)
B32_GL_TARGET_FLOATS(glTexParameterfv)
B32_THUNK(_glTexParameteriv) {
    GLenum target = c.args.u32(), name = c.args.u32();
    glTexParameteriv(target, name, c.mem.readArray<GLint>(c.args.ptr(), valueCount(name)).data());
}
// void glClipPlane(plane, const GLdouble equation[4])
B32_THUNK(_glClipPlane) {
    GLenum plane = c.args.u32();
    glClipPlane(plane, c.mem.readArray<GLdouble>(c.args.ptr(), 4).data());
}

B32_THUNK(_glGetFloatv) { getValues<GLfloat>(c, [](GLenum name, GLfloat *out) { glGetFloatv(name, out); }); }
B32_THUNK(_glGetDoublev) { getValues<GLdouble>(c, [](GLenum name, GLdouble *out) { glGetDoublev(name, out); }); }
B32_THUNK(_glGetIntegerv) { getValues<GLint>(c, [](GLenum name, GLint *out) { glGetIntegerv(name, out); }); }
// void glGetTexParameteriv(target, pname, params), glGetTexLevelParameteriv(target, level, pname, params)
B32_THUNK(_glGetTexParameteriv) {
    GLenum target = c.args.u32(), name = c.args.u32();
    GuestAddr out = c.args.ptr();
    GLint value = 0;
    glGetTexParameteriv(target, name, &value);
    if (out) c.mem.write<int32_t>(out, value);
}
B32_THUNK(_glGetTexLevelParameteriv) {
    GLenum target = c.args.u32();
    GLint level = c.args.i32();
    GLenum name = c.args.u32();
    GuestAddr out = c.args.ptr();
    GLint value = 0;
    glGetTexLevelParameteriv(target, level, name, &value);
    if (out) c.mem.write<int32_t>(out, value);
}

// void glGenTextures(n, GLuint *names), glDeleteTextures(n, const GLuint *names)
B32_THUNK(_glGenTextures) {
    GLsizei count = c.args.i32();
    GuestAddr out = c.args.ptr();
    if (count <= 0) return;
    std::vector<GLuint> names(size_t(count), 0);
    glGenTextures(count, names.data());
    c.mem.writeArray<GLuint>(out, names.data(), names.size());
}
B32_THUNK(_glDeleteTextures) {
    GLsizei count = c.args.i32();
    GuestAddr names = c.args.ptr();
    if (count > 0) glDeleteTextures(count, c.mem.readArray<GLuint>(names, size_t(count)).data());
}

// Pixels are the guest's too: its 16 and 32-bit components are swapped by GL, which a context is told to
// do when it is first made current (b32::gl::swapGuestPixels), so a guest asking for swapped bytes is
// asking for the host's own order.
B32_THUNK(_glPixelStorei) {
    GLenum name = c.args.u32();
    GLint value = c.args.i32();
    if (name == GL_UNPACK_SWAP_BYTES || name == GL_PACK_SWAP_BYTES) value = !value;
    glPixelStorei(name, value);
}
#endif

B32_C_FUNCTIONS(kFunctions, library);
B32_C_FUNCTIONS(kCGL, library);

// Methods handing out a context or pixel format as a raw pointer.
B32_OVERRIDE("CGLContextObj") { o.c.ret(hostHandle([(NSOpenGLContext *)o.receiver CGLContextObj])); }
B32_OVERRIDE("CGLPixelFormatObj") { o.c.ret(hostHandle([(NSOpenGLPixelFormat *)o.receiver CGLPixelFormatObj])); }

// Today's compiler refuses a #define of a name starting GL_, which old ones
// took and ES-derived shaders do ("#ifndef GL_ES / #define GL_ES 0"), and it
// also refuses an undefined name in #if. So each such name is renamed throughout.
namespace {
std::string withoutReservedDefines(std::string source) {
    // Old compilers also ignored stray text after an #endif ("#endif]").
    static const std::regex strayAfterEndif("^([ \\t]*#[ \\t]*endif)\\b.*$", std::regex::multiline);
    source = std::regex_replace(source, strayAfterEndif, "$1");
    static const std::regex define("#[ \\t]*define[ \\t]+(GL_\\w+)");
    std::vector<std::string> names;
    for (std::sregex_iterator it(source.begin(), source.end(), define), end; it != end; ++it) names.push_back((*it)[1].str());
    for (const std::string &name : names) source = std::regex_replace(source, std::regex("\\b" + name + "\\b"), "B32_" + name);
    return source;
}
}  // namespace

// void glShaderSource(GLuint, GLsizei count, const GLchar **strings, const GLint *lengths)
B32_THUNK(_glShaderSource) {
    GLuint shader = c.args.u32();
    GLsizei count = c.args.i32();
    GuestAddr strings = c.args.ptr(), lengths = c.args.ptr();
    std::string source;
    for (GLsizei i = 0; i < count; i++) {
        GuestAddr text = c.mem.read<uint32_t>(strings + uint32_t(i) * 4);
        int32_t length = lengths ? c.mem.read<int32_t>(lengths + uint32_t(i) * 4) : -1;
        source += length < 0 ? std::string(c.mem.cstr(text)) : std::string(c.mem.ptr<char>(text), size_t(length));
    }
    source = withoutReservedDefines(std::move(source));
    const GLchar *pointer = source.c_str();
    glShaderSource(shader, 1, &pointer, nullptr);
}

// B32_GL_SNAPSHOT=path.png saves what the guest just presented, every 60th
// frame, and logs the frame count: a way to look at a game from a script.
namespace {
void snapshotIfAsked() {
    static const char *path = getenv("B32_GL_SNAPSHOT");
    static int frames = 0;
    if (!path || ++frames % 60) return;
    GLint viewport[4];
    glGetIntegerv(GL_VIEWPORT, viewport);
    int w = viewport[2], h = viewport[3];
    GLint binding = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &binding);
    NSOpenGLContext *current = [NSOpenGLContext currentContext];
    log("frame %d: viewport %dx%d, error 0x%x, framebuffer %d status 0x%x, context %p view %s window %p layer %p renderer %s", frames, w, h, glGetError(),
        binding, glCheckFramebufferStatus(GL_FRAMEBUFFER), current, object_getClassName(current.view), current.view.window, current.view.layer, glGetString(GL_RENDERER));
    if (w <= 0 || h <= 0) return;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:w pixelsHigh:h bitsPerSample:8
        samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
    std::vector<uint8_t> flipped(size_t(w) * h * 4);
    glReadBuffer(GL_BACK);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, flipped.data());
    for (int y = 0; y < h; y++) std::memcpy(rep.bitmapData + y * w * 4, flipped.data() + (h - 1 - y) * w * 4, size_t(w) * 4);
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(path) atomically:YES];
    [rep release];
}
bool isOpenGLContext(id receiver) { return [receiver isKindOfClass:[NSOpenGLContext class]]; }
}  // namespace

namespace b32::gl {
// For the presents that don't come through here (AGL's).
void snapshotPresented() { snapshotIfAsked(); }
}  // namespace b32::gl

B32_OVERRIDE_WHEN(isOpenGLContext, "flushBuffer") {
    snapshotIfAsked();
    [(NSOpenGLContext *)o.receiver flushBuffer];
}
B32_THUNK(_CGLFlushDrawable) {
    snapshotIfAsked();
    c.ret(uint32_t(CGLFlushDrawable(static_cast<CGLContextObj>(hostPointer(c.args.u32())))));
}

// B32_TRACE_SHADERS=1 logs each shader's source and compile log.
B32_THUNK(_glCompileShader) {
    GLuint shader = c.args.u32();
    glCompileShader(shader);
    static const bool trace = getenv("B32_TRACE_SHADERS") != nullptr;
    if (!trace) return;
    GLint status = 0, sourceLength = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    glGetShaderiv(shader, GL_SHADER_SOURCE_LENGTH, &sourceLength);
    std::string source(size_t(sourceLength) + 1, 0), info(4096, 0);
    glGetShaderSource(shader, sourceLength + 1, nullptr, source.data());
    glGetShaderInfoLog(shader, GLsizei(info.size()), nullptr, info.data());
    log("shader %u compiled %s\n%s\n--- log:\n%s", shader, status ? "ok" : "FAILED", source.c_str(), info.c_str());
}

// void *glMapBuffer returns host memory no guest pointer can reach.
B32_THUNK(_glMapBuffer) {
    log("glMapBuffer isn't supported; the guest gets NULL and must fall back");
    c.ret(0);
}
B32_THUNK(_glMapBufferARB) { c.ret(0); }
B32_THUNK(_glMapBufferRange) { c.ret(0); }
