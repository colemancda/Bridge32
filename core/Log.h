#pragma once

#include <cstdio>
#include <cstdlib>

namespace b32 {

#define B32_PRINTF(fmt, args) __attribute__((format(printf, fmt, args)))

void log(const char *fmt, ...) B32_PRINTF(1, 2);
[[noreturn]] void fatal(const char *fmt, ...) B32_PRINTF(1, 2);

}  // namespace b32
