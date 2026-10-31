#include "Log.h"

#include <cstdarg>

namespace b32 {

void log(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::fputs("[b32] ", stderr);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    va_end(args);
}

void fatal(const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::fputs("[b32] fatal: ", stderr);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    va_end(args);
    std::abort();
}

}  // namespace b32
