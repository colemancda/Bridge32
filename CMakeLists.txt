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

# iOS needs dynarmic and oaknut patched to take executable memory from a
# debugger (see external/patches). Applied once to the submodule working
# trees, which then show as modified; skipped if already applied.
if(B32_IOS)
    foreach(pair "external/dynarmic/externals/oaknut|oaknut-ios-jit.patch" "external/dynarmic|dynarmic-ios-jit.patch")
        string(REPLACE "|" ";" pair "${pair}")
        list(GET pair 0 patch_dir)
        list(GET pair 1 patch_file)
        if(EXISTS "${CMAKE_SOURCE_DIR}/${patch_dir}/CMakeLists.txt" OR EXISTS "${CMAKE_SOURCE_DIR}/${patch_dir}/include")
            execute_process(COMMAND git apply --check --reverse "${CMAKE_SOURCE_DIR}/external/patches/${patch_file}"
                WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/${patch_dir}" RESULT_VARIABLE already_applied OUTPUT_QUIET ERROR_QUIET)
            if(NOT already_applied EQUAL 0)
                execute_process(COMMAND git apply "${CMAKE_SOURCE_DIR}/external/patches/${patch_file}"
                    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}/${patch_dir}" RESULT_VARIABLE apply_result)
                if(NOT apply_result EQUAL 0)
                    message(FATAL_ERROR "Can't apply external/patches/${patch_file} in ${patch_dir}")
                endif()
            endif()
        endif()
    endforeach()
endif()

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
target_include_directories(b32core PUBLIC "${CMAKE_SOURCE_DIR}")
target_compile_options(b32core PRIVATE -Wall -Wextra -Wno-unused-parameter)
# The bridge manages host object lifetimes by hand.
target_compile_options(b32core PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fno-objc-arc>)
target_link_libraries(b32core PUBLIC "-framework Foundation" "-framework CoreGraphics" "-framework CFNetwork" "-framework Accelerate" "-framework CoreText"
    "-framework SystemConfiguration" sqlite3 z ffi)

if(B32_HAVE_DYNARMIC)
    target_sources(b32core PRIVATE core/cpu/DynarmicCpu.cpp)
    target_link_libraries(b32core PUBLIC dynarmic)
    target_compile_definitions(b32core PUBLIC B32_HAVE_DYNARMIC=1)

    add_executable(b32-run cli/b32-run.cpp)
    target_link_libraries(b32-run PRIVATE b32core)
endif()

add_executable(b32-inspect cli/b32-inspect.cpp)
target_link_libraries(b32-inspect PRIVATE b32core)

# The Mac Catalyst shell (configure with -DCMAKE_TOOLCHAIN_FILE=cmake/catalyst.cmake).
# Games are wrapped into copies of it by tools/make-app.sh.
if(B32_CATALYST OR B32_IOS)
    if(NOT B32_HAVE_DYNARMIC)
        message(FATAL_ERROR "The UIKit shell needs dynarmic in external/dynarmic")
    endif()
    if(B32_IOS)
        # <ffi/ffi.h> comes from the build tree. The simulator SDK ships
        # libffi.tbd but no headers, and the macOS SDK's say API_UNAVAILABLE(ios)
        # (dropped here: the library does export everything); the device SDK has
        # no libffi at all, so it's built from external/libffi.
        file(REMOVE_RECURSE "${CMAKE_BINARY_DIR}/ffi-include")
        file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/ffi-include")
        if(B32_IOS_SIMULATOR)
            file(COPY "${B32_FFI_HEADERS_DIR}" DESTINATION "${CMAKE_BINARY_DIR}/ffi-include")
            file(READ "${CMAKE_BINARY_DIR}/ffi-include/ffi/ffi.h" B32_FFI_H)
            string(REPLACE " API_UNAVAILABLE(ios, tvos, watchos)" "" B32_FFI_H "${B32_FFI_H}")
            file(WRITE "${CMAKE_BINARY_DIR}/ffi-include/ffi/ffi.h" "${B32_FFI_H}")
        else()
            include(ExternalProject)
            execute_process(COMMAND xcrun --sdk iphoneos --show-sdk-path OUTPUT_VARIABLE B32_IPHONEOS_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
            set(B32_FFI_PREFIX "${CMAKE_BINARY_DIR}/libffi-install")
            # Built from a copy: autogen.sh would dirty the submodule. A
            # different --build makes configure cross-compile, so it doesn't try
            # to run its iOS test programs on the Mac.
            ExternalProject_Add(libffi_ext
                PREFIX "${CMAKE_BINARY_DIR}/libffi"
                SOURCE_DIR "${CMAKE_BINARY_DIR}/libffi/src"
                DOWNLOAD_COMMAND "${CMAKE_COMMAND}" -E copy_directory "${CMAKE_SOURCE_DIR}/external/libffi" "${CMAKE_BINARY_DIR}/libffi/src"
                CONFIGURE_COMMAND sh -c "./autogen.sh && ./configure --build=x86_64-apple-darwin --host=aarch64-apple-darwin --prefix=${B32_FFI_PREFIX} --disable-shared --enable-static --disable-docs --disable-multi-os-directory CC=/usr/bin/clang 'CFLAGS=-arch arm64 -isysroot ${B32_IPHONEOS_SDK} -miphoneos-version-min=17.0 -O2 -g' 'LDFLAGS=-arch arm64 -isysroot ${B32_IPHONEOS_SDK}'"
                BUILD_COMMAND make -j8
                INSTALL_COMMAND make install
                BUILD_IN_SOURCE TRUE
                BUILD_BYPRODUCTS "${B32_FFI_PREFIX}/lib/libffi.a")
            file(MAKE_DIRECTORY "${B32_FFI_PREFIX}/include")
            file(CREATE_LINK "${B32_FFI_PREFIX}/include" "${CMAKE_BINARY_DIR}/ffi-include/ffi" SYMBOLIC)
            add_library(ffi STATIC IMPORTED)
            set_target_properties(ffi PROPERTIES IMPORTED_LOCATION "${B32_FFI_PREFIX}/lib/libffi.a")
            add_dependencies(ffi libffi_ext)
            add_dependencies(b32core libffi_ext)
            # ffi.h includes <ffitarget.h> from its own directory.
            target_include_directories(b32core PUBLIC "${B32_FFI_PREFIX}/include")
        endif()
        target_include_directories(b32core PUBLIC "${CMAKE_BINARY_DIR}/ffi-include")
        target_compile_definitions(b32core PUBLIC B32_IOS=1)
    endif()
    target_sources(b32core PRIVATE core/objc/foundation.mm core/uikit/UIKitSupport.mm core/uikit/AlertView.mm core/uikit/MoviePlayer.mm core/uikit/frameworks.mm core/uikit/images.mm core/uikit/Controller.mm core/uikit/GameControllerCompat.mm core/uikit/eventloop.mm core/games/CodZombies.mm core/gl/gles.mm core/gl/renderscale.mm
        core/audio/audio.mm core/audio/audioqueue.mm core/audio/audiounit.mm)
    target_link_libraries(b32core PUBLIC "-framework UIKit" "-framework AudioToolbox" "-framework MapKit" "-framework MediaPlayer" "-framework ImageIO" "-framework QuartzCore" "-framework CoreMedia" "-framework CoreData" "-framework Security" "-framework GameController" "-framework CoreVideo"
        "-framework CoreLocation")

    add_executable(Bridge32 MACOSX_BUNDLE app/main.mm)
    target_link_libraries(Bridge32 PRIVATE b32core)
    target_compile_options(Bridge32 PRIVATE -fno-objc-arc)
    if(B32_IOS)
        set(B32_INFO_PLIST "${CMAKE_SOURCE_DIR}/app/Info-ios.plist")
        set(B32_ENTITLEMENTS "${CMAKE_SOURCE_DIR}/app/Bridge32-ios.entitlements")
    else()
        set(B32_INFO_PLIST "${CMAKE_SOURCE_DIR}/app/Info.plist")
        set(B32_ENTITLEMENTS "${CMAKE_SOURCE_DIR}/app/Bridge32.entitlements")
    endif()
    set_target_properties(Bridge32 PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST "${B32_INFO_PLIST}"
        OUTPUT_NAME Bridge32)
    # The simulator refuses ad hoc binaries with get-task-allow ("Security
    # policy issue") and doesn't need it: it runs as a Mac process, where
    # JIT works. A device build needs it for the debugger that enables JIT.
    if(B32_IOS_SIMULATOR)
        set(B32_CODESIGN_ENTITLEMENTS "")
    else()
        set(B32_CODESIGN_ENTITLEMENTS --entitlements "${B32_ENTITLEMENTS}")
    endif()
    if(B32_IOS AND NOT B32_IOS_SIMULATOR)
        # app/Info-ios.plist is the simulator's; a device build says iPhoneOS.
        add_custom_command(TARGET Bridge32 POST_BUILD
            COMMAND /usr/libexec/PlistBuddy -c "Set :CFBundleSupportedPlatforms:0 iPhoneOS" "$<TARGET_BUNDLE_DIR:Bridge32>/Info.plist")
    endif()
    add_custom_command(TARGET Bridge32 POST_BUILD
        COMMAND codesign --force --sign - ${B32_CODESIGN_ENTITLEMENTS}
                "$<TARGET_BUNDLE_DIR:Bridge32>"
        COMMENT "Signing Bridge32.app (ad hoc)")
endif()

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
    add_test(NAME run-rbtree COMMAND b32-run "${B32_GUEST_DIR}/rbtree")
    set_tests_properties(run-rbtree PROPERTIES PASS_REGULAR_EXPRESSION "rbtree passed")
    add_test(NAME run-objc COMMAND b32-run "${B32_GUEST_DIR}/objc")
    set_tests_properties(run-objc PROPERTIES PASS_REGULAR_EXPRESSION
        "count=102 name=pac.*formatted=<Counter pac: 102> / 7 / 2\\.5.*array count=3 joined=abc csv=a,b,c.*number=42.*shout=WAKA!.*class=Counter super=NSObject.*dealloc pac.*done")
endif()
