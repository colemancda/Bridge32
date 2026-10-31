// Hand-written replacements for host methods that can't be called generically:
// varargs (stringWithFormat:, arrayWithObjects:), and methods whose pointer
// arguments need more than a type encoding to convert (fast enumeration,
// id buffers with counts).
#pragma once

#include "Bridge.h"

namespace b32::objc {

struct OverrideCall {
    Call &c;
    Bridge &bridge;
    id receiver;          // host receiver
    GuestAddr guestReceiver;
    SEL sel;
    const char *name;
    Args &args;           // positioned at the first argument after _cmd
    GuestAddr retPtr;     // stret result pointer, or 0
};

using OverrideFn = void (*)(OverrideCall &);
// Decides from the receiver alone (without reading arguments) whether the
// override applies, e.g. -bounds only for UIScreen.
using OverrideCondition = bool (*)(id receiver);

struct OverrideRegistry {
    OverrideRegistry(std::initializer_list<const char *> selectors, OverrideFn fn, OverrideCondition when = nullptr);
};

#define B32_OVERRIDE_CONCAT2(a, b) a##b
#define B32_OVERRIDE_CONCAT(a, b) B32_OVERRIDE_CONCAT2(a, b)
// B32_OVERRIDE("sel1:", "sel2:") { ... uses `o` ... }
#define B32_OVERRIDE(...) B32_OVERRIDE_IMPL(B32_OVERRIDE_CONCAT(override_, __LINE__), __VA_ARGS__)
#define B32_OVERRIDE_IMPL(fn, ...)                                                    \
    static void fn(::b32::objc::OverrideCall &o);                                     \
    static ::b32::objc::OverrideRegistry B32_OVERRIDE_CONCAT(fn, _registry)({__VA_ARGS__}, fn); \
    static void fn(::b32::objc::OverrideCall &o)

// B32_OVERRIDE_WHEN(condition, "sel") { ... } applies only when
// condition(receiver) is true; other receivers take the generic path.
#define B32_OVERRIDE_WHEN(condition, ...) B32_OVERRIDE_WHEN_IMPL(B32_OVERRIDE_CONCAT(override_, __LINE__), condition, __VA_ARGS__)
#define B32_OVERRIDE_WHEN_IMPL(fn, condition, ...)                                    \
    static void fn(::b32::objc::OverrideCall &o);                                     \
    static ::b32::objc::OverrideRegistry B32_OVERRIDE_CONCAT(fn, _registry)({__VA_ARGS__}, fn, condition); \
    static void fn(::b32::objc::OverrideCall &o)

}  // namespace b32::objc
