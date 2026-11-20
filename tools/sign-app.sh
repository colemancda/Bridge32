#!/bin/sh
# Signs a wrapped app with the shell's entitlements, plus the ones its guest
# needs: Bluetooth only when the game or a framework it bundles links
# CoreBluetooth (the Mac asks the user for Bluetooth access otherwise).
#
#   tools/sign-app.sh build/apps/Game.app
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
app=$1
# A Catalyst app keeps its files in Contents/; an iOS one is flat.
if [ -d "$app/Contents" ]; then
    resources="$app/Contents/Resources"
    info_plist="$info_plist"
    base_entitlements="$root/app/Bridge32.entitlements"
else
    resources="$app"
    info_plist="$app/Info.plist"
    base_entitlements="$root/app/Bridge32-ios.entitlements"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
entitlements="$work/entitlements.plist"
cp "$base_entitlements" "$entitlements"

executable=$(/usr/libexec/PlistBuddy -c "Print :B32GuestExecutable" "$info_plist")
links_bluetooth=no
for binary in "$resources/$executable" "$resources"/Frameworks/*.dylib "$resources"/Frameworks/*.framework/*; do
    [ -f "$binary" ] || continue
    if otool -L "$binary" 2>/dev/null | grep -q '/CoreBluetooth.framework/'; then
        links_bluetooth=yes
        break
    fi
done
[ "$links_bluetooth" = yes ] &&
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.device.bluetooth bool true" "$entitlements"

# The simulator refuses ad hoc binaries with get-task-allow, and doesn't need it.
if /usr/libexec/PlistBuddy -c "Print :CFBundleSupportedPlatforms" "$info_plist" | grep -q iPhoneSimulator; then
    codesign --force --sign - "$app"
else
    codesign --force --sign - --entitlements "$entitlements" "$app"
fi
