// zlib compression and checksums (inflate is in posix.cpp). Deflate streams
// work like inflate's: each guest z_stream (32-bit: next_in 0, avail_in 4,
// total_in 8, next_out 12, avail_out 16, total_out 20, msg 24, ...,
// data_type 44, adler 48) has a host z_stream, and the buffers stay in guest
// memory.

#include "Thunks.h"
#include "core/Runtime.h"

#include <zlib.h>

#include <mutex>
#include <unordered_map>

using namespace b32;

namespace {

std::mutex lock;
std::unordered_map<GuestAddr, z_stream *> streams;

z_stream *hostStream(GuestAddr g) {
    std::lock_guard guard(lock);
    auto it = streams.find(g);
    return it == streams.end() ? nullptr : it->second;
}

void load(Call &c, GuestAddr g, z_stream *z) {
    GuestAddr in = c.mem.read<uint32_t>(g), out = c.mem.read<uint32_t>(g + 12);
    z->next_in = in ? c.mem.ptr<Bytef>(in) : nullptr;
    z->avail_in = c.mem.read<uint32_t>(g + 4);
    z->next_out = out ? c.mem.ptr<Bytef>(out) : nullptr;
    z->avail_out = c.mem.read<uint32_t>(g + 16);
}

void store(Call &c, GuestAddr g, z_stream *z) {
    c.mem.write<uint32_t>(g, z->next_in ? c.mem.guestAddrOf(z->next_in) : 0);
    c.mem.write<uint32_t>(g + 4, z->avail_in);
    c.mem.write<uint32_t>(g + 8, uint32_t(z->total_in));
    c.mem.write<uint32_t>(g + 12, z->next_out ? c.mem.guestAddrOf(z->next_out) : 0);
    c.mem.write<uint32_t>(g + 16, z->avail_out);
    c.mem.write<uint32_t>(g + 20, uint32_t(z->total_out));
    c.mem.write<uint32_t>(g + 24, 0);
    c.mem.write<uint32_t>(g + 44, uint32_t(z->data_type));
    c.mem.write<uint32_t>(g + 48, uint32_t(z->adler));
}

}  // namespace

// int deflateInit2_(z_streamp, int level, int method, int windowBits, int memLevel,
//                   int strategy, const char *version, int stream_size)
B32_THUNK(_deflateInit2_) {
    GuestAddr g = c.args.ptr();
    int level = c.args.i32(), method = c.args.i32(), windowBits = c.args.i32(), memLevel = c.args.i32();
    int strategy = c.args.i32();
    auto *z = new z_stream{};
    load(c, g, z);
    int rc = deflateInit2(z, level, method, windowBits, memLevel, strategy);
    {
        std::lock_guard guard(lock);
        streams[g] = z;
    }
    store(c, g, z);
    c.ret(uint32_t(rc));
}

// int deflateInit_(z_streamp, int level, const char *version, int stream_size)
B32_THUNK(_deflateInit_) {
    GuestAddr g = c.args.ptr();
    int level = c.args.i32();
    auto *z = new z_stream{};
    load(c, g, z);
    int rc = deflateInit(z, level);
    {
        std::lock_guard guard(lock);
        streams[g] = z;
    }
    store(c, g, z);
    c.ret(uint32_t(rc));
}

B32_THUNK(_deflate) {
    GuestAddr g = c.args.ptr();
    int flush = c.args.i32();
    z_stream *z = hostStream(g);
    if (!z) {
        c.ret(uint32_t(Z_STREAM_ERROR));
        return;
    }
    load(c, g, z);
    int rc = ::deflate(z, flush);
    store(c, g, z);
    c.ret(uint32_t(rc));
}

B32_THUNK(_deflateEnd) {
    GuestAddr g = c.args.ptr();
    z_stream *z = hostStream(g);
    int rc = z ? ::deflateEnd(z) : Z_STREAM_ERROR;
    {
        std::lock_guard guard(lock);
        streams.erase(g);
    }
    delete z;
    c.ret(uint32_t(rc));
}

B32_THUNK(_deflateBound) {
    GuestAddr g = c.args.ptr();
    z_stream *z = hostStream(g);
    c.ret(uint32_t(z ? ::deflateBound(z, c.args.u32()) : compressBound(c.args.u32())));
}

// int compress(Bytef *dest, uLongf *destLen, const Bytef *source, uLong sourceLen):
// uLong is 32-bit in the guest.
B32_THUNK(_compress) {
    GuestAddr dest = c.args.ptr(), destLen = c.args.ptr(), source = c.args.ptr();
    uLong sourceLen = c.args.u32();
    uLongf length = c.mem.read<uint32_t>(destLen);
    int rc = ::compress(c.mem.ptr<Bytef>(dest), &length, c.mem.ptr<Bytef>(source), sourceLen);
    c.mem.write<uint32_t>(destLen, uint32_t(length));
    c.ret(uint32_t(rc));
}

B32_THUNK(_compress2) {
    GuestAddr dest = c.args.ptr(), destLen = c.args.ptr(), source = c.args.ptr();
    uLong sourceLen = c.args.u32();
    int level = c.args.i32();
    uLongf length = c.mem.read<uint32_t>(destLen);
    int rc = ::compress2(c.mem.ptr<Bytef>(dest), &length, c.mem.ptr<Bytef>(source), sourceLen, level);
    c.mem.write<uint32_t>(destLen, uint32_t(length));
    c.ret(uint32_t(rc));
}

B32_THUNK(_uncompress) {
    GuestAddr dest = c.args.ptr(), destLen = c.args.ptr(), source = c.args.ptr();
    uLong sourceLen = c.args.u32();
    uLongf length = c.mem.read<uint32_t>(destLen);
    int rc = ::uncompress(c.mem.ptr<Bytef>(dest), &length, c.mem.ptr<Bytef>(source), sourceLen);
    c.mem.write<uint32_t>(destLen, uint32_t(length));
    c.ret(uint32_t(rc));
}

B32_THUNK(_compressBound) { c.ret(uint32_t(::compressBound(c.args.u32()))); }

// uLong crc32(uLong crc, const Bytef *buf, uInt len), and adler32 alike.
B32_THUNK(_crc32) {
    uLong crc = c.args.u32();
    GuestAddr buf = c.args.ptr();
    uInt len = c.args.u32();
    c.ret(uint32_t(::crc32(crc, buf ? c.mem.ptr<Bytef>(buf) : nullptr, len)));
}
B32_THUNK(_adler32) {
    uLong adler = c.args.u32();
    GuestAddr buf = c.args.ptr();
    uInt len = c.args.u32();
    c.ret(uint32_t(::adler32(adler, buf ? c.mem.ptr<Bytef>(buf) : nullptr, len)));
}

// const z_crc_t *get_crc_table(void): 256 32-bit entries, copied into guest memory once.
B32_THUNK(_get_crc_table) {
    static GuestAddr table = [&] {
        const z_crc_t *host = ::get_crc_table();
        GuestAddr t = c.heap.alloc(256 * 4);
        for (uint32_t i = 0; i < 256; i++) c.mem.write<uint32_t>(t + i * 4, uint32_t(host[i]));
        return t;
    }();
    c.ret(table);
}
