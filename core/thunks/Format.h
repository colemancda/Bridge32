#pragma once

#include "Thunks.h"

#include <string>

namespace b32 {

// Formats a printf-style string from guest memory, pulling each conversion's
// argument from `args` in the guest calling convention. %@ is left to the
// ObjC layer, which passes a describer for it.
using ObjectDescriber = std::string (*)(Call &, GuestAddr object);
std::string formatGuest(Call &c, const char *format, Args &args, ObjectDescriber describe = nullptr);

// Wide characters (the Mac's wchar_t is 32 bits) to and from UTF-8.
std::string wideToUTF8(const std::wstring &text);
std::wstring utf8ToWide(const std::string &text);

// Scans `input` by a scanf-style format, storing through the guest pointers
// `args` supplies; returns scanf's result, and how much input it used in
// *consumed (posix.cpp).
int scanGuest(Call &c, Args &args, const char *input, const char *format, size_t *consumed = nullptr);

}  // namespace b32
