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
// --- the plain (non-VFP) names --------------------------------------------
// Newer compilers call these, with the same softfp convention. Their
// comparisons return three-way results instead of 1 or 0: __eq/__ne give 0
// when equal, __lt/__le negative when less (or equal), __gt/__ge positive
// when greater (or equal), and NaN makes each one's condition false.

#define B32_PLAIN_BINOP(name, type, read, ret, op) \
    B32_THUNK(name) {                              \
        type a = c.args.read();                    \
        c.ret(a op c.args.read());                 \
    }
B32_PLAIN_BINOP(___addsf3, float, f32, retF32, +)
B32_PLAIN_BINOP(___subsf3, float, f32, retF32, -)
B32_PLAIN_BINOP(___mulsf3, float, f32, retF32, *)
B32_PLAIN_BINOP(___divsf3, float, f32, retF32, /)
B32_PLAIN_BINOP(___adddf3, double, f64, retF64, +)
B32_PLAIN_BINOP(___subdf3, double, f64, retF64, -)
B32_PLAIN_BINOP(___muldf3, double, f64, retF64, *)
B32_PLAIN_BINOP(___divdf3, double, f64, retF64, /)

namespace {
template <typename T> int32_t compare(T a, T b, int32_t unordered) {
    if (std::isnan(a) || std::isnan(b)) return unordered;
    return a < b ? -1 : a > b ? 1 : 0;
}
}  // namespace

#define B32_PLAIN_CMP(name, type, read, unordered)            \
    B32_THUNK(name) {                                         \
        type a = c.args.read();                               \
        c.ret(uint32_t(compare(a, c.args.read(), unordered))); \
    }
B32_PLAIN_CMP(___eqsf2, float, f32, 1)
B32_PLAIN_CMP(___nesf2, float, f32, 1)
B32_PLAIN_CMP(___ltsf2, float, f32, 1)
B32_PLAIN_CMP(___lesf2, float, f32, 1)
B32_PLAIN_CMP(___gtsf2, float, f32, -1)
B32_PLAIN_CMP(___gesf2, float, f32, -1)
B32_PLAIN_CMP(___eqdf2, double, f64, 1)
B32_PLAIN_CMP(___nedf2, double, f64, 1)
B32_PLAIN_CMP(___ltdf2, double, f64, 1)
B32_PLAIN_CMP(___ledf2, double, f64, 1)
B32_PLAIN_CMP(___gtdf2, double, f64, -1)
B32_PLAIN_CMP(___gedf2, double, f64, -1)
B32_THUNK(___unordsf2) {
    float a = c.args.f32();
    c.ret(std::isnan(a) || std::isnan(c.args.f32()) ? 1 : 0);
}
B32_THUNK(___unorddf2) {
    double a = c.args.f64();
    c.ret(std::isnan(a) || std::isnan(c.args.f64()) ? 1 : 0);
}

B32_THUNK(___fixsfsi) { c.ret(uint32_t(saturate<int32_t>(c.args.f32()))); }
B32_THUNK(___fixunssfsi) { c.ret(saturate<uint32_t>(c.args.f32())); }
B32_THUNK(___fixdfsi) { c.ret(uint32_t(saturate<int32_t>(c.args.f64()))); }
B32_THUNK(___fixunsdfsi) { c.ret(saturate<uint32_t>(c.args.f64())); }
B32_THUNK(___floatsisf) { c.retF32(float(c.args.i32())); }
B32_THUNK(___floatsidf) { c.retF64(double(c.args.i32())); }
B32_THUNK(___floatunsisf) { c.retF32(float(c.args.u32())); }
B32_THUNK(___floatunsidf) { c.retF64(double(c.args.u32())); }
B32_THUNK(___floatdisf) { c.retF32(float(int64_t(c.args.u64()))); }
B32_THUNK(___floatdidf) { c.retF64(double(int64_t(c.args.u64()))); }
B32_THUNK(___extendsfdf2) { c.retF64(double(c.args.f32())); }
B32_THUNK(___truncdfsf2) { c.retF32(float(c.args.f64())); }

// --- 64-bit shifts -----------------------------------------------------------
// Shift counts of 64 or more are undefined; mask them as the ARM helpers do.

B32_THUNK(___ashldi3) {
    uint64_t a = c.args.u64();
    c.ret64(a << (c.args.u32() & 63));
}
B32_THUNK(___lshrdi3) {
    uint64_t a = c.args.u64();
    c.ret64(a >> (c.args.u32() & 63));
}
