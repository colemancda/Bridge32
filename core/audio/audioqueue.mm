// AudioQueue output and AudioFile on the host's AudioToolbox.
//
// Queues and files are guest handles. Queue buffers are the tricky part: the
// guest reads and writes AudioQueueBuffer fields directly, so every host
// buffer has a guest mirror in the 32-bit layout
//   { mAudioDataBytesCapacity, mAudioData, mAudioDataByteSize, mUserData,
//     mPacketDescriptionCapacity, mPacketDescriptions, mPacketDescriptionCount }
// with its data in guest memory, copied to the host buffer on enqueue.
// AudioStreamBasicDescription, AudioTimeStamp and AudioStreamPacketDescription
// have the same layout in both ABIs and pass straight through.

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/CTable.h"

#include <AudioToolbox/AudioToolbox.h>

#include <cstddef>
#include <mutex>
#include <vector>
#include <unordered_map>

using namespace b32;

namespace {

struct Queue {
    AudioQueueRef host;
    uint32_t handle;
    GuestAddr callback;
    GuestAddr userData;
    std::unordered_map<AudioQueueBufferRef, GuestAddr> mirrors;  // host buffer -> guest mirror
    std::unordered_map<GuestAddr, AudioQueueBufferRef> buffers;  // guest mirror -> host buffer
};

std::mutex lock;
std::unordered_map<uint32_t, Queue *> queues;

Queue *queueFor(uint32_t handle) {
    std::lock_guard guard(lock);
    auto it = queues.find(handle);
    if (it == queues.end()) fatal("bad AudioQueue handle %u", handle);
    return it->second;
}

GuestMemory &guestMemory() { return objc::Bridge::shared()->runtime().mem(); }
GuestHeap &guestHeap() { return objc::Bridge::shared()->runtime().heap(); }

// The host finished playing a buffer: hand its mirror back to the guest.
void outputCallback(void *data, AudioQueueRef, AudioQueueBufferRef buffer) {
    auto *q = static_cast<Queue *>(data);
    GuestAddr mirror;
    {
        std::lock_guard guard(lock);
        mirror = q->mirrors.at(buffer);
    }
    Runtime::threadCpu().call(q->callback, {q->userData, q->handle, mirror});
}

struct PropertyListener {
    GuestAddr proc;
    GuestAddr userData;
    uint32_t queue;
};

void propertyCallback(void *data, AudioQueueRef, AudioQueuePropertyID property) {
    auto *l = static_cast<PropertyListener *>(data);
    Runtime::threadCpu().call(l->proc, {l->userData, l->queue, property});
}

}  // namespace

// OSStatus AudioQueueNewOutput(const AudioStreamBasicDescription *, AudioQueueOutputCallback,
//     void *userData, CFRunLoopRef, CFStringRef runLoopMode, UInt32 flags, AudioQueueRef *out)
B32_THUNK(_AudioQueueNewOutput) {
    auto *format = c.mem.ptr<AudioStreamBasicDescription>(c.args.ptr());
    auto *q = new Queue{};
    q->callback = c.args.ptr();
    q->userData = c.args.ptr();
    CFRunLoopRef runLoop = (CFRunLoopRef)c.rt.bridge().toHost(c.args.ptr());
    CFStringRef mode = (CFStringRef)c.rt.bridge().toHost(c.args.ptr());
    UInt32 flags = c.args.u32();
    GuestAddr out = c.args.ptr();
    OSStatus status = AudioQueueNewOutput(format, outputCallback, q, runLoop, mode, flags, &q->host);
    if (status != noErr) {
        delete q;
        c.ret(uint32_t(status));
        return;
    }
    q->handle = hostHandle(q->host);
    {
        std::lock_guard guard(lock);
        queues[q->handle] = q;
    }
    c.mem.write<uint32_t>(out, q->handle);
    c.ret(0);
}

// OSStatus AudioQueueAllocateBuffer(AudioQueueRef, UInt32 size, AudioQueueBufferRef *out)
// OSStatus AudioQueueAllocateBufferWithPacketDescriptions(AudioQueueRef, UInt32 size,
//     UInt32 numberPacketDescriptions, AudioQueueBufferRef *): the guest mirror gets an array
// of 16-byte AudioStreamPacketDescriptions of its own.
B32_THUNK(_AudioQueueAllocateBufferWithPacketDescriptions) {
    Queue *q = queueFor(c.args.u32());
    uint32_t size = c.args.u32();
    uint32_t descriptionCount = c.args.u32();
    GuestAddr out = c.args.ptr();
    AudioQueueBufferRef buffer = nullptr;
    OSStatus status = AudioQueueAllocateBufferWithPacketDescriptions(q->host, size, descriptionCount, &buffer);
    if (status != noErr) {
        c.ret(uint32_t(status));
        return;
    }
    GuestAddr mirror = c.heap.calloc(1, 28);
    c.mem.write<uint32_t>(mirror, size);
    c.mem.write<uint32_t>(mirror + 4, c.heap.calloc(1, size));
    c.mem.write<uint32_t>(mirror + 16, descriptionCount);
    c.mem.write<uint32_t>(mirror + 20, c.heap.calloc(std::max(descriptionCount, 1u), 16));
    {
        std::lock_guard guard(lock);
        q->mirrors[buffer] = mirror;
        q->buffers[mirror] = buffer;
    }
    c.mem.write<uint32_t>(out, mirror);
    c.ret(0);
}

B32_THUNK(_AudioQueueAllocateBuffer) {
    Queue *q = queueFor(c.args.u32());
    uint32_t size = c.args.u32();
    GuestAddr out = c.args.ptr();
    AudioQueueBufferRef buffer = nullptr;
    OSStatus status = AudioQueueAllocateBuffer(q->host, size, &buffer);
    if (status != noErr) {
        c.ret(uint32_t(status));
        return;
    }
    GuestAddr mirror = c.heap.calloc(1, 28);
    c.mem.write<uint32_t>(mirror, size);
    c.mem.write<uint32_t>(mirror + 4, c.heap.calloc(1, size));
    {
        std::lock_guard guard(lock);
        q->mirrors[buffer] = mirror;
        q->buffers[mirror] = buffer;
    }
    c.mem.write<uint32_t>(out, mirror);
    c.ret(0);
}

// OSStatus AudioQueueEnqueueBuffer(AudioQueueRef, AudioQueueBufferRef, UInt32 numPacketDescs,
//                                  const AudioStreamPacketDescription *)
namespace {
// Copies a guest buffer's audio (and its packet descriptions, when the caller
// passes none and the buffer has its own) into the host buffer; returns the
// descriptions to enqueue with.
AudioStreamPacketDescription *prepareBuffer(Call &c, AudioQueueBufferRef buffer, GuestAddr mirror,
                                            uint32_t &descriptionCount, GuestAddr descriptions) {
    uint32_t bytes = std::min(c.mem.read<uint32_t>(mirror + 8), buffer->mAudioDataBytesCapacity);
    std::memcpy(buffer->mAudioData, c.mem.ptr<void>(c.mem.read<uint32_t>(mirror + 4)), bytes);
    buffer->mAudioDataByteSize = bytes;
    buffer->mUserData = nullptr;
    if (descriptions) return c.mem.ptr<AudioStreamPacketDescription>(descriptions);
    uint32_t own = c.mem.read<uint32_t>(mirror + 24);
    GuestAddr ownDescriptions = c.mem.read<uint32_t>(mirror + 20);
    if (own && ownDescriptions && buffer->mPacketDescriptions) {
        own = std::min(own, buffer->mPacketDescriptionCapacity);
        std::memcpy(buffer->mPacketDescriptions, c.mem.ptr<void>(ownDescriptions), own * sizeof(AudioStreamPacketDescription));
        buffer->mPacketDescriptionCount = own;
    }
    descriptionCount = 0;
    return nullptr;
}
}  // namespace

B32_THUNK(_AudioQueueEnqueueBuffer) {
    Queue *q = queueFor(c.args.u32());
    GuestAddr mirror = c.args.ptr();
    uint32_t descriptionCount = c.args.u32();
    GuestAddr descriptions = c.args.ptr();
    AudioQueueBufferRef buffer;
    {
        std::lock_guard guard(lock);
        buffer = q->buffers.at(mirror);
    }
    auto *packets = prepareBuffer(c, buffer, mirror, descriptionCount, descriptions);
    c.ret(uint32_t(AudioQueueEnqueueBuffer(q->host, buffer, descriptionCount, packets)));
}

// OSStatus AudioQueueEnqueueBufferWithParameters(AudioQueueRef, AudioQueueBufferRef, UInt32 numPacketDescs,
//     const AudioStreamPacketDescription *, UInt32 trimFramesAtStart, UInt32 trimFramesAtEnd,
//     UInt32 numParamValues, const AudioQueueParameterEvent *, const AudioTimeStamp *startTime,
//     AudioTimeStamp *outActualStartTime)
// Parameter events ({ id, Float32 value }) and timestamps have the same layout in both.
B32_THUNK(_AudioQueueEnqueueBufferWithParameters) {
    Queue *q = queueFor(c.args.u32());
    GuestAddr mirror = c.args.ptr();
    uint32_t descriptionCount = c.args.u32();
    GuestAddr descriptions = c.args.ptr();
    uint32_t trimStart = c.args.u32(), trimEnd = c.args.u32(), paramCount = c.args.u32();
    GuestAddr params = c.args.ptr(), start = c.args.ptr(), actual = c.args.ptr();
    AudioQueueBufferRef buffer;
    {
        std::lock_guard guard(lock);
        buffer = q->buffers.at(mirror);
    }
    auto *packets = prepareBuffer(c, buffer, mirror, descriptionCount, descriptions);
    c.ret(uint32_t(AudioQueueEnqueueBufferWithParameters(
        q->host, buffer, descriptionCount, packets, trimStart, trimEnd, paramCount,
        params ? c.mem.ptr<AudioQueueParameterEvent>(params) : nullptr, start ? c.mem.ptr<AudioTimeStamp>(start) : nullptr,
        actual ? c.mem.ptr<AudioTimeStamp>(actual) : nullptr)));
}

B32_THUNK(_AudioQueueFreeBuffer) {
    Queue *q = queueFor(c.args.u32());
    GuestAddr mirror = c.args.ptr();
    AudioQueueBufferRef buffer;
    {
        std::lock_guard guard(lock);
        buffer = q->buffers.at(mirror);
        q->buffers.erase(mirror);
        q->mirrors.erase(buffer);
    }
    c.heap.free(c.mem.read<uint32_t>(mirror + 4));
    c.heap.free(mirror);
    c.ret(uint32_t(AudioQueueFreeBuffer(q->host, buffer)));
}

B32_THUNK(_AudioQueueDispose) {
    uint32_t handle = c.args.u32();
    Boolean immediate = Boolean(c.args.u32());
    Queue *q = queueFor(handle);
    OSStatus status = AudioQueueDispose(q->host, immediate);
    std::lock_guard guard(lock);
    for (auto &[mirror, buffer] : q->buffers) {
        guestHeap().free(guestMemory().read<uint32_t>(mirror + 4));
        guestHeap().free(mirror);
    }
    forgetHostHandle(q->host);
    queues.erase(handle);
    delete q;
    c.ret(uint32_t(status));
}

// OSStatus AudioQueueStart(AudioQueueRef, const AudioTimeStamp *)
B32_THUNK(_AudioQueueStart) {
    Queue *q = queueFor(c.args.u32());
    GuestAddr time = c.args.ptr();
    c.ret(uint32_t(AudioQueueStart(q->host, time ? c.mem.ptr<AudioTimeStamp>(time) : nullptr)));
}

B32_THUNK(_AudioQueueStop) {
    Queue *q = queueFor(c.args.u32());
    c.ret(uint32_t(AudioQueueStop(q->host, Boolean(c.args.u32()))));
}
B32_THUNK(_AudioQueuePause) { c.ret(uint32_t(AudioQueuePause(queueFor(c.args.u32())->host))); }
B32_THUNK(_AudioQueueReset) { c.ret(uint32_t(AudioQueueReset(queueFor(c.args.u32())->host))); }
B32_THUNK(_AudioQueueFlush) { c.ret(uint32_t(AudioQueueFlush(queueFor(c.args.u32())->host))); }

// OSStatus AudioQueuePrime(AudioQueueRef, UInt32 framesToPrepare, UInt32 *outFramesPrepared)
B32_THUNK(_AudioQueuePrime) {
    Queue *q = queueFor(c.args.u32());
    UInt32 frames = c.args.u32();
    GuestAddr out = c.args.ptr();
    c.ret(uint32_t(AudioQueuePrime(q->host, frames, out ? c.mem.ptr<UInt32>(out) : nullptr)));
}

// OSStatus AudioQueueSetParameter(AudioQueueRef, AudioQueueParameterID, AudioQueueParameterValue)
B32_THUNK(_AudioQueueSetParameter) {
    Queue *q = queueFor(c.args.u32());
    AudioQueueParameterID parameter = c.args.u32();
    c.ret(uint32_t(AudioQueueSetParameter(q->host, parameter, c.args.f32())));
}

B32_THUNK(_AudioQueueGetParameter) {
    Queue *q = queueFor(c.args.u32());
    AudioQueueParameterID parameter = c.args.u32();
    c.ret(uint32_t(AudioQueueGetParameter(q->host, parameter, c.mem.ptr<AudioQueueParameterValue>(c.args.ptr()))));
}

// Queue properties are plain values (UInt32s, an ASBD, magic cookie bytes).
B32_THUNK(_AudioQueueSetProperty) {
    Queue *q = queueFor(c.args.u32());
    AudioQueuePropertyID property = c.args.u32();
    GuestAddr data = c.args.ptr();
    c.ret(uint32_t(AudioQueueSetProperty(q->host, property, c.mem.ptr<void>(data), c.args.u32())));
}

B32_THUNK(_AudioQueueGetProperty) {
    Queue *q = queueFor(c.args.u32());
    AudioQueuePropertyID property = c.args.u32();
    GuestAddr data = c.args.ptr();
    GuestAddr size = c.args.ptr();
    c.ret(uint32_t(AudioQueueGetProperty(q->host, property, c.mem.ptr<void>(data), c.mem.ptr<UInt32>(size))));
}

// OSStatus AudioQueueGetCurrentTime(AudioQueueRef, AudioQueueTimelineRef, AudioTimeStamp *, Boolean *)
B32_THUNK(_AudioQueueGetCurrentTime) {
    Queue *q = queueFor(c.args.u32());
    c.args.u32();  // timelines aren't bridged
    GuestAddr time = c.args.ptr();
    GuestAddr discontinuity = c.args.ptr();
    c.ret(uint32_t(AudioQueueGetCurrentTime(q->host, nullptr, time ? c.mem.ptr<AudioTimeStamp>(time) : nullptr,
                                            discontinuity ? c.mem.ptr<Boolean>(discontinuity) : nullptr)));
}

// OSStatus AudioQueueAddPropertyListener(AudioQueueRef, AudioQueuePropertyID, AudioQueuePropertyListenerProc, void *)
B32_THUNK(_AudioQueueAddPropertyListener) {
    uint32_t handle = c.args.u32();
    Queue *q = queueFor(handle);
    AudioQueuePropertyID property = c.args.u32();
    auto *listener = new PropertyListener{c.args.ptr(), 0, handle};
    listener->userData = c.args.ptr();
    c.ret(uint32_t(AudioQueueAddPropertyListener(q->host, property, propertyCallback, listener)));
}

B32_THUNK(_AudioQueueRemovePropertyListener) { c.ret(0); }

// --- AudioFile ---------------------------------------------------------------------------------

namespace {
AudioFileID audioFile(uint32_t handle) { return static_cast<AudioFileID>(hostPointer(handle)); }

// Callbacks for AudioFileOpenWithCallbacks run the guest's functions.
struct FileCallbacks {
    GuestAddr clientData, read, write, getSize, setSize;
};

OSStatus readProc(void *data, SInt64 position, UInt32 count, void *buffer, UInt32 *actual) {
    auto *f = static_cast<FileCallbacks *>(data);
    GuestHeap &heap = guestHeap();
    GuestMemory &mem = guestMemory();
    GuestAddr guestBuffer = heap.alloc(std::max(count, 1u));
    GuestAddr guestActual = heap.calloc(1, 4);
    // OSStatus (*)(void *, SInt64 position, UInt32 count, void *buffer, UInt32 *actual)
    auto status = OSStatus(Runtime::threadCpu().call(
        f->read, {f->clientData, uint32_t(position), uint32_t(uint64_t(position) >> 32), count, guestBuffer, guestActual}));
    *actual = mem.read<uint32_t>(guestActual);
    std::memcpy(buffer, mem.ptr<void>(guestBuffer), *actual);
    heap.free(guestBuffer);
    heap.free(guestActual);
    return status;
}

SInt64 getSizeProc(void *data) {
    auto *f = static_cast<FileCallbacks *>(data);
    return SInt64(Runtime::threadCpu().call(f->getSize, {f->clientData}));
}
}  // namespace

// OSStatus AudioFileOpenURL(CFURLRef, AudioFilePermissions, AudioFileTypeID, AudioFileID *)
B32_THUNK(_AudioFileOpenURL) {
    CFURLRef url = (CFURLRef)c.rt.bridge().toHost(c.args.ptr());
    AudioFilePermissions permissions = AudioFilePermissions(c.args.u32());
    AudioFileTypeID hint = c.args.u32();
    GuestAddr out = c.args.ptr();
    AudioFileID file = nullptr;
    OSStatus status = AudioFileOpenURL(url, permissions, hint, &file);
    c.mem.write<uint32_t>(out, hostHandle(file));
    c.ret(uint32_t(status));
}

// OSStatus AudioFileOpenWithCallbacks(void *clientData, read, write, getSize, setSize,
//                                     AudioFileTypeID, AudioFileID *)
B32_THUNK(_AudioFileOpenWithCallbacks) {
    auto *f = new FileCallbacks{c.args.ptr(), c.args.ptr(), c.args.ptr(), c.args.ptr(), c.args.ptr()};
    AudioFileTypeID hint = c.args.u32();
    GuestAddr out = c.args.ptr();
    AudioFileID file = nullptr;
    // Read-only: the guest's write callbacks aren't needed for playback.
    OSStatus status = AudioFileOpenWithCallbacks(f, readProc, nullptr, getSizeProc, nullptr, hint, &file);
    c.mem.write<uint32_t>(out, hostHandle(file));
    c.ret(uint32_t(status));
}

B32_THUNK(_AudioFileClose) {
    uint32_t handle = c.args.u32();
    AudioFileID file = audioFile(handle);
    forgetHostHandle(file);
    c.ret(uint32_t(AudioFileClose(file)));
}

// File properties are plain values or ASBDs, as for queues.
B32_THUNK(_AudioFileGetProperty) {
    AudioFileID file = audioFile(c.args.u32());
    AudioFilePropertyID property = c.args.u32();
    GuestAddr size = c.args.ptr();
    GuestAddr data = c.args.ptr();
    c.ret(uint32_t(AudioFileGetProperty(file, property, c.mem.ptr<UInt32>(size), c.mem.ptr<void>(data))));
}

B32_THUNK(_AudioFileGetPropertyInfo) {
    AudioFileID file = audioFile(c.args.u32());
    AudioFilePropertyID property = c.args.u32();
    GuestAddr size = c.args.ptr();
    GuestAddr writable = c.args.ptr();
    c.ret(uint32_t(AudioFileGetPropertyInfo(file, property, size ? c.mem.ptr<UInt32>(size) : nullptr,
                                            writable ? c.mem.ptr<UInt32>(writable) : nullptr)));
}

// OSStatus AudioFileReadPackets(AudioFileID, Boolean useCache, UInt32 *outNumBytes,
//     AudioStreamPacketDescription *, SInt64 startingPacket, UInt32 *ioNumPackets, void *outBuffer)
// OSStatus AudioFileReadPacketData(AudioFileID, Boolean useCache, UInt32 *ioNumBytes,
//     AudioStreamPacketDescription *, SInt64 startingPacket, UInt32 *ioNumPackets, void *outBuffer):
// AudioFileReadPackets with the buffer's size given.
B32_THUNK(_AudioFileReadPacketData) {
    AudioFileID file = audioFile(c.args.u32());
    Boolean useCache = Boolean(c.args.u32());
    GuestAddr bytes = c.args.ptr();
    GuestAddr descriptions = c.args.ptr();
    SInt64 start = SInt64(c.args.u64());
    GuestAddr packets = c.args.ptr();
    GuestAddr buffer = c.args.ptr();
    c.ret(uint32_t(AudioFileReadPacketData(file, useCache, c.mem.ptr<UInt32>(bytes),
                                           descriptions ? c.mem.ptr<AudioStreamPacketDescription>(descriptions) : nullptr,
                                           start, c.mem.ptr<UInt32>(packets), c.mem.ptr<void>(buffer))));
}

B32_THUNK(_AudioFileReadPackets) {
    AudioFileID file = audioFile(c.args.u32());
    Boolean useCache = Boolean(c.args.u32());
    GuestAddr bytes = c.args.ptr();
    GuestAddr descriptions = c.args.ptr();
    SInt64 start = SInt64(c.args.u64());
    GuestAddr packets = c.args.ptr();
    GuestAddr buffer = c.args.ptr();
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    c.ret(uint32_t(AudioFileReadPackets(file, useCache, c.mem.ptr<UInt32>(bytes),
                                        descriptions ? c.mem.ptr<AudioStreamPacketDescription>(descriptions) : nullptr,
                                        start, c.mem.ptr<UInt32>(packets), c.mem.ptr<void>(buffer))));
#pragma clang diagnostic pop
}

// OSStatus AudioFileReadBytes(AudioFileID, Boolean useCache, SInt64 startingByte, UInt32 *ioNumBytes, void *buffer)
B32_THUNK(_AudioFileReadBytes) {
    AudioFileID file = audioFile(c.args.u32());
    Boolean useCache = Boolean(c.args.u32());
    SInt64 start = SInt64(c.args.u64());
    GuestAddr count = c.args.ptr();
    GuestAddr buffer = c.args.ptr();
    c.ret(uint32_t(AudioFileReadBytes(file, useCache, start, c.mem.ptr<UInt32>(count), c.mem.ptr<void>(buffer))));
}

// --- run loops: audio callbacks may be delivered on a guest thread's run loop ------------------
// (CFRunLoopRunInMode is in core/uikit/eventloop.mm, which also dispatches input.)

B32_THUNK(_CFRunLoopStop) { CFRunLoopStop((CFRunLoopRef)c.rt.bridge().toHost(c.args.ptr())); }

// --- ExtAudioFile: decoding audio files to PCM ------------------------------------------------
// The properties games use (file and client stream formats, length in
// frames) have the same layout in both ABIs; only the buffer list that
// ExtAudioFileRead fills holds pointers.

namespace {
ExtAudioFileRef extAudioFile(uint32_t handle) { return static_cast<ExtAudioFileRef>(hostPointer(handle)); }
}  // namespace

// OSStatus ExtAudioFileOpenURL(CFURLRef, ExtAudioFileRef *)
B32_THUNK(_ExtAudioFileOpenURL) {
    CFURLRef url = (CFURLRef)c.rt.bridge().toHost(c.args.ptr());
    GuestAddr out = c.args.ptr();
    ExtAudioFileRef file = nullptr;
    OSStatus status = ExtAudioFileOpenURL(url, &file);
    if (out) c.mem.write<uint32_t>(out, hostHandle(file));
    c.ret(uint32_t(status));
}

B32_THUNK(_ExtAudioFileDispose) {
    ExtAudioFileRef file = extAudioFile(c.args.u32());
    OSStatus status = ExtAudioFileDispose(file);
    forgetHostHandle(file);
    c.ret(uint32_t(status));
}

// OSStatus ExtAudioFileGetProperty(ExtAudioFileRef, ExtAudioFilePropertyID, UInt32 *ioSize, void *outData)
B32_THUNK(_ExtAudioFileGetProperty) {
    ExtAudioFileRef file = extAudioFile(c.args.u32());
    ExtAudioFilePropertyID property = c.args.u32();
    GuestAddr size = c.args.ptr(), data = c.args.ptr();
    c.ret(uint32_t(ExtAudioFileGetProperty(file, property, size ? c.mem.ptr<UInt32>(size) : nullptr,
                                           data ? c.mem.ptr<void>(data) : nullptr)));
}

// OSStatus ExtAudioFileSetProperty(ExtAudioFileRef, ExtAudioFilePropertyID, UInt32 size, const void *data)
B32_THUNK(_ExtAudioFileSetProperty) {
    ExtAudioFileRef file = extAudioFile(c.args.u32());
    ExtAudioFilePropertyID property = c.args.u32();
    UInt32 size = c.args.u32();
    GuestAddr data = c.args.ptr();
    c.ret(uint32_t(ExtAudioFileSetProperty(file, property, size, data ? c.mem.ptr<void>(data) : nullptr)));
}

// OSStatus ExtAudioFileRead(ExtAudioFileRef, UInt32 *ioNumberFrames, AudioBufferList *)
// Guest AudioBufferList: { mNumberBuffers, { mNumberChannels, mDataByteSize, mData }... }.
B32_THUNK(_ExtAudioFileRead) {
    ExtAudioFileRef file = extAudioFile(c.args.u32());
    GuestAddr frames = c.args.ptr(), list = c.args.ptr();
    uint32_t count = c.mem.read<uint32_t>(list);
    std::vector<uint8_t> storage(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * std::max(count, 1u));
    auto *host = reinterpret_cast<AudioBufferList *>(storage.data());
    host->mNumberBuffers = count;
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr b = list + 4 + i * 12;
        GuestAddr samples = c.mem.read<uint32_t>(b + 8);
        host->mBuffers[i] = {c.mem.read<uint32_t>(b), c.mem.read<uint32_t>(b + 4),
                             samples ? c.mem.ptr<void>(samples) : nullptr};
    }
    OSStatus status = ExtAudioFileRead(file, c.mem.ptr<UInt32>(frames), host);
    for (uint32_t i = 0; i < count; i++) c.mem.write<uint32_t>(list + 4 + i * 12 + 4, host->mBuffers[i].mDataByteSize);
    c.ret(uint32_t(status));
}

// OSStatus ExtAudioFileSeek(ExtAudioFileRef, SInt64 inFrameOffset)
B32_THUNK(_ExtAudioFileSeek) {
    ExtAudioFileRef file = extAudioFile(c.args.u32());
    c.ret(uint32_t(ExtAudioFileSeek(file, SInt64(c.args.u64()))));
}

// OSStatus ExtAudioFileTell(ExtAudioFileRef, SInt64 *outFrameOffset)
B32_THUNK(_ExtAudioFileTell) {
    ExtAudioFileRef file = extAudioFile(c.args.u32());
    GuestAddr out = c.args.ptr();
    SInt64 offset = 0;
    OSStatus status = ExtAudioFileTell(file, &offset);
    if (out) c.mem.write<int64_t>(out, offset);
    c.ret(uint32_t(status));
}

// --- AudioConverter ---------------------------------------------------------------------------
// Converters are guest handles. FillComplexBuffer's input callback is the
// guest's: it fills a guest AudioBufferList { count, { channels, size, data }... }
// with pointers to its own data, which are guest memory and so usable by the
// host in place. Packet descriptions have the same layout in both.

namespace {
struct Converter {
    AudioConverterRef host;
    uint32_t handle;
    GuestAddr proc = 0, userData = 0;
    GuestAddr scratch = 0;  // the callback's guest arguments
    uint32_t scratchSize = 0;
};
std::mutex convertersLock;
std::unordered_map<uint32_t, Converter *> converters;

Converter *converterFor(uint32_t handle) {
    std::lock_guard guard(convertersLock);
    auto it = converters.find(handle);
    if (it == converters.end()) fatal("bad AudioConverter handle %u", handle);
    return it->second;
}

// AudioConverterComplexInputDataProc(AudioConverterRef, UInt32 *ioNumberDataPackets,
//     AudioBufferList *ioData, AudioStreamPacketDescription **outDataPacketDescription, void *inUserData)
OSStatus converterInput(AudioConverterRef, UInt32 *packets, AudioBufferList *ioData,
                        AudioStreamPacketDescription **descriptions, void *data) {
    auto *conv = static_cast<Converter *>(data);
    GuestMemory &mem = guestMemory();
    uint32_t count = ioData->mNumberBuffers;
    uint32_t needed = 8 + 4 + count * 12;  // packets, descriptions pointer, buffer list
    if (needed > conv->scratchSize) {
        if (conv->scratch) guestHeap().free(conv->scratch);
        conv->scratchSize = needed;
        conv->scratch = guestHeap().calloc(1, needed);
    }
    GuestAddr guestPackets = conv->scratch, guestDescriptions = conv->scratch + 4, list = conv->scratch + 8;
    mem.write<uint32_t>(guestPackets, *packets);
    mem.write<uint32_t>(guestDescriptions, 0);
    mem.write<uint32_t>(list, count);
    for (uint32_t i = 0; i < count; i++) {
        mem.write<uint32_t>(list + 4 + i * 12, ioData->mBuffers[i].mNumberChannels);
        mem.write<uint32_t>(list + 8 + i * 12, 0);
        mem.write<uint32_t>(list + 12 + i * 12, 0);
    }
    auto status = OSStatus(Runtime::threadCpu().call(
        conv->proc, {conv->handle, guestPackets, list, descriptions ? guestDescriptions : 0, conv->userData}));
    *packets = mem.read<uint32_t>(guestPackets);
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr samples = mem.read<uint32_t>(list + 12 + i * 12);
        ioData->mBuffers[i].mNumberChannels = mem.read<uint32_t>(list + 4 + i * 12);
        ioData->mBuffers[i].mDataByteSize = mem.read<uint32_t>(list + 8 + i * 12);
        ioData->mBuffers[i].mData = samples ? mem.ptr<void>(samples) : nullptr;
    }
    if (descriptions) {
        GuestAddr d = mem.read<uint32_t>(guestDescriptions);
        *descriptions = d ? mem.ptr<AudioStreamPacketDescription>(d) : nullptr;
    }
    return status;
}
}  // namespace

// OSStatus AudioConverterNew(const AudioStreamBasicDescription *, const AudioStreamBasicDescription *,
//     AudioConverterRef *)
B32_THUNK(_AudioConverterNew) {
    auto *from = c.mem.ptr<AudioStreamBasicDescription>(c.args.ptr());
    auto *to = c.mem.ptr<AudioStreamBasicDescription>(c.args.ptr());
    GuestAddr out = c.args.ptr();
    AudioConverterRef host = nullptr;
    OSStatus status = AudioConverterNew(from, to, &host);
    if (status == noErr) {
        auto *conv = new Converter{host, hostHandle(host)};
        {
            std::lock_guard guard(convertersLock);
            converters[conv->handle] = conv;
        }
        c.mem.write<uint32_t>(out, conv->handle);
    }
    c.ret(uint32_t(status));
}

B32_THUNK(_AudioConverterDispose) {
    Converter *conv = converterFor(c.args.u32());
    OSStatus status = AudioConverterDispose(conv->host);
    {
        std::lock_guard guard(convertersLock);
        converters.erase(conv->handle);
    }
    forgetHostHandle(conv->host);
    if (conv->scratch) c.heap.free(conv->scratch);
    delete conv;
    c.ret(uint32_t(status));
}

// OSStatus AudioConverterSetProperty(AudioConverterRef, AudioConverterPropertyID, UInt32 size, const void *)
// The properties games set (magic cookies, quality, channel maps) are plain bytes.
B32_THUNK(_AudioConverterSetProperty) {
    Converter *conv = converterFor(c.args.u32());
    AudioConverterPropertyID property = c.args.u32();
    UInt32 size = c.args.u32();
    GuestAddr data = c.args.ptr();
    c.ret(uint32_t(AudioConverterSetProperty(conv->host, property, size, data ? c.mem.ptr<void>(data) : nullptr)));
}

// OSStatus AudioConverterFillComplexBuffer(AudioConverterRef, AudioConverterComplexInputDataProc,
//     void *inUserData, UInt32 *ioOutputDataPacketSize, AudioBufferList *outOutputData,
//     AudioStreamPacketDescription *outPacketDescription)
B32_THUNK(_AudioConverterFillComplexBuffer) {
    Converter *conv = converterFor(c.args.u32());
    conv->proc = c.args.ptr();
    conv->userData = c.args.ptr();
    GuestAddr packets = c.args.ptr(), list = c.args.ptr(), descriptions = c.args.ptr();
    uint32_t count = c.mem.read<uint32_t>(list);
    std::vector<uint8_t> storage(offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * std::max(count, 1u));
    auto *host = reinterpret_cast<AudioBufferList *>(storage.data());
    host->mNumberBuffers = count;
    for (uint32_t i = 0; i < count; i++) {
        GuestAddr b = list + 4 + i * 12, samples = c.mem.read<uint32_t>(b + 8);
        host->mBuffers[i] = {c.mem.read<uint32_t>(b), c.mem.read<uint32_t>(b + 4), samples ? c.mem.ptr<void>(samples) : nullptr};
    }
    OSStatus status = AudioConverterFillComplexBuffer(
        conv->host, converterInput, conv, c.mem.ptr<UInt32>(packets), host,
        descriptions ? c.mem.ptr<AudioStreamPacketDescription>(descriptions) : nullptr);
    for (uint32_t i = 0; i < count; i++) c.mem.write<uint32_t>(list + 4 + i * 12 + 4, host->mBuffers[i].mDataByteSize);
    c.ret(uint32_t(status));
}
