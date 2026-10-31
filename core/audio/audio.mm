// Audio for the guest: OpenAL (the Catalyst build of OpenAL.framework),
// AudioServices system sounds on the host's AudioToolbox, and the iOS-only
// AudioSession API, which has nothing to configure on a Mac.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#include <AudioToolbox/AudioServices.h>
#include <dlfcn.h>

using namespace b32;

namespace {

void *openAL() {
    static void *handle = [] {
        const char *path = "/System/iOSSupport/System/Library/Frameworks/OpenAL.framework/OpenAL";
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
};

B32_C_FUNCTIONS(kOpenAL, openAL);

// --- AudioServices system sounds --------------------------------------------------------

struct Completion {
    GuestAddr proc;
    GuestAddr clientData;
};

void soundCompleted(SystemSoundID sound, void *data) {
    auto *completion = static_cast<Completion *>(data);
    Cpu *cpu = Runtime::currentCpu();
    if (!cpu) fatal("system sound completion on a thread without a guest CPU");
    cpu->call(completion->proc, {sound, completion->clientData});
}

}  // namespace

// OSStatus AudioServicesCreateSystemSoundID(CFURLRef url, SystemSoundID *outSystemSoundID)
B32_THUNK(_AudioServicesCreateSystemSoundID) {
    CFURLRef url = (CFURLRef)c.rt.bridge().toHost(c.args.ptr());
    GuestAddr out = c.args.ptr();
    SystemSoundID sound = 0;
    OSStatus status = AudioServicesCreateSystemSoundID(url, &sound);
    if (out) c.mem.write<uint32_t>(out, sound);
    c.ret(uint32_t(status));
}

B32_THUNK(_AudioServicesDisposeSystemSoundID) { c.ret(uint32_t(AudioServicesDisposeSystemSoundID(c.args.u32()))); }
B32_THUNK(_AudioServicesPlaySystemSound) { AudioServicesPlaySystemSound(c.args.u32()); }
B32_THUNK(_AudioServicesPlayAlertSound) { AudioServicesPlayAlertSound(c.args.u32()); }

// OSStatus AudioServicesAddSystemSoundCompletion(SystemSoundID, CFRunLoopRef, CFStringRef mode,
//                                                AudioServicesSystemSoundCompletionProc, void *clientData)
// Completions are delivered on the main run loop, where the guest runs.
B32_THUNK(_AudioServicesAddSystemSoundCompletion) {
    SystemSoundID sound = c.args.u32();
    c.args.ptr();
    c.args.ptr();
    auto *completion = new Completion{c.args.ptr(), 0};
    completion->clientData = c.args.ptr();
    c.ret(uint32_t(AudioServicesAddSystemSoundCompletion(sound, nullptr, nullptr, soundCompleted, completion)));
}

B32_THUNK(_AudioServicesRemoveSystemSoundCompletion) { AudioServicesRemoveSystemSoundCompletion(c.args.u32()); }

// --- AudioSession: iOS routing and interruptions, nothing to do on a Mac ------------------

B32_THUNK(_AudioSessionInitialize) { c.ret(0); }
B32_THUNK(_AudioSessionSetActive) { c.ret(0); }
B32_THUNK(_AudioSessionSetProperty) { c.ret(0); }
B32_THUNK(_AudioSessionAddPropertyListener) { c.ret(0); }
B32_THUNK(_AudioSessionRemovePropertyListener) { c.ret(0); }

// OSStatus AudioSessionGetProperty(AudioSessionPropertyID, UInt32 *ioDataSize, void *outData)
// Every property reads as zero (no other audio playing, no headphones...).
B32_THUNK(_AudioSessionGetProperty) {
    c.args.u32();
    GuestAddr size = c.args.ptr();
    GuestAddr data = c.args.ptr();
    if (size && data) std::memset(c.mem.ptr<uint8_t>(data), 0, c.mem.read<uint32_t>(size));
    c.ret(0);
}
