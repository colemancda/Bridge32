cmake_minimum_required(VERSION 3.24)
project(Bridge32 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# dynarmic (A32 frontend, arm64 backend) runs the guest code. Without it only
# the loader tools build.
set(B32_DYNARMIC_DIR "${CMAKE_SOURCE_DIR}/external/dynarmic" CACHE PATH "dynarmic source tree")
set(B32_HAVE_DYNARMIC OFF)
if(EXISTS "${B32_DYNARMIC_DIR}/CMakeLists.txt")
    set(B32_HAVE_DYNARMIC ON)
    set(DYNARMIC_TESTS OFF CACHE BOOL "" FORCE)
    set(DYNARMIC_FRONTENDS "A32" CACHE STRING "" FORCE)
    add_subdirectory("${B32_DYNARMIC_DIR}" dynarmic EXCLUDE_FROM_ALL)
endif()

# An OBJECT library so the B32_THUNK registrars in every file are linked in.
add_library(b32core OBJECT
    core/Log.cpp
    core/Runtime.cpp
    core/cpu/Cpu.cpp
    core/loader/MachO.cpp
    core/mem/GuestHeap.cpp
    core/mem/GuestMemory.cpp
    core/thunks/Format.cpp
    core/thunks/Thunks.cpp
    core/thunks/compiler_rt.cpp
    core/thunks/cxxabi.cpp
    core/thunks/libc.cpp
)
target_include_directories(b32core PUBLIC "${CMAKE_SOURCE_DIR}")
target_compile_options(b32core PRIVATE -Wall -Wextra -Wno-unused-parameter)

if(B32_HAVE_DYNARMIC)
    target_sources(b32core PRIVATE core/cpu/DynarmicCpu.cpp)
    target_link_libraries(b32core PUBLIC dynarmic)
    target_compile_definitions(b32core PUBLIC B32_HAVE_DYNARMIC=1)

    add_executable(b32-run cli/b32-run.cpp)
    target_link_libraries(b32-run PRIVATE b32core)
endif()

add_executable(b32-inspect cli/b32-inspect.cpp)
target_link_libraries(b32-inspect PRIVATE b32core)

# Guest tests: armv7 binaries built by tests/guest/Makefile.
enable_testing()
set(B32_GUEST_DIR "${CMAKE_SOURCE_DIR}/build/guest")
add_test(NAME inspect-hello COMMAND b32-inspect "${B32_GUEST_DIR}/hello")
set_tests_properties(inspect-hello PROPERTIES PASS_REGULAR_EXPRESSION "unimplemented imports: 0")
if(B32_HAVE_DYNARMIC)
    add_test(NAME run-hello COMMAND b32-run "${B32_GUEST_DIR}/hello")
    set_tests_properties(run-hello PROPERTIES PASS_REGULAR_EXPRESSION
        "hello from armv7, argc=1.*guest heap len=10.*fib\\(20\\)=6765.*double=6\\.283")
    add_test(NAME run-cxx COMMAND b32-run "${B32_GUEST_DIR}/cxx")
    set_tests_properties(run-cxx PROPERTIES PASS_REGULAR_EXPRESSION
        "area=42.*array\\[3\\]=9.*static init ran.*counter=2.*try=42.*div=-3 mod=-2 udiv=3 ldiv=-3333333333.*fadd=3\\.75 fdiv=0\\.25 flt=1 fix=-3 dmul=-6\\.0")
endif()
