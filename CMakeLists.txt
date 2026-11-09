cmake_minimum_required(VERSION 3.24)

# Optimized with symbols unless asked otherwise: an unoptimized dynarmic
# compiles and dispatches guest code slowly enough that games stutter.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()
project(Bridge32 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# The guest architecture: arm (armv6/armv7 iOS apps, run by dynarmic) or
# i386 (32-bit Intel Mac apps, run by Unicorn). One build serves one guest.
set(B32_GUEST_ARCH "arm" CACHE STRING "Guest architecture: arm or i386")
set_property(CACHE B32_GUEST_ARCH PROPERTY STRINGS arm i386)
if(NOT B32_GUEST_ARCH STREQUAL "arm" AND NOT B32_GUEST_ARCH STREQUAL "i386")
    message(FATAL_ERROR "B32_GUEST_ARCH must be arm or i386, not ${B32_GUEST_ARCH}")
endif()

# The JIT: dynarmic (A32 frontend, arm64 backend) for arm, Unicorn (QEMU's
# TCG) for i386. Without the engine only the loader tools build.
set(B32_HAVE_ENGINE OFF)
if(B32_GUEST_ARCH STREQUAL "arm")
    set(B32_DYNARMIC_DIR "${CMAKE_SOURCE_DIR}/external/dynarmic" CACHE PATH "dynarmic source tree")
    if(EXISTS "${B32_DYNARMIC_DIR}/CMakeLists.txt")
        set(B32_HAVE_ENGINE ON)
        set(DYNARMIC_TESTS OFF CACHE BOOL "" FORCE)
        set(DYNARMIC_FRONTENDS "A32" CACHE STRING "" FORCE)
        add_subdirectory("${B32_DYNARMIC_DIR}" dynarmic EXCLUDE_FROM_ALL)
    endif()
else()
    set(B32_UNICORN_DIR "${CMAKE_SOURCE_DIR}/external/unicorn" CACHE PATH "Unicorn source tree")
    if(EXISTS "${B32_UNICORN_DIR}/CMakeLists.txt")
        set(B32_HAVE_ENGINE ON)
        # Unicorn never sets CF_PARALLEL, so lock-prefixed instructions would
        # compile to plain loads and stores; guest threads share memory here,
        # so the patch makes them real atomics (external/unicorn-parallel.patch).
        execute_process(COMMAND grep -q B32_CF_PARALLEL "${B32_UNICORN_DIR}/qemu/include/exec/exec-all.h"
            RESULT_VARIABLE B32_UNICORN_UNPATCHED)
        if(B32_UNICORN_UNPATCHED)
            execute_process(COMMAND git -C "${B32_UNICORN_DIR}" apply "${CMAKE_SOURCE_DIR}/external/unicorn-parallel.patch"
                RESULT_VARIABLE B32_PATCH_FAILED)
            if(B32_PATCH_FAILED)
                message(FATAL_ERROR "Could not apply external/unicorn-parallel.patch to ${B32_UNICORN_DIR}")
            endif()
        endif()
        set(UNICORN_ARCH "x86" CACHE STRING "" FORCE)
        set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
        set(UNICORN_BUILD_TESTS OFF CACHE BOOL "" FORCE)
        set(UNICORN_INSTALL OFF CACHE BOOL "" FORCE)
        set(UNICORN_LEGACY_STATIC_ARCHIVE OFF CACHE BOOL "" FORCE)
        add_subdirectory("${B32_UNICORN_DIR}" unicorn EXCLUDE_FROM_ALL)
    endif()
endif()

# An OBJECT library so the B32_THUNK registrars in every file are linked in.
add_library(b32core OBJECT
    core/Device.cpp
    core/Log.cpp
    core/Runtime.cpp
    core/cpu/Cpu.cpp
    core/loader/MachO.cpp
    core/mem/GuestHeap.cpp
    core/mem/GuestMemory.cpp
    core/thunks/Format.cpp
    core/thunks/Thunks.cpp
    core/thunks/CTable.mm
    core/thunks/compiler_rt.cpp
    core/thunks/cxxabi.cpp
    core/thunks/corefoundation.mm
    core/thunks/coregraphics.mm
    core/thunks/coretext.mm
    core/thunks/darwin.cpp core/thunks/dispatch.mm core/thunks/libc.cpp core/thunks/libcxx.cpp core/thunks/locale.cpp core/thunks/network.cpp core/thunks/security.mm core/thunks/zlib.cpp
    core/thunks/libstdcxx.cpp
    core/thunks/libsystem.cpp
    core/thunks/posix.cpp
    core/thunks/pthread.cpp
    core/thunks/sqlite.cpp
    core/thunks/systemconfiguration.mm
    core/objc/arc.mm core/objc/Blocks.mm core/objc/Bridge.mm core/objc/sdkstubs.mm core/objc/reflection.mm
    core/objc/Dispatch.mm
    core/objc/Encoding.cpp
    core/objc/objc_thunks.mm
    core/objc/overrides.mm
)
if(B32_GUEST_ARCH STREQUAL "arm")
    target_sources(b32core PRIVATE core/arch/arm/ArmCpu.cpp)
    target_compile_definitions(b32core PUBLIC B32_GUEST_ARM=1)
else()
    target_sources(b32core PRIVATE core/arch/i386/X86Cpu.cpp)
    target_compile_definitions(b32core PUBLIC B32_GUEST_I386=1)
endif()
target_include_directories(b32core PUBLIC "${CMAKE_SOURCE_DIR}")
target_compile_options(b32core PRIVATE -Wall -Wextra -Wno-unused-parameter)
# The bridge manages host object lifetimes by hand.
target_compile_options(b32core PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-arc>)
target_link_libraries(b32core PUBLIC "-framework Foundation" "-framework CoreGraphics" "-framework CFNetwork" "-framework Accelerate" "-framework CoreText"
    "-framework SystemConfiguration" "-framework Security" sqlite3 z ffi)

if(B32_HAVE_ENGINE)
    if(B32_GUEST_ARCH STREQUAL "arm")
        target_sources(b32core PRIVATE core/cpu/DynarmicCpu.cpp)
        target_link_libraries(b32core PUBLIC dynarmic)
        target_compile_definitions(b32core PUBLIC B32_HAVE_DYNARMIC=1)
    else()
        target_sources(b32core PRIVATE core/cpu/UnicornCpu.cpp)
        target_link_libraries(b32core PUBLIC unicorn)
        target_include_directories(b32core PUBLIC "${B32_UNICORN_DIR}/include")
    endif()

    add_executable(b32-run cli/b32-run.cpp)
    target_link_libraries(b32-run PRIVATE b32core)
endif()

add_executable(b32-inspect cli/b32-inspect.cpp)
target_link_libraries(b32-inspect PRIVATE b32core)

# The Mac Catalyst shell (configure with -DCMAKE_TOOLCHAIN_FILE=cmake/catalyst.cmake).
# Games are wrapped into copies of it by tools/make-app.sh.
if(B32_CATALYST)
    if(NOT B32_GUEST_ARCH STREQUAL "arm" OR NOT B32_HAVE_ENGINE)
        message(FATAL_ERROR "The Catalyst shell is the arm guest's and needs dynarmic in external/dynarmic")
    endif()
    target_sources(b32core PRIVATE core/objc/foundation.mm core/uikit/UIKitSupport.mm core/uikit/AlertView.mm core/uikit/MoviePlayer.mm core/uikit/frameworks.mm core/uikit/images.mm core/uikit/Controller.mm core/uikit/GameControllerCompat.mm core/uikit/eventloop.mm core/games/CodZombies.mm core/gl/gles.mm core/gl/renderscale.mm
        core/audio/audio.mm core/audio/audioqueue.mm core/audio/audiounit.mm)
    target_link_libraries(b32core PUBLIC "-framework UIKit" "-framework AudioToolbox" "-framework MapKit" "-framework MediaPlayer" "-framework ImageIO" "-framework QuartzCore" "-framework CoreMedia" "-framework CoreData" "-framework Security" "-framework GameController"
        "-framework CoreLocation")

    add_executable(Bridge32 MACOSX_BUNDLE app/main.mm)
    target_link_libraries(Bridge32 PRIVATE b32core)
    target_compile_options(Bridge32 PRIVATE -fno-objc-arc)
    set_target_properties(Bridge32 PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${CMAKE_SOURCE_DIR}/app/Info.plist"
        OUTPUT_NAME Bridge32)
    add_custom_command(TARGET Bridge32 POST_BUILD
        COMMAND codesign --force --sign - --entitlements "${CMAKE_SOURCE_DIR}/app/Bridge32.entitlements"
                "$<TARGET_BUNDLE_DIR:Bridge32>"
        COMMENT "Signing Bridge32.app (ad hoc)")
endif()

# Guest tests: binaries built by tests/guest/Makefile (ARCH=arm or i386).
enable_testing()
if(B32_GUEST_ARCH STREQUAL "arm")
    set(B32_GUEST_DIR "${CMAKE_SOURCE_DIR}/build/guest")
else()
    set(B32_GUEST_DIR "${CMAKE_SOURCE_DIR}/build/guest-i386")
endif()
add_test(NAME inspect-hello COMMAND b32-inspect "${B32_GUEST_DIR}/hello")
set_tests_properties(inspect-hello PROPERTIES PASS_REGULAR_EXPRESSION "unimplemented imports: 0")
if(B32_HAVE_ENGINE AND B32_GUEST_ARCH STREQUAL "i386")
    add_test(NAME run-hello COMMAND b32-run "${B32_GUEST_DIR}/hello")
    set_tests_properties(run-hello PROPERTIES PASS_REGULAR_EXPRESSION
        "hello from i386, argc=1.*guest heap len=10.*fib\\(20\\)=6765.*double=6\\.283.*strtod=2\\.500")
    add_test(NAME run-rbtree COMMAND b32-run "${B32_GUEST_DIR}/rbtree")
    set_tests_properties(run-rbtree PROPERTIES PASS_REGULAR_EXPRESSION "rbtree passed")
    add_test(NAME run-threads COMMAND b32-run "${B32_GUEST_DIR}/threads")
    set_tests_properties(run-threads PROPERTIES PASS_REGULAR_EXPRESSION "threads passed")
endif()
if(B32_HAVE_ENGINE AND B32_GUEST_ARCH STREQUAL "arm")
    add_test(NAME run-hello COMMAND b32-run "${B32_GUEST_DIR}/hello")
    set_tests_properties(run-hello PROPERTIES PASS_REGULAR_EXPRESSION
        "hello from armv7, argc=1.*guest heap len=10.*fib\\(20\\)=6765.*double=6\\.283")
    add_test(NAME run-cxx COMMAND b32-run "${B32_GUEST_DIR}/cxx")
    set_tests_properties(run-cxx PROPERTIES PASS_REGULAR_EXPRESSION
        "area=42.*array\\[3\\]=9.*static init ran.*counter=2.*try=42.*div=-3 mod=-2 udiv=3 ldiv=-3333333333.*fadd=3\\.75 fdiv=0\\.25 flt=1 fix=-3 dmul=-6\\.0")
    add_test(NAME run-rbtree COMMAND b32-run "${B32_GUEST_DIR}/rbtree")
    set_tests_properties(run-rbtree PROPERTIES PASS_REGULAR_EXPRESSION "rbtree passed")
    add_test(NAME run-objc COMMAND b32-run "${B32_GUEST_DIR}/objc")
    set_tests_properties(run-objc PROPERTIES PASS_REGULAR_EXPRESSION
        "count=102 name=pac.*formatted=<Counter pac: 102> / 7 / 2\\.5.*array count=3 joined=abc csv=a,b,c.*number=42.*shout=WAKA!.*class=Counter super=NSObject.*dealloc pac.*done")
endif()
