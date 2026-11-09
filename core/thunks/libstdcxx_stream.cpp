// The out-of-line parts of GCC's iostreams for i386 Mac guests. Guests inline
// a lot of this library and instantiate some of it themselves (a stringbuf's
// virtuals often live in the game), so objects have GCC's layout exactly, and
// the base streambuf's algorithms here go through the object's own vtable:
//
//   ios_base: precision 4, width 8, flags 12, exceptions 16, state 20, ... size 112
//   basic_ios: tie 112, fill 116, streambuf 120, facets 124-132, size 136
//   streambuf: vptr, in_beg 4, in_cur 8, in_end 12, out_beg 16, out_cur 20,
//              out_end 24, locale 28, size 32
//   stringbuf: mode 32, string 36
//   istream/ostream: vptr; vptr[-3] is the offset of the virtual basic_ios
//   istream: gcount 4
//
// File streams are kept host-side: a basic_filebuf's interior is only touched
// by these functions, so an fstream is a FILE * in a table keyed by its buffer.

#include "Thunks.h"
#include "core/Log.h"
#include "core/Runtime.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>

using namespace b32;

namespace {
constexpr uint32_t kPrecision = 4, kWidth = 8, kFlags = 12, kExceptions = 16, kState = 20, kFill = 116, kFillInit = 117,
                   kStreambuf = 120, kIosEnd = 136;
constexpr uint32_t kInCur = 8, kInEnd = 12, kInBeg = 4, kOutBeg = 16, kOutCur = 20, kOutEnd = 24;
constexpr uint32_t kBufMode = 32, kBufString = 36;
constexpr uint32_t kGcount = 4;
constexpr uint32_t kGoodBit = 0, kBadBit = 1, kEofBit = 2, kFailBit = 4;
constexpr uint32_t kDec = 2, kFixed = 4, kHex = 8, kLeft = 32, kOct = 64, kScientific = 256, kShowBase = 512,
                   kShowPoint = 1024, kShowPos = 2048, kSkipWs = 4096, kUpper = 16384;
constexpr uint32_t kModeIn = 8, kModeOut = 16;

// Virtual function slots in a basic_streambuf vtable.
constexpr uint32_t kSlotSync = 6, kSlotUnderflow = 9, kSlotUflow = 10, kSlotXsputn = 12, kSlotOverflow = 13, kSlotXsgetn = 8;

// sizeof(basic_filebuf): the distance from the stream's buffer to its ios in the game's inline code.
constexpr uint32_t kFilebufSize = 516;

std::mutex filesLock;
std::unordered_map<GuestAddr, FILE *> files;

GuestAddr iosOf(Call &c, GuestAddr stream) {
    return stream + c.mem.read<int32_t>(c.mem.read<uint32_t>(stream) - 12);
}
GuestAddr bufferOf(Call &c, GuestAddr stream) { return c.mem.read<uint32_t>(iosOf(c, stream) + kStreambuf); }
void addState(Call &c, GuestAddr ios, uint32_t bits) { c.mem.write<uint32_t>(ios + kState, c.mem.read<uint32_t>(ios + kState) | bits); }

GuestAddr virtualOf(Call &c, GuestAddr object, uint32_t slot) { return c.mem.read<uint32_t>(c.mem.read<uint32_t>(object) + slot * 4); }

// streambuf::sputn, by way of the object's own xsputn.
uint32_t putBytes(Call &c, GuestAddr buffer, GuestAddr text, uint32_t n) {
    return uint32_t(c.cpu.call(virtualOf(c, buffer, kSlotXsputn), {buffer, text, n}));
}

void insert(Call &c, GuestAddr stream, std::string text) {
    GuestAddr ios = iosOf(c, stream), buffer = c.mem.read<uint32_t>(ios + kStreambuf);
    // The field width applies to one insertion, padded with the fill character.
    uint32_t width = c.mem.read<uint32_t>(ios + kWidth);
    c.mem.write<uint32_t>(ios + kWidth, 0);
    if (width > text.size()) {
        char fill = c.mem.read<uint8_t>(ios + kFillInit) ? char(c.mem.read<uint8_t>(ios + kFill)) : ' ';
        if (c.mem.read<uint32_t>(ios + kFlags) & kLeft)
            text.append(width - text.size(), fill);
        else
            text.insert(0, width - text.size(), fill);
    }
    if (!buffer) {
        addState(c, ios, kBadBit);
        return;
    }
    {
        std::lock_guard guard(filesLock);
        if (auto it = files.find(buffer); it != files.end()) {
            if (std::fwrite(text.data(), 1, text.size(), it->second) != text.size()) addState(c, ios, kBadBit);
            return;
        }
    }
    GuestAddr copy = c.heap.alloc(uint32_t(text.size()) + 1);
    c.mem.copyIn(copy, text.data(), text.size());
    if (putBytes(c, buffer, copy, uint32_t(text.size())) != text.size()) addState(c, ios, kBadBit);
    c.heap.free(copy);
}

std::string formatInteger(uint32_t flags, long long value, bool isSigned) {
    char text[64];
    const char *prefix = flags & kShowBase ? (flags & kHex ? (flags & kUpper ? "0X" : "0x") : (flags & kOct ? "0" : "")) : "";
    if (flags & kHex)
        std::snprintf(text, sizeof text, flags & kUpper ? "%s%llX" : "%s%llx", prefix, (unsigned long long)uint32_t(value));
    else if (flags & kOct)
        std::snprintf(text, sizeof text, "%s%llo", prefix, (unsigned long long)uint32_t(value));
    else if (isSigned)
        std::snprintf(text, sizeof text, flags & kShowPos ? "%+lld" : "%lld", value);
    else
        std::snprintf(text, sizeof text, "%llu", (unsigned long long)value);
    return text;
}

std::string formatDouble(uint32_t flags, int precision, double value) {
    std::string format = "%";
    if (flags & kShowPos) format += '+';
    if (flags & kShowPoint) format += '#';
    format += ".*";
    if ((flags & (kFixed | kScientific)) == (kFixed | kScientific)) format += flags & kUpper ? 'A' : 'a';
    else if (flags & kFixed) format += 'f';
    else if (flags & kScientific) format += flags & kUpper ? 'E' : 'e';
    else format += flags & kUpper ? 'G' : 'g';
    char text[512];
    std::snprintf(text, sizeof text, format.c_str(), precision, value);
    return text;
}

void initIos(Call &c, GuestAddr ios, GuestAddr buffer) {
    c.mem.write<uint32_t>(ios + kPrecision, 6);
    c.mem.write<uint32_t>(ios + kWidth, 0);
    c.mem.write<uint32_t>(ios + kFlags, kSkipWs | kDec);
    c.mem.write<uint32_t>(ios + kExceptions, 0);
    c.mem.write<uint32_t>(ios + kState, buffer ? kGoodBit : kBadBit);
    c.mem.write<uint32_t>(ios + 112, 0);
    c.mem.write<uint8_t>(ios + kFill, ' ');
    c.mem.write<uint8_t>(ios + kFillInit, 1);
    c.mem.write<uint32_t>(ios + kStreambuf, buffer);
}
}  // namespace

// --- ios_base and locale ----------------------------------------------------------------

B32_THUNK(__ZNSt8ios_baseC2Ev) {
    GuestAddr self = c.args.ptr();
    std::memset(c.mem.ptr<uint8_t>(self + 4), 0, kIosEnd - 4 - 24);
}
B32_THUNK(__ZNSt8ios_baseD2Ev) {}
B32_THUNK(__ZNSt6localeC1Ev) { c.mem.write<uint32_t>(c.args.ptr(), 0); }
B32_THUNK(__ZNSt6localeD1Ev) {}
B32_THUNK(__ZNSt9basic_iosIcSt11char_traitsIcEE4initEPSt15basic_streambufIcS1_E) {
    GuestAddr ios = c.args.ptr();
    initIos(c, ios, c.args.ptr());
}
B32_THUNK(__ZNSt9basic_iosIcSt11char_traitsIcEE5clearESt12_Ios_Iostate) {
    GuestAddr ios = c.args.ptr();
    uint32_t state = c.args.u32();
    if (!c.mem.read<uint32_t>(ios + kStreambuf)) state |= kBadBit;
    c.mem.write<uint32_t>(ios + kState, state);
}
B32_THUNK(__ZNKSt9basic_iosIcSt11char_traitsIcEE5widenEc) {
    c.args.ptr();
    c.ret(c.args.u32() & 0xff);
}

// --- basic_streambuf's default virtuals: the put and get areas, then overflow and uflow ------

B32_THUNK(__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsputnEPKci) {
    GuestAddr self = c.args.ptr(), text = c.args.ptr();
    uint32_t n = c.args.u32(), done = 0;
    while (done < n) {
        GuestAddr cur = c.mem.read<uint32_t>(self + kOutCur), end = c.mem.read<uint32_t>(self + kOutEnd);
        uint32_t room = end > cur ? end - cur : 0;
        if (room) {
            uint32_t chunk = std::min(room, n - done);
            std::memmove(c.mem.ptr<char>(cur), c.mem.ptr<char>(text + done), chunk);
            c.mem.write<uint32_t>(self + kOutCur, cur + chunk);
            done += chunk;
        }
        if (done < n) {
            uint32_t ch = c.mem.read<uint8_t>(text + done);
            if (int32_t(c.cpu.call(virtualOf(c, self, kSlotOverflow), {self, ch})) == -1) break;
            done++;
        }
    }
    c.ret(done);
}
B32_THUNK(__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsgetnEPci) {
    GuestAddr self = c.args.ptr(), out = c.args.ptr();
    uint32_t n = c.args.u32(), done = 0;
    while (done < n) {
        GuestAddr cur = c.mem.read<uint32_t>(self + kInCur), end = c.mem.read<uint32_t>(self + kInEnd);
        uint32_t left = end > cur ? end - cur : 0;
        if (left) {
            uint32_t chunk = std::min(left, n - done);
            std::memmove(c.mem.ptr<char>(out + done), c.mem.ptr<char>(cur), chunk);
            c.mem.write<uint32_t>(self + kInCur, cur + chunk);
            done += chunk;
        }
        if (done < n) {
            int32_t ch = int32_t(c.cpu.call(virtualOf(c, self, kSlotUflow), {self}));
            if (ch == -1) break;
            c.mem.write<uint8_t>(out + done, uint8_t(ch));
            done++;
        }
    }
    c.ret(done);
}
B32_THUNK(__ZNSt15basic_streambufIcSt11char_traitsIcEE5uflowEv) {
    GuestAddr self = c.args.ptr();
    int32_t ch = int32_t(c.cpu.call(virtualOf(c, self, kSlotUnderflow), {self}));
    if (ch == -1) {
        c.ret(uint32_t(-1));
        return;
    }
    GuestAddr cur = c.mem.read<uint32_t>(self + kInCur);
    c.mem.write<uint32_t>(self + kInCur, cur + 1);
    c.ret(c.mem.read<uint8_t>(cur));
}
B32_THUNK(__ZNSt15basic_streambufIcSt11char_traitsIcEE4syncEv) { c.ret(0); }
B32_THUNK(__ZNSt15basic_streambufIcSt11char_traitsIcEE5imbueERKSt6locale) {}

// void basic_stringbuf::_M_sync(char *base, size_t get, size_t put): the get and
// put areas over the string's buffer.
B32_THUNK(__ZNSt15basic_stringbufIcSt11char_traitsIcESaIcEE7_M_syncEPcmm) {
    GuestAddr self = c.args.ptr(), base = c.args.ptr();
    uint32_t get = c.args.u32(), put = c.args.u32();
    uint32_t mode = c.mem.read<uint32_t>(self + kBufMode);
    GuestAddr data = c.mem.read<uint32_t>(self + kBufString);
    GuestAddr endGet = base + c.mem.read<uint32_t>(data - 12), endPut = base + c.mem.read<uint32_t>(data - 8);
    if (base != data) {
        endGet += get;
        get = 0;
        endPut = endGet;
    }
    if (mode & kModeIn) {
        c.mem.write<uint32_t>(self + kInBeg, base);
        c.mem.write<uint32_t>(self + kInCur, base + get);
        c.mem.write<uint32_t>(self + kInEnd, endGet);
    }
    if (mode & kModeOut) {
        c.mem.write<uint32_t>(self + kOutBeg, base);
        c.mem.write<uint32_t>(self + kOutCur, base + put);
        c.mem.write<uint32_t>(self + kOutEnd, endPut);
        if (!(mode & kModeIn)) {
            c.mem.write<uint32_t>(self + kInBeg, endGet);
            c.mem.write<uint32_t>(self + kInCur, endGet);
            c.mem.write<uint32_t>(self + kInEnd, endGet);
        }
    }
}

// --- ostream ---------------------------------------------------------------------------

// ostream &__ostream_insert(ostream &, const char *, int)
B32_THUNK(__ZSt16__ostream_insertIcSt11char_traitsIcEERSt13basic_ostreamIT_T0_ES6_PKS3_i) {
    GuestAddr stream = c.args.ptr(), text = c.args.ptr();
    insert(c, stream, std::string(c.mem.ptr<char>(text), c.args.u32()));
    c.ret(stream);
}
B32_THUNK(__ZStlsISt11char_traitsIcEERSt13basic_ostreamIcT_ES5_PKc) {
    GuestAddr stream = c.args.ptr(), text = c.args.ptr();
    if (text)
        insert(c, stream, c.mem.cstr(text));
    else
        addState(c, iosOf(c, stream), kBadBit);
    c.ret(stream);
}
B32_THUNK(__ZNSo5writeEPKci) {
    GuestAddr stream = c.args.ptr(), text = c.args.ptr();
    GuestAddr ios = iosOf(c, stream);
    uint32_t width = c.mem.read<uint32_t>(ios + kWidth);
    c.mem.write<uint32_t>(ios + kWidth, 0);
    insert(c, stream, std::string(c.mem.ptr<char>(text), c.args.u32()));
    c.mem.write<uint32_t>(ios + kWidth, width);
    c.ret(stream);
}
B32_THUNK(__ZNSolsEi) {
    GuestAddr stream = c.args.ptr();
    int32_t value = c.args.i32();
    insert(c, stream, formatInteger(c.mem.read<uint32_t>(iosOf(c, stream) + kFlags), value, true));
    c.ret(stream);
}
B32_THUNK(__ZNSo9_M_insertImEERSoT_) {
    GuestAddr stream = c.args.ptr();
    uint32_t value = c.args.u32();
    insert(c, stream, formatInteger(c.mem.read<uint32_t>(iosOf(c, stream) + kFlags), value, false));
    c.ret(stream);
}
B32_THUNK(__ZNSo9_M_insertIdEERSoT_) {
    GuestAddr stream = c.args.ptr();
    double value = c.args.f64();
    GuestAddr ios = iosOf(c, stream);
    insert(c, stream, formatDouble(c.mem.read<uint32_t>(ios + kFlags), c.mem.read<int32_t>(ios + kPrecision), value));
    c.ret(stream);
}

// --- fstream: a vtable only so guest code can find the virtual base ---------------------

namespace {
// An fstream is iostream (vptr, gcount, ostream's vptr), filebuf, then ios.
constexpr uint32_t kFstreamBuffer = 12, kFstreamIos = kFstreamBuffer + kFilebufSize;

GuestAddr fstreamVtable(Call &c) {
    static GuestAddr table = 0;
    static std::mutex lock;
    std::lock_guard guard(lock);
    if (!table) {
        table = c.heap.calloc(8, 4);
        c.mem.write<int32_t>(table, kFstreamIos);       // basic_iostream's istream part
        c.mem.write<int32_t>(table + 16, kFstreamIos - 8);  // its ostream part
    }
    return table;
}

std::string fopenMode(uint32_t mode) {
    const uint32_t kApp = 1, kBinary = 4, kTrunc = 32;
    std::string text;
    bool in = mode & kModeIn, out = mode & kModeOut;
    if (mode & kApp) text = in ? "a+" : "a";
    else if (in && out) text = mode & kTrunc ? "w+" : "r+";
    else if (out) text = "w";
    else text = "r";
    if (mode & kBinary) text += "b";
    return text;
}

bool openFile(Call &c, GuestAddr buffer, const char *path, uint32_t mode) {
    const uint32_t kAtEnd = 2;
    FILE *file = std::fopen(path, fopenMode(mode).c_str());
    if (!file) return false;
    if (mode & kAtEnd) ::fseeko(file, 0, SEEK_END);
    std::lock_guard guard(filesLock);
    if (auto it = files.find(buffer); it != files.end()) std::fclose(it->second);
    files[buffer] = file;
    return true;
}
void closeFile(GuestAddr buffer) {
    std::lock_guard guard(filesLock);
    if (auto it = files.find(buffer); it != files.end()) {
        std::fclose(it->second);
        files.erase(it);
    }
}
FILE *fileOf(GuestAddr buffer) {
    std::lock_guard guard(filesLock);
    auto it = files.find(buffer);
    return it == files.end() ? nullptr : it->second;
}
}  // namespace

B32_THUNK(__ZNSt13basic_fstreamIcSt11char_traitsIcEEC1Ev) {
    GuestAddr self = c.args.ptr();
    GuestAddr table = fstreamVtable(c);
    c.mem.write<uint32_t>(self, table + 12);
    c.mem.write<uint32_t>(self + kGcount, 0);
    c.mem.write<uint32_t>(self + 8, table + 28);
    std::memset(c.mem.ptr<uint8_t>(self + kFstreamIos), 0, kIosEnd);
    initIos(c, self + kFstreamIos, self + kFstreamBuffer);
    c.ret(self);
}
B32_THUNK(__ZNSt13basic_fstreamIcSt11char_traitsIcEED1Ev) {
    GuestAddr self = c.args.ptr();
    closeFile(self + kFstreamBuffer);
    c.ret(self);
}
B32_THUNK(__ZNSt13basic_fstreamIcSt11char_traitsIcEE4openEPKcSt13_Ios_Openmode) {
    GuestAddr self = c.args.ptr();
    const char *path = c.mem.cstr(c.args.ptr());
    uint32_t mode = c.args.u32();
    GuestAddr ios = self + kFstreamIos;
    c.mem.write<uint32_t>(ios + kState, openFile(c, self + kFstreamBuffer, path, mode) ? kGoodBit : kFailBit);
}
B32_THUNK(__ZNSt13basic_fstreamIcSt11char_traitsIcEE5closeEv) { closeFile(c.args.ptr() + kFstreamBuffer); }
B32_THUNK(__ZNSt13basic_fstreamIcSt11char_traitsIcEE7is_openEv) { c.ret(fileOf(c.args.ptr() + kFstreamBuffer) ? 1 : 0); }

// istream &read(char *, streamsize), on a file stream.
B32_THUNK(__ZNSi4readEPci) {
    GuestAddr stream = c.args.ptr(), out = c.args.ptr();
    uint32_t n = c.args.u32();
    GuestAddr ios = iosOf(c, stream), buffer = c.mem.read<uint32_t>(ios + kStreambuf);
    uint32_t got = 0;
    if (FILE *file = fileOf(buffer))
        got = uint32_t(std::fread(c.mem.ptr<char>(out), 1, n, file));
    else if (buffer)
        got = uint32_t(c.cpu.call(virtualOf(c, buffer, kSlotXsgetn), {buffer, out, n}));
    c.mem.write<uint32_t>(stream + kGcount, got);
    if (got < n) addState(c, ios, kEofBit | kFailBit);
    c.ret(stream);
}
// istream &seekg(streamoff, ios_base::seekdir)
B32_THUNK(__ZNSi5seekgExSt12_Ios_Seekdir) {
    GuestAddr stream = c.args.ptr();
    int64_t offset = int64_t(c.args.u64());
    uint32_t direction = c.args.u32();  // beg 0, cur 1, end 2: as SEEK_SET and friends
    GuestAddr ios = iosOf(c, stream);
    FILE *file = fileOf(c.mem.read<uint32_t>(ios + kStreambuf));
    if (!file || ::fseeko(file, offset, int(direction)) != 0) addState(c, ios, kFailBit);
    c.ret(stream);
}
// streampos tellg(): an fpos, 8 bytes of offset and the mbstate after, through a hidden pointer.
B32_THUNK(__ZNSi5tellgEv) {
    GuestAddr out = c.args.ptr(), stream = c.args.ptr();
    FILE *file = fileOf(bufferOf(c, stream));
    c.mem.write<int64_t>(out, file ? int64_t(::ftello(file)) : -1);
    c.ret(out);
    c.cpu.popStructPointer();
}

// --- std::list, the destructors of bases guests build, and an error --------------------

B32_THUNK(__ZNSt15_List_node_base4swapERS_S0_) {
    GuestAddr a = c.args.ptr(), b = c.args.ptr();
    auto next = [&](GuestAddr n) { return c.mem.read<uint32_t>(n); };
    auto prev = [&](GuestAddr n) { return c.mem.read<uint32_t>(n + 4); };
    auto setNext = [&](GuestAddr n, GuestAddr v) { c.mem.write<uint32_t>(n, v); };
    auto setPrev = [&](GuestAddr n, GuestAddr v) { c.mem.write<uint32_t>(n + 4, v); };
    bool aFull = next(a) != a, bFull = next(b) != b;
    GuestAddr an = next(a), ap = prev(a), bn = next(b), bp = prev(b);
    if (bFull) {
        setNext(a, bn);
        setPrev(a, bp);
        setPrev(bn, a);
        setNext(bp, a);
    } else {
        setNext(a, a);
        setPrev(a, a);
    }
    if (aFull) {
        setNext(b, an);
        setPrev(b, ap);
        setPrev(an, b);
        setNext(ap, b);
    } else {
        setNext(b, b);
        setPrev(b, b);
    }
}
// void _List_node_base::transfer(first, last): moves [first, last) before this.
B32_THUNK(__ZNSt15_List_node_base8transferEPS_S0_) {
    GuestAddr self = c.args.ptr(), first = c.args.ptr(), last = c.args.ptr();
    if (self == last) return;
    GuestAddr lastPrev = c.mem.read<uint32_t>(last + 4), firstPrev = c.mem.read<uint32_t>(first + 4);
    GuestAddr selfPrev = c.mem.read<uint32_t>(self + 4);
    c.mem.write<uint32_t>(lastPrev, self);
    c.mem.write<uint32_t>(firstPrev, last);
    c.mem.write<uint32_t>(selfPrev, first);
    c.mem.write<uint32_t>(last + 4, firstPrev);
    c.mem.write<uint32_t>(first + 4, selfPrev);
    c.mem.write<uint32_t>(self + 4, lastPrev);
}

#define B32_RETURNS_THIS(symbol) B32_THUNK(symbol) { c.ret(c.args.ptr()); }
B32_RETURNS_THIS(__ZNSdD0Ev)
B32_RETURNS_THIS(__ZNSdD1Ev)
B32_RETURNS_THIS(__ZNSiD0Ev)
B32_RETURNS_THIS(__ZNSiD1Ev)
B32_RETURNS_THIS(__ZNSoD0Ev)
B32_RETURNS_THIS(__ZNSoD1Ev)
B32_RETURNS_THIS(__ZThn8_NSdD0Ev)
B32_RETURNS_THIS(__ZThn8_NSdD1Ev)
B32_RETURNS_THIS(__ZTv0_n12_NSdD0Ev)
B32_RETURNS_THIS(__ZTv0_n12_NSdD1Ev)
B32_RETURNS_THIS(__ZTv0_n12_NSiD0Ev)
B32_RETURNS_THIS(__ZTv0_n12_NSiD1Ev)
B32_RETURNS_THIS(__ZTv0_n12_NSoD0Ev)
B32_RETURNS_THIS(__ZTv0_n12_NSoD1Ev)

B32_THUNK(__ZSt19__throw_logic_errorPKc) { fatal("guest threw std::logic_error: %s", c.mem.cstr(c.args.ptr())); }

// basic_stringbuf's own vtable, for a stream built from the library's rather
// than from a copy the guest instantiated. Writing grows the string as the
// real one does; the put area is the string's buffer, which guest inline
// str() reads directly.
B32_THUNK(__b32_stringbuf_overflow) {
    GuestAddr self = c.args.ptr();
    int32_t ch = c.args.i32();
    constexpr int32_t kEof = -1;
    if (ch == kEof) {
        c.ret(0);
        return;
    }
    if (!(c.mem.read<uint32_t>(self + kBufMode) & kModeOut)) {
        c.ret(uint32_t(kEof));
        return;
    }
    GuestAddr cur = c.mem.read<uint32_t>(self + kOutCur), end = c.mem.read<uint32_t>(self + kOutEnd);
    if (cur >= end) {
        GuestAddr old = c.mem.read<uint32_t>(self + kBufString), base = c.mem.read<uint32_t>(self + kOutBeg);
        uint32_t used = cur - base, capacity = std::max(c.mem.read<uint32_t>(old - 8) * 2, 512u);
        GuestAddr rep = c.heap.alloc(12 + capacity + 1), data = rep + 12;
        c.mem.write<uint32_t>(rep, used);
        c.mem.write<uint32_t>(rep + 4, capacity);
        c.mem.write<int32_t>(rep + 8, 0);
        if (used) c.mem.copyIn(data, c.mem.ptr<char>(base), used);
        c.mem.write<uint8_t>(data + used, 0);
        c.mem.write<uint32_t>(self + kBufString, data);
        c.mem.write<uint32_t>(self + kOutBeg, data);
        c.mem.write<uint32_t>(self + kOutEnd, data + capacity);
        cur = data + used;
        if (old != c.rt.dataSymbol("__ZNSs4_Rep20_S_empty_rep_storageE") + 12) {
            auto *refcount = c.mem.ptr<int32_t>(old - 4);
            if (__atomic_fetch_sub(refcount, 1, __ATOMIC_ACQ_REL) <= 0) c.heap.free(old - 12);
        }
    }
    c.mem.write<uint8_t>(cur, uint8_t(ch));
    c.mem.write<uint32_t>(self + kOutCur, cur + 1);
    c.ret(uint32_t(ch) & 0xff);
}
B32_THUNK(__b32_stringbuf_underflow) {
    GuestAddr self = c.args.ptr();
    GuestAddr cur = c.mem.read<uint32_t>(self + kInCur), end = c.mem.read<uint32_t>(self + kInEnd);
    c.ret(cur < end ? c.mem.read<uint8_t>(cur) : uint32_t(-1));
}
B32_THUNK(__b32_returns_this) { c.ret(c.args.ptr()); }
B32_THUNK(__b32_returns_eof) { c.ret(uint32_t(-1)); }
B32_THUNK(__b32_returns_zero) { c.ret(0); }

// { offset to top, typeinfo, then the slots of basic_streambuf }.
B32_DATA(__ZTVSt15basic_stringbufIcSt11char_traitsIcESaIcEE, 64) {
    static const char *const kSlots[] = {
        "__b32_returns_this",                                        // complete destructor
        "__b32_returns_this",                                        // deleting destructor
        "__ZNSt15basic_streambufIcSt11char_traitsIcEE5imbueERKSt6locale",
        "__b32_returns_this",                                        // setbuf
        "__b32_returns_eof",                                         // seekoff
        "__b32_returns_eof",                                         // seekpos
        "__ZNSt15basic_streambufIcSt11char_traitsIcEE4syncEv",
        "__b32_returns_zero",                                        // showmanyc
        "__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsgetnEPci",
        "__b32_stringbuf_underflow",
        "__ZNSt15basic_streambufIcSt11char_traitsIcEE5uflowEv",
        "__b32_returns_eof",                                         // pbackfail
        "__ZNSt15basic_streambufIcSt11char_traitsIcEE6xsputnEPKci",
        "__b32_stringbuf_overflow",
    };
    for (uint32_t i = 0; i < sizeof kSlots / sizeof kSlots[0]; i++)
        rt.mem().write<uint32_t>(addr + 8 + i * 4, rt.thunks().stubFor(kSlots[i]));
}

// The library's vtables that guest inline code stores while building an
// object it finishes itself. Nothing calls through these in the base state.
// basic_ostringstream: the stream's vptr, its stringbuf, then the virtual ios,
// 44 bytes in. Guest inline code builds one from these: the VTT's entries are
// vtable pointers, and all it reads through them is that offset (vptr[-3]).
namespace {
constexpr uint32_t kOstringstreamIos = 44;
}
B32_DATA(__ZTVSt19basic_ostringstreamIcSt11char_traitsIcESaIcEE, 64) { rt.mem().write<int32_t>(addr, kOstringstreamIos); }
B32_DATA(__ZTTSt19basic_ostringstreamIcSt11char_traitsIcESaIcEE, 16) {
    GuestAddr construction = rt.heap().calloc(16, 4);
    rt.mem().write<int32_t>(construction, kOstringstreamIos);
    GuestAddr vtable = rt.dataSymbol("__ZTVSt19basic_ostringstreamIcSt11char_traitsIcESaIcEE");
    rt.mem().write<uint32_t>(addr, vtable + 12);
    rt.mem().write<uint32_t>(addr + 4, construction + 12);
    rt.mem().write<uint32_t>(addr + 8, construction + 32);
    rt.mem().write<uint32_t>(addr + 12, vtable + 32);
}
B32_DATA(__ZTVSt9basic_iosIcSt11char_traitsIcEE, 64) {}
B32_DATA(__ZTVSt15basic_streambufIcSt11char_traitsIcEE, 64) {}
B32_DATA(__ZTVSt13basic_filebufIcSt11char_traitsIcEE, 64) {}
