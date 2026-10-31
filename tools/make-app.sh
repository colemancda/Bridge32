#!/bin/sh
# Wraps a decrypted 32-bit iOS app (.app directory or .ipa) into a Mac
# Catalyst app that runs it through Bridge32.
#
#   tools/make-app.sh [--orientation landscape-right|landscape-left|portrait] Game.ipa [Out.app]
#
# The guest's files go in Out.app/Contents/Resources, so the game's
# NSBundle mainBundle, nibs and resources resolve as on the device.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
shell_app="${B32_SHELL_APP:-$root/build/catalyst/Bridge32.app}"
orientation=""
if [ "${1:-}" = "--orientation" ]; then
    orientation=$2
    shift 2
fi
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

python3 -I "$here/merge-plist.py" "$guest/Info.plist" "$root/app/Info.plist" "$out/Contents/Info.plist" "$(basename "$guest")" $orientation

codesign --force --sign - --entitlements "$root/app/Bridge32.entitlements" "$out"
echo "$out"
