// Audio for the guest: AudioServices system sounds on the host's AudioToolbox,
// and the iOS-only AudioSession API, which has nothing to configure on a Mac.
// OpenAL is in openal.mm.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#include <AudioToolbox/AudioServices.h>
#include <dlfcn.h>

using namespace b32;

namespace {


// --- AudioServices system sounds --------------------------------------------------------

struct Completion {
    GuestAddr proc;
    GuestAddr clientData;
};

void soundCompleted(SystemSoundID sound, void *data) {
    auto *completion = static_cast<Completion *>(data);
    Runtime::threadCpu().call(completion->proc, {sound, completion->clientData});
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
B32_THUNK(_AudioSessionRemovePropertyListenerWithUserData) { c.ret(0); }

// OSStatus AudioSessionGetProperty(AudioSessionPropertyID, UInt32 *ioDataSize, void *outData)
// Every property reads as zero (no other audio playing, no headphones...).
B32_THUNK(_AudioSessionGetProperty) {
    c.args.u32();
    GuestAddr size = c.args.ptr();
    GuestAddr data = c.args.ptr();
    if (size && data) std::memset(c.mem.ptr<uint8_t>(data), 0, c.mem.read<uint32_t>(size));
    c.ret(0);
}

// OSStatus AudioSessionGetPropertySize(AudioSessionPropertyID, UInt32 *outDataSize): the sample
// rates are Float64s; everything else is a 32-bit value or a CF object.
B32_THUNK(_AudioSessionGetPropertySize) {
    uint32_t property = c.args.u32();
    GuestAddr size = c.args.ptr();
    bool float64 = property == 'chsr' || property == 'hwsr';  // current and preferred hardware sample rates
    if (size) c.mem.write<uint32_t>(size, float64 ? 8 : 4);
    c.ret(0);
}

