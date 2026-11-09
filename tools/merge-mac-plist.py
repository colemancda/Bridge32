#!/usr/bin/env python3
"""Writes the Info.plist for a wrapped Mac app: the guest's own keys (bundle id,
name, NSMainNibFile, NSPrincipalClass, document types) with the shell's
executable and the keys that describe the original binary replaced.

usage: merge-mac-plist.py GUEST_INFO_PLIST SHELL_INFO_PLIST OUT_INFO_PLIST [GUEST_EXECUTABLE]

GUEST_EXECUTABLE overrides the guest's CFBundleExecutable, for launcher scripts.
"""
import plistlib
import sys

# Keys about the original binary or the systems it ran on.
DROP = {
    "LSMinimumSystemVersion", "LSMinimumSystemVersionByArchitecture", "LSArchitecturePriority", "LSRequiresCarbon",
    "LSRequiresNativeExecution", "NSJavaNeeded", "NSJavaPath", "NSJavaRoot", "DTPlatformBuild", "DTPlatformVersion",
    "DTSDKBuild", "DTSDKName", "DTCompiler", "DTXcode", "DTXcodeBuild", "BuildMachineOSBuild",
}
FROM_SHELL = {"CFBundleExecutable", "NSRequiresAquaSystemAppearance"}


def main():
    guest_path, shell_path, out_path = sys.argv[1:4]
    with open(guest_path, "rb") as f:
        guest = plistlib.load(f)
    with open(shell_path, "rb") as f:
        shell = plistlib.load(f)
    merged = {k: v for k, v in guest.items() if k not in DROP}
    merged["B32GuestExecutable"] = sys.argv[4] if len(sys.argv) > 4 else guest["CFBundleExecutable"]
    if "LSMinimumSystemVersion" in guest:
        merged["B32GuestSDKVersion"] = guest["LSMinimumSystemVersion"]
    merged.update({k: shell[k] for k in FROM_SHELL if k in shell})
    merged.setdefault("NSPrincipalClass", "NSApplication")
    with open(out_path, "wb") as f:
        plistlib.dump(merged, f)


if __name__ == "__main__":
    main()
