#pragma once

#include "Thunks.h"

#include <string>

namespace b32 {

// Formats a printf-style string from guest memory, pulling each conversion's
// argument from `args` in the guest calling convention. %@ is left to the
// ObjC layer, which passes a describer for it.
using ObjectDescriber = std::string (*)(Call &, GuestAddr object);
std::string formatGuest(Call &c, const char *format, Args &args, ObjectDescriber describe = nullptr);

}  // namespace b32
