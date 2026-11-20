---
name: Xcode 3
platform: macos
kind: app
developer: Apple
reports:
  - date: 2026-11-19
    bridge32: "9b7b109d"
    pr: 12
    guest: i386
    app_version: "3.1.4"
    level: 2
    source: pr
    notes: Runs to its event loop with its own menu bar. Opening a file fails at the editor's nib.
  - date: 2026-11-19
    bridge32: "71f36d10"
    pr: 13
    guest: i386
    app_version: "3.1.4"
    level: 3
    source: pr
    notes: Opens a source file into its editor window, but the file's text doesn't draw.
    screenshots:
      - url: https://github.com/user-attachments/assets/cf0124de-dfb3-43ee-940b-8a17dc717c11
        caption: Editor window with hello.c, before its text drew
  - date: 2026-11-19
    bridge32: "23c4ecb0"
    pr: 14
    guest: i386
    app_version: "3.1.4"
    level: 3
    source: pr
    notes: Opens a project into its project window and a source file with syntax coloring, then stops on private AppKit calls and a segfault.
    screenshots:
      - url: https://github.com/user-attachments/assets/68b98dd9-387b-41cf-abe5-9cc1edd58284
        caption: Editor with hello.c in syntax colors
      - url: https://github.com/user-attachments/assets/0cb23313-b55e-4769-adb3-75c0f903cf0f
        caption: Project window for the Standard Tool template
  - date: 2026-11-19
    bridge32: "0a901747"
    pr: 15
    guest: i386
    level: 3
    source: pr
    notes: Shows a project's source in the project window's editor and stays up without missing calls.
    screenshots:
      - url: https://github.com/user-attachments/assets/98d9a979-7e97-4879-b1b7-b1a36538311f
        caption: Hello project with main.c in its editor
  - date: 2026-11-19
    bridge32: "bf33b88a"
    pr: 17
    guest: i386
    app_version: "3.1.4"
    level: 3
    source: pr
    notes: Its gcc 4.0, as and ld build an Objective-C hello world that runs. Building from Xcode's own window isn't done.
  - date: 2026-11-19
    bridge32: "3aba8cdb"
    pr: 18
    guest: i386
    level: 3
    source: pr
    notes: Finds the Mac OS X 10.5 base SDK, and opens the Hello project and main.c with no missing calls.
    screenshots:
      - url: https://github.com/user-attachments/assets/94dd4884-1e95-4e0c-9ae2-a0ef7fbd1a82
        caption: Overview showing the 10.5 base SDK
---

Xcode takes the wrapped app's `Contents` for its Developer folder. To give it the base SDK and
command-line tools, install them there from the Packages folder of the Xcode Tools installer:

```sh
tools/install-xcode3-tools.sh "build/apps/Xcode 3.app" "/Volumes/Xcode Tools/Packages"
```

Its build system starts tools with `NSTask`, which doesn't run them through Bridge32 yet, so
building from its window isn't supported yet.
