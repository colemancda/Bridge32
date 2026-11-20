#pragma once

#include <TargetConditionals.h>

// Mac Catalyst keeps the iOS frameworks that macOS has no copy of (UIKit,
// OpenGL ES, OpenAL) under /System/iOSSupport; on iOS they're at the root.
// A string literal, to prefix a path: B32_IOS_SUPPORT "/System/Library/...".
#if TARGET_OS_MACCATALYST
#define B32_IOS_SUPPORT "/System/iOSSupport"
#else
#define B32_IOS_SUPPORT ""
#endif
