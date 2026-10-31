#include "Format.h"

#include "core/Log.h"

#include <cstdio>
#include <cstring>
#include <string>

namespace b32 {

namespace {
// Appends UTF-16 text as UTF-8 (unpaired surrogates become U+FFFD).
void appendUTF16(std::string &out, const std::u16string &text) {
    for (size_t i = 0; i < text.size(); i++) {
        uint32_t cp = text[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < text.size() && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF)
            cp = 0x10000 + ((cp - 0xD800) << 10) + (text[++i] - 0xDC00);
        else if (cp >= 0xD800 && cp <= 0xDFFF)
            cp = 0xFFFD;
        if (cp < 0x80) {
            out += char(cp);
        } else if (cp < 0x800) {
            out += char(0xC0 | cp >> 6);
            out += char(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            out += char(0xE0 | cp >> 12);
            out += char(0x80 | ((cp >> 6) & 0x3F));
            out += char(0x80 | (cp & 0x3F));
        } else {
            out += char(0xF0 | cp >> 18);
            out += char(0x80 | ((cp >> 12) & 0x3F));
            out += char(0x80 | ((cp >> 6) & 0x3F));
            out += char(0x80 | (cp & 0x3F));
        }
    }
}
}  // namespace

std::string formatGuest(Call &c, const char *format, Args &args, ObjectDescriber describe) {
    std::string out;
    char piece[512];
    for (const char *p = format; *p;) {
        if (*p != '%') {
            out += *p++;
            continue;
        }
        const char *start = p++;
        if (*p == '%') {
            out += '%';
            p++;
            continue;
        }

        // Rebuild the spec for the host's snprintf: flags, width, precision.
        std::string spec = "%";
        while (*p && std::strchr("-+ #0'", *p)) spec += *p++;
        auto number = [&] {
            if (*p == '*') {
                p++;
                spec += std::to_string(args.i32());
                return;
            }
            while (*p >= '0' && *p <= '9') spec += *p++;
        };
        number();
        if (*p == '.') {
            spec += *p++;
            number();
        }

        // Length modifiers decide how many guest words the argument takes.
        bool wide = false;  // 64-bit integer
        bool longDouble = false;
        while (*p && std::strchr("hlqjztL", *p)) {
            if (*p == 'q' || (*p == 'l' && p[1] == 'l')) {
                wide = true;
                if (*p == 'l') p++;
            } else if (*p == 'j') {
                wide = true;  // intmax_t is 64-bit
            } else if (*p == 'L') {
                longDouble = true;  // long double is double on ARM
            }
            p++;  // h, hh, l, z and t are all 32-bit on armv7
        }
        char conv = *p ? *p++ : '\0';

        switch (conv) {
        case 'd': case 'i': case 'u': case 'o': case 'x': case 'X': case 'c':
            if (wide) {
                std::snprintf(piece, sizeof piece, (spec + "ll" + conv).c_str(), (long long)args.u64());
            } else {
                std::snprintf(piece, sizeof piece, (spec + conv).c_str(), args.u32());
            }
            out += piece;
            break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': case 'A':
            (void)longDouble;
            std::snprintf(piece, sizeof piece, (spec + conv).c_str(), args.f64());
            out += piece;
            break;
        case 's': {
            GuestAddr s = args.ptr();
            const char *host = s ? c.mem.cstr(s) : "(null)";
            int n = std::snprintf(nullptr, 0, (spec + 's').c_str(), host);
            std::string tmp(size_t(n) + 1, '\0');
            std::snprintf(tmp.data(), tmp.size(), (spec + 's').c_str(), host);
            tmp.resize(size_t(n));
            out += tmp;
            break;
        }
        case 'p':
            std::snprintf(piece, sizeof piece, (spec + "#x").c_str(), args.u32());
            out += piece;
            break;
        case 'C':  // a unichar (UTF-16 code unit), as UTF-8
            appendUTF16(out, [&] { uint16_t ch = uint16_t(args.u32()); return std::u16string(1, char16_t(ch)); }());
            break;
        case 'S': {  // a NUL-terminated unichar string
            GuestAddr s = args.ptr();
            std::u16string text;
            if (s)
                for (GuestAddr q = s; uint16_t ch = c.mem.read<uint16_t>(q); q += 2) text += char16_t(ch);
            appendUTF16(out, text);
            break;
        }
        case 'n': args.ptr(); break;  // never write back through %n
        case '@':
            if (!describe) fatal("%%@ in a C format string: %s", format);
            out += describe(c, args.ptr());
            break;
        default:
            log("unsupported printf conversion '%.*s'", int(p - start), start);
            out.append(start, size_t(p - start));
            break;
        }
    }
    return out;
}

}  // namespace b32
