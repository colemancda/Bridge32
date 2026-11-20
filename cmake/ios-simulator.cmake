# Toolchain file for the iOS Simulator build:
#   cmake -S . -B build/ios-sim -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/ios-simulator.cmake
# Everything, dynarmic included, is compiled for arm64-apple-ios-simulator.
# The simulator runs as a Mac process, so JIT works without a debugger.

set(B32_IOS_SIMULATOR ON CACHE BOOL "" FORCE)
set(CMAKE_OSX_SYSROOT iphonesimulator)
include("${CMAKE_CURRENT_LIST_DIR}/ios-common.cmake")
