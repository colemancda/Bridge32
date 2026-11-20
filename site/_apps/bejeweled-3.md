---
name: Bejeweled 3
platform: macos
kind: game
developer: PopCap
reports:
  - date: 2026-11-09
    bridge32: "7bd2e815"
    pr: 3
    guest: i386
    level: 2
    source: pr
    notes: Loads in about 8 minutes, drawing nothing until then, and reaches its title screen and new-player prompt.
    screenshots:
      - url: https://github.com/user-attachments/assets/f5574528-b6d4-4bb4-99b0-32fa0d68af2e
        caption: Welcome prompt over the title screen
  - date: 2026-11-09
    bridge32: "51053dba"
    pr: 4
    guest: i386
    level: 3
    source: pr
    notes: Reaches its menus after loading in 86 seconds. No match has been played.
    screenshots:
      - url: https://github.com/user-attachments/assets/4b090650-2d45-42ba-84fa-335a0901100f
        caption: Game-mode menu
---

This is the Steam build. It runs through its own i386 `libsteam_api`, which reports no 32-bit
Steam client, so Steam features don't connect.
