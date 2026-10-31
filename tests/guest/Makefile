# Builds the armv7 guest test binaries with the current Xcode's clang and the
# patched iOS 9.3 SDK (see make-sdk.sh in HalfLife-iOS9 for the tbd fixes).

SDK     ?= /Volumes/Crucial-2TB/Developer/HalfLife-iOS9/sdk/iPhoneOS9.3.sdk
OUT     ?= ../../build/guest
CC      := xcrun clang
# -marm: Xcode 27's linker writes an even LC_MAIN entry offset for Thumb code.
CFLAGS  := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=9.0 -marm -O1 -Wall

TESTS   := hello cxx objc UIKitTest.app

.PHONY: all clean
all: $(addprefix $(OUT)/,$(TESTS))

$(OUT)/hello: hello/hello.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<

# No C++ standard library headers: the test only needs the runtime (libc++abi,
# re-exported by libc++) and links the libgcc helpers from libSystem.
$(OUT)/cxx: cxx/cxx.cpp
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -std=c++17 -o $@ $< -lc++

# Manual retain/release, as in iPhone OS 2-4 apps.
$(OUT)/objc: objc/objc.m
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -fno-objc-arc -o $@ $< -framework Foundation

# An app bundle, for tools/make-app.sh to wrap into the Catalyst shell.
$(OUT)/UIKitTest.app: uikit/main.m uikit/Info.plist
	@mkdir -p $@
	$(CC) $(CFLAGS) -fno-objc-arc -o $@/UIKitTest uikit/main.m -framework UIKit -framework Foundation -framework CoreGraphics
	cp uikit/Info.plist $@/Info.plist

clean:
	rm -rf $(OUT)
