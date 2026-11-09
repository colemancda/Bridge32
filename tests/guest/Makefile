# Builds the guest test binaries with the current Xcode's clang.
#   make            armv7, against the patched iOS 9.3 SDK (see make-sdk.sh in
#                   HalfLife-iOS9 for the tbd fixes)
#   make ARCH=i386  i386, compiled by clang (which still targets i386) and
#                   linked by tools/i386-link.py, since Apple's ld no longer
#                   links i386; no SDK needed, Bridge32 binds imports by name

ARCH    ?= arm
SDK     ?= /Volumes/Crucial-2TB/Developer/HalfLife-iOS9/sdk/iPhoneOS9.3.sdk
CC      := xcrun clang

ifeq ($(ARCH),i386)
OUT     ?= ../../build/guest-i386
CFLAGS  := -arch i386 -target i386-apple-macos10.13 -mdynamic-no-pic -fno-asynchronous-unwind-tables \
           -fno-unwind-tables -O1 -Wall -Wno-unused-command-line-argument
LINK    := python3 ../../tools/i386-link.py
TESTS   := hello rbtree threads bench

.PHONY: all clean
all: $(addprefix $(OUT)/,$(TESTS))

.SECONDEXPANSION:
$(OUT)/%: $$*/$$*.c ../../tools/i386-link.py
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -c -o $@.o $<
	$(LINK) -o $@ $@.o

else
OUT     ?= ../../build/guest
# -marm: Xcode 27's linker writes an even LC_MAIN entry offset for Thumb code.
CFLAGS  := -arch armv7 -isysroot $(SDK) -miphoneos-version-min=9.0 -marm -O1 -Wall

TESTS   := hello cxx objc rbtree UIKitTest.app GLES1Test.app

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

# The libstdc++ tree helpers aren't in the SDK stubs; Bridge32 provides them.
RBTREE_SYMBOLS := __ZSt29_Rb_tree_insert_and_rebalancebPSt18_Rb_tree_node_baseS0_RS_ \
	__ZSt28_Rb_tree_rebalance_for_erasePSt18_Rb_tree_node_baseRS_ \
	__ZSt18_Rb_tree_incrementPSt18_Rb_tree_node_base __ZSt18_Rb_tree_decrementPSt18_Rb_tree_node_base
$(OUT)/rbtree: rbtree/rbtree.c
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) -o $@ $< $(foreach s,$(RBTREE_SYMBOLS),-Wl,-U,$(s))

# An app bundle, for tools/make-app.sh to wrap into the Catalyst shell.
$(OUT)/UIKitTest.app: uikit/main.m uikit/Info.plist
	@mkdir -p $@
	$(CC) $(CFLAGS) -fno-objc-arc -o $@/UIKitTest uikit/main.m -framework UIKit -framework Foundation -framework CoreGraphics
	cp uikit/Info.plist $@/Info.plist

$(OUT)/GLES1Test.app: gles1/main.m gles1/Info.plist
	@mkdir -p $@
	$(CC) $(CFLAGS) -fno-objc-arc -o $@/GLES1Test gles1/main.m -framework UIKit -framework Foundation \
		-framework OpenGLES -framework QuartzCore
	cp gles1/Info.plist $@/Info.plist

endif

clean:
	rm -rf $(OUT)
