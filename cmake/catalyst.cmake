# Toolchain file for the Mac Catalyst build:
#   cmake -S . -B build/catalyst -G Ninja -DCMAKE_TOOLCHAIN_FILE=cmake/catalyst.cmake
# Everything, dynarmic included, is compiled for arm64-apple-ios-macabi so
# the app can link UIKit from the macOS SDK's iOSSupport.

set(B32_CATALYST ON CACHE BOOL "" FORCE)
set(B32_CATALYST_TARGET "arm64-apple-ios17.0-macabi")

set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64)
# The deployment target comes from the triple; keep CMake from adding
# -mmacosx-version-min, which conflicts with it.
set(CMAKE_OSX_DEPLOYMENT_TARGET "")

foreach(lang C CXX OBJC OBJCXX ASM)
    set(CMAKE_${lang}_COMPILER_TARGET "${B32_CATALYST_TARGET}")
endforeach()

# UIKit and the other iOS frameworks live in the macOS SDK's iOSSupport tree.
execute_process(COMMAND xcrun --sdk macosx --show-sdk-path OUTPUT_VARIABLE B32_MACOS_SDK OUTPUT_STRIP_TRAILING_WHITESPACE)
set(CMAKE_OSX_SYSROOT "${B32_MACOS_SDK}")
set(B32_IOS_SUPPORT "${B32_MACOS_SDK}/System/iOSSupport")
set(B32_CATALYST_FLAGS "-iframework ${B32_IOS_SUPPORT}/System/Library/Frameworks -isystem ${B32_IOS_SUPPORT}/usr/include")
foreach(lang C CXX OBJC OBJCXX)
    set(CMAKE_${lang}_FLAGS_INIT "${B32_CATALYST_FLAGS}")
endforeach()
set(CMAKE_EXE_LINKER_FLAGS_INIT "-F${B32_IOS_SUPPORT}/System/Library/Frameworks -L${B32_IOS_SUPPORT}/usr/lib")
