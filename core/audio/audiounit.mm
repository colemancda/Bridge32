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
#include <vector>

using namespace b32;

namespace {

// A guest AURenderCallback: the render callback, or a render notification.
struct Callback {
    GuestAddr proc = 0, refCon = 0;
    GuestAddr scratch = 0;  // the callback's guest arguments
    uint32_t scratchSize = 0;
};

struct Unit {
    AudioUnit host;
    uint32_t handle;
    Callback render;
    std::vector<Callback *> notifications;
};

std::mutex lock;
std::unordered_map<uint32_t, Unit *> units;

// The unit for a guest handle; for an unknown one (games stop units they
// never made, even NULL) the thunk returns paramErr, as the host would.
Unit *unitFor(Call &c, uint32_t handle) {
    std::lock_guard guard(lock);
    auto it = units.find(handle);
    if (it != units.end()) return it->second;
    c.ret(uint32_t(kAudio_ParamError));
    return nullptr;
}

GuestMemory &guestMemory() { return objc::Bridge::shared()->runtime().mem(); }
GuestHeap &guestHeap() { return objc::Bridge::shared()->runtime().heap(); }

constexpr uint32_t kTimeStampOffset = 4, kBufferListOffset = 4 + 64;

OSStatus callGuest(void *data, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timeStamp, UInt32 bus,
                   UInt32 frames, AudioBufferList *ioData) {
    auto *unit = static_cast<Callback *>(data);
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
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    OSStatus status = AudioComponentInstanceDispose(unit->host);
    {
        std::lock_guard guard(lock);
        units.erase(unit->handle);
    }
    forgetHostHandle(unit->host);
    if (unit->render.scratch) c.heap.free(unit->render.scratch);
    for (Callback *n : unit->notifications) {
        if (n->scratch) c.heap.free(n->scratch);
        delete n;
    }
    delete unit;
    c.ret(uint32_t(status));
}

B32_THUNK(_AudioUnitInitialize) {
    if (Unit *unit = unitFor(c, c.args.u32())) c.ret(uint32_t(AudioUnitInitialize(unit->host)));
}
B32_THUNK(_AudioUnitUninitialize) {
    if (Unit *unit = unitFor(c, c.args.u32())) c.ret(uint32_t(AudioUnitUninitialize(unit->host)));
}
B32_THUNK(_AudioOutputUnitStart) {
    if (Unit *unit = unitFor(c, c.args.u32())) c.ret(uint32_t(AudioOutputUnitStart(unit->host)));
}
B32_THUNK(_AudioOutputUnitStop) {
    if (Unit *unit = unitFor(c, c.args.u32())) c.ret(uint32_t(AudioOutputUnitStop(unit->host)));
}

// OSStatus AudioUnitSetProperty(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
//     AudioUnitElement, const void *data, UInt32 size)
B32_THUNK(_AudioUnitSetProperty) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    AudioUnitPropertyID property = c.args.u32();
    AudioUnitScope scope = c.args.u32();
    AudioUnitElement element = c.args.u32();
    GuestAddr data = c.args.ptr();
    UInt32 size = c.args.u32();
    if (property == kAudioUnitProperty_SetRenderCallback) {
        // AURenderCallbackStruct { proc, refCon }: two guest words.
        unit->render.proc = data ? c.mem.read<uint32_t>(data) : 0;
        unit->render.refCon = data ? c.mem.read<uint32_t>(data + 4) : 0;
        AURenderCallbackStruct callback = {unit->render.proc ? callGuest : nullptr, &unit->render};
        c.ret(uint32_t(AudioUnitSetProperty(unit->host, property, scope, element, &callback, sizeof callback)));
        return;
    }
    if (property == kAudioOutputUnitProperty_SetInputCallback) {
        log("audio input callbacks aren't supported; ignoring");
        c.ret(0);
        return;
    }
    // Nor is recording: turning on the input bus (element 1) would only make
    // macOS ask for the microphone and block AudioOutputUnitStart until it's
    // answered (Black Ops Zombies' voice chat).
    if (property == kAudioOutputUnitProperty_EnableIO && scope == kAudioUnitScope_Input && element == 1) {
        c.ret(0);
        return;
    }
    c.ret(uint32_t(AudioUnitSetProperty(unit->host, property, scope, element, data ? c.mem.ptr<void>(data) : nullptr, size)));
}

// OSStatus AudioUnitGetProperty(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
//     AudioUnitElement, void *outData, UInt32 *ioSize)
B32_THUNK(_AudioUnitGetProperty) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    AudioUnitPropertyID property = c.args.u32();
    AudioUnitScope scope = c.args.u32();
    AudioUnitElement element = c.args.u32();
    GuestAddr data = c.args.ptr(), size = c.args.ptr();
    // Properties holding a CF object (the caller owns it): a 4-byte guest
    // reference in place of the host pointer.
    if (property == kAudioUnitProperty_ClassInfo || property == kAudioUnitProperty_ElementName ||
        property == kAudioUnitProperty_ParameterValueStrings || property == kAudioUnitProperty_FactoryPresets) {
        CFTypeRef object = nullptr;
        UInt32 hostSize = sizeof object;
        OSStatus status = AudioUnitGetProperty(unit->host, property, scope, element, data ? &object : nullptr, &hostSize);
        if (data) c.mem.write<uint32_t>(data, status == noErr && object ? objc::Bridge::shared()->toGuest((id)object) : 0);
        if (size) c.mem.write<uint32_t>(size, 4);
        c.ret(uint32_t(status));
        return;
    }
    c.ret(uint32_t(AudioUnitGetProperty(unit->host, property, scope, element, data ? c.mem.ptr<void>(data) : nullptr,
                                        size ? c.mem.ptr<UInt32>(size) : nullptr)));
}

// OSStatus AudioUnitAddRenderNotify(AudioUnit, AURenderCallback, void *refCon): a guest
// function called before and after each render, with the same arguments.
B32_THUNK(_AudioUnitAddRenderNotify) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    auto *notification = new Callback{c.args.ptr(), c.args.ptr()};
    unit->notifications.push_back(notification);
    c.ret(uint32_t(AudioUnitAddRenderNotify(unit->host, callGuest, notification)));
}

// AudioUnitParameterValue (a float) AudioUnitGetParameter / SetParameter.
// OSStatus AudioUnitGetParameter(AudioUnit, AudioUnitParameterID, AudioUnitScope, AudioUnitElement,
//     AudioUnitParameterValue *)
B32_THUNK(_AudioUnitGetParameter) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    AudioUnitParameterID id = c.args.u32();
    AudioUnitScope scope = c.args.u32();
    AudioUnitElement element = c.args.u32();
    GuestAddr out = c.args.ptr();
    AudioUnitParameterValue value = 0;
    OSStatus status = AudioUnitGetParameter(unit->host, id, scope, element, &value);
    if (out) c.mem.write<float>(out, value);
    c.ret(uint32_t(status));
}
// OSStatus AudioUnitSetParameter(AudioUnit, AudioUnitParameterID, AudioUnitScope, AudioUnitElement,
//     AudioUnitParameterValue, UInt32 bufferOffsetInFrames)
B32_THUNK(_AudioUnitSetParameter) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    AudioUnitParameterID id = c.args.u32();
    AudioUnitScope scope = c.args.u32();
    AudioUnitElement element = c.args.u32();
    float value = c.args.f32();
    c.ret(uint32_t(AudioUnitSetParameter(unit->host, id, scope, element, value, c.args.u32())));
}

// OSStatus AudioUnitRemoveRenderNotify(AudioUnit, AURenderCallback, void *refCon)
B32_THUNK(_AudioUnitRemoveRenderNotify) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    GuestAddr proc = c.args.ptr(), refCon = c.args.ptr();
    for (auto it = unit->notifications.begin(); it != unit->notifications.end(); ++it) {
        Callback *n = *it;
        if (n->proc != proc || n->refCon != refCon) continue;
        OSStatus status = AudioUnitRemoveRenderNotify(unit->host, callGuest, n);
        // The host may be about to call it on the audio thread, so the
        // scratch arguments stay allocated.
        unit->notifications.erase(it);
        c.ret(uint32_t(status));
        return;
    }
    c.ret(0);
}

// Property listeners would call the guest from the host's notification
// threads; nothing so far needs them, so they're accepted and never called.
B32_THUNK(_AudioUnitAddPropertyListener) { c.ret(0); }
B32_THUNK(_AudioUnitRemovePropertyListener) { c.ret(0); }
B32_THUNK(_AudioUnitRemovePropertyListenerWithUserData) { c.ret(0); }

// OSStatus AudioUnitRender(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
//     UInt32 bus, UInt32 frames, AudioBufferList *): the flags and time stamp have the
// same layout, the buffer list is rebuilt with host pointers to the guest's samples.
B32_THUNK(_AudioUnitRender) {
    Unit *unit = unitFor(c, c.args.u32());
    if (!unit) return;
    GuestAddr flags = c.args.ptr(), timeStamp = c.args.ptr();
    UInt32 bus = c.args.u32(), frames = c.args.u32();
    GuestAddr list = c.args.ptr();
    uint32_t count = c.mem.read<uint32_t>(list);
    std::vector<uint8_t> storage(offsetof(AudioBufferList, mBuffers) + std::max(count, 1u) * sizeof(AudioBuffer));
    auto *hostList = reinterpret_cast<AudioBufferList *>(storage.data());
    hostList->mNumberBuffers = count;
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr data = c.mem.read<uint32_t>(list + 12 + i * 12);
        if (!data) fatal("AudioUnitRender into the unit's own buffers isn't supported");
        hostList->mBuffers[i] = {c.mem.read<uint32_t>(list + 4 + i * 12), c.mem.read<uint32_t>(list + 8 + i * 12),
                                 c.mem.ptr<void>(data)};
    }
    OSStatus status = AudioUnitRender(unit->host, flags ? c.mem.ptr<AudioUnitRenderActionFlags>(flags) : nullptr,
                                      c.mem.ptr<AudioTimeStamp>(timeStamp), bus, frames, hostList);
    for (uint32_t i = 0; i < count; i++) c.mem.write<uint32_t>(list + 8 + i * 12, hostList->mBuffers[i].mDataByteSize);
    c.ret(uint32_t(status));
}

// Processing graphs. The AUGraph is a host handle; AUNodes are plain numbers
// in both ABIs; a node's AudioUnit becomes a guest unit handle like one from
// AudioComponentInstanceNew (owned by the graph, so never disposed here).

namespace {

AUGraph graphFor(uint32_t handle) { return static_cast<AUGraph>(hostPointer(handle)); }

uint32_t unitHandle(AudioUnit host) {
    uint32_t handle = hostHandle(host);
    std::lock_guard guard(lock);
    if (!units.count(handle)) units[handle] = new Unit{host, handle};
    return handle;
}

}  // namespace

// OSStatus NewAUGraph(AUGraph *out)
B32_THUNK(_NewAUGraph) {
    GuestAddr out = c.args.ptr();
    AUGraph graph = nullptr;
    OSStatus status = NewAUGraph(&graph);
    if (status == noErr) c.mem.write<uint32_t>(out, hostHandle(graph));
    c.ret(uint32_t(status));
}

B32_THUNK(_DisposeAUGraph) {
    AUGraph graph = graphFor(c.args.u32());
    c.ret(uint32_t(DisposeAUGraph(graph)));
    forgetHostHandle(graph);
}

B32_THUNK(_AUGraphOpen) { c.ret(uint32_t(AUGraphOpen(graphFor(c.args.u32())))); }
B32_THUNK(_AUGraphClose) { c.ret(uint32_t(AUGraphClose(graphFor(c.args.u32())))); }
B32_THUNK(_AUGraphInitialize) { c.ret(uint32_t(AUGraphInitialize(graphFor(c.args.u32())))); }
B32_THUNK(_AUGraphUninitialize) { c.ret(uint32_t(AUGraphUninitialize(graphFor(c.args.u32())))); }
B32_THUNK(_AUGraphStart) { c.ret(uint32_t(AUGraphStart(graphFor(c.args.u32())))); }
B32_THUNK(_AUGraphStop) { c.ret(uint32_t(AUGraphStop(graphFor(c.args.u32())))); }

// OSStatus AUGraphIsOpen/IsInitialized/IsRunning(AUGraph, Boolean *out)
template <OSStatus (*query)(AUGraph, Boolean *)>
static void graphQuery(Call &c) {
    AUGraph graph = graphFor(c.args.u32());
    GuestAddr out = c.args.ptr();
    Boolean value = false;
    OSStatus status = query(graph, &value);
    if (out) c.mem.write<uint8_t>(out, value);
    c.ret(uint32_t(status));
}
B32_THUNK(_AUGraphIsOpen) { graphQuery<AUGraphIsOpen>(c); }
B32_THUNK(_AUGraphIsInitialized) { graphQuery<AUGraphIsInitialized>(c); }
B32_THUNK(_AUGraphIsRunning) { graphQuery<AUGraphIsRunning>(c); }

// OSStatus AUGraphUpdate(AUGraph, Boolean *outIsUpdated)
B32_THUNK(_AUGraphUpdate) { graphQuery<AUGraphUpdate>(c); }

// OSStatus AUGraphAddNode(AUGraph, const AudioComponentDescription *, AUNode *out)
B32_THUNK(_AUGraphAddNode) {
    AUGraph graph = graphFor(c.args.u32());
    auto *desc = c.mem.ptr<AudioComponentDescription>(c.args.ptr());
    GuestAddr out = c.args.ptr();
    AUNode node = 0;
    OSStatus status = AUGraphAddNode(graph, desc, &node);
    if (out) c.mem.write<int32_t>(out, node);
    c.ret(uint32_t(status));
}

B32_THUNK(_AUGraphRemoveNode) {
    AUGraph graph = graphFor(c.args.u32());
    c.ret(uint32_t(AUGraphRemoveNode(graph, AUNode(c.args.u32()))));
}

// OSStatus AUGraphGetNodeCount(AUGraph, UInt32 *out)
B32_THUNK(_AUGraphGetNodeCount) {
    AUGraph graph = graphFor(c.args.u32());
    GuestAddr out = c.args.ptr();
    UInt32 count = 0;
    OSStatus status = AUGraphGetNodeCount(graph, &count);
    if (out) c.mem.write<uint32_t>(out, count);
    c.ret(uint32_t(status));
}

// OSStatus AUGraphGetIndNode(AUGraph, UInt32 index, AUNode *out)
B32_THUNK(_AUGraphGetIndNode) {
    AUGraph graph = graphFor(c.args.u32());
    UInt32 index = c.args.u32();
    GuestAddr out = c.args.ptr();
    AUNode node = 0;
    OSStatus status = AUGraphGetIndNode(graph, index, &node);
    if (out) c.mem.write<int32_t>(out, node);
    c.ret(uint32_t(status));
}

// OSStatus AUGraphNodeInfo(AUGraph, AUNode, AudioComponentDescription *outDesc, AudioUnit *outUnit)
B32_THUNK(_AUGraphNodeInfo) {
    AUGraph graph = graphFor(c.args.u32());
    AUNode node = AUNode(c.args.u32());
    GuestAddr desc = c.args.ptr(), outUnit = c.args.ptr();
    AudioUnit unit = nullptr;
    OSStatus status = AUGraphNodeInfo(graph, node, desc ? c.mem.ptr<AudioComponentDescription>(desc) : nullptr,
                                      outUnit ? &unit : nullptr);
    if (outUnit) c.mem.write<uint32_t>(outUnit, status == noErr && unit ? unitHandle(unit) : 0);
    c.ret(uint32_t(status));
}

// OSStatus AUGraphConnectNodeInput(AUGraph, AUNode source, UInt32 sourceOutput, AUNode dest, UInt32 destInput)
B32_THUNK(_AUGraphConnectNodeInput) {
    AUGraph graph = graphFor(c.args.u32());
    AUNode source = AUNode(c.args.u32());
    UInt32 output = c.args.u32();
    AUNode dest = AUNode(c.args.u32());
    c.ret(uint32_t(AUGraphConnectNodeInput(graph, source, output, dest, c.args.u32())));
}

B32_THUNK(_AUGraphDisconnectNodeInput) {
    AUGraph graph = graphFor(c.args.u32());
    AUNode dest = AUNode(c.args.u32());
    c.ret(uint32_t(AUGraphDisconnectNodeInput(graph, dest, c.args.u32())));
}

B32_THUNK(_AUGraphClearConnections) { c.ret(uint32_t(AUGraphClearConnections(graphFor(c.args.u32())))); }

// OSStatus AUGraphSetNodeInputCallback(AUGraph, AUNode, UInt32 input, const AURenderCallbackStruct *):
// like a unit's render callback, one guest copy of the arguments per input.
B32_THUNK(_AUGraphSetNodeInputCallback) {
    AUGraph graph = graphFor(c.args.u32());
    AUNode node = AUNode(c.args.u32());
    UInt32 input = c.args.u32();
    GuestAddr data = c.args.ptr();
    // Kept for the graph's lifetime: the host may still be rendering with an
    // earlier one when it's replaced.
    auto *callback = new Callback{data ? c.mem.read<uint32_t>(data) : 0, data ? c.mem.read<uint32_t>(data + 4) : 0};
    AURenderCallbackStruct host = {callback->proc ? callGuest : nullptr, callback};
    c.ret(uint32_t(AUGraphSetNodeInputCallback(graph, node, input, &host)));
}
