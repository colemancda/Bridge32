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
  - date: 2026-11-09
    bridge32: "51053dba"
    pr: 4
    guest: i386
    level: 3
    source: pr
    notes: Reaches its menus after loading in 86 seconds. No match has been played.
---

This is the Steam build. It runs through its own i386 `libsteam_api`, which reports no 32-bit
Steam client, so Steam features don't connect.
