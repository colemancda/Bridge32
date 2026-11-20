---
name: Doom 3
platform: macos
kind: game
reports:
  - date: 2026-11-19
    bridge32: "90a4c219"
    pr: 19
    guest: i386
    app_version: "1.3.1"
    level: 3
    source: pr
    notes: Loads its game library and draws its main menu in a window, where it asks for its CD key. Input and play aren't tried.
    screenshots:
      - url: https://github.com/user-attachments/assets/d30d0caa-e04f-42de-b251-5365fe4b750a
        caption: Main menu with the CD key prompt
  - date: 2026-11-19
    bridge32: "bdd49f36"
    pr: 20
    guest: i386
    level: 3
    source: pr
    notes: Stays at its main menu with mouse deltas, and sees 1024 MB of video memory. A level isn't tried, as it waits for its CD key.
---

- The wrapped app looks for `base` beside itself: put the game's `base` folder, or a link to it,
  next to the wrapped `Doom 3.app`.
- `glMapBufferARB` still returns NULL.
