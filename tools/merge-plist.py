#!/usr/bin/env python3
"""Writes the Info.plist for a wrapped game: the guest's own keys (bundle id,
name, NSMainNibFile, ...) with the shell's platform keys on top.

usage: merge-plist.py GUEST_INFO_PLIST SHELL_INFO_PLIST OUT_INFO_PLIST [GUEST_BUNDLE_NAME [ORIENTATION]]

ORIENTATION (portrait, landscape-left, landscape-right) turns the guest's
screen on the Mac, for games that draw landscape without declaring it.
"""
import plistlib
import sys

# iOS-only keys that would confuse the Mac or describe the original binary.
DROP = {
    "MinimumOSVersion", "UIRequiredDeviceCapabilities", "DTPlatformName", "DTPlatformVersion",
    "DTPlatformBuild", "DTSDKName", "DTSDKBuild", "DTXcode", "DTXcodeBuild", "DTCompiler",
    "BuildMachineOSBuild", "SignerIdentity", "CFBundleResourceSpecification", "LSRequiresIPhoneOS",
    "UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad",
}
# Shell keys that always win: the host executable and platform.
FROM_SHELL = {
    "CFBundleExecutable", "CFBundleSupportedPlatforms", "LSMinimumSystemVersion", "UIDeviceFamily",
    "UIApplicationSupportsIndirectInputEvents", "CFBundlePackageType", "UIApplicationSceneManifest",
}


def main():
    guest_path, shell_path, out_path = sys.argv[1:4]
    bundle_name = sys.argv[4] if len(sys.argv) > 4 else None
    orientation = sys.argv[5] if len(sys.argv) > 5 else None
    with open(guest_path, "rb") as f:
        guest = plistlib.load(f)
    with open(shell_path, "rb") as f:
        shell = plistlib.load(f)

    merged = {k: v for k, v in guest.items() if k not in DROP}
    for key in FROM_SHELL:
        if key in shell:
            merged[key] = shell[key]
    merged["B32GuestExecutable"] = guest["CFBundleExecutable"]
    # The shell's UIDeviceFamily wins for the Mac; keep the guest's (iPhone,
    # iPad or both) for choosing the device the guest sees.
    merged["B32GuestDeviceFamily"] = guest.get("UIDeviceFamily", [1])
    # The SDK the guest was built with (or, failing that, the oldest iOS it
    # runs on): from iOS 8 the screen's bounds follow the orientation.
    sdk = guest.get("DTPlatformVersion") or guest.get("DTSDKName", "").replace("iphoneos", "") \
        or guest.get("MinimumOSVersion")
    if sdk:
        merged["B32GuestSDKVersion"] = str(sdk)
    # The guest bundle's directory name, recreated next to Documents/ in the
    # container the way iOS lays out an app's sandbox.
    if bundle_name:
        merged["B32GuestBundleName"] = bundle_name
    if orientation:
        names = {"portrait": "UIInterfaceOrientationPortrait",
                 "landscape-left": "UIInterfaceOrientationLandscapeLeft",
                 "landscape-right": "UIInterfaceOrientationLandscapeRight"}
        merged["B32Orientation"] = names[orientation]
    elif "UIInterfaceOrientation" not in guest:
        # Newer games only list the orientations they support; one that
        # supports no portrait orientation starts in the first one listed.
        ipad_only = merged["B32GuestDeviceFamily"] == [2]
        supported = (guest.get("UISupportedInterfaceOrientations~ipad" if ipad_only else
                               "UISupportedInterfaceOrientations~iphone")
                     or guest.get("UISupportedInterfaceOrientations") or [])
        if supported and not any("Portrait" in o for o in supported):
            merged["B32Orientation"] = supported[0]
    # Apps from before iOS 13 never saw dark mode: they set light backgrounds
    # and leave text in the default label color, which dark mode turns white.
    merged.setdefault("UIUserInterfaceStyle", "Light")
    # macOS asks why an app uses Bluetooth before CoreBluetooth works; iOS 9
    # and earlier apps only had the peripheral key, or none.
    if "NSBluetoothAlwaysUsageDescription" not in merged:
        merged["NSBluetoothAlwaysUsageDescription"] = guest.get(
            "NSBluetoothPeripheralUsageDescription", "This app uses Bluetooth to talk to nearby devices.")
    # A distinct identifier, so the wrapped game gets its own sandbox
    # container and never collides with an installed iOS app of the same id.
    merged["CFBundleIdentifier"] = guest.get("CFBundleIdentifier", "unknown") + ".bridge32"

    with open(out_path, "wb") as f:
        plistlib.dump(merged, f)


if __name__ == "__main__":
    main()
