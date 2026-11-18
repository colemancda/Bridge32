// The fonts the text engine (ats.mm) knows, for QuickDraw's own text calls (quickdraw.mm), which name a font
// by its QuickDraw family number.
#pragma once

#include <CoreText/CoreText.h>

#include <cstdint>
#include <string>

namespace b32::appkit {

// The CoreText font for a QuickDraw font family (0 the system font, 1 the application font, others what
// FMGetFontFamilyFromATSFontFamilyRef handed out), a size in points (0 for the family's usual 12) and style
// bits (bold 1, italic 2). The caller releases it.
CTFontRef copyQuickDrawFont(int16_t family, int16_t size, int16_t face);
// A QuickDraw font family's name.
std::string quickDrawFamilyName(int16_t family);

}  // namespace b32::appkit
