// ICU's regular expressions (libicucore's uregex_*), which Xcode 3's editor uses to color source.
//
// A guest regex is a handle for the host's; its pattern and text are copied out of guest memory
// (UTF-16 in the guest's byte order), and the copy of the text lives as long as ICU searches it.
// Status codes go in and out through the guest's UErrorCode, as ICU's functions take it.

#include "Thunks.h"

#include "core/Log.h"
#include "core/Runtime.h"

#include <unicode/uregex.h>

#include <mutex>
#include <string>
#include <unordered_map>

using namespace b32;

namespace {
struct GuestRegex {
    URegularExpression *host = nullptr;
    std::u16string text;
};
std::mutex regexesLock;
std::unordered_map<GuestAddr, GuestRegex *> regexes;

GuestRegex *regexAt(GuestAddr handle) {
    std::lock_guard guard(regexesLock);
    auto it = regexes.find(handle);
    return it == regexes.end() ? nullptr : it->second;
}

// UTF-16 from guest memory: `length` units, or up to a NUL for -1.
std::u16string guestUChars(Call &c, GuestAddr text, int32_t length) {
    std::u16string out;
    if (!text) return out;
    if (length < 0)
        for (GuestAddr p = text; uint16_t ch = c.mem.read<uint16_t>(p); p += 2) out += char16_t(ch);
    else
        for (int32_t i = 0; i < length; i++) out += char16_t(c.mem.read<uint16_t>(text + uint32_t(i) * 2));
    return out;
}

// The guest's UErrorCode in and out around a call.
struct Status {
    Call &c;
    GuestAddr guest;
    UErrorCode code;
    Status(Call &c, GuestAddr guest) : c(c), guest(guest), code(guest ? UErrorCode(c.mem.read<int32_t>(guest)) : U_ZERO_ERROR) {}
    ~Status() {
        if (guest) c.mem.write<int32_t>(guest, int32_t(code));
    }
};
}  // namespace

// URegularExpression *uregex_open(const UChar *pattern, int32_t patternLength, uint32_t flags,
//     UParseError *pe, UErrorCode *status)
B32_THUNK(_uregex_open) {
    GuestAddr pattern = c.args.ptr();
    int32_t length = c.args.i32();
    uint32_t flags = c.args.u32();
    GuestAddr parseError = c.args.ptr();
    Status status(c, c.args.ptr());
    if (U_FAILURE(status.code)) return c.ret(0);
    std::u16string text = guestUChars(c, pattern, length);
    UParseError pe{};
    URegularExpression *re = uregex_open(reinterpret_cast<const UChar *>(text.data()), int32_t(text.size()), flags, &pe,
                                         &status.code);
    if (parseError) {  // { int32_t line, offset; UChar preContext[16], postContext[16]; }
        c.mem.write<int32_t>(parseError, pe.line);
        c.mem.write<int32_t>(parseError + 4, pe.offset);
        for (int i = 0; i < U_PARSE_CONTEXT_LEN; i++) {
            c.mem.write<uint16_t>(parseError + 8 + uint32_t(i) * 2, pe.preContext[i]);
            c.mem.write<uint16_t>(parseError + 40 + uint32_t(i) * 2, pe.postContext[i]);
        }
    }
    if (!re) return c.ret(0);
    GuestAddr handle = c.heap.calloc(1, 4);
    std::lock_guard guard(regexesLock);
    regexes[handle] = new GuestRegex{re, {}};
    c.ret(handle);
}

B32_THUNK(_uregex_close) {
    GuestAddr handle = c.args.ptr();
    GuestRegex *r;
    {
        std::lock_guard guard(regexesLock);
        auto it = regexes.find(handle);
        if (it == regexes.end()) return;
        r = it->second;
        regexes.erase(it);
    }
    uregex_close(r->host);
    delete r;
    c.heap.free(handle);
}

// void uregex_setText(URegularExpression *, const UChar *text, int32_t textLength, UErrorCode *)
B32_THUNK(_uregex_setText) {
    GuestRegex *r = regexAt(c.args.ptr());
    GuestAddr text = c.args.ptr();
    int32_t length = c.args.i32();
    Status status(c, c.args.ptr());
    if (!r) {
        status.code = U_ILLEGAL_ARGUMENT_ERROR;
        return;
    }
    r->text = guestUChars(c, text, length);
    uregex_setText(r->host, reinterpret_cast<const UChar *>(r->text.data()), int32_t(r->text.size()), &status.code);
}

// UBool uregex_find(URegularExpression *, int32_t startIndex, UErrorCode *)
B32_THUNK(_uregex_find) {
    GuestRegex *r = regexAt(c.args.ptr());
    int32_t start = c.args.i32();
    Status status(c, c.args.ptr());
    c.ret(r ? uregex_find(r->host, start, &status.code) : 0);
}

// int32_t uregex_start / uregex_end(URegularExpression *, int32_t groupNum, UErrorCode *)
B32_THUNK(_uregex_start) {
    GuestRegex *r = regexAt(c.args.ptr());
    int32_t group = c.args.i32();
    Status status(c, c.args.ptr());
    c.ret(uint32_t(r ? uregex_start(r->host, group, &status.code) : -1));
}
B32_THUNK(_uregex_end) {
    GuestRegex *r = regexAt(c.args.ptr());
    int32_t group = c.args.i32();
    Status status(c, c.args.ptr());
    c.ret(uint32_t(r ? uregex_end(r->host, group, &status.code) : -1));
}

// void uregex_reset(URegularExpression *, int32_t index, UErrorCode *)
B32_THUNK(_uregex_reset) {
    GuestRegex *r = regexAt(c.args.ptr());
    int32_t index = c.args.i32();
    Status status(c, c.args.ptr());
    if (r) uregex_reset(r->host, index, &status.code);
}

// int32_t uregex_groupCount(URegularExpression *, UErrorCode *)
B32_THUNK(_uregex_groupCount) {
    GuestRegex *r = regexAt(c.args.ptr());
    Status status(c, c.args.ptr());
    c.ret(uint32_t(r ? uregex_groupCount(r->host, &status.code) : 0));
}

// const char *u_errorName(UErrorCode)
B32_THUNK(_u_errorName) { c.ret(c.rt.internString(u_errorName(UErrorCode(c.args.i32())))); }
