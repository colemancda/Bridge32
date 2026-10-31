// Table-driven thunks for plain C APIs (OpenGL ES, OpenAL): each function is a
// name plus a signature string "<ret>:<args>", converted generically and
// called through libffi. Codes:
//   v  void (return only)
//   i  32-bit signed (GLint, ALint, GLfixed, GLshort; GLenum returns too)
//   u  32-bit unsigned (GLenum, GLuint, GLbitfield, GLboolean, GLubyte)
//   f  float
//   z  pointer-sized integer (GLintptr, GLsizeiptr): 32-bit guest, 64-bit host
//   p  pointer into guest memory (passed through without copying)
//   a  vertex array pointer, or an offset when an array buffer is bound
//   e  index pointer, or an offset when an element array buffer is bound
//   o  CF or ObjC object, converted by the bridge (CF types are toll-free
//      ObjC objects on the host)
//   d  double: two words in the guest
//   h  opaque host pointer (ALCdevice *, ALCcontext *), a small handle in the guest
//   S  array of guest C string pointers, as many as the previous argument says
//      (glShaderSource)
//   B  boolean (return only)
//   s  C string (return only), copied into guest memory once per first argument
#pragma once

#include "Thunks.h"

#include <cstddef>

namespace b32 {

struct CFunction {
    const char *name;
    const char *sig;
};

using LibraryLoader = void *(*)();

// Registers every function as the import "_<name>", resolved from the
// library on first call.
void registerCFunctions(const CFunction *functions, size_t count, LibraryLoader library);

// Whether a buffer is bound for 'a' (array) or 'e' (element) pointers;
// installed by the GL module.
using BufferBoundQuery = bool (*)(char code);
void setBufferBoundQuery(BufferBoundQuery query);

// The guest handles behind 'h': opaque host pointers as small integers.
uint32_t hostHandle(void *pointer);
void *hostPointer(uint32_t handle);
void forgetHostHandle(void *pointer);

// For an `extern NSString *const` (or other object constant) the host
// exports: the guest variable holds the guest proxy of the host's value.
void objcConstant(class Runtime &rt, GuestAddr addr, const char *name);

}  // namespace b32

#define B32_C_FUNCTIONS(table, loader)                                                     \
    static int B32_CTABLE_CONCAT(ctable_registration_, __LINE__) =                        \
        (::b32::registerCFunctions(table, sizeof(table) / sizeof(table[0]), loader), 0)
#define B32_CTABLE_CONCAT2(a, b) a##b
#define B32_CTABLE_CONCAT(a, b) B32_CTABLE_CONCAT2(a, b)

// The library defining the constant must already be loaded.
#define B32_OBJC_CONSTANT(name) \
    B32_DATA(_##name, 4) { ::b32::objcConstant(rt, addr, #name); }
