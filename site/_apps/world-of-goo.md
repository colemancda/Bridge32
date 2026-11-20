---
name: World of Goo
platform: macos
kind: game
reports:
  - date: 2026-11-18
    bridge32: "4ebc3106"
    pr: 7
    guest: ppc
    app_version: "1.30"
    level: 2
    source: pr
    notes: Gets through loading to its title screen and takes mouse input, at about 50 frames per second.
  - date: 2026-11-18
    bridge32: "d3479a33"
    pr: 8
    guest: ppc
    level: 4
    source: pr
    notes: Plays into the first level full screen, with mouse input and typing a name.
---

It runs full screen; `B32Windowed` or `B32_WINDOWED=1` gives it an ordinary window instead.
