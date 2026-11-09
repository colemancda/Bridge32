// The Audio Hardware API that older Mac guests drive directly (the BASS library
// among them). The modern SDK has dropped these calls, and a guest only needs
// one place to send its samples, so this presents a single stereo output device
// and feeds the guest's IOProc from the host's default output unit.
//
// An IOProc runs as (device, now, in, inTime, out, outTime, client), with
// AudioTimeStamps of the same layout in both ABIs and 32-bit AudioBufferLists.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/Thunks.h"

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <set>
#include <vector>

using namespace b32;

namespace {
constexpr uint32_t kDevice = 1;
constexpr uint32_t kChannels = 2, kFrameBytes = kChannels * sizeof(Float32);
constexpr uint32_t kMinFrames = 64, kMaxFrames = 4096;
constexpr OSStatus kUnknownProperty = 'who?', kBadDevice = '!dev', kNotRunning = 'stop';
constexpr uint32_t kTimesSize = 3 * sizeof(AudioTimeStamp);

struct Device {
    std::mutex lock;
    Float64 rate = 44100;
    uint32_t frames = 512;
    GuestAddr proc = 0, client = 0;
    AudioUnit unit = nullptr;
    bool running = false;
    std::atomic<uint64_t> sampleTime{0};
    GuestAddr scratch = 0;
    uint32_t scratchSize = 0;
} device;

AudioStreamBasicDescription format() {
    AudioStreamBasicDescription d{};
    d.mSampleRate = device.rate;
    d.mFormatID = kAudioFormatLinearPCM;
    d.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    d.mBytesPerPacket = d.mBytesPerFrame = kFrameBytes;
    d.mFramesPerPacket = 1;
    d.mChannelsPerFrame = kChannels;
    d.mBitsPerChannel = 32;
    return d;
}

GuestMemory &guestMemory() { return objc::Bridge::shared()->runtime().mem(); }
GuestHeap &guestHeap() { return objc::Bridge::shared()->runtime().heap(); }

OSStatus render(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *time, UInt32, UInt32 frames, AudioBufferList *io) {
    AudioBuffer &output = io->mBuffers[0];
    uint32_t bytes = frames * kFrameBytes;
    uint32_t inputList = kTimesSize, outputList = inputList + 4, samples = outputList + 16;
    if (samples + bytes > device.scratchSize) {
        if (device.scratch) guestHeap().free(device.scratch);
        device.scratchSize = (samples + bytes) * 2;
        device.scratch = guestHeap().calloc(1, device.scratchSize);
    }
    GuestMemory &mem = guestMemory();
    GuestAddr base = device.scratch;
    AudioTimeStamp stamp = *time;
    stamp.mSampleTime = Float64(device.sampleTime.load());
    stamp.mFlags |= kAudioTimeStampSampleTimeValid;
    for (uint32_t i = 0; i < 3; i++) mem.copyIn(base + i * sizeof stamp, &stamp, sizeof stamp);
    mem.write<uint32_t>(base + inputList, 0);
    mem.write<uint32_t>(base + outputList, 1);
    mem.write<uint32_t>(base + outputList + 4, kChannels);
    mem.write<uint32_t>(base + outputList + 8, bytes);
    mem.write<uint32_t>(base + outputList + 12, base + samples);
    std::memset(mem.ptr<uint8_t>(base + samples), 0, bytes);

    Runtime::threadCpu().call(device.proc, {kDevice, base, base + inputList, base + 64, base + outputList, base + 128, device.client});

    std::memcpy(output.mData, mem.ptr<uint8_t>(base + samples), std::min(bytes, output.mDataByteSize));
    device.sampleTime += frames;
    return noErr;
}

OSStatus startUnit() {
    AudioComponentDescription d{kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &d);
    if (!component) return kBadDevice;
    OSStatus status = AudioComponentInstanceNew(component, &device.unit);
    if (status) return status;
    AudioStreamBasicDescription f = format();
    AURenderCallbackStruct callback{render, nullptr};
    status = AudioUnitSetProperty(device.unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    if (!status) status = AudioUnitSetProperty(device.unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    if (!status) {
        // The guest sized its mixing to this; the host treats it as a request.
        UInt32 frames = device.frames;
        AudioUnitSetProperty(device.unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, sizeof frames);
        status = AudioUnitInitialize(device.unit);
    }
    if (!status) status = AudioOutputUnitStart(device.unit);
    if (status) {
        AudioComponentInstanceDispose(device.unit);
        device.unit = nullptr;
    }
    return status;
}

void stopUnit() {
    if (!device.unit) return;
    AudioOutputUnitStop(device.unit);
    AudioUnitUninitialize(device.unit);
    AudioComponentInstanceDispose(device.unit);
    device.unit = nullptr;
}

void logUnknown(uint32_t property) {
    static std::mutex lock;
    static std::set<uint32_t> seen;
    std::lock_guard guard(lock);
    if (seen.insert(property).second)
        log("audio hardware: no property '%c%c%c%c'", char(property >> 24), char(property >> 16), char(property >> 8), char(property));
}

// The property's value in guest form, or empty if there's no such property.
bool deviceProperty(Call &c, bool isInput, uint32_t property, std::vector<uint8_t> &out) {
    auto scalar = [&](auto value) {
        out.resize(sizeof value);
        std::memcpy(out.data(), &value, sizeof value);
    };
    switch (property) {
    case kAudioDevicePropertyDeviceNameCFString:
        scalar(c.rt.bridge().toGuest((__bridge id)CFSTR("Default Output")));
        return true;
    case kAudioDevicePropertyNominalSampleRate:
        scalar(device.rate);
        return true;
    case kAudioDevicePropertyBufferFrameSize:
        scalar(device.frames);
        return true;
    case kAudioDevicePropertyLatency:
        scalar(uint32_t(0));
        return true;
    case kAudioDevicePropertyStreamFormat:
        if (isInput) return false;
        scalar(format());
        return true;
    case kAudioDevicePropertyStreamConfiguration: {
        uint32_t list[4] = {0, kChannels, device.frames * kFrameBytes, 0};
        if (isInput) {
            out.assign(4, 0);
        } else {
            list[0] = 1;
            out.resize(sizeof list);
            std::memcpy(out.data(), list, sizeof list);
        }
        return true;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        if (isInput) return false;
        uint32_t layout[3] = {kAudioChannelLayoutTag_Stereo, 0, 0};
        out.resize(sizeof layout);
        std::memcpy(out.data(), layout, sizeof layout);
        return true;
    }
    }
    return false;
}
}  // namespace

// --- the system object ---------------------------------------------------------------

B32_THUNK(_AudioGetCurrentHostTime) { c.ret64(AudioGetCurrentHostTime()); }
B32_THUNK(_AudioGetHostClockFrequency) { c.retF64(AudioGetHostClockFrequency()); }

// OSStatus AudioHardwareGetPropertyInfo(id, UInt32 *size, Boolean *writable)
B32_THUNK(_AudioHardwareGetPropertyInfo) {
    uint32_t property = c.args.u32();
    GuestAddr size = c.args.ptr(), writable = c.args.ptr();
    if (property != kAudioHardwarePropertyDevices && property != kAudioHardwarePropertyDefaultOutputDevice &&
        property != kAudioHardwarePropertyDefaultInputDevice) {
        logUnknown(property);
        c.ret(uint32_t(kUnknownProperty));
        return;
    }
    if (size) c.mem.write<uint32_t>(size, 4);
    if (writable) c.mem.write<uint8_t>(writable, 0);
    c.ret(0);
}
// OSStatus AudioHardwareGetProperty(id, UInt32 *ioSize, void *out)
B32_THUNK(_AudioHardwareGetProperty) {
    uint32_t property = c.args.u32();
    GuestAddr size = c.args.ptr(), out = c.args.ptr();
    uint32_t value;
    switch (property) {
    case kAudioHardwarePropertyDevices:
    case kAudioHardwarePropertyDefaultOutputDevice: value = kDevice; break;
    case kAudioHardwarePropertyDefaultInputDevice: value = kAudioDeviceUnknown; break;
    default:
        logUnknown(property);
        c.ret(uint32_t(kUnknownProperty));
        return;
    }
    c.mem.write<uint32_t>(out, value);
    c.mem.write<uint32_t>(size, 4);
    c.ret(0);
}
// One device that never changes, so there's nothing to tell a listener.
B32_THUNK(_AudioHardwareAddPropertyListener) { c.ret(0); }
B32_THUNK(_AudioHardwareRemovePropertyListener) { c.ret(0); }
B32_THUNK(_AudioDeviceAddPropertyListener) { c.ret(0); }
B32_THUNK(_AudioDeviceRemovePropertyListener) { c.ret(0); }

// --- the device ----------------------------------------------------------------------

// OSStatus AudioDeviceGetPropertyInfo(device, channel, isInput, id, UInt32 *size, Boolean *writable)
B32_THUNK(_AudioDeviceGetPropertyInfo) {
    uint32_t id = c.args.u32();
    c.args.u32();
    bool isInput = c.args.u32() & 0xff;
    uint32_t property = c.args.u32();
    GuestAddr size = c.args.ptr(), writable = c.args.ptr();
    std::vector<uint8_t> value;
    if (id != kDevice) {
        c.ret(uint32_t(kBadDevice));
        return;
    }
    std::lock_guard guard(device.lock);
    if (!deviceProperty(c, isInput, property, value)) {
        logUnknown(property);
        c.ret(uint32_t(kUnknownProperty));
        return;
    }
    if (size) c.mem.write<uint32_t>(size, uint32_t(value.size()));
    if (writable) c.mem.write<uint8_t>(writable, property == kAudioDevicePropertyBufferFrameSize || property == kAudioDevicePropertyNominalSampleRate);
    c.ret(0);
}
// OSStatus AudioDeviceGetProperty(device, channel, isInput, id, UInt32 *ioSize, void *out)
B32_THUNK(_AudioDeviceGetProperty) {
    uint32_t id = c.args.u32();
    c.args.u32();
    bool isInput = c.args.u32() & 0xff;
    uint32_t property = c.args.u32();
    GuestAddr size = c.args.ptr(), out = c.args.ptr();
    std::vector<uint8_t> value;
    if (id != kDevice) {
        c.ret(uint32_t(kBadDevice));
        return;
    }
    std::lock_guard guard(device.lock);
    if (!deviceProperty(c, isInput, property, value)) {
        logUnknown(property);
        c.ret(uint32_t(kUnknownProperty));
        return;
    }
    uint32_t n = std::min(c.mem.read<uint32_t>(size), uint32_t(value.size()));
    if (out) c.mem.copyIn(out, value.data(), n);
    c.mem.write<uint32_t>(size, n);
    c.ret(0);
}
// OSStatus AudioDeviceSetProperty(device, when, channel, isInput, id, size, const void *data)
B32_THUNK(_AudioDeviceSetProperty) {
    uint32_t id = c.args.u32();
    c.args.ptr();
    c.args.u32();
    c.args.u32();
    uint32_t property = c.args.u32();
    c.args.u32();
    GuestAddr data = c.args.ptr();
    if (id != kDevice) {
        c.ret(uint32_t(kBadDevice));
        return;
    }
    std::lock_guard guard(device.lock);
    switch (property) {
    case kAudioDevicePropertyNominalSampleRate: device.rate = c.mem.read<Float64>(data); break;
    case kAudioDevicePropertyBufferFrameSize:
        device.frames = std::clamp(c.mem.read<uint32_t>(data), kMinFrames, kMaxFrames);
        break;
    case kAudioDevicePropertyStreamFormat: device.rate = c.mem.read<Float64>(data); break;
    default:
        logUnknown(property);
        c.ret(uint32_t(kUnknownProperty));
        return;
    }
    c.ret(0);
}

// OSStatus AudioDeviceAddIOProc(device, proc, client)
B32_THUNK(_AudioDeviceAddIOProc) {
    c.args.u32();
    std::lock_guard guard(device.lock);
    device.proc = c.args.ptr();
    device.client = c.args.ptr();
    c.ret(0);
}
B32_THUNK(_AudioDeviceRemoveIOProc) {
    std::lock_guard guard(device.lock);
    stopUnit();
    device.running = false;
    device.proc = 0;
    c.ret(0);
}
B32_THUNK(_AudioDeviceStart) {
    std::lock_guard guard(device.lock);
    OSStatus status = noErr;
    if (!device.running && device.proc) {
        status = startUnit();
        device.running = status == noErr;
    }
    c.ret(uint32_t(status));
}
B32_THUNK(_AudioDeviceStop) {
    std::lock_guard guard(device.lock);
    stopUnit();
    device.running = false;
    c.ret(0);
}
// OSStatus AudioDeviceGetCurrentTime(device, AudioTimeStamp *out)
B32_THUNK(_AudioDeviceGetCurrentTime) {
    c.args.u32();
    GuestAddr out = c.args.ptr();
    if (!device.running) {
        c.ret(uint32_t(kNotRunning));
        return;
    }
    AudioTimeStamp stamp{};
    stamp.mSampleTime = Float64(device.sampleTime.load());
    stamp.mHostTime = AudioGetCurrentHostTime();
    stamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    c.mem.copyIn(out, &stamp, sizeof stamp);
    c.ret(0);
}
