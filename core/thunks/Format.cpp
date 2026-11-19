#include "Format.h"

#include "core/Log.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace b32 {

namespace {
void appendCodePoint(std::string &out, uint32_t cp) {
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

// Appends UTF-16 text as UTF-8 (unpaired surrogates become U+FFFD).
void appendUTF16(std::string &out, const std::u16string &text) {
    for (size_t i = 0; i < text.size(); i++) {
        uint32_t cp = text[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < text.size() && text[i + 1] >= 0xDC00 && text[i + 1] <= 0xDFFF)
            cp = 0x10000 + ((cp - 0xD800) << 10) + (text[++i] - 0xDC00);
        else if (cp >= 0xD800 && cp <= 0xDFFF)
            cp = 0xFFFD;
        appendCodePoint(out, cp);
    }
}
}  // namespace

std::string wideToUTF8(const std::wstring &text) {
    std::string out;
    for (wchar_t ch : text) appendCodePoint(out, uint32_t(ch));
    return out;
}

std::wstring utf8ToWide(const std::string &text) {
    std::wstring out;
    for (size_t i = 0; i < text.size();) {
        unsigned char lead = static_cast<unsigned char>(text[i]);
        int extra = lead < 0x80 ? 0 : lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : lead >= 0xC0 ? 1 : 0;
        uint32_t cp = extra == 0 ? lead : lead & (0x3F >> extra);
        i++;
        for (int k = 0; k < extra && i < text.size(); k++, i++) cp = cp << 6 | (static_cast<unsigned char>(text[i]) & 0x3F);
        out.push_back(wchar_t(cp));
    }
    return out;
}

namespace {
// What a conversion takes from the arguments.
enum class ArgKind { Word, Wide, Double, LongDouble };

// "%3$@": the argument's 1-based position, with p past the '$'; 0 (p unmoved) for none.
int positionAt(const char *&p) {
    const char *q = p;
    int n = 0;
    while (*q >= '1' && *q <= '9' && n < 100) n = n * 10 + (*q++ - '0');
    while (n && *q >= '0' && *q <= '9') n = n * 10 + (*q++ - '0');
    if (!n || *q != '$') return 0;
    p = q + 1;
    return n;
}

// The kinds of a format's positional arguments, by position (index 0 unused), so they can be read in order
// before any is formatted; empty when the format numbers none.
std::vector<ArgKind> positionalKinds(const char *format) {
    std::vector<ArgKind> kinds;
    for (const char *p = format; *p;) {
        if (*p++ != '%') continue;
        if (*p == '%') {
            p++;
            continue;
        }
        int position = positionAt(p);
        if (!position) return {};
        while (*p && (std::strchr("-+ #0'.*", *p) || (*p >= '0' && *p <= '9'))) p++;
        ArgKind kind = ArgKind::Word;
        while (*p && std::strchr("hlqjztL", *p)) {
            if (*p == 'q' || *p == 'j' || (*p == 'l' && p[1] == 'l')) {
                kind = ArgKind::Wide;
                if (*p == 'l') p++;
            } else if (*p == 'L') {
                kind = ArgKind::LongDouble;
            }
            p++;
        }
        char conv = *p ? *p++ : '\0';
        if (std::strchr("fFeEgGaA", conv) && conv) kind = kind == ArgKind::LongDouble ? ArgKind::LongDouble : ArgKind::Double;
        else if (kind == ArgKind::LongDouble) kind = ArgKind::Word;
        if (kinds.size() <= size_t(position)) kinds.resize(size_t(position) + 1, ArgKind::Word);
        kinds[size_t(position)] = kind;
    }
    return kinds;
}
}  // namespace

std::string formatGuest(Call &c, const char *format, Args &args, ObjectDescriber describe) {
    args.beginVarArgs();

    // Numbered arguments ("%2$@ %1$@", as localized strings reorder them) are read in order first.
    using LongDouble = decltype(args.longDouble());
    struct Value {
        uint64_t bits = 0;
        double d = 0;
        LongDouble ld{};
    };
    std::vector<Value> numbered;
    std::vector<ArgKind> kinds = positionalKinds(format);
    for (size_t i = 1; i < kinds.size(); i++) {
        Value v;
        switch (kinds[i]) {
        case ArgKind::Word: v.bits = args.u32(); break;
        case ArgKind::Wide: v.bits = args.u64(); break;
        case ArgKind::Double: v.d = args.f64(); break;
        case ArgKind::LongDouble: v.ld = args.longDouble(); break;
        }
        numbered.push_back(v);
    }
    int position = 0;  // the conversion's argument, when numbered
    auto value = [&]() -> const Value & {
        static const Value none;
        return position >= 1 && size_t(position) <= numbered.size() ? numbered[size_t(position) - 1] : none;
    };
    auto u32 = [&]() -> uint32_t { return position ? uint32_t(value().bits) : args.u32(); };
    auto i32 = [&]() -> int32_t { return int32_t(u32()); };
    auto ptr = [&]() -> GuestAddr { return u32(); };
    auto u64 = [&]() -> uint64_t { return position ? value().bits : args.u64(); };
    auto f64 = [&]() -> double { return position ? value().d : args.f64(); };
    auto readLongDouble = [&]() -> LongDouble { return position ? value().ld : args.longDouble(); };

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
        position = numbered.empty() ? 0 : positionAt(p);

        // Rebuild the spec for the host's snprintf: flags, width, precision.
        std::string spec = "%";
        while (*p && std::strchr("-+ #0'", *p)) spec += *p++;
        auto number = [&] {
            if (*p == '*') {
                p++;
                spec += std::to_string(position ? 0 : i32());
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
        bool wideChars = false;  // %ls and %lc: a wchar_t string or character
        while (*p && std::strchr("hlqjztL", *p)) {
            if (*p == 'q' || (*p == 'l' && p[1] == 'l')) {
                wide = true;
                if (*p == 'l') p++;
            } else if (*p == 'l') {
                wideChars = true;
            } else if (*p == 'j') {
                wide = true;  // intmax_t is 64-bit
            } else if (*p == 'L') {
                longDouble = true;
            }
            p++;  // h, hh, l, z and t are all 32-bit on armv7
        }
        char conv = *p ? *p++ : '\0';

        switch (conv) {
        case 'c':
            if (wideChars) {  // a wint_t, as UTF-8
                std::string text;
                appendCodePoint(text, u32());
                out += text;
                break;
            }
            [[fallthrough]];
        case 'd': case 'i': case 'u': case 'o': case 'x': case 'X':
            if (wide) {
                std::snprintf(piece, sizeof piece, (spec + "ll" + conv).c_str(), (long long)u64());
            } else {
                std::snprintf(piece, sizeof piece, (spec + conv).c_str(), u32());
            }
            out += piece;
            break;
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': case 'a': case 'A':
            std::snprintf(piece, sizeof piece, (spec + conv).c_str(), longDouble ? readLongDouble() : f64());
            out += piece;
            break;
        case 's': {
            GuestAddr s = ptr();
            if (wideChars) {  // a wchar_t string, as UTF-8
                std::string host = !s ? "(null)" : wideToUTF8(c.mem.readWide(s));
                int n = std::snprintf(nullptr, 0, (spec + 's').c_str(), host.c_str());
                std::string tmp(size_t(n) + 1, '\0');
                std::snprintf(tmp.data(), tmp.size(), (spec + 's').c_str(), host.c_str());
                tmp.resize(size_t(n));
                out += tmp;
                break;
            }
            // A missing argument (KSCrash's "Could not stat %s: %s" passes one)
            // reads whatever word follows, which a device tolerates more often.
            const char *host = !s ? "(null)" : c.mem.isMapped(s) ? c.mem.cstr(s) : "(bad pointer)";
            int n = std::snprintf(nullptr, 0, (spec + 's').c_str(), host);
            std::string tmp(size_t(n) + 1, '\0');
            std::snprintf(tmp.data(), tmp.size(), (spec + 's').c_str(), host);
            tmp.resize(size_t(n));
            out += tmp;
            break;
        }
        case 'p':
            std::snprintf(piece, sizeof piece, (spec + "#x").c_str(), u32());
            out += piece;
            break;
        case 'C':  // a unichar (UTF-16 code unit), as UTF-8
            appendUTF16(out, [&] { uint16_t ch = uint16_t(u32()); return std::u16string(1, char16_t(ch)); }());
            break;
#if defined(B32_GUEST_MAC)
        case 'S': {  // on the Mac, a wchar_t string like %ls
            GuestAddr s = ptr();
            if (s) out += wideToUTF8(c.mem.readWide(s));
            break;
        }
#else
        case 'S': {  // a NUL-terminated unichar string
            GuestAddr s = ptr();
            std::u16string text;
            if (s)
                for (GuestAddr q = s; uint16_t ch = c.mem.read<uint16_t>(q); q += 2) text += char16_t(ch);
            appendUTF16(out, text);
            break;
        }
#endif
        case 'n': ptr(); break;  // never write back through %n
        case '@':
            if (!describe) fatal("%%@ in a C format string: %s", format);
            out += describe(c, ptr());
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
