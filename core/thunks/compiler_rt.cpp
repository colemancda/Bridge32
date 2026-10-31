// libgcc/compiler-rt helpers that armv6 code calls for integer division and
// for floating point. The *vfp variants use the softfp convention like every
// other iOS armv6/armv7 call: arguments and results in core registers, and
// comparisons return 1 or 0.

#include "Thunks.h"

#include <cmath>
#include <limits>
#include <type_traits>

using namespace b32;

// --- integer division (armv6 has no divide instruction) --------------------

namespace {
// Guest division by zero is undefined; return 0 like the ARM helpers do
// rather than trapping on the host.
template <typename T> T divide(T a, T b) {
    if (b == 0) return 0;
    if constexpr (std::is_signed_v<T>)
        if (a == std::numeric_limits<T>::min() && b == -1) return a;
    return a / b;
}
template <typename T> T modulo(T a, T b) {
    if (b == 0) return a;
    if constexpr (std::is_signed_v<T>)
        if (b == -1) return 0;
    return a % b;
}
}  // namespace

B32_THUNK(___divsi3) {
    int32_t a = c.args.i32();
    c.ret(uint32_t(divide(a, c.args.i32())));
}
B32_THUNK(___udivsi3) {
    uint32_t a = c.args.u32();
    c.ret(divide(a, c.args.u32()));
}
B32_THUNK(___modsi3) {
    int32_t a = c.args.i32();
    c.ret(uint32_t(modulo(a, c.args.i32())));
}
B32_THUNK(___umodsi3) {
    uint32_t a = c.args.u32();
    c.ret(modulo(a, c.args.u32()));
}
B32_THUNK(___divdi3) {
    int64_t a = int64_t(c.args.u64());
    c.ret64(uint64_t(divide(a, int64_t(c.args.u64()))));
}
B32_THUNK(___udivdi3) {
    uint64_t a = c.args.u64();
    c.ret64(divide(a, c.args.u64()));
}
B32_THUNK(___moddi3) {
    int64_t a = int64_t(c.args.u64());
    c.ret64(uint64_t(modulo(a, int64_t(c.args.u64()))));
}
B32_THUNK(___umoddi3) {
    uint64_t a = c.args.u64();
    c.ret64(modulo(a, c.args.u64()));
}

// --- single precision ------------------------------------------------------

#define B32_FLOAT_BINOP(name, op)                \
    B32_THUNK(name) {                            \
        float a = c.args.f32();                  \
        c.retF32(a op c.args.f32());             \
    }
B32_FLOAT_BINOP(___addsf3vfp, +)
B32_FLOAT_BINOP(___subsf3vfp, -)
B32_FLOAT_BINOP(___mulsf3vfp, *)
B32_FLOAT_BINOP(___divsf3vfp, /)

#define B32_FLOAT_CMP(name, expr)                \
    B32_THUNK(name) {                            \
        float a = c.args.f32();                  \
        float b = c.args.f32();                  \
        c.ret((expr) ? 1 : 0);                   \
    }
B32_FLOAT_CMP(___eqsf2vfp, a == b)
B32_FLOAT_CMP(___nesf2vfp, a != b)
B32_FLOAT_CMP(___ltsf2vfp, a < b)
B32_FLOAT_CMP(___lesf2vfp, a <= b)
B32_FLOAT_CMP(___gtsf2vfp, a > b)
B32_FLOAT_CMP(___gesf2vfp, a >= b)
B32_FLOAT_CMP(___unordsf2vfp, std::isnan(a) || std::isnan(b))

// --- double precision ------------------------------------------------------

#define B32_DOUBLE_BINOP(name, op)               \
    B32_THUNK(name) {                            \
        double a = c.args.f64();                 \
        c.retF64(a op c.args.f64());             \
    }
B32_DOUBLE_BINOP(___adddf3vfp, +)
B32_DOUBLE_BINOP(___subdf3vfp, -)
B32_DOUBLE_BINOP(___muldf3vfp, *)
B32_DOUBLE_BINOP(___divdf3vfp, /)

#define B32_DOUBLE_CMP(name, expr)               \
    B32_THUNK(name) {                            \
        double a = c.args.f64();                 \
        double b = c.args.f64();                 \
        c.ret((expr) ? 1 : 0);                   \
    }
B32_DOUBLE_CMP(___eqdf2vfp, a == b)
B32_DOUBLE_CMP(___nedf2vfp, a != b)
B32_DOUBLE_CMP(___ltdf2vfp, a < b)
B32_DOUBLE_CMP(___ledf2vfp, a <= b)
B32_DOUBLE_CMP(___gtdf2vfp, a > b)
B32_DOUBLE_CMP(___gedf2vfp, a >= b)
B32_DOUBLE_CMP(___unorddf2vfp, std::isnan(a) || std::isnan(b))

// --- conversions -----------------------------------------------------------

namespace {
// Float-to-int conversions saturate like VCVT does, instead of being UB.
template <typename To, typename From> To saturate(From v) {
    if (std::isnan(v)) return 0;
    if (v <= From(std::numeric_limits<To>::min())) return std::numeric_limits<To>::min();
    if (v >= From(std::numeric_limits<To>::max())) return std::numeric_limits<To>::max();
    return To(v);
}
}  // namespace

B32_THUNK(___fixsfsivfp) { c.ret(uint32_t(saturate<int32_t>(c.args.f32()))); }
B32_THUNK(___fixunssfsivfp) { c.ret(saturate<uint32_t>(c.args.f32())); }
B32_THUNK(___fixdfsivfp) { c.ret(uint32_t(saturate<int32_t>(c.args.f64()))); }
B32_THUNK(___fixunsdfsivfp) { c.ret(saturate<uint32_t>(c.args.f64())); }
B32_THUNK(___floatsisfvfp) { c.retF32(float(c.args.i32())); }
B32_THUNK(___floatunssisfvfp) { c.retF32(float(c.args.u32())); }
B32_THUNK(___floatsidfvfp) { c.retF64(double(c.args.i32())); }
B32_THUNK(___floatunssidfvfp) { c.retF64(double(c.args.u32())); }
B32_THUNK(___extendsfdf2vfp) { c.retF64(double(c.args.f32())); }
B32_THUNK(___truncdfsf2vfp) { c.retF32(float(c.args.f64())); }
