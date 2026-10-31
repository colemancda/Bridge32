// Audio units (RemoteIO output, which many games mix their own sound into)
// on the host's AudioToolbox. Components and units are guest handles.
//
// The render callback is the only part that needs converting: the host calls
// it on its audio thread with an AudioBufferList of 64-bit AudioBuffers, so
// each unit keeps a guest copy of the callback's arguments
//   flags (4), AudioTimeStamp (64, same layout), AudioBufferList
//   { mNumberBuffers, { mNumberChannels, mDataByteSize, mData }... }
// with the sample data in guest memory, copied back to the host's buffers
// after the guest has filled them. Other properties (stream formats, flags)
// have the same layout in both ABIs and pass straight through.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#include <AudioToolbox/AudioToolbox.h>

#include <cstring>
#include <mutex>
#include <unordered_map>

using namespace b32;

namespace {

struct Unit {
    AudioUnit host;
    uint32_t handle;
    GuestAddr proc = 0, refCon = 0;
    GuestAddr scratch = 0;  // the callback's guest arguments
    uint32_t scratchSize = 0;
};

std::mutex lock;
std::unordered_map<uint32_t, Unit *> units;

Unit *unitFor(uint32_t handle) {
    std::lock_guard guard(lock);
    auto it = units.find(handle);
    if (it == units.end()) fatal("bad AudioUnit handle %u", handle);
    return it->second;
}

GuestMemory &guestMemory() { return objc::Bridge::shared()->runtime().mem(); }
GuestHeap &guestHeap() { return objc::Bridge::shared()->runtime().heap(); }

constexpr uint32_t kTimeStampOffset = 4, kBufferListOffset = 4 + 64;

OSStatus render(void *data, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp, UInt32 bus,
                UInt32 frames, AudioBufferList *ioData) {
    auto *unit = static_cast<Unit *>(data);
    GuestMemory &mem = guestMemory();
    uint32_t count = ioData ? ioData->mNumberBuffers : 0;
    uint32_t bytes = 0;
    for (uint32_t i = 0; i < count; i++) bytes += ioData->mBuffers[i].mDataByteSize;
    uint32_t listSize = 4 + count * 12;
    uint32_t needed = kBufferListOffset + listSize + bytes;
    if (needed > unit->scratchSize) {
        if (unit->scratch) guestHeap().free(unit->scratch);
        unit->scratchSize = needed * 2;
        unit->scratch = guestHeap().calloc(1, unit->scratchSize);
    }
    GuestAddr base = unit->scratch;
    mem.write<uint32_t>(base, flags ? *flags : 0);
    if (timeStamp) mem.copyIn(base + kTimeStampOffset, timeStamp, sizeof *timeStamp);
    GuestAddr list = base + kBufferListOffset;
    mem.write<uint32_t>(list, count);
    GuestAddr samples = list + listSize;
    for (uint32_t i = 0; i < count; i++) {
        const AudioBuffer &b = ioData->mBuffers[i];
        mem.write<uint32_t>(list + 4 + i * 12, b.mNumberChannels);
        mem.write<uint32_t>(list + 8 + i * 12, b.mDataByteSize);
        mem.write<uint32_t>(list + 12 + i * 12, samples);
        if (b.mData) mem.copyIn(samples, b.mData, b.mDataByteSize);
        samples += b.mDataByteSize;
    }

    auto status = OSStatus(Runtime::threadCpu().call(
        unit->proc, {unit->refCon, base, base + kTimeStampOffset, bus, frames, list}));

    if (flags) *flags = mem.read<uint32_t>(base);
    for (uint32_t i = 0; i < count; i++) {
        AudioBuffer &b = ioData->mBuffers[i];
        GuestAddr guestData = mem.read<uint32_t>(list + 12 + i * 12);
        uint32_t size = std::min(mem.read<uint32_t>(list + 8 + i * 12), b.mDataByteSize);
        if (b.mData && guestData) std::memcpy(b.mData, mem.ptr<void>(guestData), size);
    }
    return status;
}

}  // namespace

// AudioComponent AudioComponentFindNext(AudioComponent, const AudioComponentDescription *)
B32_THUNK(_AudioComponentFindNext) {
    auto after = static_cast<AudioComponent>(hostPointer(c.args.u32()));
    auto *desc = c.mem.ptr<AudioComponentDescription>(c.args.ptr());
    AudioComponent found = AudioComponentFindNext(after, desc);
    c.ret(found ? hostHandle(found) : 0);
}

// OSStatus AudioComponentInstanceNew(AudioComponent, AudioComponentInstance *out)
B32_THUNK(_AudioComponentInstanceNew) {
    auto component = static_cast<AudioComponent>(hostPointer(c.args.u32()));
    GuestAddr out = c.args.ptr();
    AudioComponentInstance instance = nullptr;
    OSStatus status = AudioComponentInstanceNew(component, &instance);
    if (status == noErr) {
        auto *unit = new Unit{instance, hostHandle(instance)};
        {
            std::lock_guard guard(lock);
            units[unit->handle] = unit;
        }
        c.mem.write<uint32_t>(out, unit->handle);
    }
    c.ret(uint32_t(status));
}

B32_THUNK(_AudioComponentInstanceDispose) {
    Unit *unit = unitFor(c.args.u32());
    OSStatus status = AudioComponentInstanceDispose(unit->host);
    {
        std::lock_guard guard(lock);
        units.erase(unit->handle);
    }
    forgetHostHandle(unit->host);
    if (unit->scratch) c.heap.free(unit->scratch);
    delete unit;
    c.ret(uint32_t(status));
}

B32_THUNK(_AudioUnitInitialize) { c.ret(uint32_t(AudioUnitInitialize(unitFor(c.args.u32())->host))); }
B32_THUNK(_AudioUnitUninitialize) { c.ret(uint32_t(AudioUnitUninitialize(unitFor(c.args.u32())->host))); }
B32_THUNK(_AudioOutputUnitStart) { c.ret(uint32_t(AudioOutputUnitStart(unitFor(c.args.u32())->host))); }
B32_THUNK(_AudioOutputUnitStop) { c.ret(uint32_t(AudioOutputUnitStop(unitFor(c.args.u32())->host))); }

// OSStatus AudioUnitSetProperty(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
//     AudioUnitElement, const void *data, UInt32 size)
B32_THUNK(_AudioUnitSetProperty) {
    Unit *unit = unitFor(c.args.u32());
    AudioUnitPropertyID property = c.args.u32();
    AudioUnitScope scope = c.args.u32();
    AudioUnitElement element = c.args.u32();
    GuestAddr data = c.args.ptr();
    UInt32 size = c.args.u32();
    if (property == kAudioUnitProperty_SetRenderCallback) {
        // AURenderCallbackStruct { proc, refCon }: two guest words.
        unit->proc = data ? c.mem.read<uint32_t>(data) : 0;
        unit->refCon = data ? c.mem.read<uint32_t>(data + 4) : 0;
        AURenderCallbackStruct callback = {unit->proc ? render : nullptr, unit};
        c.ret(uint32_t(AudioUnitSetProperty(unit->host, property, scope, element, &callback, sizeof callback)));
        return;
    }
    if (property == kAudioOutputUnitProperty_SetInputCallback) {
        log("audio input callbacks aren't supported; ignoring");
        c.ret(0);
        return;
    }
    c.ret(uint32_t(AudioUnitSetProperty(unit->host, property, scope, element, data ? c.mem.ptr<void>(data) : nullptr, size)));
}

// OSStatus AudioUnitGetProperty(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
//     AudioUnitElement, void *outData, UInt32 *ioSize)
B32_THUNK(_AudioUnitGetProperty) {
    Unit *unit = unitFor(c.args.u32());
    AudioUnitPropertyID property = c.args.u32();
    AudioUnitScope scope = c.args.u32();
    AudioUnitElement element = c.args.u32();
    GuestAddr data = c.args.ptr(), size = c.args.ptr();
    c.ret(uint32_t(AudioUnitGetProperty(unit->host, property, scope, element, data ? c.mem.ptr<void>(data) : nullptr,
                                        size ? c.mem.ptr<UInt32>(size) : nullptr)));
}
