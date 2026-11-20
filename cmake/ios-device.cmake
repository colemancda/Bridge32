# Toolchain file for the iOS device build:
#   cmake -S . -B build/ios -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/ios-device.cmake
# Everything, dynarmic included, is compiled for arm64-apple-ios. Nothing can
# map executable memory without a debugger attached (StikDebug, AltJIT or
# TrollStore), which oaknut's JitPool asks for; see external/patches.

set(B32_IOS_SIMULATOR OFF CACHE BOOL "" FORCE)
set(CMAKE_OSX_SYSROOT iphoneos)
include("${CMAKE_CURRENT_LIST_DIR}/ios-common.cmake")
