// ObjC type encodings, laid out for both ABIs: the guest's 32-bit iOS armv6/
// armv7 one (4-byte pointers, 8-byte types 4-byte aligned) and the host's
// arm64 one. Encodings come from the host runtime, so the ambiguous host
// types are resolved to their 32-bit meaning here:
//  - 'q'/'Q' is NSInteger/NSUInteger (4 bytes) unless marked wide
//  - 'd' inside CoreGraphics/UIKit geometry structs is CGFloat (4 bytes)
//  - a top-level 'd' is a double unless marked as CGFloat
#pragma once

#include "core/mem/GuestMemory.h"

#include <ffi/ffi.h>

#include <memory>
#include <string>
#include <vector>

namespace b32::objc {

struct Type {
    char code = 'v';            // ObjC encoding character; '{' for structs, '[' for arrays
    std::string name;           // struct name
    std::vector<Type> fields;   // struct fields or the array element
    uint32_t count = 0;         // array length
    std::shared_ptr<Type> pointee;  // for '^'

    // Overrides for ambiguous host codes (set by the parser or callers).
    bool wide = false;       // 'q'/'Q' really is 64-bit in the guest
    bool cgfloat = false;    // 'd' is CGFloat, so a float in the guest

    uint32_t guestSize() const;
    uint32_t guestAlign() const;
    size_t hostSize() const;
    size_t hostAlign() const;
    bool isStruct() const { return code == '{'; }
    bool isObject() const { return code == '@' || code == '#'; }
    // The float or double this type is or wraps (a struct or one-element array
    // around just that), or null.
    const Type *singleFloatingField() const;
    // True when guest and host bytes are identical, so pointers to it can be
    // passed through without copying.
    bool sameLayout() const;
};

// Where the guest ABI puts a function's result of a given type.
enum class ReturnClass {
    Integer,   // the integer result registers (arm's soft-float values too)
    Memory,    // through a hidden pointer in the first argument word
    Floating,  // the FPU (x87's ST(0))
};
ReturnClass guestReturnClass(const Type &type);

struct Signature {
    Type ret;
    std::vector<Type> args;  // including self and _cmd for methods
};

// Parses one type at `p` and advances past it (and past any offset digits).
Type parseType(const char *&p);
Signature parseSignature(const char *encoding);

// libffi description of a host type. The returned pointers live as long as
// the process (they're cached per encoding).
ffi_type *ffiType(const Type &type);

}  // namespace b32::objc
