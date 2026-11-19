#!/bin/sh
# Installs Xcode 3's developer tools into a wrapped Xcode 3, from the Packages folder of the
# Xcode Tools installer (Xcode 3.1.4's, for one):
#
#   tools/install-xcode3-tools.sh "build/apps/Xcode 3.app" "/Volumes/Xcode Tools/Packages"
#
# Xcode takes its Developer folder to be the wrapper's Contents, three folders above
# DevToolsFoundation, as /Developer is on a Mac with the tools installed. This puts there what it
# looks for in that folder:
#   SDKs/MacOSX10.5.sdk     the base SDK (MacOSX10.5.pkg); without it the Overview reads "Missing"
#   usr                     gcc 4.0, as, ld and the other command-line tools (gcc4.0.pkg and
#                           DeveloperToolsCLI.pkg), which Xcode runs to build and to index
#   Library/Xcode, Platforms
#                           specifications, templates and the Mac OS X platform (DeveloperTools.pkg)
# The tools are i386 and PowerPC programs; Xcode starts them through Bridge32 as it starts anything.
set -eu

app=$1
packages=$2
developer="$app/Contents"
[ -d "$developer/B32Guest" ] || { echo "$app isn't a wrapped Mac app" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Unpacks a flat package's payload into $work/<name>.
unpack() {
    pkgutil --expand "$packages/$1.pkg" "$work/$1.pkg"
    ditto -x -z "$work/$1.pkg/Payload" "$work/$1"
}

# Copies $work/<package>/<item> to the Developer folder, merging with what's there (APFS clones
# where it can).
install_item() {
    mkdir -p "$developer/$(dirname "$2")"
    cp -cR "$work/$1/$2" "$developer/$(dirname "$2")/" 2>/dev/null || cp -R "$work/$1/$2" "$developer/$(dirname "$2")/"
}

unpack MacOSX10.5
install_item MacOSX10.5 SDKs
unpack gcc4.0
install_item gcc4.0 usr
unpack DeveloperToolsCLI
install_item DeveloperToolsCLI usr
unpack DeveloperTools
install_item DeveloperTools Library/Xcode
install_item DeveloperTools Platforms

codesign --force --sign - "$app"
echo "Installed the SDK and tools in $developer"
