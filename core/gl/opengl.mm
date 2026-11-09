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
#include <dlfcn.h>

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
};
}  // namespace

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
