#!/bin/sh
# Wraps a decrypted 32-bit iOS app (.app directory or .ipa) into a Mac
# Catalyst app that runs it through Bridge32.
#
#   tools/make-app.sh [--orientation landscape-right|landscape-left|portrait] [--guest-libs DIR] Game.ipa [Out.app]
#
# --guest-libs (or $B32_GUEST_LIBS) names a folder of armv6/armv7 builds of
# libstdc++ and libgcc_s, such as an old iPhoneOS SDK's /usr/lib; they're
# copied into the app and run as guest code for games written in C++.
#
# The guest's files go in Out.app/Contents/Resources, so the game's
# NSBundle mainBundle, nibs and resources resolve as on the device.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
shell_app="${B32_SHELL_APP:-$root/build/catalyst/Bridge32.app}"
orientation=""
guest_libs="${B32_GUEST_LIBS:-}"
while :; do
    case "${1:-}" in
    --orientation) orientation=$2; shift 2 ;;
    --guest-libs) guest_libs=$2; shift 2 ;;
    *) break ;;
    esac
done
input=$1

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

if [ -n "$guest_libs" ]; then
    mkdir -p "$resources/B32GuestLibraries"
    for lib in "$guest_libs"/libstdc++*.dylib "$guest_libs"/libgcc_s*.dylib; do
        [ -f "$lib" ] && cp "$lib" "$resources/B32GuestLibraries/"
    done
fi

python3 -I "$here/merge-plist.py" "$guest/Info.plist" "$root/app/Info.plist" "$out/Contents/Info.plist" "$(basename "$guest")" $orientation

codesign --force --sign - --entitlements "$root/app/Bridge32.entitlements" "$out"
echo "$out"
