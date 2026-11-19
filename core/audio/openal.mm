// OpenAL for the guest: the host's OpenAL.framework (the Catalyst build of it for iOS guests),
// called through the C table.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/thunks/CTable.h"

#include <TargetConditionals.h>
#include <dlfcn.h>

#include <string>

using namespace b32;

namespace {

void *openAL() {
    static void *handle = [] {
#if TARGET_OS_MACCATALYST
        const char *path = "/System/iOSSupport/System/Library/Frameworks/OpenAL.framework/OpenAL";
#else
        const char *path = "/System/Library/Frameworks/OpenAL.framework/OpenAL";
#endif
        void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!h) fatal("can't load the host's OpenAL (%s): %s", path, dlerror());
        return h;
    }();
    return handle;
}

constexpr CFunction kOpenAL[] = {
    {"alcOpenDevice", "h:p"}, {"alcCloseDevice", "B:h"}, {"alcCreateContext", "h:hp"},
    {"alcMakeContextCurrent", "B:h"}, {"alcProcessContext", "v:h"}, {"alcSuspendContext", "v:h"},
    {"alcDestroyContext", "v:h"}, {"alcGetCurrentContext", "h:"}, {"alcGetContextsDevice", "h:h"},
    {"alcGetError", "i:h"}, {"alcGetString", "s:hi"}, {"alcGetIntegerv", "v:hiip"},
    {"alGetError", "i:"}, {"alGenSources", "v:ip"}, {"alDeleteSources", "v:ip"}, {"alIsSource", "B:u"},
    {"alGenBuffers", "v:ip"}, {"alDeleteBuffers", "v:ip"}, {"alIsBuffer", "B:u"}, {"alBufferData", "v:uipii"},
    {"alSourcef", "v:uif"}, {"alSource3f", "v:uifff"}, {"alSourcefv", "v:uip"},
    {"alSourcei", "v:uii"}, {"alSource3i", "v:uiiii"}, {"alSourceiv", "v:uip"},
    {"alGetSourcef", "v:uip"}, {"alGetSourcei", "v:uip"}, {"alGetSourcefv", "v:uip"}, {"alGetSourceiv", "v:uip"},
    {"alSourcePlay", "v:u"}, {"alSourceStop", "v:u"}, {"alSourcePause", "v:u"}, {"alSourceRewind", "v:u"},
    {"alSourcePlayv", "v:ip"}, {"alSourceStopv", "v:ip"}, {"alSourcePausev", "v:ip"},
    {"alSourceQueueBuffers", "v:uip"}, {"alSourceUnqueueBuffers", "v:uip"},
    {"alListenerf", "v:if"}, {"alListener3f", "v:ifff"}, {"alListenerfv", "v:ip"}, {"alListeneri", "v:ii"},
    {"alGetListenerf", "v:ip"}, {"alGetListenerfv", "v:ip"},
    {"alDistanceModel", "v:i"}, {"alDopplerFactor", "v:f"}, {"alSpeedOfSound", "v:f"},
    {"alEnable", "v:i"}, {"alDisable", "v:i"}, {"alGetString", "s:i"}, {"alGetInteger", "i:i"}, {"alGetFloat", "f:i"},
    {"alIsExtensionPresent", "B:p"}, {"alcIsExtensionPresent", "B:hp"}, {"alGetEnumValue", "i:p"},
};

B32_C_FUNCTIONS(kOpenAL, openAL);

}  // namespace

// --- OpenAL extensions -----------------------------------------------------------------------

// ALvoid *alcGetProcAddress(ALCdevice *, const ALCchar *funcName) and
// alGetProcAddress(const ALchar *): the guest gets our thunk for an extension
// we bridge, or NULL.
namespace {
GuestAddr procAddress(Call &c, GuestAddr name) {
    std::string symbol = std::string("_") + c.mem.cstr(name);
    if (!ThunkRegistry::all().count(symbol)) {
        log("OpenAL extension %s isn't bridged", symbol.c_str() + 1);
        return 0;
    }
    return c.rt.thunks().stubFor(symbol);
}
}  // namespace
B32_THUNK(_alcGetProcAddress) {
    c.args.u32();
    c.ret(procAddress(c, c.args.ptr()));
}
B32_THUNK(_alGetProcAddress) { c.ret(procAddress(c, c.args.ptr())); }

// void alBufferDataStatic(ALint buffer, ALenum format, ALvoid *data, ALsizei size, ALsizei freq):
// Apple's zero-copy variant, which the host's OpenAL has too. Guest memory
// never moves, so the buffer plays from the guest's own bytes: engines stream
// music by rewriting them in place (Sonic CD), which a copy would miss.
B32_THUNK(_alBufferDataStatic) {
    using BufferData = void (*)(int32_t, int32_t, const void *, int32_t, int32_t);
    static auto bufferDataStatic = [] {
        auto getProcAddress = reinterpret_cast<void *(*)(const char *)>(dlsym(openAL(), "alGetProcAddress"));
        return reinterpret_cast<BufferData>(getProcAddress("alBufferDataStatic"));
    }();
    static auto bufferData = reinterpret_cast<BufferData>(dlsym(openAL(), "alBufferData"));
    int32_t buffer = c.args.i32();
    int32_t format = c.args.i32();
    GuestAddr data = c.args.ptr();
    int32_t size = c.args.i32();
    (bufferDataStatic ?: bufferData)(buffer, format, c.mem.ptr<void>(data), size, c.args.i32());
}

// The host mixes at its own rate.
B32_THUNK(_alcMacOSXMixerOutputRate) {}
B32_THUNK(_alcMacOSXGetMixerOutputRate) { c.retF64(44100.0); }
