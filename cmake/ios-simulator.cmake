# Toolchain file for the iOS Simulator build (phase 1 of the iOS port):
#   cmake -S . -B build/ios-sim -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/ios-simulator.cmake
# Everything, dynarmic included, is compiled for arm64-apple-ios-simulator.
# The simulator runs as a Mac process, so JIT works without a debugger.

set(B32_IOS ON CACHE BOOL "" FORCE)
set(B32_IOS_SIMULATOR ON CACHE BOOL "" FORCE)

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT iphonesimulator)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)

# The iOS SDKs ship libffi.tbd but not its headers; ffi.h and ffitarget.h in
# the macOS SDK are the same arm64 ones. dynarmic's exception handler also
# needs mach_exc.defs, which only the macOS SDK has (mig reads it for arm64).
execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE B32_MACOS_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
set(B32_FFI_HEADERS_DIR "${B32_MACOS_SDK}/usr/include/ffi" CACHE PATH "Directory holding ffi.h")
set(MACH_EXC_DEFS_DIR "${B32_MACOS_SDK}/usr/include" CACHE PATH "Directory holding mach/mach_exc.defs")

# dynarmic only needs Boost's headers, which Homebrew's prefix holds; the iOS
# sysroot keeps find_package from looking there on its own.
set(Boost_INCLUDE_DIR "/opt/homebrew/include" CACHE PATH "Boost headers")
list(APPEND CMAKE_FIND_ROOT_PATH /opt/homebrew)
