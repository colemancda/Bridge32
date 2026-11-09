#include "Encoding.h"

#include "core/Log.h"
#include "core/arch/Arch.h"

#include <algorithm>
#include <cstring>
#include <deque>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

namespace b32::objc {

namespace {

// Structs whose double fields are CGFloat (float on 32-bit iOS).
bool isGeometryStruct(const std::string &name) {
    static const std::unordered_set<std::string> names = {
        "CGPoint", "CGSize", "CGRect", "CGVector", "CGAffineTransform", "UIEdgeInsets",
        "UIOffset", "NSDirectionalEdgeInsets", "CATransform3D",
    };
    return names.count(name) != 0;
}

// Fixes up the ambiguous codes inside a struct once its name is known.
void markStruct(Type &t) {
    bool geometry = isGeometryStruct(t.name);
    for (auto &f : t.fields) {
        if (geometry && f.code == 'd') f.cgfloat = true;
        if (f.isStruct()) markStruct(f);
    }
}

uint32_t roundUp(uint32_t v, uint32_t a) { return (v + a - 1) / a * a; }

// Bitfields (b<width>) carry no type, so each run of them in a struct
// becomes the unsigned ints holding it, as clang packs `unsigned x : n`
// fields; guest and host then lay the struct out alike.
void packBitfields(std::vector<Type> &fields) {
    std::vector<Type> packed;
    for (size_t i = 0; i < fields.size();) {
        if (fields[i].code != 'b') {
            packed.push_back(std::move(fields[i++]));
            continue;
        }
        uint32_t bits = 0;
        for (; i < fields.size() && fields[i].code == 'b'; i++) bits += fields[i].count;
        for (uint32_t word = 0; word < std::max<uint32_t>(roundUp(bits, 32) / 32, 1); word++) {
            packed.emplace_back();
            packed.back().code = 'I';
        }
    }
    fields = std::move(packed);
}

// Cache key for a struct or array's host layout.
std::string layoutKey(const Type &t) {
    std::string key(1, t.code);
    if (t.code == '[') key += std::to_string(t.count);
    for (const auto &f : t.fields) key += f.isStruct() || f.code == '[' ? layoutKey(f) : std::string(1, f.code);
    key += t.code == '{' ? '}' : t.code == '[' ? ']' : ' ';
    return key;
}

}  // namespace

Type parseType(const char *&p) {
    // Method type qualifiers (const, in, out, inout, bycopy, byref, oneway).
    while (*p && std::strchr("rnNoORV", *p)) p++;
    Type t;
    t.code = *p ? *p++ : 'v';
    switch (t.code) {
    case '{': {
        const char *nameEnd = p;
        while (*nameEnd && *nameEnd != '=' && *nameEnd != '}') nameEnd++;
        t.name.assign(p, nameEnd);
        p = nameEnd;
        if (*p == '=') {
            p++;
            while (*p && *p != '}') t.fields.push_back(parseType(p));
        }
        if (*p == '}') p++;
        packBitfields(t.fields);
        markStruct(t);
        break;
    }
    case '(': {  // unions: marshalled as their largest member
        while (*p && *p != '=' && *p != ')') p++;
        std::vector<Type> members;
        if (*p == '=') {
            p++;
            while (*p && *p != ')') members.push_back(parseType(p));
        }
        if (*p == ')') p++;
        if (!members.empty()) {
            t = *std::max_element(members.begin(), members.end(),
                                  [](const Type &a, const Type &b) { return a.guestSize() < b.guestSize(); });
        } else {
            t.code = 'v';
        }
        break;
    }
    case '[': {
        while (*p >= '0' && *p <= '9') t.count = t.count * 10 + uint32_t(*p++ - '0');
        if (*p == ']') {
            // clang encodes SIMD vectors (simd_float3, matrix columns) as
            // arrays with no element type: kept as opaque 16-byte elements,
            // the size of a 4-lane vector, so the signature still parses.
            Type lanes;
            lanes.code = '[';
            lanes.count = 16;
            lanes.fields.push_back(Type{});
            lanes.fields.back().code = 'C';
            t.fields.push_back(lanes);
        } else {
            t.fields.push_back(parseType(p));
        }
        if (*p == ']') p++;
        break;
    }
    case '^':
        t.pointee = std::make_shared<Type>(parseType(p));
        break;
    case '@':
        if (*p == '?') {  // block, with its own signature in <...> in extended encodings
            p++;
            if (*p == '<') {
                int depth = 0;
                do {
                    if (*p == '<') depth++;
                    else if (*p == '>') depth--;
                    p++;
                } while (*p && depth > 0);
            }
        } else if (*p == '"') {  // class name annotation
            p++;
            while (*p && *p != '"') p++;
            if (*p) p++;
        }
        break;
    case 'b':  // bitfield width, kept in count
        while (*p >= '0' && *p <= '9') t.count = t.count * 10 + uint32_t(*p++ - '0');
        break;
    default: break;
    }
    // Stack offsets that follow each type in method encodings.
    while (*p == '-' || (*p >= '0' && *p <= '9')) p++;
    return t;
}

Signature parseSignature(const char *encoding) {
    Signature sig;
    const char *p = encoding;
    sig.ret = parseType(p);
    while (*p) sig.args.push_back(parseType(p));
    return sig;
}

uint32_t Type::guestSize() const {
    switch (code) {
    case 'v': return 0;
    case 'c': case 'C': case 'B': return 1;
    case 's': case 'S': return 2;
    case 'i': case 'I': case 'l': case 'L': case 'f':
    case '@': case '#': case ':': case '*': case '^': case '?':
        return 4;
    case 'q': case 'Q': return wide ? 8 : 4;
    case 'd': return cgfloat ? 4 : 8;
    case '[': return count * fields[0].guestSize();
    case '{': {
        uint32_t size = 0, align = 1;
        for (const auto &f : fields) {
            size = roundUp(size, f.guestAlign()) + f.guestSize();
            align = std::max(align, f.guestAlign());
        }
        return roundUp(size, align);
    }
    default: fatal("no guest size for type encoding '%c'", code);
    }
}

uint32_t Type::guestAlign() const {
    if (code == '{') {
        uint32_t align = 1;
        for (const auto &f : fields) align = std::max(align, f.guestAlign());
        return align;
    }
    if (code == '[') return fields[0].guestAlign();
    // 8-byte types are only 4-byte aligned in the iOS 32-bit ABI.
    return std::min<uint32_t>(std::max<uint32_t>(guestSize(), 1), 4);
}

const Type *Type::singleFloatingField() const {
    if (code == 'f' || code == 'd') return this;
    if ((code == '{' && fields.size() == 1) || (code == '[' && count == 1)) return fields[0].singleFloatingField();
    return nullptr;
}

ReturnClass guestReturnClass(const Type &type) {
    if (type.isStruct() && arch::structReturnedInMemory(type.guestSize())) return ReturnClass::Memory;
    if (arch::kFloatResultsInFpu && type.singleFloatingField()) return ReturnClass::Floating;
    return ReturnClass::Integer;
}

size_t Type::hostSize() const { return ffiType(*this)->size; }
size_t Type::hostAlign() const { return ffiType(*this)->alignment; }

bool Type::sameLayout() const {
    switch (code) {
    case 'c': case 'C': case 'B': case 's': case 'S': case 'i': case 'I': case 'f': return true;
    case 'q': case 'Q': return wide;
    case 'd': return !cgfloat;
    case '[': return fields[0].sameLayout();
    case '{': {
        if (guestSize() != hostSize()) return false;
        return std::all_of(fields.begin(), fields.end(), [](const Type &f) { return f.sameLayout(); });
    }
    default: return false;  // pointers and objects are 4 vs 8 bytes
    }
}

ffi_type *ffiType(const Type &type) {
    switch (type.code) {
    case 'v': return &ffi_type_void;
    case 'c': return &ffi_type_sint8;
    case 'C': case 'B': return &ffi_type_uint8;
    case 's': return &ffi_type_sint16;
    case 'S': return &ffi_type_uint16;
    case 'i': return &ffi_type_sint32;
    case 'I': return &ffi_type_uint32;
    case 'l': return &ffi_type_slong;
    case 'L': return &ffi_type_ulong;
    case 'q': return &ffi_type_sint64;
    case 'Q': return &ffi_type_uint64;
    case 'f': return &ffi_type_float;
    case 'd': return &ffi_type_double;
    case '@': case '#': case ':': case '*': case '^': case '?': return &ffi_type_pointer;
    case '{':
    case '[': {
        // Struct and array descriptions are built once and kept forever.
        static std::recursive_mutex lock;
        static std::deque<ffi_type> types;
        static std::deque<std::vector<ffi_type *>> elementLists;
        static std::unordered_map<std::string, ffi_type *> cache;
        std::lock_guard guard(lock);
        std::string key = layoutKey(type);
        if (auto it = cache.find(key); it != cache.end()) return it->second;
        std::vector<ffi_type *> elements;
        if (type.code == '{')
            for (const auto &f : type.fields) elements.push_back(ffiType(f));
        else
            for (uint32_t i = 0; i < type.count; i++) elements.push_back(ffiType(type.fields[0]));
        elements.push_back(nullptr);
        elementLists.push_back(std::move(elements));
        ffi_type &t = types.emplace_back();
        t.size = 0;
        t.alignment = 0;
        t.type = FFI_TYPE_STRUCT;
        t.elements = elementLists.back().data();
        // Fill in size and alignment.
        ffi_cif cif;
        ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 0, &t, nullptr);
        cache.emplace(key, &t);
        return &t;
    }
    default: fatal("no host type for encoding '%c'", type.code);
    }
}

}  // namespace b32::objc
