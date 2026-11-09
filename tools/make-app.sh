#!/bin/sh
# Wraps a decrypted 32-bit iOS app (.app directory or .ipa) into a Mac
# Catalyst app that runs it through Bridge32.
#
#   tools/make-app.sh [--orientation landscape-right|landscape-left|portrait] [--guest-libs DIR]
#                     [--controller tilt|swipe] [--fps] [--device iphone|ipad] Game.ipa [Out.app]
#
# --fps shows a frame rate counter and logs slow frames (or run with
# B32_SHOW_FPS=1).
#
# --controller maps a game controller's right stick and D-pad: "tilt" fakes
# the accelerometer (racing games), "swipe" swipes from the middle of the
# screen (maze games like PAC-MAN); see core/uikit/Controller.mm.
#
# --guest-libs (or $B32_GUEST_LIBS) names a folder of armv6/armv7 builds of
# libstdc++, libgcc_s, libc++, libc++abi and libxml2, such as an old iPhoneOS
# SDK's /usr/lib; they're copied into the app and run as guest code for the
# games that link them.
#
# The guest's files go in Out.app/Contents/Resources, so the game's
# NSBundle mainBundle, nibs and resources resolve as on the device.
#
# Given an i386 Mac app (Foo.app/Contents/...) instead, it wraps that into the
# AppKit shell (build/i386/Bridge32.app, from -DB32_MAC=ON; the options above
# don't apply): the app's Resources become the shell's, and its executable and
# Frameworks go to Contents/B32Guest with their relative layout intact.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
shell_app="${B32_SHELL_APP:-$root/build/catalyst/Bridge32.app}"
orientation=""
guest_libs="${B32_GUEST_LIBS:-}"
controller=""
device=""
fps=""
while :; do
    case "${1:-}" in
    --orientation) orientation=$2; shift 2 ;;
    --guest-libs) guest_libs=$2; shift 2 ;;
    --controller) controller=$2; shift 2 ;;
    --device) device=$2; shift 2 ;;
    --fps) fps=1; shift ;;
    *) break ;;
    esac
done
input=$1

if [ -d "$input/Contents" ]; then
    guest=${input%/}
    shell_app="${B32_MAC_SHELL_APP:-$root/build/i386/Bridge32.app}"
    [ -d "$shell_app" ] || { echo "build the AppKit shell first: cmake -S . -B build/i386 -DB32_GUEST_ARCH=i386 -DB32_MAC=ON" >&2; exit 1; }
    executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$guest/Contents/Info.plist")
    # A launcher script (TowerFall's starts a Mono kickstart binary) isn't what
    # runs: its i386 Mach-O beside it is, from the same folder.
    chdir_flag=""
    if ! lipo -archs "$guest/Contents/MacOS/$executable" 2>/dev/null | grep -qw i386; then
        for candidate in "$guest"/Contents/MacOS/*; do
            [ -f "$candidate" ] && lipo -archs "$candidate" 2>/dev/null | grep -qw i386 || continue
            executable=$(basename "$candidate")
            chdir_flag=1
            break
        done
    fi
    name=$(basename "$guest" .app)
    out=${2:-$root/build/apps/$name.app}
    mkdir -p "$(dirname "$out")"
    rm -rf "$out"
    cp -R "$shell_app" "$out"
    mkdir -p "$out/Contents/B32Guest/MacOS" "$out/Contents/Resources"
    # Clones where the disk can: guests are often gigabytes.
    clone() { cp -cR "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; }
    clone "$guest/Contents/MacOS/." "$out/Contents/B32Guest/MacOS/"
    [ -d "$guest/Contents/Resources" ] && clone "$guest/Contents/Resources/." "$out/Contents/Resources/"
    [ -d "$guest/Contents/Frameworks" ] && clone "$guest/Contents/Frameworks" "$out/Contents/B32Guest/Frameworks"
    python3 -I "$here/merge-mac-plist.py" "$guest/Contents/Info.plist" "$root/app/mac/Info.plist" "$out/Contents/Info.plist" "$executable"
    [ -n "$chdir_flag" ] && /usr/libexec/PlistBuddy -c "Add :B32GuestChdir bool true" "$out/Contents/Info.plist"
    # Resource forks go alongside as plain files, since signing can't take them.
    (cd "$guest/Contents" && find . -type f -xattrname com.apple.ResourceFork) | while IFS= read -r file; do
        relative=${file#./}
        mkdir -p "$out/Contents/B32Guest/Forks/$(dirname "$relative")"
        cat "$guest/Contents/$relative/..namedfork/rsrc" > "$out/Contents/B32Guest/Forks/$relative"
    done
    # codesign refuses a bundle with extended attributes, which old apps have.
    xattr -cr "$out"
    codesign --force --sign - "$out"
    # Re-wrapping leaves LaunchServices remembering the old signature.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$out"
    echo "$out"
    exit 0
fi

[ -d "$shell_app" ] || { echo "build the Catalyst shell first: cmake --build build/catalyst" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

case "$input" in
*.ipa)
    unzip -q "$input" -d "$work/ipa"
    guest=$(ls -d "$work"/ipa/Payload/*.app | head -1)
    ;;
*)
    guest=$input
    ;;
esac
[ -f "$guest/Info.plist" ] || { echo "$input has no Info.plist" >&2; exit 1; }

name=$(basename "$guest" .app)
out=${2:-$root/build/apps/$name.app}
mkdir -p "$(dirname "$out")"
rm -rf "$out"
cp -R "$shell_app" "$out"

# Guest files, minus its iOS signature and FairPlay leftovers.
resources="$out/Contents/Resources"
mkdir -p "$resources"
(cd "$guest" && tar cf - --exclude _CodeSignature --exclude SC_Info --exclude embedded.mobileprovision \
    --exclude CodeResources --exclude ResourceRules.plist .) | (cd "$resources" && tar xf -)

# Nibs compiled for iOS 7 and 8 are folders of objects-<version>+.nib and
# runtime.nib; today's UIKit reads keyedobjects.nib from such a folder. The
# newest of the old archives goes in under that name.
find "$resources" -type d -name '*.nib' | while IFS= read -r nib; do
    [ -f "$nib/keyedobjects.nib" ] && continue
    archive=$(ls "$nib"/objects-*.nib 2>/dev/null | sort -t- -k2 -V | tail -1)
    [ -n "$archive" ] || archive="$nib/runtime.nib"
    [ -f "$archive" ] && cp "$archive" "$nib/keyedobjects.nib"
done

if [ -n "$guest_libs" ]; then
    mkdir -p "$resources/B32GuestLibraries"
    for lib in "$guest_libs"/libstdc++*.dylib "$guest_libs"/libgcc_s*.dylib "$guest_libs"/libxml2*.dylib \
               "$guest_libs"/libc++*.dylib; do
        [ -f "$lib" ] && cp "$lib" "$resources/B32GuestLibraries/"
    done
fi

python3 -I "$here/merge-plist.py" "$guest/Info.plist" "$root/app/Info.plist" "$out/Contents/Info.plist" "$(basename "$guest")" $orientation

# The device the guest sees, when its UIDeviceFamily says otherwise (iPad
# builds relabelled for iPhone).
case "$device" in
iphone) family=1 ;;
ipad) family=2 ;;
"") family="" ;;
*) echo "--device is iphone or ipad" >&2; exit 1 ;;
esac
if [ -n "$family" ]; then
    /usr/libexec/PlistBuddy -c "Delete :B32GuestDeviceFamily" -c "Add :B32GuestDeviceFamily array" \
        -c "Add :B32GuestDeviceFamily:0 integer $family" "$out/Contents/Info.plist"
fi

[ -n "$controller" ] && /usr/libexec/PlistBuddy -c "Add :B32Controller string $controller" "$out/Contents/Info.plist"
[ -n "$fps" ] && /usr/libexec/PlistBuddy -c "Add :B32ShowFPS bool true" "$out/Contents/Info.plist"

"$here/sign-app.sh" "$out"
echo "$out"
