# Builds the armv7 guest test binaries with the current Xcode's clang and the
# patched iOS 9.3 SDK (see make-sdk.sh in HalfLife-iOS9 for the tbd fixes).

SDK     ?= /Volumes/Crucial-2TB/Developer/HalfLife-iOS9/sdk/iPhoneOS9.3.sdk
OUT     ?= ../../build/guest
CC      := xcrun clang
# -marm: Xcode 27's linker writes an even LC_MAIN entry offset for Thumb code.
CFLAGS  := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=9.0 -marm -O1 -Wall

TESTS   := hello

.PHONY: all clean
all: $(addprefix $(OUT)/,$(TESTS))

$(OUT)/hello: hello/hello.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -rf $(OUT)
