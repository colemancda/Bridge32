// The Sound Manager's sampled-sound channels, which HIToolbox's 64-bit side doesn't have, on AudioQueue.
//
// A channel is the guest's SndChannel (its callBack and userInfo where the guest reads them) and a host
// queue behind it. bufferCmd converts the sound header's samples into a queue buffer; callBackCmd calls
// the channel's callback once the buffers queued before it are nearly played, as the hardware had taken
// them, so a game that streams a buffer at a time from its callback (Halo's mixer, 550 frames at a
// time) keeps a short pipeline full instead of starving between buffers. Commands that change how the
// channel plays (volume, rate) take effect at once; quietCmd and flushCmd drop what hasn't played.
//
// Sample data is copied when its bufferCmd is taken, in the header's own format: 8-bit offset binary or
// 16-bit, which an i386 program writes in its own byte order ('twos' and 'sowt' in a compressed header
// say which).

#include "core/Log.h"
#include "core/Runtime.h"
#include "core/objc/Bridge.h"
#include "core/thunks/Thunks.h"

#include <AudioToolbox/AudioToolbox.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <vector>

using namespace b32;

namespace {

constexpr uint16_t kQuietCmd = 3, kFlushCmd = 4, kReInitCmd = 5, kCallBackCmd = 13, kAvailableCmd = 24, kVersionCmd = 25,
                   kVolumeCmd = 46, kGetVolumeCmd = 47, kSoundCmd = 80, kBufferCmd = 81, kRateCmd = 82, kGetRateCmd = 85,
                   kRateMultiplierCmd = 86, kGetRateMultiplierCmd = 87;
constexpr uint8_t kStdSH = 0x00, kExtSH = 0xFF, kCmpSH = 0xFE;
constexpr uint32_t kChannelSize = 1060;  // SndChannel with its standard 128-command queue
constexpr uint32_t kCallBackOffset = 8;
constexpr uint32_t kLead = 3;  // buffers that may be queued ahead of a callback still to come
constexpr int32_t kBadChannel = -205, kBadFormat = -206;

GuestMemory &memory() { return objc::Bridge::shared()->runtime().mem(); }

struct Format {
    double rate = 0;
    uint32_t channels = 0;
    bool operator==(const Format &) const = default;
};

struct Channel {
    GuestAddr guest = 0;
    bool ownsMemory = false;
    std::mutex lock;
    AudioQueueRef queue = nullptr;
    Format format;
    uint64_t enqueued = 0, completed = 0;  // buffers given to the queue, and played
    uint32_t generation = 0;               // bumped by quietCmd and flushCmd: older buffers don't count
    struct Pending {
        uint64_t after;  // the buffers queued before it
        uint16_t cmd;
        int16_t param1;
        uint32_t param2;
    };
    std::deque<Pending> callbacks;
    float volume = 1, pan = 0, rate = 1;
    dispatch_queue_t calls = dispatch_queue_create("b32.soundmanager", DISPATCH_QUEUE_SERIAL);
    GuestAddr scratch = 0;  // the SndCommand a callback gets
};

std::mutex channelsLock;
std::unordered_map<GuestAddr, Channel *> channels;

Channel *channelAt(GuestAddr guest) {
    std::lock_guard guard(channelsLock);
    auto it = channels.find(guest);
    return it == channels.end() ? nullptr : it->second;
}

struct Tag {
    Channel *channel;
    uint32_t generation;
};

void applyControls(Channel *ch) {
    if (!ch->queue) return;
    AudioQueueSetParameter(ch->queue, kAudioQueueParam_Volume, ch->volume);
    AudioQueueSetParameter(ch->queue, kAudioQueueParam_Pan, ch->pan);
    AudioQueueSetParameter(ch->queue, kAudioQueueParam_PlayRate, std::clamp(ch->rate, 0.5f, 2.0f));
}

void fireDue(Channel *ch);

void bufferDone(void *data, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    auto *tag = static_cast<Tag *>(buffer->mUserData);
    Channel *ch = tag->channel;
    bool current;
    {
        std::lock_guard guard(ch->lock);
        current = tag->generation == ch->generation;
        if (current) ch->completed++;
    }
    delete tag;
    AudioQueueFreeBuffer(queue, buffer);
    if (current) fireDue(ch);
}

// Calls the callbacks whose buffers are nearly played, in order, on the channel's own thread.
void fireDue(Channel *ch) {
    std::vector<Channel::Pending> due;
    {
        std::lock_guard guard(ch->lock);
        while (!ch->callbacks.empty() && ch->callbacks.front().after < ch->completed + kLead) {
            due.push_back(ch->callbacks.front());
            ch->callbacks.pop_front();
        }
    }
    for (const Channel::Pending &p : due)
        dispatch_async(ch->calls, ^{
            GuestMemory &mem = memory();
            GuestAddr proc = mem.read<uint32_t>(ch->guest + kCallBackOffset);
            if (!proc) return;
            mem.write<uint16_t>(ch->scratch, p.cmd);
            mem.write<int16_t>(ch->scratch + 2, p.param1);
            mem.write<uint32_t>(ch->scratch + 4, p.param2);
            Runtime::threadCpu().call(proc, {ch->guest, ch->scratch});
        });
}

// Makes the channel's queue play `format`, starting it afresh if it played another.
bool ensureQueue(Channel *ch, Format format) {
    if (ch->queue && ch->format == format) return true;
    if (ch->queue) {
        AudioQueueDispose(ch->queue, true);
        ch->queue = nullptr;
        ch->generation++;
        ch->completed = ch->enqueued;
    }
    AudioStreamBasicDescription asbd{};
    asbd.mSampleRate = format.rate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    asbd.mChannelsPerFrame = format.channels;
    asbd.mBitsPerChannel = 16;
    asbd.mBytesPerFrame = asbd.mBytesPerPacket = 2 * format.channels;
    asbd.mFramesPerPacket = 1;
    if (AudioQueueNewOutput(&asbd, bufferDone, ch, nullptr, nullptr, 0, &ch->queue) != noErr) {
        ch->queue = nullptr;
        return false;
    }
    // Varispeed, so rateCmd and rateMultiplierCmd change the pitch with the speed, as they did.
    UInt32 on = 1, varispeed = kAudioQueueTimePitchAlgorithm_Varispeed;
    AudioQueueSetProperty(ch->queue, kAudioQueueProperty_EnableTimePitch, &on, sizeof on);
    AudioQueueSetProperty(ch->queue, kAudioQueueProperty_TimePitchAlgorithm, &varispeed, sizeof varispeed);
    ch->format = format;
    applyControls(ch);
    AudioQueueStart(ch->queue, nullptr);
    return true;
}

// bufferCmd: the header's samples, as 16-bit native integers, onto the channel's queue.
OSErr playBuffer(Channel *ch, GuestAddr header) {
    GuestMemory &mem = memory();
    GuestAddr samples = mem.read<uint32_t>(header);
    uint8_t encode = mem.read<uint8_t>(header + 20);
    Format format;
    format.rate = mem.read<uint32_t>(header + 8) / 65536.0;
    uint32_t frames, bits = 8;
    bool bigEndian = false, unsignedSamples = false;
    if (encode == kStdSH) {
        format.channels = 1;
        frames = mem.read<uint32_t>(header + 4);
        unsignedSamples = true;
        if (!samples) samples = header + 22;
    } else if (encode == kExtSH || encode == kCmpSH) {
        format.channels = mem.read<uint32_t>(header + 4);
        frames = mem.read<uint32_t>(header + 22);
        bits = mem.read<uint16_t>(header + (encode == kExtSH ? 48 : 62));
        if (!samples) samples = header + 64;
        if (encode == kCmpSH) {
            uint32_t type = mem.read<uint32_t>(header + 40);
            int16_t compression = mem.read<int16_t>(header + 56);
            if (compression != 0 && compression != -1) {  // notCompressed, fixedCompression
                static bool warned = false;
                if (!warned) log("Sound Manager: compressed sound (id %d) isn't played", compression), warned = true;
                return kBadFormat;
            }
            bigEndian = type == 'twos' || (type == 'NONE' && bits == 16);
            unsignedSamples = type == 'raw ' || (type == 'NONE' && bits == 8);
        } else {
            unsignedSamples = bits == 8;
        }
    } else {
        return kBadFormat;
    }
    if (!format.channels || format.channels > 8 || !(bits == 8 || bits == 16) || format.rate <= 0) return kBadFormat;
    if (!frames) return noErr;
    std::lock_guard guard(ch->lock);
    if (!ensureQueue(ch, format)) return kBadFormat;
    uint32_t count = frames * format.channels, bytes = count * 2;
    AudioQueueBufferRef buffer = nullptr;
    if (AudioQueueAllocateBuffer(ch->queue, bytes, &buffer) != noErr) return kBadFormat;
    auto *out = static_cast<int16_t *>(buffer->mAudioData);
    if (bits == 16) {
        std::memcpy(out, mem.ptr<const int16_t>(samples), bytes);
        if (bigEndian)
            for (uint32_t i = 0; i < count; i++) out[i] = int16_t(__builtin_bswap16(uint16_t(out[i])));
    } else {
        std::vector<uint8_t> raw(count);
        std::memcpy(raw.data(), mem.ptr<const uint8_t>(samples), count);
        for (uint32_t i = 0; i < count; i++)
            out[i] = int16_t((unsignedSamples ? int(raw[i]) - 128 : int(int8_t(raw[i]))) << 8);
    }
    buffer->mAudioDataByteSize = bytes;
    buffer->mUserData = new Tag{ch, ch->generation};
    if (AudioQueueEnqueueBuffer(ch->queue, buffer, 0, nullptr) != noErr) {
        delete static_cast<Tag *>(buffer->mUserData);
        AudioQueueFreeBuffer(ch->queue, buffer);
        return kBadFormat;
    }
    ch->enqueued++;
    return noErr;
}

// What hasn't played is dropped; callbacks still to come don't come.
void silence(Channel *ch) {
    std::lock_guard guard(ch->lock);
    ch->callbacks.clear();
    ch->generation++;
    ch->completed = ch->enqueued;
    if (ch->queue) {
        AudioQueueReset(ch->queue);
        AudioQueueStart(ch->queue, nullptr);
    }
}

OSErr doCommand(Channel *ch, GuestAddr command, bool immediate) {
    GuestMemory &mem = memory();
    uint16_t cmd = mem.read<uint16_t>(command);
    int16_t param1 = mem.read<int16_t>(command + 2);
    uint32_t param2 = mem.read<uint32_t>(command + 4);
    switch (cmd) {
    case kBufferCmd:
    case kSoundCmd:
        return playBuffer(ch, param2);
    case kCallBackCmd: {
        if (immediate) {  // run now, in the guest's own call
            std::lock_guard guard(ch->lock);
            ch->callbacks.push_front({0, cmd, param1, param2});
        } else {
            std::lock_guard guard(ch->lock);
            ch->callbacks.push_back({ch->enqueued, cmd, param1, param2});
        }
        fireDue(ch);
        return noErr;
    }
    case kQuietCmd:
    case kFlushCmd:
        silence(ch);
        return noErr;
    case kVolumeCmd: {  // left in the low word, right in the high, 0x100 each at full volume
        float left = (param2 & 0xffff) / 256.0f, right = (param2 >> 16) / 256.0f;
        std::lock_guard guard(ch->lock);
        ch->volume = std::min(std::max(left, right), 1.0f);
        ch->pan = left + right > 0 ? (right - left) / (left + right) : 0;
        applyControls(ch);
        return noErr;
    }
    case kGetVolumeCmd: {
        std::lock_guard guard(ch->lock);
        uint32_t left = uint32_t(std::lround(ch->volume * (1 - std::max(ch->pan, 0.0f)) * 256));
        uint32_t right = uint32_t(std::lround(ch->volume * (1 + std::min(ch->pan, 0.0f)) * 256));
        if (param2) mem.write<uint32_t>(param2, right << 16 | left);
        return noErr;
    }
    case kRateCmd:
    case kRateMultiplierCmd: {  // Fixed: 1.0 plays at the sound's own rate
        std::lock_guard guard(ch->lock);
        ch->rate = param2 ? param2 / 65536.0f : 1.0f;
        applyControls(ch);
        return noErr;
    }
    case kGetRateCmd:
    case kGetRateMultiplierCmd: {
        std::lock_guard guard(ch->lock);
        if (param2) mem.write<uint32_t>(param2, uint32_t(std::lround(ch->rate * 65536)));
        return noErr;
    }
    case kVersionCmd:
        if (param2) mem.write<uint32_t>(param2, 0x00030000);
        return noErr;
    case kAvailableCmd:
    case kReInitCmd:
    default:
        return noErr;
    }
}

}  // namespace

// OSErr SndNewChannel(SndChannelPtr *chan, short synth, long init, SndCallBackUPP userRoutine)
B32_THUNK(_SndNewChannel) {
    GuestAddr out = c.args.ptr();
    c.args.u32();
    c.args.u32();
    GuestAddr routine = c.args.ptr();
    auto *ch = new Channel;
    ch->guest = c.mem.read<uint32_t>(out);
    if (!ch->guest) {
        ch->guest = c.heap.calloc(1, kChannelSize);
        ch->ownsMemory = true;
        c.mem.write<uint32_t>(out, ch->guest);
    }
    c.mem.write<uint32_t>(ch->guest + kCallBackOffset, routine);
    c.mem.write<int16_t>(ch->guest + 30, 128);  // qLength
    ch->scratch = c.heap.calloc(1, 8);
    std::lock_guard guard(channelsLock);
    channels[ch->guest] = ch;
    c.ret(0);
}
// OSErr SndDisposeChannel(SndChannelPtr, Boolean quietNow): what's queued is dropped either way.
B32_THUNK(_SndDisposeChannel) {
    GuestAddr guest = c.args.ptr();
    Channel *ch;
    {
        std::lock_guard guard(channelsLock);
        auto it = channels.find(guest);
        if (it == channels.end()) return c.ret(uint32_t(kBadChannel));
        ch = it->second;
        channels.erase(it);
    }
    silence(ch);
    dispatch_sync(ch->calls, ^{});  // a callback already on its way finishes first
    if (ch->queue) AudioQueueDispose(ch->queue, true);
    if (ch->ownsMemory) c.heap.free(ch->guest);
    c.heap.free(ch->scratch);
    // The channel itself is kept: a buffer the queue already finished may still name it.
    c.ret(0);
}
// OSErr SndDoCommand(SndChannelPtr, const SndCommand *, Boolean noWait) and SndDoImmediate(chan, cmd)
B32_THUNK(_SndDoCommand) {
    Channel *ch = channelAt(c.args.ptr());
    GuestAddr command = c.args.ptr();
    c.ret(uint32_t(ch ? doCommand(ch, command, false) : kBadChannel));
}
B32_THUNK(_SndDoImmediate) {
    Channel *ch = channelAt(c.args.ptr());
    GuestAddr command = c.args.ptr();
    c.ret(uint32_t(ch ? doCommand(ch, command, true) : kBadChannel));
}
// OSErr SndChannelStatus(SndChannelPtr, short length, SCStatus *): busy while anything is left to play.
// SCStatus: scStartTime 0, scEndTime 4, scCurrentTime 8, scChannelBusy 12, scChannelDisposed 13,
// scChannelPaused 14, scUnused 15, scChannelAttributes 16, scCPULoad 20.
B32_THUNK(_SndChannelStatus) {
    Channel *ch = channelAt(c.args.ptr());
    int16_t length = int16_t(c.args.u32());
    GuestAddr status = c.args.ptr();
    if (!status || length <= 0) return c.ret(0);
    std::vector<uint8_t> zeros(size_t(length), 0);
    c.mem.copyIn(status, zeros.data(), zeros.size());
    if (ch && length > 12) {
        std::lock_guard guard(ch->lock);
        c.mem.write<uint8_t>(status + 12, ch->enqueued > ch->completed || !ch->callbacks.empty());
    }
    c.ret(0);
}
// OSErr SndPlay(SndChannelPtr, SndListHandle, Boolean async): 'snd ' resources aren't read yet.
B32_THUNK(_SndPlay) {
    static bool warned = false;
    if (!warned) log("Sound Manager: SndPlay of a 'snd ' resource isn't supported yet"), warned = true;
    c.ret(0);
}
B32_THUNK(_NewSndCallBackUPP) { c.ret(c.args.ptr()); }
B32_THUNK(_DisposeSndCallBackUPP) {}
