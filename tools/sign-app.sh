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
resources="$app/Contents/Resources"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
entitlements="$work/entitlements.plist"
cp "$root/app/Bridge32.entitlements" "$entitlements"

executable=$(/usr/libexec/PlistBuddy -c "Print :B32GuestExecutable" "$app/Contents/Info.plist")
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

codesign --force --sign - --entitlements "$entitlements" "$app"
