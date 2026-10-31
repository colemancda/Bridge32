#!/usr/bin/env python3
"""Writes the Info.plist for a wrapped game: the guest's own keys (bundle id,
name, NSMainNibFile, ...) with the shell's platform keys on top.

usage: merge-plist.py GUEST_INFO_PLIST SHELL_INFO_PLIST OUT_INFO_PLIST
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
    with open(guest_path, "rb") as f:
        guest = plistlib.load(f)
    with open(shell_path, "rb") as f:
        shell = plistlib.load(f)

    merged = {k: v for k, v in guest.items() if k not in DROP}
    for key in FROM_SHELL:
        if key in shell:
            merged[key] = shell[key]
    merged["B32GuestExecutable"] = guest["CFBundleExecutable"]
    # A distinct identifier, so the wrapped game gets its own sandbox
    # container and never collides with an installed iOS app of the same id.
    merged["CFBundleIdentifier"] = guest.get("CFBundleIdentifier", "unknown") + ".bridge32"

    with open(out_path, "wb") as f:
        plistlib.dump(merged, f)


if __name__ == "__main__":
    main()
