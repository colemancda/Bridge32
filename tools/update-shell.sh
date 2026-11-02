#!/bin/sh
# Puts the freshly built shell into already-wrapped apps and re-signs them,
# without copying their game files again.
#
#   tools/update-shell.sh build/apps/Game.app [...]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
shell="${B32_SHELL_APP:-$root/build/catalyst/Bridge32.app}/Contents/MacOS/Bridge32"
for app in "$@"; do
    cp "$shell" "$app/Contents/MacOS/Bridge32"
    "$here/sign-app.sh" "$app"
done
